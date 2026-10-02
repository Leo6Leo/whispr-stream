import AppKit
import SwiftUI

/// A borderless, non-activating panel that floats above other apps.
///
/// `.nonactivatingPanel` is essential: if the HUD took focus, the paste would
/// land in the HUD instead of the app the user was typing into.
///
/// The panel is deliberately a **fixed, oversized canvas** with the capsule
/// centred inside it. Resizing an NSWindow is not animatable in step with
/// SwiftUI's layout spring, so growing the window per partial made the capsule
/// visibly snap. With a fixed window, SwiftUI owns every transition.
final class HUDPanel: NSPanel, NSWindowDelegate {
    private static let canvasHeight: CGFloat = 190
    private static let bottomMargin: CGFloat = 120
    private static let savedCenterXKey = "hudPosition.centerX"
    private static let savedCenterYKey = "hudPosition.centerY"

    private var isApplyingPosition = false
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var presentation = HUDPresentationState()

    var presentationGeneration: UInt64 { presentation.generation }

    init(state: AppState) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: Self.canvasHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Accept mouse input without activation. Movement is deliberately
        // implemented by HUDView's custom gesture rather than native window
        // dragging, which opts into macOS tiling and magnetic snap zones.
        ignoresMouseEvents = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let host = NSHostingView(rootView: HUDView(
            state: state,
            onDragChanged: { [weak self] in self?.updateDrag() },
            onDragEnded: { [weak self] in self?.endDrag() }
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        // NSHostingView draws an opaque backing by default, which would show as
        // a square behind the rounded capsule.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host
        delegate = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Restores the user-selected centre, falling back to bottom-centre on the
    /// active screen. The centre is stored instead of the frame origin so the
    /// position survives display-width changes without drifting.
    func reposition() {
        guard let mainScreen = NSScreen.main else { return }

        let defaults = UserDefaults.standard
        let savedCenter: NSPoint? = {
            guard defaults.object(forKey: Self.savedCenterXKey) != nil,
                  defaults.object(forKey: Self.savedCenterYKey) != nil else {
                return nil
            }
            return NSPoint(
                x: defaults.double(forKey: Self.savedCenterXKey),
                y: defaults.double(forKey: Self.savedCenterYKey)
            )
        }()

        let screen: NSScreen
        let center: NSPoint
        if let savedCenter,
           let savedScreen = NSScreen.screens.first(where: { $0.frame.contains(savedCenter) }) {
            screen = savedScreen
            center = savedCenter
        } else {
            screen = mainScreen
            let visible = screen.visibleFrame
            center = NSPoint(
                x: visible.midX,
                y: visible.minY + Self.bottomMargin - HUDView.shadowInset
                    + Self.canvasHeight / 2
            )
        }

        let visible = screen.visibleFrame
        let width = min(900, visible.width - 80)
        let restoredFrame = NSRect(
            x: center.x - width / 2,
            y: center.y - Self.canvasHeight / 2,
            width: width,
            height: Self.canvasHeight
        )

        isApplyingPosition = true
        setFrame(restoredFrame, display: false)
        isApplyingPosition = false
    }

    /// Moves directly in screen coordinates so macOS never treats the gesture
    /// as a draggable title bar and therefore never offers tiling or snapping.
    private func updateDrag() {
        let mouse = NSEvent.mouseLocation
        if dragStartMouse == nil {
            dragStartMouse = mouse
            dragStartOrigin = frame.origin
        }
        guard let startMouse = dragStartMouse,
              let startOrigin = dragStartOrigin else { return }

        let origin = NSPoint(
            x: startOrigin.x + mouse.x - startMouse.x,
            y: startOrigin.y + mouse.y - startMouse.y
        )
        isApplyingPosition = true
        setFrameOrigin(origin)
        isApplyingPosition = false
    }

    private func endDrag() {
        // Capture the final pointer position even if SwiftUI coalesced the last
        // mouse-move event, then persist the exact, unsnapped centre.
        updateDrag()
        dragStartMouse = nil
        dragStartOrigin = nil
        saveCurrentPosition()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingPosition else { return }
        saveCurrentPosition()
    }

    private func saveCurrentPosition() {
        let defaults = UserDefaults.standard
        defaults.set(Double(frame.midX), forKey: Self.savedCenterXKey)
        defaults.set(Double(frame.midY), forKey: Self.savedCenterYKey)
    }

    func present() {
        let startsHidden = presentation.phase == .hidden
        presentation.present()
        reposition()
        if startsHidden { alphaValue = 0 }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Fades out, then runs `completion` — callers must not reset state before
    /// it fires or the HUD visibly reverts mid-fade.
    func dismiss(completion: (() -> Void)? = nil) {
        let generation = presentation.beginDismiss()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.presentation.completeDismiss(generation) else { return }
            self.orderOut(nil)
            completion?()
        }
    }
}
