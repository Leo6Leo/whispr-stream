import Foundation

/// Arrival times belong to glyphs, not hypotheses. A new hypothesis can arrive
/// before the preceding animation finishes; matching glyphs must never replay.
///
/// Ported from the Meeting Notes live transcript
/// (codex/local-meeting-transcription), which grouped arrivals into word
/// springs the same way.
struct LiveTextAnimation {
    struct Run: Equatable {
        var text: String
        let startedAt: Date?
    }

    /// One animated unit: an English word with its trailing punctuation and
    /// space, or a single CJK character with any punctuation that follows it.
    struct Word: Equatable {
        var text: String
        /// When this word's spring starts, already staggered after the other
        /// words from the same preview. Nil once settled.
        let startsAt: Date?
        let isCommitted: Bool
        /// True when the word was already on screen and changed (a revised
        /// spelling, a word that grew), as opposed to arriving new. Revisions
        /// refresh in place; only new words fade in from nothing.
        let isRevision: Bool
    }

    /// Words from one preview start 25 ms apart, bounded so a large result
    /// is never held back for long.
    static let stagger: TimeInterval = 0.025
    static let maximumStagger: TimeInterval = 0.18

    private(set) var text: String
    private var characters: [Character]
    private var arrivals: [Date?]
    /// Per character: inserted while other characters were removed from the
    /// same region, that is, as a replacement rather than an append.
    private var replaced: [Bool]
    /// How long an arrival stays live: the longest stagger plus the spring.
    private let retireAfter: TimeInterval

    init(stableText: String = "", retireAfter: TimeInterval = LiveTranscriptMotion.duration) {
        text = stableText
        characters = Array(stableText)
        arrivals = Array(repeating: nil, count: characters.count)
        replaced = Array(repeating: false, count: characters.count)
        self.retireAfter = retireAfter
    }

    var runs: [Run] {
        var result: [Run] = []
        for (character, arrival) in zip(characters, arrivals) {
            if !result.isEmpty && result[result.count - 1].startedAt == arrival {
                result[result.count - 1].text.append(character)
            } else {
                result.append(Run(text: String(character), startedAt: arrival))
            }
        }
        return result
    }

    /// Words with their staggered start times. A word animates whole when any
    /// of its own letters is new, so a revised word springs in again while
    /// untouched neighbours stay put. Trailing spaces and punctuation ride
    /// with the word for layout but never replay it: the space that arrives
    /// with the next word, or a period the model adds later, must not blink a
    /// word the user has already read. Words never straddle `committedCount`,
    /// so each keeps a single style.
    func words(committedCount: Int) -> [Word] {
        var result: [Word] = []
        var staggerIndex: [Date: Int] = [:]
        for range in Self.wordRanges(in: characters, splittingAt: committedCount) {
            let core = range.filter { Self.isCJK(characters[$0]) || Self.isWordCharacter(characters[$0]) }
            let source = core.isEmpty ? Array(range) : core
            let fresh = source.filter { arrivals[$0] != nil }
            let arrival = fresh.compactMap { arrivals[$0] }.max()
            var startsAt: Date?
            if let arrival {
                let index = staggerIndex[arrival, default: 0]
                staggerIndex[arrival] = index + 1
                startsAt = arrival.addingTimeInterval(
                    min(Double(index) * Self.stagger, Self.maximumStagger)
                )
            }
            // A word that kept some of its letters, or whose new letters took
            // the place of removed ones, was already being read: it changed,
            // it did not arrive.
            let isRevision = arrival != nil
                && (fresh.count < source.count || fresh.contains { replaced[$0] })
            result.append(Word(
                text: String(characters[range]),
                startsAt: startsAt,
                isCommitted: range.lowerBound < committedCount,
                isRevision: isRevision
            ))
        }
        return result
    }

    var animationEnd: Date? {
        arrivals.compactMap { $0 }.max()?.addingTimeInterval(retireAfter)
    }

    mutating func update(to newText: String, at now: Date) {
        // Continuous 200 ms previews can outpace the animation indefinitely.
        // Retire finished glyphs here as well as on idle, keeping frame work
        // bounded to the recent tail even throughout uninterrupted speech.
        settle(at: now)
        guard text != newText else { return }
        // The first words of an utterance appear at once. The capsule is
        // already fading them in from "Listening…"; a stagger and a spring on
        // top only delay the moment the user sees they were heard.
        if characters.isEmpty {
            characters = Array(newText)
            arrivals = Array(repeating: nil, count: characters.count)
            replaced = Array(repeating: false, count: characters.count)
            text = newText
            return
        }
        let next = Array(newText)
        let prefix = zip(characters, next).prefix { $0 == $1 }.count
        var suffix = 0
        while suffix < min(characters.count, next.count) - prefix,
              characters[characters.count - suffix - 1] == next[next.count - suffix - 1] {
            suffix += 1
        }
        // Trim the stable paragraph first. Align only the edited middle so a
        // correction plus an append doesn't reanimate the words between them.
        let oldMiddle = Array(characters[prefix..<(characters.count - suffix)])
        let newMiddle = Array(next[prefix..<(next.count - suffix)])
        // Prefer earlier occurrences when an appended word repeats a letter
        // from the existing tail (e.g. "plan" → "plan. Bring notes"). The
        // standard forward diff otherwise pairs that letter with the append.
        let difference = Array(newMiddle.reversed()).difference(from: Array(oldMiddle.reversed()))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(oldMiddle.count - 1 - offset)
            case let .insert(offset, _, _): inserted.insert(newMiddle.count - 1 - offset)
            }
        }
        var survivors = oldMiddle.indices.filter { !removed.contains($0) }
            .map { (arrivals[prefix + $0], replaced[prefix + $0]) }.makeIterator()
        // Insertions that coincide with removals are replacements; a region
        // that only grew is an append.
        let isReplacement = !removed.isEmpty
        var middleArrivals: [Date?] = []
        var middleReplaced: [Bool] = []
        for index in newMiddle.indices {
            if inserted.contains(index) {
                middleArrivals.append(now)
                middleReplaced.append(isReplacement)
            } else {
                let survivor = survivors.next() ?? (nil, false)
                middleArrivals.append(survivor.0)
                middleReplaced.append(survivor.1)
            }
        }
        arrivals = Array(arrivals.prefix(prefix)) + middleArrivals + Array(arrivals.suffix(suffix))
        replaced = Array(replaced.prefix(prefix)) + middleReplaced + Array(replaced.suffix(suffix))
        characters = next
        text = newText
    }

    mutating func settle(at now: Date) {
        for index in arrivals.indices {
            if let arrival = arrivals[index], now.timeIntervalSince(arrival) >= retireAfter {
                arrivals[index] = nil
                replaced[index] = false
            }
        }
    }

    /// Splits text into animation units. Latin words stay whole (apostrophes
    /// included), unspaced CJK animates per character, and punctuation and
    /// spaces ride with the unit before them.
    static func wordRanges(in characters: [Character], splittingAt boundary: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < characters.count {
            let start = index
            let limit = start < boundary ? min(boundary, characters.count) : characters.count
            if isCJK(characters[index]) {
                index += 1
            } else if isWordCharacter(characters[index]) {
                while index < limit,
                      isWordCharacter(characters[index])
                        || (isApostrophe(characters[index])
                            && index + 1 < limit
                            && isWordCharacter(characters[index + 1])) {
                    index += 1
                }
            }
            while index < limit,
                  !isCJK(characters[index]),
                  !isWordCharacter(characters[index]) {
                index += 1
            }
            if index == start { index += 1 }
            ranges.append(start..<index)
        }
        return ranges
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        !isCJK(character) && (character.isLetter || character.isNumber || character == "_")
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x20000...0x2FFFF: // CJK Extensions B+
            return true
        default:
            return false
        }
    }
}
