import AppKit

/// Watches a modifier-only shortcut or a recorded key chord globally.
///
/// Modifier-only presets arrive as `.flagsChanged`; ordinary chords and
/// function keys arrive as `.keyDown`/`.keyUp`. The monitor keeps those input
/// paths separate but feeds both into the same activation state machine.
final class HotKeyMonitor {
    private var shortcut: TriggerShortcut
    private var mode: ActivationMode

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPhysicalTriggerDown = false
    private var isActive = false
    private var isSuspended = false

    /// Begin capturing. Return true only when recording actually started. The
    /// monitor commits its active state after this callback succeeds, so a
    /// rejected startup or permission attempt can be retried on the next press.
    var onStart: (() -> Bool)?
    /// Stop capturing and transcribe.
    var onStop: (() -> Void)?

    init(shortcut: TriggerShortcut, mode: ActivationMode) {
        self.shortcut = shortcut
        self.mode = mode
    }

    /// Backwards-compatible construction for callers/tests that still name a
    /// legacy modifier preset directly.
    convenience init(key: TriggerKey, mode: ActivationMode) {
        self.init(shortcut: .modifierOnly(key), mode: mode)
    }

    func start() {
        guard !isSuspended else { return }
        removeMonitors()
        let eventMask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        let handler: (NSEvent) -> Void = { [weak self] event in self?.handle(event) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: eventMask,
            handler: handler
        )
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { event in
            handler(event)
            return event
        }
    }

    func stop() {
        removeMonitors()
        isPhysicalTriggerDown = false
        isActive = false
    }

    /// Apply new settings. A mode or shortcut change ends any in-flight
    /// recording, then installs the new configuration unless capture is
    /// currently suspended for the local recorder.
    func rebind(shortcut: TriggerShortcut, mode: ActivationMode) {
        if isActive {
            isActive = false
            onStop?()
        }
        isPhysicalTriggerDown = false
        self.shortcut = shortcut
        self.mode = mode
        guard !isSuspended else { return }
        start()
    }

    /// Temporarily gets out of the way while the Settings/onboarding window
    /// records a replacement shortcut.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        if isActive {
            isActive = false
            onStop?()
        }
        removeMonitors()
        isPhysicalTriggerDown = false
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        isPhysicalTriggerDown = false
        start()
    }

    /// Applies the recorder's complete current state, rather than assuming a
    /// transition callback was observed. This matters when the speech engine
    /// finishes starting while a recorder sheet is already open.
    func setSuspendedForShortcutCapture(_ shouldSuspend: Bool) {
        if shouldSuspend {
            suspend()
        } else if isSuspended {
            resume()
        } else {
            start()
        }
    }

    /// Synchronize the monitor after dictation is stopped by something other
    /// than the trigger key, such as the recording time limit. In tap mode this
    /// makes the very next complete press start again instead of acting like a
    /// stale stop.
    func cancelActiveDictation() {
        isActive = false
    }

    /// Internal so both event paths can be exercised without installing global
    /// event monitors in the test process.
    func handle(_ event: NSEvent) {
        guard !isSuspended,
              !SyntheticInputEvent.wasGeneratedByWhisprStream(event) else { return }

        switch shortcut.key {
        case let .modifier(key):
            handleModifierEvent(event, key: key)
        default:
            handleChordEvent(event)
        }
    }

    private func handleModifierEvent(_ event: NSEvent, key: TriggerKey) {
        guard event.type == .flagsChanged, event.keyCode == key.keyCode else { return }
        let down = event.modifierFlags.contains(key.flag)
        guard down != isPhysicalTriggerDown else { return } // ignore repeats
        isPhysicalTriggerDown = down

        if down {
            handlePressEdge()
        } else {
            handleReleaseEdge()
        }
    }

    private func handleChordEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            guard event.keyCode == shortcut.keyCode,
                  !event.isARepeat,
                  TriggerModifiers(event.modifierFlags) == shortcut.modifiers,
                  !isPhysicalTriggerDown else { return }
            isPhysicalTriggerDown = true
            handlePressEdge()

        case .keyUp:
            guard event.keyCode == shortcut.keyCode, isPhysicalTriggerDown else { return }
            isPhysicalTriggerDown = false
            handleReleaseEdge()

        case .flagsChanged:
            // A user can release Control/Option/Shift before releasing the
            // primary key. Stop a hold immediately, but do not react to an
            // unrelated extra modifier pressed after the chord began.
            guard mode == .hold,
                  isPhysicalTriggerDown,
                  !shortcut.modifiers.isEmpty,
                  !TriggerModifiers(event.modifierFlags).isSuperset(of: shortcut.modifiers)
            else { return }
            isPhysicalTriggerDown = false
            handleReleaseEdge()

        default:
            break
        }
    }

    private func handlePressEdge() {
        switch mode {
        case .hold:
            guard !isActive else { return }
            isActive = onStart?() ?? false

        case .tap:
            if isActive {
                isActive = false
                onStop?()
            } else {
                isActive = onStart?() ?? false
            }
        }
    }

    private func handleReleaseEdge() {
        guard mode == .hold, isActive else { return }
        isActive = false
        onStop?()
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// Prompts for Accessibility on first launch; returns current trust state.
    @discardableResult
    static func ensureAccessibility(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
