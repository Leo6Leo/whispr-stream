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
