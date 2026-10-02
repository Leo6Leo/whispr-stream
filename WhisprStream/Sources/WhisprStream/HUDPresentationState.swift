/// Identifies the display cycle that owns an asynchronous dismissal.
/// Window visibility alone cannot distinguish an old fade from a new recording.
struct HUDPresentationState {
    enum Phase { case hidden, visible, dismissing }

    private(set) var phase: Phase = .hidden
    private(set) var generation: UInt64 = 0

    mutating func present() {
        generation &+= 1
        phase = .visible
    }

    mutating func beginDismiss() -> UInt64 {
        generation &+= 1
        phase = .dismissing
        return generation
    }

    /// Only the current fade may hide the window and reset the app's state.
    mutating func completeDismiss(_ generation: UInt64) -> Bool {
        guard self.generation == generation, phase == .dismissing else { return false }
        phase = .hidden
        return true
    }
}
