import Foundation

/// A designed start/finish sound pair.
///
/// The audio is rendered offline by `sound-design/render_sounds.py`, a port of
/// the Web Audio graph in `sound-design/index.html`, into
/// `Resources/Sounds/<slug>-{start,finish}.caf`. Editing a pair means editing
/// the builder in that script and re-running it — nothing here synthesises audio.
enum SoundPair: String, CaseIterable, Identifiable {
    case openResolve, clickDouble
    case risingRun, motifPhrase, callAnswer
    case crispClick, deepClick, tripleClick, chirpClick
    case appleReference

    var id: String { rawValue }

    /// Filename stem shared by both halves.
    var slug: String {
        switch self {
        case .openResolve: return "open-resolve"
        case .clickDouble: return "click-double"
        case .risingRun: return "rising-run"
        case .motifPhrase: return "motif-phrase"
        case .callAnswer: return "call-answer"
        case .crispClick: return "crisp-click"
        case .deepClick: return "deep-click"
        case .tripleClick: return "triple-click"
        case .chirpClick: return "chirp-click"
        case .appleReference: return "apple-ref"
        }
    }

    var label: String {
        switch self {
        case .openResolve: return "Open → Resolve"
        case .clickDouble: return "Click → Double-Click"
        case .risingRun: return "Rising Run → Cascade"
        case .motifPhrase: return "Motif → Phrase"
        case .callAnswer: return "Call → Answer"
        case .crispClick: return "Crisp Click"
        case .deepClick: return "Deep Click"
        case .tripleClick: return "Click → Triple Click"
        case .chirpClick: return "Click → Chirp"
        case .appleReference: return "Dictation (reference)"
        }
    }

    var detail: String {
        switch self {
        case .openResolve:
            return "Start plays an open interval, like a question. Finish recalls it, then climbs to complete the chord an octave up."
        case .clickDouble:
            return "A tuned click with almost no pitch, built for near-zero fatigue across hundreds of uses a day. Finish adds one brighter click."
        case .risingRun:
            return "Start is a quick three-note run. Finish recalls it, then leaps on to finish the scale an octave up."
        case .motifPhrase:
            return "Start is a small melodic turn — up, down, up. Finish recalls the turn, then extends it into a resolving phrase."
        case .callAnswer:
            return "The only pair that resolves downward. Start rises like a question; finish answers it, settling back home."
        case .crispClick:
            return "Very short, very bright, no pitch at all — the most mechanical option, like a camera shutter half-press."
        case .deepClick:
            return "A low, weighty thock with a soft tone underneath for body. Heavier than the standard click."
        case .tripleClick:
            return "The standard click, with a third quieter click trailing the finish — a mechanism settling into place."
        case .chirpClick:
            return "The standard click, with the finish's pitch whisper swapped for a tiny upward sweep. Motion, not melody."
        case .appleReference:
            return "A plain two-note pair, up to start and down to finish. Deliberately unlayered — closest to a familiar system chime."
        }
    }

    /// How long the start half rings, used to space the two halves when
    /// auditioning. Matches the durations declared in `index.html`.
    var startDuration: TimeInterval {
        switch self {
        case .openResolve: return 0.22
        case .clickDouble, .tripleClick, .chirpClick: return 0.05
        case .risingRun: return 0.19
        case .motifPhrase: return 0.21
        case .callAnswer: return 0.24
        case .crispClick: return 0.03
        case .deepClick: return 0.07
        case .appleReference: return 0.21
        }
    }

    var startFile: String { "\(slug)-start" }
    var finishFile: String { "\(slug)-finish" }

    /// Grouped exactly as the design page presents them.
    static let groups: [(String, [SoundPair])] = [
        ("Recommended", [.openResolve, .clickDouble]),
        ("Melodic", [.risingRun, .motifPhrase, .callAnswer]),
        ("Clicks", [.crispClick, .deepClick, .tripleClick, .chirpClick]),
        ("Plain", [.appleReference]),
    ]
}

/// What the app plays around a dictation.
///
/// `system` is the original behaviour and is deliberately kept: a single macOS
/// alert sound on insert, nothing on start. `systemDefault` is the pair macOS's
/// own dictation uses, read from a private system framework rather than
/// bundled. Only pairs and the system default have a start half, so selecting
/// one is what turns the start sound on.
enum SoundTheme: Hashable {
    case pair(SoundPair)
    case systemDefault
    case system(String)

    /// File stems of macOS's own dictation cues inside
    /// AssistantServices.framework, plus the start cue's ring time, used to
    /// space the two halves when auditioning.
    static let systemDefaultStartFile = "dt-begin"
    static let systemDefaultFinishFile = "dt-confirm"
    static let systemDefaultStartDuration: TimeInterval = 0.32

    var storageValue: String {
        switch self {
        case let .pair(p): return "pair:\(p.rawValue)"
        case .systemDefault: return "system-default"
        case let .system(name): return "system:\(name)"
        }
    }

    /// Parses stored values, tolerating the pre-pairs format.
    ///
    /// Before pairs existed the key held a bare alert-sound name ("Funk"), so a
    /// value with no prefix is one of those and must keep working untouched.
    init?(storageValue raw: String) {
        if let name = raw.stripping("pair:") {
            guard let pair = SoundPair(rawValue: name) else { return nil }
            self = .pair(pair)
        } else if raw == SoundTheme.systemDefault.storageValue {
            self = .systemDefault
        } else if let name = raw.stripping("system:") {
            self = .system(name)
        } else if !raw.isEmpty {
            self = .system(raw)
        } else {
            return nil
        }
    }

    var label: String {
        switch self {
        case let .pair(p): return p.label
        case .systemDefault: return "System Default"
        case let .system(name): return name
        }
    }
}

private extension String {
    func stripping(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
