import Foundation
#if canImport(WhisprStream)
@testable import WhisprStream
#endif

/// Shared by XCTest and the Command Line Tools runner, using production policies.
enum ReleaseLifecycleChecks {
    static func hud(_ check: (Bool, String) -> Void) {
        var state = HUDPresentationState()
        check(state.phase == .hidden, "HUD starts hidden")
        state.present()
        let scheduledDismissal = state.generation
        let oldFade = state.beginDismiss()
        check(state.generation != scheduledDismissal, "starting a fade invalidates queued dismissals")

        // A second recording starts during the previous recording's fade.
        state.present()
        let newRecording = state.generation
        check(!state.completeDismiss(oldFade), "old fade cannot finish the new recording")
        check(state.phase == .visible, "new recording stays visible")
        check(state.generation == newRecording, "stale callback leaves the current cycle intact")
        check(state.generation != scheduledDismissal, "old delayed dismiss cannot target a new recording")

        // Readiness/error presentations must invalidate old callbacks too.
        let replacedFade = state.beginDismiss()
        let currentFade = state.beginDismiss()
        check(!state.completeDismiss(replacedFade), "only the latest fade owns completion")
        check(state.completeDismiss(currentFade), "current fade can finish")
        check(state.phase == .hidden, "completed fade hides the HUD")
        check(!state.completeDismiss(currentFade), "completion runs at most once")

        state.present()
        let beforeRefresh = state.generation
        state.present()
        check(state.generation != beforeRefresh, "refreshing a visible HUD also invalidates old timers")
        check(state.phase == .visible, "refresh keeps the HUD visible")
    }

    static func updatePrompt(_ check: (Bool, String) -> Void) {
        let suite = "WhisprStream-ReleaseLifecycleChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = AppUpdatePromptPolicy(defaults: defaults)

        check(!policy.shouldPresent(version: "1.0.3", isBusy: true), "recording defers the prompt")
        check(!policy.shouldPresent(version: "1.0.3", isBusy: true), "review/probe/paste still defer it")
        check(defaults.string(forKey: AppUpdatePromptPolicy.lastPromptedVersionKey) == nil,
              "deferral must not consume the available version")
        check(policy.shouldPresent(version: "1.0.3", isBusy: false), "completion allows a deferred prompt")
        // A new recording can begin between scheduling and executing the retry.
        check(!policy.shouldPresent(version: "1.0.3", isBusy: true), "retry rechecks current activity")
        check(policy.shouldPresent(version: "1.0.3"), "next idle period can retry again")
        policy.markPresented(version: "1.0.3")
        check(!policy.shouldPresent(version: "1.0.3"), "shown version is not repeated")
        check(!policy.shouldPresent(version: "1.0.4", isBusy: true), "later versions also respect dictation")
        check(policy.shouldPresent(version: "1.0.4"), "later version is eligible when idle")
    }
}
