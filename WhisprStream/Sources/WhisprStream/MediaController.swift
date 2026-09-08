import AppKit
import Foundation

/// A media app WhisprStream can pause and resume around dictation.
enum MediaApp: String, CaseIterable {
    case music = "Music"
    case spotify = "Spotify"

    var bundleIdentifier: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }
}

/// Abstracts real player control so the pause/resume bookkeeping can be tested
/// without scripting live apps.
protocol MediaPlayerBackend {
    /// True only when the app is running AND currently playing. Must never
    /// launch a closed app just to answer.
    func isPlaying(_ app: MediaApp) -> Bool
    func pause(_ app: MediaApp)
    func play(_ app: MediaApp)
}

/// Pauses whatever music is playing while the microphone is open and resumes
/// exactly what it paused.
///
/// On macOS, opening the mic forces Bluetooth headsets from stereo (A2DP) down
/// to call-quality (HFP), so playback audibly drops the moment dictation starts.
/// Pausing during the recording window avoids that, and only what WhisprStream
/// paused is resumed — music that was already stopped is never started.
final class MediaController {
    private let backend: MediaPlayerBackend
    private let isEnabled: () -> Bool
    private let execute: (@escaping () -> Void) -> Void

    /// Mutated only inside `execute`, which is serial, so no extra locking.
    private var pausedApps: [MediaApp] = []

    private static let controlQueue = DispatchQueue(label: "whisprstream.media-control")

    init(
        backend: MediaPlayerBackend = AppleScriptMediaBackend(),
        isEnabled: @escaping () -> Bool,
        execute: @escaping (@escaping () -> Void) -> Void = { work in
            MediaController.controlQueue.async(execute: work)
        }
    ) {
        self.backend = backend
        self.isEnabled = isEnabled
        self.execute = execute
    }

    /// Pause every currently-playing known app, remembering them for resume.
    /// Scripting runs off the caller's thread so the HUD isn't delayed.
    func pauseForDictation() {
        guard isEnabled() else { return }
        execute { [self] in
            guard pausedApps.isEmpty else { return }   // a session is already paused
            for app in MediaApp.allCases where backend.isPlaying(app) {
                backend.pause(app)
                pausedApps.append(app)
            }
        }
    }

    /// Resume exactly the apps this controller paused. Idempotent: safe to call
    /// when nothing was paused, so abnormal stop paths can call it defensively.
    func resumeAfterDictation() {
        execute { [self] in
            let toResume = pausedApps
            pausedApps.removeAll()
            for app in toResume { backend.play(app) }
        }
    }
}

/// Controls Music and Spotify through `osascript`. Runs off the main thread (on
/// the controller's serial queue), and only ever scripts an app that is already
/// running, so a closed player is never launched.
struct AppleScriptMediaBackend: MediaPlayerBackend {
    func isPlaying(_ app: MediaApp) -> Bool {
        guard isRunning(app) else { return false }
        return runScript("tell application \"\(app.rawValue)\" to player state is playing") == "true"
    }

    func pause(_ app: MediaApp) {
        guard isRunning(app) else { return }
        runScript("tell application \"\(app.rawValue)\" to pause")
    }

    func play(_ app: MediaApp) {
        guard isRunning(app) else { return }
        runScript("tell application \"\(app.rawValue)\" to play")
    }

    private func isRunning(_ app: MediaApp) -> Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: app.bundleIdentifier)
            .isEmpty
    }

    @discardableResult
    private func runScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()   // swallow "not authorized" / errors
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
