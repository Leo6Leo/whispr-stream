import AppKit
import ServiceManagement

/// Registers and unregisters the app's login item. The system owns the actual
/// state, so callers should read `isEnabled` instead of caching a value.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Applies the preference; returns false when the system rejects it.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.write(
                "login item \(enabled ? "registration" : "unregistration") failed: "
                    + error.localizedDescription
            )
            return false
        }
    }

    /// Deep-links to the pane where macOS manages login items.
    static func openSystemSettingsPane() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}
