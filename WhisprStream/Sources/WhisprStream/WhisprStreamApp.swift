import AppKit
import AVFoundation
import Combine
import SwiftUI

struct DeferredTranscriptDelivery: Equatable {
    let text: String
    let adjustForCursor: Bool
}

struct TranscriptDeliveryGate {
    private(set) var pending: DeferredTranscriptDelivery?

    mutating func submit(
        _ delivery: DeferredTranscriptDelivery,
        whileContextIsResolving: Bool
    ) -> DeferredTranscriptDelivery? {
        guard whileContextIsResolving else {
            pending = nil
            return delivery
        }
        pending = delivery
        return nil
    }

    mutating func takePending() -> DeferredTranscriptDelivery? {
        defer { pending = nil }
        return pending
    }

    mutating func reset() {
        pending = nil
    }
}

/// A resident model can remain logically loaded while macOS pages its memory
/// out. Treat readiness as a lease so the first dictation after a long idle
/// pays any restoration cost in the explicit warm-up UI, not after recording.
struct SpeechEngineWarmupGate {
    static let idleInterval: TimeInterval = 5 * 60

    private(set) var lastActivityAt: Date?

    mutating func markActivity(at date: Date = Date()) {
        lastActivityAt = date
    }

    mutating func reset() {
        lastActivityAt = nil
    }

    func requiresWarmup(
        at date: Date = Date(),
        idleInterval: TimeInterval = Self.idleInterval
    ) -> Bool {
        guard let lastActivityAt else { return false }
        return date.timeIntervalSince(lastActivityAt) >= idleInterval
    }
}

@main
enum Main {
    static func main() {
        if TriggerShortcutE2E.isRequested {
            TriggerShortcutE2E.run()
            return
        }

        if ContextAwareCapitalizationE2E.isRequested {
            ContextAwareCapitalizationE2E.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        app.run()
    }
}

private final class StatusUpdateDotView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: bounds).fill()

        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let speechEngineStartupTimeout: TimeInterval = 20

    private let state = AppState()
    private lazy var settings = Settings.shared
    private let windows = AppWindows()
    private let runtime = RuntimeManager.shared
    private let updates = AppUpdateManager()
    private let updatePromptPolicy = AppUpdatePromptPolicy()

    private var panel: HUDPanel!
    private var statusItem: NSStatusItem!
    private var statusUpdateDot: StatusUpdateDotView?
    private var updateStatusObservation: AnyCancellable?
    private var periodicUpdateTimer: Timer?
    private var initialUpdateCheckWork: DispatchWorkItem?
    private let capture = AudioCapture()
    private var hotkey: HotKeyMonitor!
    private var asr: ASRService!
    private var dismissWork: DispatchWorkItem?
    private var isASRReady = false
    private var isRewarmingSpeechEngine = false
    private var speechEngineWarmupGate = SpeechEngineWarmupGate()
    private var speechEngineGeneration = 0
    private var speechEngineStartedAt: TimeInterval?
    private var speechEngineStartupWork: DispatchWorkItem?
    private var shouldShowFirstDictationCoach = false
    private var precedingTextAtDictationStart: String?
    private var resolvedPrecedingText: String?
    private var hasResolvedPrecedingText = false
    private var isResolvingPrecedingText = false
    private var transcriptDeliveryGate = TranscriptDeliveryGate()
    private var cursorContextGeneration = 0
    private var activeCursorContextGeneration: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The updater retains its rollback copy until this process proves that
        // AppKit reached the application delegate and stays alive briefly.
        UpdateLaunchHealth.signalIfRequested()
        mergeCrossBuildContentIfNeeded()
        panel = HUDPanel(state: state)
        state.onDictationLimitReached = { [weak self] in
            guard let self else { return }
            self.hotkey.cancelActiveDictation()
            self.endDictation()
        }
        setUpStatusItem()
        setUpUpdateMonitoring()

        let trusted = AXIsProcessTrusted()
        Log.write("launch: accessibility=\(trusted ? "granted" : "DENIED") "
                  + "onboarded=\(settings.hasCompletedOnboarding) "
                  + "coachPending=\(settings.needsFirstDictationCoach) "
                  + "developerTestMode=\(DeveloperTestMode.isEnabled)")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openDeveloperTestSetup),
            name: .whisprDeveloperTestModeActivated,
            object: nil
        )

        if runtime.isReady, ModelCatalog.state(for: settings.model).isInstalled {
            if settings.hasCompletedOnboarding {
                queueFirstDictationCoachIfNeeded()
            }
            startSpeechEngine()
            if settings.hasCompletedOnboarding {
                // Onboarding requests these itself; only prompt directly when skipped.
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    Task { @MainActor in self?.presentFirstDictationCoachIfReady() }
                }
                if !trusted { HotKeyMonitor.ensureAccessibility() }
            } else {
                showOnboarding()
            }
        } else {
            presentSetup()
        }

        if settings.hasCompletedOnboarding {
            scheduleInitialUpdateCheck()
        }
    }

    private func mergeCrossBuildContentIfNeeded() {
        do {
            guard let pending = try LegacyPreferencesMigration.pendingPlan() else { return }
            LegacyPreferencesMigration.apply(pending)
            let summary = pending.summary
            Log.write(
                "cross-build content merge completed: "
                    + "vocabularyAdded=\(summary.vocabularyAdded) "
                    + "shortcutsAdded=\(summary.shortcutsAdded) "
                    + "shortcutConflictsSkipped=\(summary.shortcutConflictsSkipped) "
                    + "invalidShortcutsSkipped=\(summary.invalidShortcutsSkipped)"
            )
        } catch {
            // A malformed counterpart must never overwrite the current domain.
            Log.write("cross-build content merge failed: \(error)")
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from System Settings is the only reliable signal that an
        // Accessibility grant may have changed. A pending coach survives the
        // permission-skip path and is retried here.
        presentFirstDictationCoachIfReady()
        refreshStatusMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .whisprDeveloperTestModeActivated, object: nil)
        initialUpdateCheckWork?.cancel()
        periodicUpdateTimer?.invalidate()
        updateStatusObservation?.cancel()
        hotkey?.stop()
        speechEngineStartupWork?.cancel()
        asr?.shutdown()
    }

    // MARK: - Wiring

    private func presentSetup() {
        showOnboarding()
    }

    private func showOnboarding() {
        windows.showOnboarding(
            settings: settings,
            runtime: runtime,
            onPrerequisitesReady: { [weak self] in self?.startSpeechEngine() }
        ) { [weak self] in
            guard let self else { return }
            self.settings.hasCompletedOnboarding = true
            self.startSpeechEngine()
            self.queueFirstDictationCoachIfNeeded()
            self.scheduleInitialUpdateCheck()
        }
    }

    // MARK: - App updates

    private func setUpUpdateMonitoring() {
        updateStatusObservation = updates.$status
            .removeDuplicates()
            .sink { [weak self] status in
                self?.handleUpdateStatus(status)
            }

        periodicUpdateTimer = Timer.scheduledTimer(
            withTimeInterval: 6 * 60 * 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdatesIfAppropriate() }
        }
    }

    private func scheduleInitialUpdateCheck() {
        initialUpdateCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.checkForUpdatesIfAppropriate()
        }
        initialUpdateCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func checkForUpdatesIfAppropriate() {
        guard settings.hasCompletedOnboarding else { return }
        switch updates.status {
        case .idle, .upToDate, .failed:
            updates.checkForUpdates()
        case .checking, .available, .downloading, .installing:
            break
        }
    }

    private func handleUpdateStatus(_ status: AppUpdateManager.Status) {
        // `@Published` delivers from `willSet`, so `updates.status` still holds
        // the previous value while this callback is running. Use the emitted
        // value directly to keep the badge and menu in sync on the first frame.
        refreshStatusMenu(using: status)
        guard settings.hasCompletedOnboarding,
              case let .available(release) = status,
              updatePromptPolicy.shouldPresent(version: release.version)
        else { return }

        updatePromptPolicy.markPresented(version: release.version)
        windows.showUpdatePrompt(updates: updates)
    }

    private func queueFirstDictationCoachIfNeeded() {
        guard FirstDictationCoachPolicy.shouldOffer(
            needsFirstDictationCoach: settings.needsFirstDictationCoach,
            isDeveloperFirstRunSimulation: DeveloperTestMode.isEnabled
        ) else { return }
        shouldShowFirstDictationCoach = true
        presentFirstDictationCoachIfReady()
    }

    private func presentFirstDictationCoachIfReady() {
        guard FirstDictationCoachPolicy.shouldPresent(
            isQueued: shouldShowFirstDictationCoach,
            isSpeechEngineReady: isASRReady,
            hasMicrophonePermission: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            hasAccessibilityPermission: AXIsProcessTrusted()
        ) else { return }
        markFirstDictationCoachHandled()
        windows.showFirstDictationCoach(
            shortcut: settings.triggerShortcut,
            mode: settings.activationMode
        )
    }

    private func markFirstDictationCoachHandled() {
        shouldShowFirstDictationCoach = false
        settings.needsFirstDictationCoach = false
    }

    private func startSpeechEngine() {
        guard asr == nil else { return }
        isASRReady = false
        isRewarmingSpeechEngine = false
        speechEngineWarmupGate.reset()
        state.phase = .loading
        do {
            try launchSpeechEngine()
        } catch {
            state.phase = .failed("Could not start the ASR engine")
            panel.present()
            return
        }

        hotkey = HotKeyMonitor(
            shortcut: settings.triggerShortcut,
            mode: settings.activationMode
        )
        hotkey.onStart = { [weak self] in
            guard let self, self.beginDictation() else { return false }
            if self.shouldShowFirstDictationCoach {
                self.markFirstDictationCoachHandled()
            }
            self.windows.dismissFirstDictationCoach()
            return true
        }
        hotkey.onStop = { [weak self] in self?.endDictation() }
        settings.onHotKeyConfigurationChange = { [weak self] in
            guard let self else { return }
            self.hotkey.rebind(
                shortcut: self.settings.triggerShortcut,
                mode: self.settings.activationMode
            )
            self.refreshStatusMenu()
        }
        settings.onTriggerShortcutCaptureChange = { [weak self] capturing in
            guard let hotkey = self?.hotkey else { return }
            hotkey.setSuspendedForShortcutCapture(capturing)
        }
        hotkey.setSuspendedForShortcutCapture(settings.isCapturingTriggerShortcut)
        settings.onContextChange = { [weak self] terms in self?.asr?.setContext(terms) }
        settings.onModelChange = { [weak self] _ in self?.reloadASR() }
        settings.onShortUtteranceLanguageChange = { [weak self] _ in self?.reloadASR() }
        capture.onBuffer = { [weak self] pcm, level in
            self?.asr?.sendAudio(pcm)
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.level = self.state.level * 0.55 + CGFloat(level) * 0.45
            }
        }
        capture.onFailure = { [weak self] error in
            guard let self, self.state.phase == .listening else { return }
            self.state.stopDictationTimer()
            self.state.level = 0
            self.state.phase = .failed("Microphone unavailable")
            self.asr.stopUtterance()
            Log.write("microphone capture stopped: \(error.localizedDescription)")
            self.scheduleDismiss(after: 1.8)
        }
        refreshStatusMenu()
    }

    private func launchSpeechEngine() throws {
        speechEngineGeneration &+= 1
        let generation = speechEngineGeneration
        let service = try makeService()
        service.onEvent = { [weak self] event in
            guard let self, self.speechEngineGeneration == generation else { return }
            self.handle(event)
        }
        speechEngineStartedAt = ProcessInfo.processInfo.systemUptime
        try service.start()
        asr = service
        armSpeechEngineStartupTimeout(generation: generation)
    }

    private func armSpeechEngineStartupTimeout(generation: Int) {
        speechEngineStartupWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.speechEngineGeneration == generation,
                  !self.isASRReady else { return }
            let operation = self.isRewarmingSpeechEngine ? "warm-up" : "startup"
            Log.write("speech engine \(operation) timed out after \(Int(Self.speechEngineStartupTimeout))s")
            self.settings.isReloadingModel = false
            self.speechEngineGeneration &+= 1
            self.asr?.shutdown()
            self.asr = nil
            self.isRewarmingSpeechEngine = false
            self.speechEngineWarmupGate.reset()
            self.state.phase = .failed("Speech engine took too long to \(operation == "warm-up" ? "warm up" : "start")")
            self.panel.present()
            self.refreshStatusMenu()
        }
        speechEngineStartupWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.speechEngineStartupTimeout,
            execute: work
        )
    }

    private func makeService() throws -> ASRService {
        let root = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
        let script = root.appendingPathComponent("asr_server.py")

        let env = ProcessInfo.processInfo.environment
        guard let python = runtime.executableURL else {
            Log.write("no managed Python runtime")
            throw CocoaError(.fileNoSuchFile)
        }

        let selectedModel = settings.model.isBuiltIn ? settings.model : .small
        let model: String
        let engine: ASREngine
        let bits: Int
        if FeatureFlags.optionalModelsEnabled {
            model = env["WHISPR_MODEL"] ?? selectedModel.rawValue
            engine = ASREngine(rawValue: env["WHISPR_ENGINE"] ?? "")
                ?? selectedModel.engine
            bits = Int(env["WHISPR_BITS"] ?? "8") ?? 8
        } else {
            // Release builds ignore developer overrides as well as old custom
            // selections, keeping the public runtime on its pinned Qwen path.
            model = selectedModel.rawValue
            engine = .qwen3
            bits = 8
        }

        return ASRService(
            python: python,
            script: script,
            model: model,
            engine: engine,
            bits: bits,
            context: settings.asrContext,
            shortUtteranceLanguage: settings.shortUtteranceLanguage
        )
    }

    /// Restarts the sidecar on the currently selected model.
    ///
    /// The weights load once at sidecar start, so a model switch cannot be
    /// applied to the running process the way the vocabulary can — the whole
    /// sidecar has to come down and pay the load again.
    private func reloadASR() {
        // Deliberately does not drive the HUD's `.loading` phase: the user is in
        // Settings, not dictating, and racing a phase change against the dismiss
        // animation is what makes the capsule flicker. Progress is reported in
        // the Settings window instead.
        if state.phase == .listening {
            capture.stop()
            state.stopDictationTimer()
            state.level = 0
            dismissNow()
        }

        speechEngineStartupWork?.cancel()
        speechEngineGeneration &+= 1
        isASRReady = false
        isRewarmingSpeechEngine = false
        speechEngineWarmupGate.reset()
        speechEngineStartedAt = nil
        asr?.shutdown()
        asr = nil
        settings.isReloadingModel = true

        do {
            try launchSpeechEngine()
        } catch {
            settings.isReloadingModel = false
            state.phase = .failed("Could not start the ASR engine")
            panel.present()
            scheduleDismiss(after: 2.0)
        }
        refreshStatusMenu()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "WhisprStream"
        )
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly

        let dot = StatusUpdateDotView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setAccessibilityElement(false)
        button.addSubview(dot, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: 5),
            dot.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: 5),
        ])
        statusUpdateDot = dot
        refreshStatusMenu()
    }

    private func refreshStatusMenu(using emittedStatus: AppUpdateManager.Status? = nil) {
        let updateStatus = emittedStatus ?? updates.status
        let menu = NSMenu()
        let showsUpdateDot = updateStatus.showsUpdateAttention
        updateStatusButtonBadge(isVisible: showsUpdateDot)

        switch updateStatus {
        case .available:
            statusItem.button?.toolTip = "WhisprStream — update available"
        case .downloading, .installing:
            statusItem.button?.toolTip = "WhisprStream — installing update"
        case .idle, .checking, .upToDate, .failed:
            statusItem.button?.toolTip = "WhisprStream"
        }

        let verb = settings.activationMode == .hold ? "Hold" : "Tap"
        let hintTitle: String
        if isASRReady {
            hintTitle = "\(verb) \(settings.triggerShortcut.compactDisplay) to dictate"
        } else if asr != nil {
            hintTitle = "Speech engine warming up…"
        } else {
            hintTitle = "Speech engine unavailable"
        }
        let hint = NSMenuItem(
            title: hintTitle,
            action: nil, keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)

        switch updateStatus {
        case let .available(release):
            menu.addItem(.separator())
            let updateItem = menu.addItem(
                withTitle: "Update WhisprStream to \(release.version)…",
                action: #selector(openUpdatePrompt),
                keyEquivalent: ""
            )
            updateItem.image = NSImage(
                systemSymbolName: "arrow.down.circle.fill",
                accessibilityDescription: "Update available"
            )
            updateItem.target = self
        case let .downloading(release):
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: "Downloading WhisprStream \(release.version)…",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        case let .installing(release):
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: "Installing WhisprStream \(release.version)…",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        case .idle, .checking, .upToDate, .failed:
            break
        }

        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Setup Guide…", action: #selector(openOnboarding), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "About WhisprStream", action: #selector(openAbout), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit WhisprStream",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem.menu = menu
    }

    private func updateStatusButtonBadge(isVisible: Bool) {
        statusUpdateDot?.isHidden = !isVisible
        statusUpdateDot?.needsDisplay = isVisible
    }

    @objc private func openSettings() {
        windows.showSettings(settings, runtime: runtime, updates: updates)
    }

    @objc private func openAbout() { windows.showAbout(updates: updates) }

    @objc private func openUpdatePrompt() { windows.showUpdatePrompt(updates: updates) }

    @objc private func openDeveloperTestSetup() { presentSetup() }

    @objc private func openOnboarding() { showOnboarding() }

    // MARK: - Dictation lifecycle

    @discardableResult
    private func beginDictation() -> Bool {
        guard isASRReady else {
            guard asr != nil else {
                state.phase = .failed("Speech engine is not running")
                panel.present()
                scheduleDismiss(after: 1.8)
                return false
            }
            state.phase = .loading
            panel.present()
            return false
        }
        if speechEngineWarmupGate.requiresWarmup() {
            beginIdleSpeechEngineWarmup()
            return false
        }
        guard state.phase != .listening else { return false }
        guard activeCursorContextGeneration == nil else {
            Log.write("dictation start ignored while cursor context probe settles")
            return false
        }
        dismissWork?.cancel()
        cursorContextGeneration &+= 1
        resolvedPrecedingText = nil
        isResolvingPrecedingText = false
        transcriptDeliveryGate.reset()
        precedingTextAtDictationStart = settings.autoInsert
            && settings.contextAwareCapitalization
            ? TextInserter.textBeforeCursor()
            : nil
        resolvedPrecedingText = precedingTextAtDictationStart
        hasResolvedPrecedingText = precedingTextAtDictationStart != nil
        state.reset()
        state.phase = .listening
        state.startDictationTimer()
        panel.present()

        settings.playStart()
        let shortLanguage = ShortUtteranceLanguageResolver.modelLanguage(
            for: settings.shortUtteranceLanguage
        )
        asr.beginUtterance(shortUtteranceLanguage: shortLanguage)
        do {
            try capture.start()
            // Accessibility is instantaneous when an editor exposes its text.
            // For other apps, run the guarded keyboard fallback while the user
            // is speaking so its clipboard waits are off the critical path.
            if settings.autoInsert,
               settings.contextAwareCapitalization,
               !hasResolvedPrecedingText {
                startCursorContextResolution(allowWhilePhysicalModifiersPressed: true)
            }
            return true
        } catch {
            asr.stopUtterance()
            cancelCursorContextResolution()
            state.stopDictationTimer()
            state.phase = .failed("Microphone unavailable")
            scheduleDismiss(after: 1.6)
            return false
        }
    }

    private func beginIdleSpeechEngineWarmup() {
        guard isASRReady, !isRewarmingSpeechEngine, asr != nil else { return }
        dismissWork?.cancel()
        isASRReady = false
        isRewarmingSpeechEngine = true
        state.reset()
        state.phase = .loading
        panel.present()
        speechEngineStartedAt = ProcessInfo.processInfo.systemUptime
        Log.write("speech engine idle lease expired; starting readiness warm-up")
        asr.warmUp()
        armSpeechEngineStartupTimeout(generation: speechEngineGeneration)
        refreshStatusMenu()
    }

    private func endDictation() {
        // Releasing the shortcut during first-launch warm-up must not dismiss
        // the HUD. Startup completion owns that lifecycle and replaces it with
        // the brief Ready state before dismissal.
        guard state.phase != .loading else { return }
        guard state.phase == .listening else { return }
        capture.stop()
        state.stopDictationTimer()
        state.level = 0
        state.phase = .thinking
        if settings.autoInsert,
           settings.contextAwareCapitalization,
           !hasResolvedPrecedingText,
           !isResolvingPrecedingText {
            startCursorContextResolution(allowWhilePhysicalModifiersPressed: false)
        }
        asr.stopUtterance()
    }

    private func handle(_ event: ASRService.Event) {
        switch event {
        case let .ready(ms):
            completeSpeechEngineWarmup(ms: ms, kind: "startup")

        case let .warmed(ms):
            completeSpeechEngineWarmup(ms: ms, kind: "idle")

        case let .partial(committed, tail):
            guard state.phase == .listening else { return }
            state.committed = committed
            state.tail = tail

        case let .final(text, secs, ms):
            speechEngineWarmupGate.markActivity()
            precedingTextAtDictationStart = nil
            state.lastAudioSecs = secs
            state.lastDurationMS = ms
            guard !text.isEmpty else {
                cancelCursorContextResolution()
                dismissNow()
                return
            }
            let normalizedText = SpokenSymbolNormalizer.normalize(
                SpelledLetterNormalizer.normalize(
                    SpokenNumberNormalizer.normalize(text)
                )
            )
            let formattedText = TranscriptFormatter.format(
                normalizedText,
                usePunctuation: settings.usePunctuation
            )
            let expansion = TranscriptExpander.expand(formattedText, using: settings.voiceShortcuts)
            if let matchedID = expansion.matchedShortcutID {
                Log.write("voice shortcut matched id=\(matchedID) inputChars=\(normalizedText.count) outputChars=\(expansion.text.count)")
            }
            // Shortcut replacements are user-authored literal output; preserve
            // their casing even when they are inserted mid-sentence. Every
            // delivery still passes through the gate: a keyboard cursor probe
            // owns the selection and pasteboard until its completion callback,
            // even when the final text does not need capitalization adjustment.
            let delivery = DeferredTranscriptDelivery(
                text: expansion.text,
                adjustForCursor: settings.autoInsert
                    && settings.contextAwareCapitalization
                    && expansion.matchedShortcutID == nil
            )
            if let ready = transcriptDeliveryGate.submit(
                delivery,
                whileContextIsResolving: isResolvingPrecedingText
            ) {
                deliverTranscript(ready)
            } else {
                Log.write("transcript delivery waiting for cursor context probe")
            }

        case let .error(message):
            cancelCursorContextResolution()
            if !isASRReady {
                speechEngineStartupWork?.cancel()
                speechEngineStartupWork = nil
                speechEngineStartedAt = nil
                Log.write("speech engine startup failed: \(message)")
                speechEngineGeneration &+= 1
                asr?.shutdown()
                asr = nil
                isRewarmingSpeechEngine = false
                speechEngineWarmupGate.reset()
                settings.isReloadingModel = false
                refreshStatusMenu()
            }
            state.stopDictationTimer()
            state.phase = .failed(message)
            scheduleDismiss(after: 1.8)

        case let .terminated(message):
            cancelCursorContextResolution()
            speechEngineStartupWork?.cancel()
            speechEngineStartupWork = nil
            speechEngineStartedAt = nil
            speechEngineGeneration &+= 1
            isASRReady = false
            isRewarmingSpeechEngine = false
            speechEngineWarmupGate.reset()
            asr = nil
            settings.isReloadingModel = false
            state.stopDictationTimer()
            state.phase = .failed(message)
            refreshStatusMenu()
            scheduleDismiss(after: 1.8)
        }
    }

    private func completeSpeechEngineWarmup(ms: Int, kind: String) {
        let wallMS = speechEngineStartedAt.map {
            Int((ProcessInfo.processInfo.systemUptime - $0) * 1000)
        } ?? ms
        Log.write("speech engine ready: kind=\(kind) reported=\(ms)ms wall=\(wallMS)ms")
        speechEngineStartupWork?.cancel()
        speechEngineStartupWork = nil
        speechEngineStartedAt = nil
        isASRReady = true
        isRewarmingSpeechEngine = false
        speechEngineWarmupGate.markActivity()
        settings.isReloadingModel = false
        presentFirstDictationCoachIfReady()
        if state.phase == .loading {
            if panel.isVisible {
                state.phase = .ready
                scheduleDismiss(after: 0.65)
            } else {
                state.phase = .idle
            }
        }
        refreshStatusMenu()
    }

    private func deliverPendingTranscriptIfReady() {
        guard !isResolvingPrecedingText,
              let delivery = transcriptDeliveryGate.takePending() else { return }
        deliverTranscript(delivery)
    }

    private func startCursorContextResolution(
        allowWhilePhysicalModifiersPressed: Bool
    ) {
        guard !isResolvingPrecedingText, !hasResolvedPrecedingText else { return }
        let contextGeneration = cursorContextGeneration
        let startedAt = ProcessInfo.processInfo.systemUptime
        isResolvingPrecedingText = true
        activeCursorContextGeneration = contextGeneration
        TextInserter.resolveTextBeforeCursor(
            fallback: precedingTextAtDictationStart,
            allowWhilePhysicalModifiersPressed: allowWhilePhysicalModifiersPressed
        ) { [weak self] text in
            guard let self,
                  self.activeCursorContextGeneration == contextGeneration else { return }
            self.activeCursorContextGeneration = nil
            self.isResolvingPrecedingText = false
            guard self.cursorContextGeneration == contextGeneration else { return }
            self.hasResolvedPrecedingText = true
            self.resolvedPrecedingText = text
            let durationMS = Int(
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            )
            Log.write(
                "cursor context prefetch finished duration=\(durationMS)ms "
                    + "available=\(text != nil)"
            )
            self.deliverPendingTranscriptIfReady()
        }
    }

    private func deliverTranscript(_ delivery: DeferredTranscriptDelivery) {
        let precedingText = delivery.adjustForCursor ? resolvedPrecedingText : nil
        cancelCursorContextResolution()
        deliverFinalTranscript(
            delivery.text,
            precedingText: precedingText,
            adjustForCursor: delivery.adjustForCursor
        )
    }

    private func cancelCursorContextResolution() {
        cursorContextGeneration &+= 1
        precedingTextAtDictationStart = nil
        resolvedPrecedingText = nil
        hasResolvedPrecedingText = false
        if activeCursorContextGeneration == nil {
            isResolvingPrecedingText = false
        }
        transcriptDeliveryGate.reset()
    }

    private func deliverFinalTranscript(
        _ text: String,
        precedingText: String?,
        adjustForCursor: Bool
    ) {
        let deliveredText = adjustForCursor
            ? TranscriptFormatter.adjustedForCursor(text, precedingText: precedingText)
            : text
        guard !deliveredText.isEmpty else {
            dismissNow()
            return
        }
        let insertionText = TranscriptFormatter.textForInsertion(deliveredText)
        state.committed = deliveredText
        state.tail = ""
        state.phase = .inserted

        TextInserter.deliver(
            deliveredText,
            insertionText: insertionText,
            insertAtCursor: settings.autoInsert,
            copyToClipboard: settings.copyToClipboard
        )
        settings.playFeedback()
        scheduleDismiss(after: 0.42)
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissNow() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Clears state only once the fade has finished. Resetting any earlier makes
    /// the HUD flip back to the "Listening…" placeholder mid-fade, because
    /// `.idle` renders as the listening state.
    private func dismissNow() {
        dismissWork?.cancel()
        panel.dismiss { [weak self] in
            guard let self else { return }
            self.state.phase = .idle
            self.state.reset()
        }
    }
}
