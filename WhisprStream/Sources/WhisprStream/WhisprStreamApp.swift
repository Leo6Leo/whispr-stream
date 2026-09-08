import AppKit
import AVFoundation
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let speechEngineStartupTimeout: TimeInterval = 20

    private let state = AppState()
    private lazy var settings = Settings.shared
    private let windows = AppWindows()
    private let runtime = RuntimeManager.shared

    private var panel: HUDPanel!
    private var statusItem: NSStatusItem!
    private let capture = AudioCapture()
    private let media = MediaController(isEnabled: { Settings.shared.pauseMediaWhileDictating })
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .whisprDeveloperTestModeActivated, object: nil)
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
        }
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
            Log.write("speech engine startup timed out after \(Int(Self.speechEngineStartupTimeout))s")
            self.settings.isReloadingModel = false
            self.speechEngineGeneration &+= 1
            self.asr?.shutdown()
            self.asr = nil
            self.state.phase = .failed("Speech engine took too long to start")
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
            media.resumeAfterDictation()
            state.stopDictationTimer()
            state.level = 0
            dismissNow()
        }

        speechEngineStartupWork?.cancel()
        speechEngineGeneration &+= 1
        isASRReady = false
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
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "WhisprStream"
        )
        refreshStatusMenu()
    }

    private func refreshStatusMenu() {
        let menu = NSMenu()

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

    @objc private func openSettings() { windows.showSettings(settings, runtime: runtime) }
    @objc private func openAbout() { windows.showAbout() }

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

        // Pause playing music before the mic opens so Bluetooth stays in stereo.
        media.pauseForDictation()
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

    private func endDictation() {
        // Releasing the shortcut during first-launch warm-up must not dismiss
        // the HUD. Startup completion owns that lifecycle and replaces it with
        // the brief Ready state before dismissal.
        guard state.phase != .loading else { return }
        guard state.phase == .listening else { return }
        capture.stop()
        media.resumeAfterDictation()
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
            let wallMS = speechEngineStartedAt.map {
                Int((ProcessInfo.processInfo.systemUptime - $0) * 1000)
            } ?? ms
            Log.write("speech engine ready: reported=\(ms)ms wall=\(wallMS)ms")
            speechEngineStartupWork?.cancel()
            speechEngineStartupWork = nil
            speechEngineStartedAt = nil
            isASRReady = true
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

        case let .partial(committed, tail):
            guard state.phase == .listening else { return }
            state.committed = committed
            state.tail = tail

        case let .final(text, secs, ms):
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

            media.resumeAfterDictation()
            cancelCursorContextResolution()
            if !isASRReady {
                speechEngineStartupWork?.cancel()
                speechEngineStartupWork = nil
                speechEngineStartedAt = nil
                Log.write("speech engine startup failed: \(message)")
                speechEngineGeneration &+= 1
                asr?.shutdown()
                asr = nil
                settings.isReloadingModel = false
                refreshStatusMenu()
            }
            state.stopDictationTimer()
            state.phase = .failed(message)
            scheduleDismiss(after: 1.8)

        case let .terminated(message):

            media.resumeAfterDictation()
            cancelCursorContextResolution()
            speechEngineStartupWork?.cancel()
            speechEngineStartupWork = nil
            speechEngineStartedAt = nil
            speechEngineGeneration &+= 1
            isASRReady = false
            asr = nil
            settings.isReloadingModel = false
            state.stopDictationTimer()
            state.phase = .failed(message)
            refreshStatusMenu()
            scheduleDismiss(after: 1.8)
        }
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
