import AppKit
import Carbon.HIToolbox

/// ⌥S during a live dictation switches between microphone and system audio.
///
/// A global NSEvent monitor can only observe, so ⌥S would still type "ß" into
/// the editor being dictated into. An active CGEventTap swallows the chord
/// instead. The tap is enabled only while dictation is live; the rest of the
/// time it is disabled and adds nothing to normal typing.
final class SourceToggleKeyTap {
    var onToggle: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The keyUp matching a swallowed keyDown must be swallowed too, even if
    /// Option was released first.
    private var isSwallowingKeyUp = false

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, tap == nil { install() }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
        if !enabled { isSwallowingKeyUp = false }
    }

    private func install() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<SourceToggleKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("source toggle key tap unavailable (Accessibility not granted?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        runLoopSource = source
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            break
        default:
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_S)
        else { return Unmanaged.passUnretained(event) }

        if type == .keyUp {
            guard isSwallowingKeyUp else { return Unmanaged.passUnretained(event) }
            isSwallowingKeyUp = false
            return nil
        }

        let flags = event.flags
        guard flags.contains(.maskAlternate),
              !flags.contains(.maskCommand),
              !flags.contains(.maskControl)
        else { return Unmanaged.passUnretained(event) }

        isSwallowingKeyUp = true
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { [weak self] in self?.onToggle?() }
        }
        return nil
    }
}
