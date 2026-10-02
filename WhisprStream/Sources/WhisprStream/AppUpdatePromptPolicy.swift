import Foundation

/// A busy dictation defers the automatic prompt without consuming its version.
/// The caller retries after the HUD, review, cursor probe, and paste finish.
struct AppUpdatePromptPolicy {
    static let lastPromptedVersionKey = "updates.lastPromptedVersion"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shouldPresent(version: String, isBusy: Bool = false) -> Bool {
        !isBusy && defaults.string(forKey: Self.lastPromptedVersionKey) != version
    }

    func markPresented(version: String) {
        defaults.set(version, forKey: Self.lastPromptedVersionKey)
    }
}
