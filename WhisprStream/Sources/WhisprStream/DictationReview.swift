import Foundation
import Combine

/// A bounded disagreement, not a probability or a new model-generated guess.
struct DictationReview: Codable, Equatable {
    let prefix: String
    let preferred: String
    let alternative: String
    let suffix: String

    var recommendedText: String { prefix + preferred + suffix }
    var alternativeText: String { prefix + alternative + suffix }
    var excerpt: String { String(prefix.suffix(65)) + "[" + preferred + "]" + String(suffix.prefix(65)) }

    static func parse(_ value: Any?, transcript: String) -> Self? {
        guard let review = decode(value), review.recommendedText == transcript,
              transcript.count <= 12_000,
              isTerm(review.preferred), isTerm(review.alternative),
              !isMoot(review.preferred, review.alternative)
        else { return nil }
        return review
    }

    private static func decode(_ value: Any?) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Third-person pronouns that sound identical in Mandarin (tā). Audio
    /// cannot tell them apart, so a choice among them is not worth asking.
    static let homophonePronouns: Set<Character> = ["他", "她", "它", "牠", "祂"]

    /// Letters and digits only, NFKC and case folded, with every homophone
    /// pronoun read as 他. Mirrors `moot_review_key` in asr_server.py.
    static func comparisonKey(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: nil)
        return String(folded.compactMap { character -> Character? in
            guard character.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { return nil }
            return homophonePronouns.contains(character) ? "他" : character
        })
    }

    /// True when two options differ only in spacing, casing, punctuation or a
    /// homophone pronoun (`back end`/`Backend`, `Uh,`/`uh`, 他/她). Such a
    /// question is pointless; the stabilizer's own selection stands.
    static func isMoot(_ preferred: String, _ alternative: String) -> Bool {
        let key = comparisonKey(preferred)
        return !key.isEmpty && key == comparisonKey(alternative)
    }

    static func isTerm(_ text: String) -> Bool {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !term.isEmpty && term.count <= 48
            && !text.contains(where: { $0.isNewline })
            && term.split(whereSeparator: \.isWhitespace).count <= 3
            && term.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
    }

    /// Most word choices one dictation may ask about; more reads as a rewrite.
    static let maximumWords = 3

    /// Every word choice for a transcript, in reading order.
    ///
    /// `reviews` (several words) wins over the original single `review`. Each
    /// item must describe the same transcript and the words must not overlap;
    /// one bad item rejects the set rather than asking a partial question.
    /// A moot item (see `isMoot`) is dropped instead: every item carries the
    /// full transcript as prefix + preferred + suffix, so the remaining words
    /// stay consistent on their own. The server already drops these.
    static func parseAll(_ list: Any?, single: Any?, transcript: String) -> [Self] {
        guard let items = list as? [Any], !items.isEmpty else {
            return parse(single, transcript: transcript).map { [$0] } ?? []
        }
        var reviews: [Self] = []
        for item in items {
            if let review = parse(item, transcript: transcript) {
                reviews.append(review)
            } else if let review = decode(item), review.recommendedText == transcript,
                      isMoot(review.preferred, review.alternative) {
                continue
            } else {
                return []
            }
        }
        reviews.sort { $0.prefix.count < $1.prefix.count }
        guard reviews.count <= maximumWords else { return [] }
        for (earlier, later) in zip(reviews, reviews.dropFirst())
        where !earlier.suffix.hasSuffix(later.preferred + later.suffix)
            || earlier.suffix.count < later.preferred.count + later.suffix.count {
            return []
        }
        return reviews
    }

    /// The transcript with each word set to its preferred term, or to its
    /// alternative where `alternatives[i]` is true. `reviews` is in reading
    /// order, as `parseAll` returns it.
    static func compose(_ reviews: [Self], alternatives: [Bool]) -> String {
        guard let first = reviews.first else { return "" }
        var text = first.prefix
        for (index, review) in reviews.enumerated() {
            let useAlternative = alternatives.indices.contains(index) && alternatives[index]
            text += useAlternative ? review.alternative : review.preferred
            if index + 1 < reviews.count {
                let next = reviews[index + 1]
                text += String(review.suffix.dropLast(next.preferred.count + next.suffix.count))
            } else {
                text += review.suffix
            }
        }
        return text
    }

    func term(in text: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix),
              text.count >= prefix.count + suffix.count else { return nil }
        let middle = String(text.dropFirst(prefix.count).dropLast(suffix.count))
        return Self.isTerm(middle) ? middle.trimmingCharacters(in: .whitespaces) : nil
    }
}

struct CorrectionRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let review: DictationReview
    let chosenText: String
    let model: String
    let manual: Bool
}

/// Text-only feedback stays on this Mac. Suggestions never rewrite output.
@MainActor
final class CorrectionStore: ObservableObject {
    static let shared = CorrectionStore()
    static let maximumRecords = 200
    @Published private(set) var records: [CorrectionRecord] = []
    @Published private(set) var errorMessage: String?
    var onChange: (() -> Void)?
    let url: URL
    private var loadFailed = false

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisprStream/Corrections.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: self.url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 8_000_000 else {
                throw CocoaError(.fileReadTooLarge)
            }
            records = Array(try JSONDecoder().decode([CorrectionRecord].self, from: Data(contentsOf: self.url))
                .suffix(Self.maximumRecords))
        } catch {
            loadFailed = true
            errorMessage = "Saved corrections could not be read. Clear them to start again."
        }
    }

    var preferredTerms: [String] {
        // Learn only explicitly chosen candidates. A manually rewritten sentence
        // is useful feedback, but is not evidence for a particular word mapping.
        var votes: [String: [String: Int]] = [:]
        for record in records where !record.manual {
            guard record.chosenText == record.review.recommendedText
                    || record.chosenText == record.review.alternativeText else { continue }
            // A spacing/casing/pronoun-only choice is no longer asked, and old
            // records of one are not evidence for a vocabulary hint either.
            guard !DictationReview.isMoot(record.review.preferred, record.review.alternative) else { continue }
            let choices = [record.review.preferred, record.review.alternative]
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.sorted()
            guard let term = record.review.term(in: record.chosenText), term.count >= 2,
                  !Self.isEverydayWord(term) else { continue }
            votes[choices.joined(separator: "\u{0}"), default: [:]][term, default: 0] += 1
        }
        let winners = votes.values.compactMap { counts -> String? in
            let ranked = counts.sorted { $0.value > $1.value }
            guard let winner = ranked.first, winner.value >= 2,
                  winner.value - (ranked.dropFirst().first?.value ?? 0) >= 2 else { return nil }
            return winner.key
        }
        return Array(Set(winners).sorted().prefix(32))
    }

    /// True for ordinary words that must never become a learned decoder hint.
    /// Biasing the decoder toward `the` or `add` buys nothing and has turned
    /// common words into vocabulary before (the -> OAuth). The English list is
    /// asr_server.py's COMMON_ENGLISH_WORDS plus everyday words seen in
    /// real choices; CJK terms made only of function characters and pronouns
    /// (它它, 他的) and common multi-character function words are excluded too.
    nonisolated static func isEverydayWord(_ term: String) -> Bool {
        let key = DictationReview.comparisonKey(term)
        guard !key.isEmpty else { return true }
        if EverydayWords.english.contains(key) || EverydayWords.chinese.contains(key) { return true }
        return key.allSatisfy { EverydayWords.chineseFunctionCharacters.contains($0) }
    }

    @discardableResult
    func record(_ review: DictationReview, chosenText: String, model: String, manual: Bool) -> Bool {
        guard !loadFailed, !chosenText.isEmpty, chosenText.count <= 12_000 else { return false }
        guard manual || chosenText == review.recommendedText || chosenText == review.alternativeText else { return false }
        var next = records
        next.append(CorrectionRecord(id: UUID(), date: Date(), review: review,
                                     chosenText: chosenText, model: model, manual: manual))
        next = Array(next.suffix(Self.maximumRecords))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            records = next
            errorMessage = nil
            onChange?()
            return true
        } catch {
            errorMessage = "The choice was used, but could not be saved on this Mac."
            return false
        }
    }

    func clear() {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            records = []
            loadFailed = false
            errorMessage = nil
            onChange?()
        } catch { errorMessage = "Saved corrections could not be cleared." }
    }
}

/// Ordinary words excluded from learned vocabulary. Keys are compared after
/// `DictationReview.comparisonKey` (letters/digits only, case folded), so
/// contractions appear without apostrophes.
enum EverydayWords {
    static let english: Set<String> = Set("""
    a about above after again against all also am an and any are as at
    be because been before being below between both but by
    can could did do does doing done down during
    each even ever every few for from further
    get give go going got had has have having he her here hers him his how
    i if in into is it its just
    let like look made make many may me might more most much must my
    need never new no nor not now of off on once one only or other our out over own
    per pro put really right said same say see she should since so some still such
    take than that the their them then there these they this those through to too two
    under until up upon us use used very
    want was way we well were what when where which while who whom why will with
    would yes yet you your
    actually add added adding already always another anything around ask asked away
    back big call called calling came change changed changes check close come comes coming
    day days different end enough everything feel find first fix fixed
    gets give gives good great guess hello help hey hi hmm idea im ive
    keep kind know last later leave less little long lot lots
    maybe mean means mine move name next nothing number ok okay oh open
    part people person place please point pretty quite
    read run said says seems send set show side something sometimes soon sorry sort start stop sure
    talk tell test tested testing tests thank thanks thing things think thought three time times
    today told tomorrow tried tries try trying turn uh um usually
    wanted wants week went whats work works working write wrong yeah year years yesterday
    dont doesnt didnt cant wont isnt arent wasnt thats theres lets youre theyre
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    static let chinese: Set<String> = [
        "我们", "你们", "他们", "什么", "怎么", "然后", "因为", "所以", "但是", "可以",
        "没有", "已经", "现在", "自己", "时候", "知道", "觉得", "如果", "的话", "一些",
        "好像", "应该", "需要", "还有", "而且", "或者", "其实", "可能", "一下", "东西",
        "事情", "问题", "这样", "那样", "这些", "那些", "就是", "还是", "这里", "那里",
    ]

    /// A CJK term made only of these (pronouns read as 他) is never a term.
    static let chineseFunctionCharacters: Set<Character> = Set(
        "他我你您们的了吗呢吧啊呀哎呃嗯哦噢么嘛是在有和就也都还又再这那个一不很要说到得地着过把被给让"
    )
}
