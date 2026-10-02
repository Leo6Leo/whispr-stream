import AppKit
import AVFoundation
import Combine
import SwiftUI

struct DeferredTranscriptDelivery: Equatable {
    let text: String
    let adjustForCursor: Bool
    var review: DictationReview? = nil
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
    private var reviewPanel: DictationReviewPanel?
    private var reviewTarget: TextInserter.ReviewTarget?
    private var pendingTranscriptDeliveries = 0
    private var needsCursorSnapshotAfterDelivery = false

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
        capture.stop()
        state.stopDictationTimer()
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
        if case .available = status { scheduleAutomaticUpdatePrompt() }
    }

    private func scheduleAutomaticUpdatePrompt() {
        // Wait until @Published has committed the status and any enclosing
        // cancellation/error handler has finished changing dictation state.
        DispatchQueue.main.async { [weak self] in
            self?.presentAutomaticUpdateIfPossible()
        }
    }

    private func presentAutomaticUpdateIfPossible() {
        let isBusy = state.phase != .idle || reviewPanel != nil
            || activeCursorContextGeneration != nil || pendingTranscriptDeliveries > 0
        guard settings.hasCompletedOnboarding,
              case let .available(release) = updates.status,
              updatePromptPolicy.shouldPresent(version: release.version, isBusy: isBusy)
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

        // Keep input available even when startup fails, so the next press can
        // retry. Reuse the monitor instead of leaving old global hooks behind.
        if hotkey == nil {
            hotkey = HotKeyMonitor(
                shortcut: settings.triggerShortcut,
                mode: settings.activationMode
            )
        }
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
        settings.onLearningChange = { [weak self] in self?.refreshLearnedContext() }
        CorrectionStore.shared.onChange = { [weak self] in self?.refreshLearnedContext() }
        settings.onModelChange = { [weak self] _ in self?.reloadASR() }
        settings.onShortUtteranceLanguageChange = { [weak self] _ in self?.reloadASR() }
        capture.onBuffer = { [weak self] pcm, level in
            self?.asr?.sendAudio(pcm)
            DispatchQueue.main.async {
                guard let self, self.state.phase == .listening else { return }
                self.state.level = self.state.level * 0.55 + CGFloat(level) * 0.45
            }
        }
        capture.onFailure = { [weak self] error in
            guard let self, self.state.phase == .listening else { return }
            Log.write("microphone capture stopped: \(error.localizedDescription)")
            self.failSpeechEngine("Microphone unavailable")
        }

        do {
            try launchSpeechEngine()
        } catch {
            failSpeechEngine("Could not start the ASR engine")
            return
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
            Log.write("speech engine startup timed out after \(Int(Self.speechEngineStartupTimeout))s")
            self.failSpeechEngine("Speech engine took too long to start")
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
            shortUtteranceLanguage: settings.shortUtteranceLanguage,
            learnedContext: learnedContext
        )
    }

    /// Restarts the sidecar on the currently selected model.
    ///
    /// The weights load once at sidecar start, so a model switch cannot be
    /// applied to the running process the way the vocabulary can — the whole
    /// sidecar has to come down and pay the load again.
    private func reloadASR() {
        speechEngineGeneration &+= 1
        hotkey?.cancelActiveDictation()
        if state.phase == .thinking {
            reviewPanel?.cancel()
            reviewPanel = nil
            reviewTarget = nil
            cancelCursorContextResolution()
            dismissNow()
        }
        // Reload in the background, reporting progress only in Settings.
        if state.phase == .listening {
            capture.stop()
            state.stopDictationTimer()
            state.level = 0
            cancelCursorContextResolution()
            dismissNow()
        }

        speechEngineStartupWork?.cancel()
        isASRReady = false
        speechEngineStartedAt = nil
        asr?.shutdown()
        asr = nil
        settings.isReloadingModel = true

        do {
            try launchSpeechEngine()
        } catch {
            failSpeechEngine("Could not start the ASR engine")
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
        guard reviewPanel == nil, state.phase != .thinking else { return false }
        if asr == nil { startSpeechEngine() }
        // The serial sidecar writer queues start/audio/stop while the model
        // loads and warms once in the background. Capture immediately so the
        // first shortcut press works, including after a long idle or restart.
        // A synchronous launch failure has already presented its error.
        guard asr != nil else { return false }
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
        reviewTarget = nil
        precedingTextAtDictationStart = nil
        hasResolvedPrecedingText = false
        // Recording can start immediately, but the preceding paste still
        // owns the clipboard and may change this field's value and selection.
        needsCursorSnapshotAfterDelivery = pendingTranscriptDeliveries > 0
        if !needsCursorSnapshotAfterDelivery { captureDictationCursorSnapshot() }
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
            failSpeechEngine("Microphone unavailable")
            return false
        }
    }

    private func endDictation() {
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
            completeSpeechEngineStartup(ms: ms)

        case let .partial(committed, tail):
            guard state.phase == .listening else { return }
            state.committed = committed
            state.tail = tail

        case let .final(text, secs, ms, review):
            guard state.phase == .thinking, reviewPanel == nil else { return }
            precedingTextAtDictationStart = nil
            state.lastAudioSecs = secs
            state.lastDurationMS = ms
            guard !text.isEmpty else {
                cancelCursorContextResolution()
                dismissNow()
                return
            }
            let delivery = prepareDelivery(text, review: review)
            if let ready = transcriptDeliveryGate.submit(
                delivery,
                whileContextIsResolving: isResolvingPrecedingText
                    || pendingTranscriptDeliveries > 0 || needsCursorSnapshotAfterDelivery
            ) {
                deliverTranscript(ready)
            } else {
                Log.write("transcript delivery waiting for clipboard or cursor context")
            }

        case let .error(message), let .terminated(message):
            failSpeechEngine(message)
        }
    }

    private func failSpeechEngine(_ message: String) {
        // Stop hardware before leaving .listening: key release and the safety
        // timer can no longer own cleanup once the UI has entered .failed.
        capture.stop()
        hotkey?.cancelActiveDictation()
        state.stopDictationTimer()
        state.level = 0

        speechEngineStartupWork?.cancel()
        speechEngineStartupWork = nil
        speechEngineStartedAt = nil
        // Retire the entire sidecar, fencing both queued events and review
        // callbacks. Sending only "stop" could deliver an aborted final during
        // the next dictation. A new shortcut press can restart the engine.
        speechEngineGeneration &+= 1
        isASRReady = false
        asr?.shutdown()
        asr = nil
        settings.isReloadingModel = false

        reviewPanel?.cancel()
        reviewPanel = nil
        reviewTarget = nil
        cancelCursorContextResolution()
        state.phase = .failed(message)
        panel.present()
        refreshStatusMenu()
        scheduleDismiss(after: 1.8)
    }

    private func completeSpeechEngineStartup(ms: Int) {
        let wallMS = speechEngineStartedAt.map {
            Int((ProcessInfo.processInfo.systemUptime - $0) * 1000)
        } ?? ms
        Log.write("speech engine ready: kind=startup reported=\(ms)ms wall=\(wallMS)ms")
        speechEngineStartupWork?.cancel()
        speechEngineStartupWork = nil
        speechEngineStartedAt = nil
        isASRReady = true
        settings.isReloadingModel = false
        presentFirstDictationCoachIfReady()
        // Readiness must not replace an active recording or pending final,
        // nor present a HUD when startup completes without user interaction.
        refreshStatusMenu()
        scheduleAutomaticUpdatePrompt()
    }

    private func deliverPendingTranscriptIfReady() {
        guard pendingTranscriptDeliveries == 0,
              !needsCursorSnapshotAfterDelivery, !isResolvingPrecedingText,
              let delivery = transcriptDeliveryGate.takePending() else { return }
        deliverTranscript(delivery)
    }

    private func captureDictationCursorSnapshot() {
        needsCursorSnapshotAfterDelivery = false
        reviewTarget = settings.reviewUncertainWords ? TextInserter.captureReviewTarget() : nil
        precedingTextAtDictationStart = settings.autoInsert
            && settings.contextAwareCapitalization
            ? TextInserter.textBeforeCursor()
            : nil
        resolvedPrecedingText = precedingTextAtDictationStart
        hasResolvedPrecedingText = precedingTextAtDictationStart != nil
    }

    private func resumeDictationAfterDelivery() {
        guard pendingTranscriptDeliveries == 0 else { return }
        if needsCursorSnapshotAfterDelivery {
            guard state.phase == .listening || state.phase == .thinking else { return }
            captureDictationCursorSnapshot()
            if settings.autoInsert, settings.contextAwareCapitalization, !hasResolvedPrecedingText {
                startCursorContextResolution(allowWhilePhysicalModifiersPressed: state.phase == .listening)
            }
        }
        deliverPendingTranscriptIfReady()
    }

    private func startCursorContextResolution(
        allowWhilePhysicalModifiersPressed: Bool
    ) {
        guard pendingTranscriptDeliveries == 0,
              !isResolvingPrecedingText, !hasResolvedPrecedingText else { return }
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
            defer { self.scheduleAutomaticUpdatePrompt() }
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
        if settings.reviewUncertainWords, let review = delivery.review {
            presentReview(review, precedingText: precedingText)
            return
        }
        deliverFinalTranscript(
            delivery.text,
            precedingText: precedingText,
            adjustForCursor: delivery.adjustForCursor
        )
    }

    private var learnedContext: String {
        settings.learnFromCorrections ? CorrectionStore.shared.preferredTerms.joined(separator: "\n") : ""
    }

    private func refreshLearnedContext() { asr?.setLearnedContext(learnedContext) }

    private func prepareDelivery(_ text: String, review: DictationReview? = nil) -> DeferredTranscriptDelivery {
        let normalized = SpokenSymbolNormalizer.normalize(
            SpelledLetterNormalizer.normalize(SpokenNumberNormalizer.normalize(text))
        )
        let formatted = TranscriptFormatter.format(normalized, usePunctuation: settings.usePunctuation)
        let expansion = TranscriptExpander.expand(formatted, using: settings.voiceShortcuts)
        // Explicit shortcut expansions remain literal and bypass word review.
        return DeferredTranscriptDelivery(
            text: expansion.text,
            adjustForCursor: settings.autoInsert && settings.contextAwareCapitalization
                && expansion.matchedShortcutID == nil,
            review: expansion.matchedShortcutID == nil ? review : nil
        )
    }

    private func presentReview(_ review: DictationReview, precedingText: String?) {
        dismissWork?.cancel()
        panel.dismiss()
        let target = reviewTarget
        let savesChoices = settings.learnFromCorrections
        let model = settings.model.rawValue
        let generation = speechEngineGeneration
        reviewPanel = DictationReviewPanel(review: review, savesChoices: savesChoices) { [weak self] text, manual in
            guard let self, self.speechEngineGeneration == generation else { return }
            self.reviewPanel = nil
            self.reviewTarget = nil
            guard let text else {
                target?.application.activate(options: [])
                self.state.phase = .idle
                self.scheduleAutomaticUpdatePrompt()
                return
            }
            if savesChoices && self.settings.learnFromCorrections {
                CorrectionStore.shared.record(review, chosenText: text, model: model, manual: manual)
            }
            let chosen = self.prepareDelivery(text)
            guard self.settings.autoInsert else {
                target?.application.activate(options: [])
                self.panel.present()
                self.deliverFinalTranscript(chosen.text, precedingText: nil, adjustForCursor: false)
                return
            }
            TextInserter.restoreReviewTarget(target, isCurrent: { [weak self] in
                self?.speechEngineGeneration == generation
            }) { [weak self] processID in
                guard let self, self.speechEngineGeneration == generation else { return }
                self.panel.present()
                self.deliverFinalTranscript(chosen.text, precedingText: precedingText,
                                            adjustForCursor: chosen.adjustForCursor && processID != nil,
                                            targetProcessID: processID, forceClipboard: processID == nil)
            }
        }
        reviewPanel?.show()
    }

    private func cancelCursorContextResolution() {
        cursorContextGeneration &+= 1
        needsCursorSnapshotAfterDelivery = false
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
        adjustForCursor: Bool,
        targetProcessID: pid_t? = nil,
        forceClipboard: Bool = false
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
        state.phase = forceClipboard ? .failed("Copied — return to your original field to paste") : .inserted

        pendingTranscriptDeliveries += 1
        TextInserter.deliver(
            deliveredText,
            insertionText: insertionText,
            insertAtCursor: settings.autoInsert && !forceClipboard,
            copyToClipboard: settings.copyToClipboard || forceClipboard,
            targetProcessID: targetProcessID,
            completion: { [weak self] in
                guard let self else { return }
                self.pendingTranscriptDeliveries -= 1
                self.resumeDictationAfterDelivery()
                self.scheduleAutomaticUpdatePrompt()
            }
        )
        settings.playFeedback()
        scheduleDismiss(after: forceClipboard ? 3 : 0.42)
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissWork?.cancel()
        let generation = panel.presentationGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.presentationGeneration == generation else { return }
            self.dismissNow()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Clears state only once the fade has finished. Resetting any earlier makes
    /// the HUD flip back to the "Listening…" placeholder mid-fade, because
    /// `.idle` renders as the listening state.
    private func dismissNow() {
        dismissWork?.cancel()
        dismissWork = nil
        panel.dismiss { [weak self] in
            guard let self else { return }
            self.state.phase = .idle
            self.state.reset()
            self.scheduleAutomaticUpdatePrompt()
        }
    }
}
