import XCTest
@testable import WhisprStream

final class DictationReviewLearningTests: XCTestCase {
    func testSpacingCasingPunctuationAndPronounChoicesAreNotAsked() {
        for (preferred, alternative) in [("Backend", "back end"), ("APP", " A P P"), ("Uh,", "uh"),
                                         ("testing", "Testing."), ("他", "她"), ("它", "他")] {
            let payload = ["prefix": "x ", "preferred": preferred, "alternative": alternative, "suffix": " y"]
            XCTAssertNil(DictationReview.parse(payload, transcript: "x \(preferred) y"), "\(preferred)|\(alternative)")
        }
        XCTAssertFalse(DictationReview.isMoot("Codex", "codecs"))
        XCTAssertFalse(DictationReview.isMoot("Claude", "cloth"))
    }

    func testMootWordIsDroppedFromASetWhileRealWordsAreAsked() {
        let moot = ["prefix": "Use ", "preferred": "back end", "alternative": "Backend", "suffix": " and Vim"]
        let real = ["prefix": "Use back end and ", "preferred": "Vim", "alternative": "Emacs", "suffix": ""]
        let reviews = DictationReview.parseAll([moot, real], single: nil, transcript: "Use back end and Vim")
        XCTAssertEqual(reviews.map(\.preferred), ["Vim"])
        XCTAssertEqual(DictationReview.compose(reviews, alternatives: [true]), "Use back end and Emacs")
        XCTAssertTrue(DictationReview.parseAll([moot], single: nil, transcript: "Use back end and Vim").isEmpty)
    }

    @MainActor
    func testEverydayWordsAreNeverLearned() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whispr-learning-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CorrectionStore(url: url)
        let choices = [
            DictationReview(prefix: "Please ", preferred: "add", alternative: "at", suffix: " it."),
            DictationReview(prefix: "Open ", preferred: "the", alternative: "a", suffix: " file."),
            DictationReview(prefix: "我觉得", preferred: "它它", alternative: "他", suffix: "说得对"),
            DictationReview(prefix: "我用 ", preferred: "Codex", alternative: "codecs", suffix: " 写代码。"),
        ]
        for _ in 0..<2 {
            for review in choices {
                XCTAssertTrue(store.record(review, chosenText: review.recommendedText, model: "test", manual: false))
            }
        }
        XCTAssertEqual(store.preferredTerms, ["Codex"])
    }
}
