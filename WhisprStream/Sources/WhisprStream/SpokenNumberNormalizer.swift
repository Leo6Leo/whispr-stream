import Foundation

/// Converts unambiguous English and Chinese number phrases in a finished
/// transcript to digits.
///
/// This is deliberately a post-processing step rather than ASR prompt context:
/// context can bias the model, but it cannot guarantee that "twenty four" is
/// inserted as `24`. English digit sequences and structured quantities are
/// converted, while isolated small-number words stay natural in prose. Chinese
/// digit sequences and quantities with explicit units are handled separately.
enum SpokenNumberNormalizer {
    private enum Word {
        case digit(Int)
        case teen(Int)
        case tens(Int)
        case scale(Int64)
        case point
        case and
        case minus

        var isDigit: Bool {
            if case .digit = self { return true }
            return false
        }
    }

    private struct Token {
        let range: Range<String.Index>
        let word: Word?
    }

    private static let words: [String: Word] = [
        "zero": .digit(0), "oh": .digit(0),
        "one": .digit(1), "two": .digit(2), "three": .digit(3),
        "four": .digit(4), "five": .digit(5), "six": .digit(6),
        "seven": .digit(7), "eight": .digit(8), "nine": .digit(9),
        "ten": .teen(10), "eleven": .teen(11), "twelve": .teen(12),
        "thirteen": .teen(13), "fourteen": .teen(14), "fifteen": .teen(15),
        "sixteen": .teen(16), "seventeen": .teen(17), "eighteen": .teen(18),
        "nineteen": .teen(19),
        "twenty": .tens(20), "thirty": .tens(30), "forty": .tens(40),
        "fifty": .tens(50), "sixty": .tens(60), "seventy": .tens(70),
        "eighty": .tens(80), "ninety": .tens(90),
        "hundred": .scale(100), "thousand": .scale(1_000),
        "million": .scale(1_000_000), "billion": .scale(1_000_000_000),
        "trillion": .scale(1_000_000_000_000),
        "point": .point, "and": .and, "minus": .minus, "negative": .minus
    ]

    private static let chineseDigits: [Character: Int64] = [
        "零": 0, "〇": 0,
        "一": 1, "壹": 1, "幺": 1,
        "二": 2, "两": 2, "兩": 2, "贰": 2, "貳": 2,
        "三": 3, "叁": 3, "參": 3,
        "四": 4, "肆": 4,
        "五": 5, "伍": 5,
        "六": 6, "陆": 6, "陸": 6,
        "七": 7, "柒": 7,
        "八": 8, "捌": 8,
        "九": 9, "玖": 9,
    ]

    private static let chineseSmallUnits: [Character: Int64] = [
        "十": 10, "拾": 10,
        "百": 100, "佰": 100,
        "千": 1_000, "仟": 1_000,
    ]

    private static let chineseLargeUnits: [Character: Int64] = [
        "万": 10_000, "萬": 10_000,
        "亿": 100_000_000, "億": 100_000_000,
    ]

    private static let chinesePoints: Set<Character> = ["点", "點"]
    private static let chineseMinuses: Set<Character> = ["负", "負"]

    private static let chineseNumberCharacters: Set<Character> = {
        Set(chineseDigits.keys)
            .union(chineseSmallUnits.keys)
            .union(chineseLargeUnits.keys)
            .union(chinesePoints)
            .union(chineseMinuses)
    }()

    static func normalize(_ text: String) -> String {
        let tokens = tokenize(text)

        var replacements: [(Range<String.Index>, String)] = []
        var start = 0

        while start < tokens.count {
            guard tokens[start].word != nil else {
                start += 1
                continue
            }

            var end = start + 1
            while end < tokens.count,
                  tokens[end].word != nil,
                  separatedByWhitespaceOrHyphen(tokens[end - 1].range.upperBound..<tokens[end].range.lowerBound,
                                                in: text) {
                end += 1
            }

            let words = tokens[start..<end].compactMap(\.word)
            if shouldNormalizeEnglish(words), let number = parse(words) {
                replacements.append((
                    tokens[start].range.lowerBound..<tokens[end - 1].range.upperBound,
                    number
                ))
            }
            start = end
        }

        var result = text
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return normalizeChinese(in: result)
    }

    /// A single word such as "one" is usually prose, not an identifier. Runs
    /// ("one three five") and structured quantities ("twenty four", "one
    /// hundred") remain unambiguous enough to normalize.
    private static func shouldNormalizeEnglish(_ words: [Word]) -> Bool {
        guard words.count == 1 else { return true }
        return !words[0].isDigit
    }

    private static func normalizeChinese(in text: String) -> String {
        var replacements: [(Range<String.Index>, String)] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard chineseNumberCharacters.contains(text[index]) else {
                index = text.index(after: index)
                continue
            }

            let start = index
            repeat {
                index = text.index(after: index)
            } while index < text.endIndex && chineseNumberCharacters.contains(text[index])

            let range = start..<index
            if let number = normalizeChineseRun(text[range]) {
                replacements.append((range, number))
            }
        }

        var result = text
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func normalizeChineseRun(_ run: Substring) -> String? {
        var characters = Array(run)
        guard !characters.isEmpty else { return nil }

        var negative = false
        if let first = characters.first, chineseMinuses.contains(first) {
            negative = true
            characters.removeFirst()
        }
        guard !characters.isEmpty,
              !characters.contains(where: chineseMinuses.contains) else { return nil }

        let points = characters.indices.filter { chinesePoints.contains(characters[$0]) }
        guard points.count <= 1 else { return nil }

        let integerCharacters: ArraySlice<Character>
        let fractionCharacters: ArraySlice<Character>
        if let point = points.first {
            guard point > characters.startIndex, point + 1 < characters.endIndex else { return nil }
            integerCharacters = characters[..<point]
            fractionCharacters = characters[(point + 1)...]
            guard fractionCharacters.allSatisfy({ chineseDigits[$0] != nil }) else { return nil }
        } else {
            integerCharacters = characters[...]
            fractionCharacters = []
        }

        let containsUnit = integerCharacters.contains {
            chineseSmallUnits[$0] != nil || chineseLargeUnits[$0] != nil
        }
        let integer: String
        if containsUnit {
            // Requiring an explicit digit avoids rewriting lexical uses of
            // unit-only forms such as "千万不要".
            guard integerCharacters.contains(where: { chineseDigits[$0] != nil }),
                  let value = parseChineseInteger(integerCharacters) else { return nil }
            integer = String(value)
        } else {
            let digits = integerCharacters.compactMap { chineseDigits[$0] }
            // Preserve an isolated 一/二/etc. in ordinary Chinese prose, just
            // as isolated English small-number words are preserved.
            guard digits.count == integerCharacters.count,
                  digits.count >= 2 || !fractionCharacters.isEmpty || negative else { return nil }
            integer = digits.map(String.init).joined()
        }

        var result = (negative ? "-" : "") + integer
        if !fractionCharacters.isEmpty {
            result += "." + fractionCharacters.compactMap { chineseDigits[$0] }.map(String.init).joined()
        }
        return result
    }

    private static func parseChineseInteger(_ characters: ArraySlice<Character>) -> Int64? {
        var total: Int64 = 0
        var section: Int64 = 0
        var pendingDigit: Int64?

        for character in characters {
            if let digit = chineseDigits[character] {
                // Consecutive digits belong to the digit-sequence form, not a
                // unit-based quantity. Zero may bridge units (一百零五), but
                // reject other mixed ambiguous forms.
                if let pendingDigit {
                    guard pendingDigit == 0 else { return nil }
                }
                pendingDigit = digit
                continue
            }

            if let unit = chineseSmallUnits[character] {
                let multiplier = pendingDigit ?? 1
                guard let contribution = safeMultiply(multiplier, unit),
                      let nextSection = safeAdd(section, contribution) else { return nil }
                section = nextSection
                pendingDigit = nil
                continue
            }

            if let unit = chineseLargeUnits[character] {
                guard let withPending = safeAdd(section, pendingDigit ?? 0) else { return nil }
                let group = max(withPending, 1)
                guard let contribution = safeMultiply(group, unit),
                      let nextTotal = safeAdd(total, contribution) else { return nil }
                total = nextTotal
                section = 0
                pendingDigit = nil
                continue
            }

            return nil
        }

        guard let withPending = safeAdd(section, pendingDigit ?? 0) else { return nil }
        return safeAdd(total, withPending)
    }

    private static func safeAdd(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    private static func safeMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : result
    }

    private static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index].isLetter else {
                index = text.index(after: index)
                continue
            }

            let begin = index
            repeat {
                index = text.index(after: index)
            } while index < text.endIndex && text[index].isLetter

            let range = begin..<index
            let value = String(text[range]).lowercased()
            result.append(Token(range: range, word: words[value]))
        }
        return result
    }

    private static func separatedByWhitespaceOrHyphen(
        _ range: Range<String.Index>,
        in text: String
    ) -> Bool {
        text[range].allSatisfy { $0.isWhitespace || $0 == "-" }
    }

    private static func parse(_ words: [Word]) -> String? {
        guard !words.isEmpty else { return nil }

        var words = words
        var negative = false
        if case .minus = words.first {
            negative = true
            words.removeFirst()
        }
        guard !words.isEmpty, !words.contains(where: { if case .minus = $0 { return true }; return false }) else {
            return nil
        }

        let pointIndices = words.indices.filter {
            if case .point = words[$0] { return true }
            return false
        }
        if pointIndices.count > 1 {
            return parseDottedDigitSequence(words, negative: negative)
        }

        let integerWords: ArraySlice<Word>
        let fractionWords: ArraySlice<Word>
        if let point = pointIndices.first {
            guard point > words.startIndex, point + 1 < words.endIndex else { return nil }
            integerWords = words[..<point]
            fractionWords = words[(point + 1)...]
            guard fractionWords.allSatisfy(\.isDigit) else { return nil }
        } else {
            integerWords = words[...]
            fractionWords = []
        }

        guard let integer = parseInteger(Array(integerWords)) else { return nil }
        var output = (negative ? "-" : "") + integer
        if !fractionWords.isEmpty {
            output += "." + fractionWords.compactMap { word in
                guard case let .digit(value) = word else { return nil }
                return String(value)
            }.joined()
        }
        return output
    }

    /// Multiple spoken points usually describe a dotted identifier such as a
    /// software version: "one point two point three" -> "1.2.3". Keep this
    /// deliberately narrower than ordinary number parsing so prose containing
    /// repeated uses of "point" cannot be folded into an invented number.
    private static func parseDottedDigitSequence(_ words: [Word], negative: Bool) -> String? {
        var components: [String] = []
        var digits = ""

        for word in words {
            if case .point = word {
                guard !digits.isEmpty else { return nil }
                components.append(digits)
                digits = ""
                continue
            }

            guard case let .digit(value) = word else { return nil }
            digits += String(value)
        }

        guard !digits.isEmpty else { return nil }
        components.append(digits)
        return (negative ? "-" : "") + components.joined(separator: ".")
    }

    private static func parseInteger(_ words: [Word]) -> String? {
        guard !words.isEmpty else { return nil }

        // A run of digit words is how people normally dictate identifiers,
        // phone numbers, and years: "one two three" -> 123.
        if words.allSatisfy(\.isDigit) {
            let digits = words.compactMap { word -> String? in
                guard case let .digit(value) = word else { return nil }
                return String(value)
            }.joined()
            return digits
        }

        var total: Int64 = 0
        var current: Int64 = 0
        var sawNumber = false
        var previousWasScale = false

        for (index, word) in words.enumerated() {
            switch word {
            case let .digit(value), let .teen(value), let .tens(value):
                current += Int64(value)
                sawNumber = true
                previousWasScale = false

            case let .scale(scale):
                guard sawNumber else { return nil }
                guard scale != 100 || !previousWasScale else { return nil }
                if scale == 100 {
                    current = max(current, 1)
                    guard current <= Int64.max / scale else { return nil }
                    current *= scale
                } else {
                    let group = max(current, 1)
                    guard group <= Int64.max / scale else { return nil }
                    let contribution = group * scale
                    guard total <= Int64.max - contribution else { return nil }
                    total += contribution
                    current = 0
                }
                previousWasScale = true

            case .and:
                // "and" is accepted only after a scale: "one hundred and
                // five". This avoids turning list-like speech such as
                // "one and two" into the number 12.
                guard previousWasScale,
                      index + 1 < words.count,
                      !isScale(words[index + 1]) else { return nil }

            case .point, .minus:
                return nil
            }
        }

        guard sawNumber else { return nil }
        guard total <= Int64.max - current else { return nil }
        return String(total + current)
    }

    private static func isScale(_ word: Word) -> Bool {
        if case .scale = word { return true }
        return false
    }
}
