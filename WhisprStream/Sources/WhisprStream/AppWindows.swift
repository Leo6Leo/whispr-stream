import AppKit
import SwiftUI

/// Creates and reuses the app's auxiliary windows.
///
/// The app runs as an `.accessory` (no Dock icon), so it must explicitly
/// activate itself when showing a window or the window appears behind whatever
/// the user was using and can't take keyboard input.
@MainActor
final class AppWindows {
    private var onboarding: NSWindow?
    private var settings: NSWindow?
    private var about: NSWindow?
    private var updatePrompt: NSWindow?
    private var firstDictationCoach: FirstDictationCoachPanel?
    private var firstDictationCoachDismissal: DispatchWorkItem?

    // MARK: - Onboarding

    func showOnboarding(
        settings appSettings: Settings,
        runtime: RuntimeManager,
        onPrerequisitesReady: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        if let onboarding {
            present(onboarding)
            return
        }
        let window = makeWindow(
            title: "Welcome to WhisprStream",
            styleMask: [.titled, .closable, .fullSizeContentView]
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        let view = OnboardingView(
            settings: appSettings,
            runtime: runtime,
            onPrerequisitesReady: onPrerequisitesReady
        ) { [weak self] in
            self?.onboarding?.close()
            self?.onboarding = nil
            onFinish()
        }
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(NSSize(width: 580, height: 620))
        onboarding = window
        present(window)
    }

    // MARK: - First dictation coach

    func showFirstDictationCoach(shortcut: TriggerShortcut, mode: ActivationMode) {
        dismissFirstDictationCoach(animated: false)

        let coach = FirstDictationCoachPanel(shortcut: shortcut, mode: mode)
        firstDictationCoach = coach
        coach.present()

        let dismissal = DispatchWorkItem { [weak self, weak coach] in
            guard let self, let coach, self.firstDictationCoach === coach else { return }
            self.firstDictationCoach = nil
            self.firstDictationCoachDismissal = nil
            coach.dismiss(animated: true)
        }
        firstDictationCoachDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: dismissal)
    }

    func dismissFirstDictationCoach(animated: Bool = false) {
        firstDictationCoachDismissal?.cancel()
        firstDictationCoachDismissal = nil
        let coach = firstDictationCoach
        firstDictationCoach = nil
        coach?.dismiss(animated: animated)
    }

    // MARK: - Settings

    func showSettings(
        _ appSettings: Settings,
        runtime: RuntimeManager,
        updates: AppUpdateManager
    ) {
        if let settings {
            present(settings)
            return
        }
        let window = makeWindow(title: "Settings - WhisprStream", styleMask: [.titled, .closable])
        let host = NSHostingView(rootView: SettingsView(
            settings: appSettings,
            runtime: runtime,
            updates: updates,
            onShowUpdate: { [weak self, weak updates] in
                guard let updates else { return }
                self?.showUpdatePrompt(updates: updates)
            }
        ))
        window.contentView = host
        // Let the tabbed form declare its own size rather than forcing one —
        // a hard-coded height is what clipped the last section before.
        window.setContentSize(host.fittingSize)
        settings = window
        present(window)
    }

    // MARK: - About

    func showAbout(updates: AppUpdateManager) {
        if let about {
            present(about)
            return
        }
        let window = makeWindow(
            title: "About WhisprStream",
            styleMask: [.titled, .closable, .fullSizeContentView]
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: AboutView(
            updates: updates,
            onShowUpdate: { [weak self, weak updates] in
                guard let updates else { return }
                self?.showUpdatePrompt(updates: updates)
            }
        ))
        window.setContentSize(NSSize(width: 420, height: 430))
        about = window
        present(window)
    }

    // MARK: - App updates

    func showUpdatePrompt(updates: AppUpdateManager) {
        if let updatePrompt {
            present(updatePrompt)
            return
        }

        let window = makeWindow(
            title: "WhisprStream Update",
            styleMask: [.titled, .closable, .fullSizeContentView]
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: AppUpdatePromptView(
            updates: updates,
            onDismiss: { [weak window] in window?.close() }
        ))
        window.setContentSize(NSSize(width: 470, height: 390))
        updatePrompt = window
        present(window)
    }

    // MARK: - Plumbing

    private func makeWindow(title: String, styleMask: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
