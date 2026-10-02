// Command Line Tools fallback: compile with HUDPresentationState.swift,
// AppUpdatePromptPolicy.swift, and the shared ReleaseLifecycleChecks.swift.
@main
struct ReleaseLifecycleRunner {
    static func main() {
        var checks = 0
        let check: (Bool, String) -> Void = { condition, message in
            precondition(condition, message)
            checks += 1
        }
        ReleaseLifecycleChecks.hud(check)
        ReleaseLifecycleChecks.updatePrompt(check)
        print("\(checks) HUD lifecycle and automatic update checks passed.")
    }
}
