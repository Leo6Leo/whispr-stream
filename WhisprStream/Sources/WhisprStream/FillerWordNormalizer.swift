import Foundation

/// Removes hesitation sounds the speech engine transcribes verbatim, such as
/// `um`, `uh`, and `呃`, and repairs the punctuation left around them.
///
/// Words fall into two tiers. Unambiguous hesitations are removed wherever
/// they stand alone. Words that are also real speech (`啊` as a sentence
/// particle, `嗯` as "yes", `ah` as an interjection) are removed only when
/// they stand alone and their position marks a pause: opening a sentence
/// (unless a reply such as `好的` follows), repeating, sitting between commas,
/// or next to an unambiguous hesitation. Context-dependent words such as `那个` or `like`
/// are never touched.
enum FillerWordNormalizer {
    private enum Tier {
        case always
        case isolated
    }

    private struct Token {
        let range: Range<String.Index>
        let tier: Tier
        let isCapitalized: Bool
    }

    private struct Removal {
        let range: Range<String.Index>
        let joiner: String
        let capitalizesNextWord: Bool
    }

    private static let latinFillers: [String: Tier] = [
        "um": .always, "umm": .always, "uh": .always, "uhh": .always,
        "uhm": .always, "erm": .always,
        "ah": .isolated
    ]

    private static let cjkFillers: [Character: Tier] = [
        "呃": .always,
        "啊": .isolated, "嗯": .isolated, "额": .isolated
    ]

    private static let commas: Set<Character> = [",", "，", "、"]

    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？"
    ]

    static func normalize(_ text: String) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        let removals = groupIntoRuns(tokens, in: text).compactMap { removal(for: $0, in: text) }
        guard !removals.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        var capitalizeNext = false
        for removal in removals where removal.range.lowerBound >= cursor {
            appendSegment(text[cursor..<removal.range.lowerBound], to: &result, capitalizing: capitalizeNext)
            result += removal.joiner
            cursor = removal.range.upperBound
            capitalizeNext = removal.capitalizesNextWord
        }
        appendSegment(text[cursor...], to: &result, capitalizing: capitalizeNext)

        // A dictation made only of hesitations has nothing left to insert.
        guard result.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return result
    }

    // MARK: - Tokens and runs

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if let tier = cjkFillers[character] {
                let next = text.index(after: index)
                if let token = cjkToken(character, tier: tier, at: index..<next, in: text) {
                    tokens.append(token)
                }
                index = next
                continue
            }

            guard isASCIILetter(character) else {
                index = text.index(after: index)
                continue
            }

            let start = index
            while index < text.endIndex, isASCIILetter(text[index]) {
                index = text.index(after: index)
            }
            let word = String(text[start..<index])
            guard let tier = latinFillers[word.lowercased()],
                  !isJoinedToWord(before: start, in: text),
                  !isJoinedToWord(after: index, in: text),
                  !isAcronym(word)
            else { continue }
            tokens.append(Token(
                range: start..<index,
                tier: tier,
                isCapitalized: word.first?.isUppercase == true
            ))
        }
        return tokens
    }

    private static func cjkToken(
        _ character: Character,
        tier: Tier,
        at range: Range<String.Index>,
        in text: String
    ) -> Token? {
        switch tier {
        case .always:
            // 呃逆 is a hiccup, not a hesitation.
            if range.upperBound < text.endIndex, text[range.upperBound] == "逆" { return nil }
        case .isolated:
            // Attached to a word, these are particles (好啊) or repeats (嗯嗯).
            if range.lowerBound > text.startIndex,
               text[text.index(before: range.lowerBound)].isLetter { return nil }
            if range.upperBound < text.endIndex, text[range.upperBound].isLetter { return nil }
        }
        return Token(range: range, tier: tier, isCapitalized: false)
    }

    /// Adjacent fillers separated only by spaces or commas (`um, ah,`) are
    /// removed together so their shared punctuation is repaired once.
    private static func groupIntoRuns(_ tokens: [Token], in text: String) -> [[Token]] {
        var runs: [[Token]] = []
        for token in tokens {
            if let previous = runs.last?.last,
               text[previous.range.upperBound..<token.range.lowerBound].allSatisfy(isSeparator) {
                runs[runs.count - 1].append(token)
            } else {
                runs.append([token])
            }
        }
        return runs
    }

    // MARK: - Removal and punctuation repair

    private static func removal(for run: [Token], in text: String) -> Removal? {
        guard let first = run.first, let last = run.last else { return nil }

        let previous = previousNonWhitespace(before: first.range.lowerBound, in: text)
        let following = nextNonWhitespace(from: last.range.upperBound, in: text)
        let atSentenceStart = previous.map { sentenceTerminators.contains(text[$0]) } ?? true

        // The run takes its own trailing commas and spaces with it:
        // `sure, um, which` -> `sure, which`.
        var start = first.range.lowerBound
        var end = last.range.upperBound
        while end < text.endIndex, isSeparator(text[end]) {
            end = text.index(after: end)
        }

        guard isRemovable(run, previous: previous, following: following,
                          atSentenceStart: atSentenceStart, nextWordAt: end, in: text)
        else { return nil }

        let right: Character? = end < text.endIndex ? text[end] : nil
        if right.map(sentenceTerminators.contains) ?? true {
            if atSentenceStart, right != nil {
                // `that. Um. So` -> `that. So`: the hesitation was a whole sentence.
                while end < text.endIndex,
                      sentenceTerminators.contains(text[end]) || text[end].isWhitespace {
                    end = text.index(after: end)
                }
            } else {
                // `I think, um.` -> `I think.`
                while start > text.startIndex,
                      isSeparator(text[text.index(before: start)]) {
                    start = text.index(before: start)
                }
            }
        }

        return Removal(
            range: start..<end,
            joiner: joiner(between: start, and: end, removing: text[start..<end], in: text),
            capitalizesNextWord: atSentenceStart && first.isCapitalized
        )
    }

    /// Ambiguous words are hesitations when they open a sentence, repeat
    /// (`嗯，啊，`), or sit between commas mid-sentence. The one exception is a
    /// sentence-opening reply such as `嗯，好的` or `Ah, I see`.
    private static func isRemovable(
        _ run: [Token],
        previous: String.Index?,
        following: String.Index?,
        atSentenceStart: Bool,
        nextWordAt next: String.Index,
        in text: String
    ) -> Bool {
        if run.contains(where: { $0.tier == .always }) { return true }
        if atSentenceStart {
            return !run.contains { opensReply($0, nextWordAt: next, in: text) }
        }
        if run.count >= 2 { return true }
        let afterComma = previous.map { commas.contains(text[$0]) } ?? false
        let beforePause = following.map {
            commas.contains(text[$0]) || sentenceTerminators.contains(text[$0])
        } ?? false
        return afterComma && beforePause
    }

    private static let replyOpenings: [String: [String]] = [
        "嗯": ["好", "对", "是", "行", "可以", "没问题", "ok", "okay", "yes", "yeah"],
        "啊": ["原来", "对了", "是吗", "好"],
        "ah": ["i see", "ok", "okay", "right", "yes", "yeah"]
    ]

    private static func opensReply(_ token: Token, nextWordAt next: String.Index, in text: String) -> Bool {
        guard let openings = replyOpenings[text[token.range].lowercased()] else { return false }
        let rest = text[next...]
        return openings.contains { opening in
            guard rest.lowercased().hasPrefix(opening) else { return false }
            // `ok` must not match `okra`; Chinese openings have no word boundary.
            guard opening.first?.isASCII == true else { return true }
            let boundary = rest.index(rest.startIndex, offsetBy: opening.count)
            return boundary == rest.endIndex || !isASCIILetter(rest[boundary])
        }
    }

    /// Keeps a word boundary only where the removed text had one and neither
    /// neighbor already provides it: `一呃 meet` -> `一 meet`, but
    /// `这个呃，Warmer` -> `这个Warmer`.
    private static func joiner(
        between start: String.Index,
        and end: String.Index,
        removing removed: Substring,
        in text: String
    ) -> String {
        guard start > text.startIndex, end < text.endIndex else { return "" }
        let left = text[text.index(before: start)]
        let right = text[end]
        guard !left.isWhitespace, !right.isWhitespace,
              !commas.contains(left), !sentenceTerminators.contains(right),
              removed.contains(where: \.isWhitespace)
        else { return "" }
        return " "
    }

    private static func appendSegment(_ segment: Substring, to result: inout String, capitalizing: Bool) {
        guard capitalizing, let first = segment.first, first.isASCII, first.isLowercase else {
            result += segment
            return
        }
        let word = segment.prefix(while: \.isLetter)
        // Leave mixed-case names such as `iPhone` alone.
        guard !word.dropFirst().contains(where: \.isUppercase) else {
            result += segment
            return
        }
        result += first.uppercased()
        result += segment.dropFirst()
    }

    // MARK: - Character classes

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || commas.contains(character)
    }

    private static func previousNonWhitespace(before index: String.Index, in text: String) -> String.Index? {
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            if !text[cursor].isWhitespace { return cursor }
        }
        return nil
    }

    private static func nextNonWhitespace(from index: String.Index, in text: String) -> String.Index? {
        var cursor = index
        while cursor < text.endIndex {
            if !text[cursor].isWhitespace { return cursor }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    /// `uh-oh`, `um's`, and longer words that merely start with a filler are
    /// not hesitations.
    private static func isJoinedToWord(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return false }
        let adjacent = text[text.index(before: index)]
        return (adjacent.isASCII && (adjacent.isLetter || adjacent.isNumber)) || isWordJoiner(adjacent)
    }

    private static func isJoinedToWord(after index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return false }
        let adjacent = text[index]
        return (adjacent.isASCII && adjacent.isNumber) || isWordJoiner(adjacent)
    }

    private static func isWordJoiner(_ character: Character) -> Bool {
        character == "'" || character == "’" || character == "-"
    }

    /// `UM` or `UH` written in capitals is an abbreviation, not a hesitation.
    private static func isAcronym(_ word: String) -> Bool {
        word.count >= 2 && word.allSatisfy(\.isUppercase)
    }
}
