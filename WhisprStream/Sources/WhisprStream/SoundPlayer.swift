import AVFoundation
import Foundation

/// Plays macOS's built-in alert sounds and the app's own sounds.
///
/// Each file gets one cached, pre-buffered `AVAudioPlayer`, so a cue starts
/// without disk or decoder latency.
///
/// This used to go through `AudioServicesPlaySystemSound`, which follows the
/// alert-volume setting. On macOS 27.0.1 that API plays every sound twice
/// (one call, one completion, two audible copies) while `afplay` and
/// `AVAudioPlayer` play the same file once. The trade-off is that cues now
/// follow output volume instead of alert volume. Playing in-process also
/// keeps them inside `excludesCurrentProcessAudio` for system audio capture.
final class SoundPlayer {
    static let shared = SoundPlayer()

    private var players: [String: AVAudioPlayer] = [:]
    private let lock = NSLock()

    private init() {}

    /// Directories scanned for sounds, in priority order.
    private static let directories = [
        "/System/Library/Sounds",
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds"),
    ]

    /// Every playable sound name, de-duplicated, system first then user.
    static let available: [String] = {
        var seen = Set<String>()
        var names: [String] = []
        for dir in directories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for file in files.sorted() {
                let name = (file as NSString).deletingPathExtension
                guard !name.isEmpty, !seen.contains(name), url(for: name) != nil else { continue }
                seen.insert(name)
                names.append(name)
            }
        }
        return names
    }()

    static func url(for name: String) -> URL? {
        for dir in directories {
            for ext in ["aiff", "aif", "wav", "m4a", "caf"] {
                let path = (dir as NSString).appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    /// Marks an id as one of the app's own sounds rather than a macOS alert
    /// sound, so the two namespaces can share one cache without colliding.
    private static let bundledPrefix = "bundled:"

    static func bundledID(_ file: String) -> String { bundledPrefix + file }

    /// Resolves either namespace to a file on disk.
    private static func resolve(_ id: String) -> URL? {
        guard id.hasPrefix(bundledPrefix) else { return url(for: id) }
        let file = String(id.dropFirst(bundledPrefix.count))
        return Bundle.main.url(forResource: file, withExtension: "caf", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: file, withExtension: "caf")
    }

    /// Loads a sound and caches its player. Safe to call repeatedly.
    @discardableResult
    func prepare(_ name: String) -> Bool {
        player(for: name) != nil
    }

    func play(_ name: String) {
        guard let player = player(for: name) else { return }
        // Restart rather than overlap when the same cue fires again mid-play.
        player.currentTime = 0
        player.play()
    }

    private func player(for name: String) -> AVAudioPlayer? {
        lock.lock()
        defer { lock.unlock() }

        if let player = players[name] { return player }
        guard let url = Self.resolve(name),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[name] = player
        return player
    }

    /// Plays one of the app's own bundled sounds.
    func playBundled(_ file: String) { play(Self.bundledID(file)) }

    func prepareBundled(_ file: String) { prepare(Self.bundledID(file)) }
}
