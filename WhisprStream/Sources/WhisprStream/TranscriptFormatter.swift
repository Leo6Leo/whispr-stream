import Foundation

/// Applies the user's sentence-ending punctuation preference to final text.
enum TranscriptFormatter {
    /// Removes punctuation added at the end of a transcript when punctuation
    /// is disabled. Internal punctuation and closing quotes/brackets are
    /// preserved. Cursor-separating whitespace is added only on the insertion
    /// path so the HUD and retained clipboard stay clean.
    static func format(_ text: String, usePunctuation: Bool) -> String {
        guard !usePunctuation else { return text }

        var result = text
        while result.last?.isWhitespace == true {
            result.removeLast()
        }

        var closingSuffix: [Character] = []
        while let last = result.last, closingCharacters.contains(last) {
            closingSuffix.append(last)
            result.removeLast()
        }
        while let last = result.last, sentenceTerminators.contains(last) {
            result.removeLast()
        }
        result.append(contentsOf: closingSuffix.reversed())
        return result
    }

    /// Text pasted at the cursor must not fuse with the word before it, or
    /// consecutive dictations become `Hello.World`. When the text before the
    /// cursor is known, the separator is decided from it: none after
    /// whitespace, at a line start, in an empty field, after an opening
    /// bracket or quote, or next to CJK text; one space after a Latin word or
    /// sentence punctuation. Unknown context keeps the trailing space earlier
    /// releases always added. The result is written to the pasteboard exactly
    /// once and is what the clipboard keeps afterwards; the HUD shows `text`.
    static func textForInsertion(_ text: String, precedingText: String? = nil) -> String {
        guard !text.isEmpty else { return text }
        guard let precedingText else {
            return text.last?.isWhitespace == true ? text : text + " "
        }
        return needsSeparator(between: precedingText, and: text) ? " " + text : text
    }

    /// Whether a space belongs between `precedingText` and `text`.
    static func needsSeparator(between precedingText: String, and text: String) -> Bool {
        guard let last = precedingText.last, let first = text.first else { return false }
        if last.isWhitespace || first.isWhitespace { return false }
        if isCJK(last) || isCJK(first) { return false }
        if attachesToNext.contains(last) || attachesToPrevious.contains(first) { return false }
        return true
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }

    /// Characters that attach to what follows them. Straight quotes and
    /// backticks are ambiguous between opening and closing and are left out.
    private static let attachesToNext: Set<Character> = [
        "(", "[", "{", "“", "‘", "«", "‹", "/", "\\", "@", "#", "$", "-", "–", "—", "_"
    ]

    /// Characters that attach to what precedes them.
    private static let attachesToPrevious: Set<Character> = [
        ",", ".", ";", ":", "!", "?", ")", "]", "}", "”", "’", "»", "›", "%"
    ]

    /// Removes sentence-style capitalization when dictation continues text
    /// immediately before the cursor. Unknown cursor context is deliberately a
    /// no-op, as are sentence boundaries, the pronoun "I", and acronyms.
    static func adjustedForCursor(_ text: String, precedingText: String?) -> String {
        guard !text.isEmpty,
              let precedingText,
              isContinuation(precedingText),
              let firstLetter = text.firstIndex(where: \.isLetter)
        else { return text }

        let word = text[firstLetter...].prefix {
            $0.isLetter || $0 == "'" || $0 == "’"
        }
        let wordText = String(word)
        let straightWord = wordText.replacingOccurrences(of: "’", with: "'")
        if straightWord == "I" || straightWord.hasPrefix("I'") || isAcronym(wordText) {
            return text
        }

        let letter = text[firstLetter]
        let lowered = String(letter).lowercased()
        guard lowered != String(letter) else { return text }

        var result = text
        result.replaceSubrange(firstLetter...firstLetter, with: lowered)
        return result
    }

    private static func isContinuation(_ precedingText: String) -> Bool {
        var end = precedingText.endIndex

        while end > precedingText.startIndex {
            let previous = precedingText.index(before: end)
            let character = precedingText[previous]
            guard character.isWhitespace else { break }
            if character == "\n" || character == "\r" { return false }
            end = previous
        }

        while end > precedingText.startIndex {
            let previous = precedingText.index(before: end)
            guard closingCharacters.contains(precedingText[previous]) else { break }
            end = previous
        }

        guard end > precedingText.startIndex else { return false }
        let character = precedingText[precedingText.index(before: end)]
        if sentenceTerminators.contains(character) { return false }
        if character.isLetter || character.isNumber { return true }
        return continuationPunctuation.contains(character)
    }

    private static func isAcronym(_ word: String) -> Bool {
        let casedLetters = word.filter {
            $0.isLetter && String($0).lowercased() != String($0).uppercased()
        }
        guard casedLetters.count >= 2 else { return false }
        return casedLetters.allSatisfy { String($0) == String($0).uppercased() }
    }

    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？"
    ]

    private static let closingCharacters: Set<Character> = [
        "\"", "'", "”", "’", "»", "›", "」", "』", "】",
        ")", "]", "}", "）", "］", "｝"
    ]

    private static let continuationPunctuation: Set<Character> = [
        ",", ";", ":", "-", "–", "—", "/", "=", "+", "&",
        "，", "；", "：", "、"
    ]
}
