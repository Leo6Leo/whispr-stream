// Standalone checks for machines with Command Line Tools but no XCTest.
// Compile together with Sources/WhisprStream/DictationReview.swift.
import Foundation

@main
struct DictationReviewChecks {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
        }
        let review = DictationReview(prefix: "我用 ", preferred: "Codex", alternative: "Codec", suffix: " 写代码。")
        let payload: [String: String] = ["prefix": review.prefix, "preferred": review.preferred,
                                       "alternative": review.alternative, "suffix": review.suffix]
        check(DictationReview.parse(payload, transcript: review.recommendedText) == review, "valid wire metadata")
        check(DictationReview.parse(payload, transcript: "other text") == nil, "reject stale metadata")
        check(DictationReview.parse(["preferred": "Codex"], transcript: "Codex") == nil, "reject incomplete metadata")
        check(DictationReview.parse(NSNull(), transcript: "Codex") == nil, "ignore null metadata")
        check(review.term(in: review.alternativeText) == "Codec", "unicode surrounding text")
        check(review.term(in: "completely rewritten") == nil, "do not guess a manual replacement")
        check(!DictationReview.isTerm("\nCodex"), "reject multiline prompt terms")
        check(!DictationReview.isTerm("..."), "reject punctuation candidates")
        let sentence = "Use Codex and Vim today"
        let first: [String: String] = ["prefix": "Use ", "preferred": "Codex", "alternative": "Codec",
                                       "suffix": " and Vim today"]
        let second: [String: String] = ["prefix": "Use Codex and ", "preferred": "Vim", "alternative": "Emacs",
                                        "suffix": " today"]
        let several = DictationReview.parseAll([second, first], single: nil, transcript: sentence)
        check(several.map(\.preferred) == ["Codex", "Vim"], "several words arrive in reading order")
        check(DictationReview.compose(several, alternatives: [false, false]) == sentence, "best guesses rebuild the transcript")
        check(DictationReview.compose(several, alternatives: [true, false]) == "Use Codec and Vim today", "first word alone")
        check(DictationReview.compose(several, alternatives: [false, true]) == "Use Codex and Emacs today", "second word alone")
        check(DictationReview.compose(several, alternatives: [true, true]) == "Use Codec and Emacs today", "both words")
        check(DictationReview.parseAll([first, ["prefix": "x"]], single: nil, transcript: sentence).isEmpty,
              "one malformed word rejects the whole set")
        check(DictationReview.parseAll([first, first], single: nil, transcript: sentence).isEmpty,
              "overlapping words are rejected")
        check(DictationReview.parseAll(nil, single: payload, transcript: review.recommendedText) == [review],
              "the original single-word shape still parses")
        let fourth = ["prefix": "Use Codex and Vim ", "preferred": "today", "alternative": "Tuesday", "suffix": ""]
        let crowded: [[String: String]] = [first, second, fourth, fourth]
        check(DictationReview.parseAll(crowded, single: nil, transcript: sentence).isEmpty, "too many words is not a question")
        check(several.allSatisfy { $0.term(in: $0.alternativeText) == $0.alternative }, "each word stays learnable on its own")
        for (preferred, alternative) in [("Backend", "back end"), ("ChatGPT", " Chat GPT "), ("Uh,", "uh"),
                                         ("testing", "Testing."), ("他", "她"), ("它", "他"), ("她们", "他们")] {
            let moot: [String: String] = ["prefix": "x ", "preferred": preferred, "alternative": alternative, "suffix": " y"]
            check(DictationReview.parse(moot, transcript: "x \(preferred) y") == nil, "no question for \(preferred)|\(alternative)")
        }
        check(!DictationReview.isMoot("Codex", "codecs") && !DictationReview.isMoot("他", "那")
              && !DictationReview.isMoot(",", "。"), "real choices stay askable")
        let spaced = "Use back end and Vim"
        let mootWord: [String: String] = ["prefix": "Use ", "preferred": "back end", "alternative": "Backend",
                                          "suffix": " and Vim"]
        let realWord: [String: String] = ["prefix": "Use back end and ", "preferred": "Vim", "alternative": "Emacs",
                                          "suffix": ""]
        let kept = DictationReview.parseAll([mootWord, realWord], single: nil, transcript: spaced)
        check(kept.map(\.preferred) == ["Vim"], "a moot word is dropped and the real one is still asked")
        check(DictationReview.compose(kept, alternatives: [true]) == "Use back end and Emacs", "dropped word keeps its selection")
        check(DictationReview.parseAll([mootWord], single: nil, transcript: spaced).isEmpty, "only moot words ask nothing")
        check(CorrectionStore.isEverydayWord("The") && CorrectionStore.isEverydayWord("add")
              && CorrectionStore.isEverydayWord("它它") && CorrectionStore.isEverydayWord("他们")
              && !CorrectionStore.isEverydayWord("Codex") && !CorrectionStore.isEverydayWord("Claude")
              && !CorrectionStore.isEverydayWord("省电"), "everyday words are not vocabulary")
        let junkURL = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-junk-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: junkURL) }
        let junk = CorrectionStore(url: junkURL)
        let addOrAt = DictationReview(prefix: "Please ", preferred: "add", alternative: "at", suffix: " it.")
        let theOrA = DictationReview(prefix: "Open ", preferred: "the", alternative: "a", suffix: " file.")
        let pronoun = DictationReview(prefix: "我觉得", preferred: "它", alternative: "他", suffix: "说得对")
        let cloth = DictationReview(prefix: "Ask ", preferred: "cloth", alternative: "Claude", suffix: " now.")
        for _ in 0..<2 {
            junk.record(addOrAt, chosenText: addOrAt.recommendedText, model: "test", manual: false)
            junk.record(theOrA, chosenText: theOrA.recommendedText, model: "test", manual: false)
            junk.record(pronoun, chosenText: pronoun.recommendedText, model: "test", manual: false)
            junk.record(cloth, chosenText: cloth.alternativeText, model: "test", manual: false)
        }
        check(junk.preferredTerms == ["Claude"], "only real terms are learned from repeated choices")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-choice-checks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Corrections.json")
        let store = CorrectionStore(url: url)
        check(store.preferredTerms.isEmpty, "no preference without feedback")
        check(store.record(review, chosenText: review.recommendedText, model: "test", manual: false), "save first choice")
        check(store.preferredTerms.isEmpty, "one choice is not a learned preference")
        check(store.record(review, chosenText: review.recommendedText, model: "test", manual: false), "save repeated choice")
        check(store.preferredTerms == ["Codex"], "two consistent choices create a hint")
        check(CorrectionStore(url: url).preferredTerms == ["Codex"], "preference survives reload")
        check(store.record(review, chosenText: review.alternativeText, model: "test", manual: false), "save disagreement")
        check(store.preferredTerms.isEmpty, "conflicting feedback removes weak preference")
        for _ in 0..<3 { store.record(review, chosenText: review.alternativeText, model: "test", manual: true) }
        check(store.preferredTerms.isEmpty, "manual sentences do not create automatic mappings")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "feedback file is private")
        for _ in 0..<205 { store.record(review, chosenText: review.recommendedText, model: "test", manual: false) }
        check(store.records.count == CorrectionStore.maximumRecords, "bounded feedback retention")
        store.clear()
        check(store.records.isEmpty && store.preferredTerms.isEmpty, "clear removes records and hints")
        check(!FileManager.default.fileExists(atPath: url.path), "clear deletes file")
        try Data("broken".utf8).write(to: url)
        let broken = CorrectionStore(url: url)
        check(broken.errorMessage != nil, "surface unreadable store")
        check(!broken.record(review, chosenText: review.recommendedText, model: "test", manual: false), "preserve unreadable data")
        let preservedData = try Data(contentsOf: url)
        check(preservedData == Data("broken".utf8), "failed load is not overwritten")
        broken.clear()
        check(broken.record(review, chosenText: review.recommendedText, model: "test", manual: false), "clear permits recovery")
        print("\(checks) dictation review and local learning checks passed.")
    }
}
