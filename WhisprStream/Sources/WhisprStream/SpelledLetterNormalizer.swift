import Foundation

/// Joins letters that the speech engine emits as separate words while a user
/// spells an acronym, name, or identifier (for example, `O I N P` -> `OINP`).
///
/// Only adjacent, single ASCII-letter tokens separated entirely by whitespace
/// are joined. Punctuation remains a boundary, which keeps ordinary prose such
/// as `I, a developer` unchanged.
enum SpelledLetterNormalizer {
    private struct Token {
        let range: Range<String.Index>
        let letter: Character
    }

    static func normalize(_ text: String) -> String {
        let tokens = tokenize(text)
        guard tokens.count >= 2 else { return text }

        var replacements: [(Range<String.Index>, String)] = []
        var start = 0

        while start < tokens.count {
            var end = start + 1
            while end < tokens.count,
                  text[tokens[end - 1].range.upperBound..<tokens[end].range.lowerBound]
                    .allSatisfy(\.isWhitespace) {
                end += 1
            }

            if end - start >= 2 {
                let range = tokens[start].range.lowerBound..<tokens[end - 1].range.upperBound
                let joined = String(tokens[start..<end].map(\.letter))
                replacements.append((range, joined))
            }
            start = end
        }

        var result = text
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard isASCIILetter(text[index]) else {
                index = text.index(after: index)
                continue
            }

            let start = index
            index = text.index(after: index)

            // A token only represents a spelled letter when it is not part of
            // a larger ASCII word, including one connected by an apostrophe.
            // Without the apostrophe check, the `s` in "That's a" and the
            // following `a` look like a spelled-letter run and become `sa`.
            guard !isAttachedToASCIIWord(before: start, in: text),
                  !isAttachedToASCIIWord(after: index, in: text)
            else { continue }

            tokens.append(Token(range: start..<index, letter: text[start]))
        }
        return tokens
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    private static func isAttachedToASCIIWord(
        before index: String.Index,
        in text: String
    ) -> Bool {
        guard index > text.startIndex else { return false }
        let adjacent = text.index(before: index)
        if isASCIIAlphanumeric(text[adjacent]) { return true }
        guard isApostrophe(text[adjacent]), adjacent > text.startIndex else {
            return false
        }
        return isASCIIAlphanumeric(text[text.index(before: adjacent)])
    }

    private static func isAttachedToASCIIWord(
        after index: String.Index,
        in text: String
    ) -> Bool {
        guard index < text.endIndex else { return false }
        if isASCIIAlphanumeric(text[index]) { return true }
        guard isApostrophe(text[index]) else { return false }
        let next = text.index(after: index)
        return next < text.endIndex && isASCIIAlphanumeric(text[next])
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }
}
