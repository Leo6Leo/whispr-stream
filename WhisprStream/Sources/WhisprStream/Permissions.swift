import AVFoundation
import AppKit
import SwiftUI

/// Live view of the permissions the app uses.
///
/// Microphone and Accessibility are required for dictation. Screen & System
/// Audio Recording is optional: macOS routes system audio through it, so it
/// only matters while "System audio" is the selected source, and onboarding
/// never asks for it.
///
/// macOS never notifies an app that a permission changed, so onboarding polls.
/// Accessibility in particular only re-reads as granted after the user flips the
/// switch in System Settings, and there is no callback for it.
@MainActor
final class Permissions: ObservableObject {
    @Published private(set) var microphone: AVAuthorizationStatus = .notDetermined
    @Published private(set) var accessibility: Bool = false
    @Published private(set) var screenCapture: Bool = false

    private var timer: Timer?

    init() { refresh() }

    /// The required pair. Screen capture is deliberately left out: microphone
    /// dictation works without it.
    var allGranted: Bool { microphone == .authorized && accessibility }

    /// Preflight only; never prompts. For call sites with no reason to hold a
    /// live `Permissions` object, such as the dictation start path.
    static var isScreenCaptureGranted: Bool { CGPreflightScreenCaptureAccess() }

    func refresh() {
        // Assign only on change. `@Published` publishes on every set, and the
        // onboarding polls this every 0.6 s; republishing identical values
        // re-rendered the whole Setup Guide on each tick, which made its
        // looping welcome animation hitch.
        let currentMicrophone = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphone != currentMicrophone { microphone = currentMicrophone }
        // Never prompt from a poll — the prompts are triggered explicitly below.
        let currentAccessibility = AXIsProcessTrusted()
        if accessibility != currentAccessibility { accessibility = currentAccessibility }
        let currentScreenCapture = Self.isScreenCaptureGranted
        if screenCapture != currentScreenCapture { screenCapture = currentScreenCapture }
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

    /// Shows the system Screen & System Audio Recording prompt. macOS shows it
    /// once; after that only the switch in System Settings can change the
    /// answer, so fall through to opening the pane directly.
    func requestScreenCapture() {
        refresh()
        guard !screenCapture else { return }
        if !CGRequestScreenCaptureAccess() {
            openSettings(.screenCapture)
        }
        refresh()
    }

    enum Pane {
        case microphone, accessibility, screenCapture

        var url: URL {
            switch self {
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenCapture:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    func openSettings(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}
