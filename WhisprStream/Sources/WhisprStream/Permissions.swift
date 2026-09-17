import AVFoundation
import AppKit
import SwiftUI

/// Live view of the two permissions the app needs.
///
/// macOS never notifies an app that a permission changed, so onboarding polls.
/// Accessibility in particular only re-reads as granted after the user flips the
/// switch in System Settings, and there is no callback for it.
@MainActor
final class Permissions: ObservableObject {
    @Published private(set) var microphone: AVAuthorizationStatus = .notDetermined
    @Published private(set) var accessibility: Bool = false

    private var timer: Timer?

    init() { refresh() }

    var allGranted: Bool { microphone == .authorized && accessibility }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        // Never prompt from a poll — the prompt is triggered explicitly below.
        accessibility = AXIsProcessTrusted()
    }

    /// Polls while onboarding is on screen so cards update the moment a
    /// permission is granted in System Settings.
    func beginPolling() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func endPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Requests

    func requestMicrophone() {
        // A click can arrive before the next poll after returning from Settings.
        refresh()
        guard microphone != .authorized else { return }
        guard microphone == .notDetermined else {
            openSettings(.microphone)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    /// Shows the system Accessibility prompt. Once denied, macOS won't show it
    /// again, so fall through to opening the settings pane directly.
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !trusted {
            openSettings(.accessibility)
        }
        refresh()
    }

    enum Pane {
        case microphone, accessibility

        var url: URL {
            switch self {
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            }
        }
    }

    func openSettings(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}
