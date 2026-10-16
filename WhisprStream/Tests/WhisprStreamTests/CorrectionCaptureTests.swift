import XCTest
@testable import WhisprStream

final class CorrectionCaptureTests: XCTestCase {
    private func diff(
        baseline: String,
        inserted: String,
        current: String,
        caret: Int? = nil
    ) -> CapturedCorrection? {
        guard let range = CorrectionDiff.insertedRange(of: inserted, in: baseline, caret: caret) else {
            XCTFail("inserted text not found in baseline")
            return nil
        }
        return CorrectionDiff.correction(baseline: baseline, insertedRange: range, current: current)
    }

    func testSingleEnglishWordFixInsideInsertedSpan() {
        let inserted = "Let me check the hevy app later."
        let result = diff(
            baseline: "Earlier text. " + inserted + "\n",
            inserted: inserted,
            current: "Earlier text. Let me check the Hevy app later.\n"
        )
        XCTAssertEqual(result, CapturedCorrection(
            inserted: inserted,
            corrected: "Let me check the Hevy app later."
        ))
    }

    func testChineseTwoCharacterWordFix() {
        let inserted = "我们明天去开会讨论一下这个方案。"
        let result = diff(
            baseline: inserted,
            inserted: inserted,
            current: "我们明天去开会讨论一下这个方按。"
        )
        XCTAssertEqual(result?.corrected, "我们明天去开会讨论一下这个方按。")
    }

    func testTwoSeparateFixesInsideSpanAreKept() {
        let inserted = "the codex cli and the lora adapter"
        let result = diff(
            baseline: inserted,
            inserted: inserted,
            current: "the Codex CLI and the LoRA adapter"
        )
        XCTAssertEqual(result?.corrected, "the Codex CLI and the LoRA adapter")
    }

    func testEditOutsideInsertedSpanIsIgnored() {
        let inserted = "second sentence here."
        XCTAssertNil(diff(
            baseline: "first sentence. " + inserted,
            inserted: inserted,
            current: "First sentence! " + inserted
        ))
    }

    func testAppendedTextAfterSpanIsNotACorrection() {
        let inserted = "hello there"
        XCTAssertNil(diff(
            baseline: inserted,
            inserted: inserted,
            current: inserted + " and more words typed afterwards"
        ))
    }

    func testRewriteIsRejected() {
        let inserted = "can you send me the report"
        XCTAssertNil(diff(
            baseline: inserted,
            inserted: inserted,
            current: "please forward the quarterly numbers"
        ))
    }

    func testDeletingTheWholeSpanIsNotACorrection() {
        let inserted = "oops wrong field"
        XCTAssertNil(diff(baseline: "keep " + inserted, inserted: inserted, current: "keep "))
    }

    func testUnchangedValueYieldsNothing() {
        let inserted = "nothing changed"
        XCTAssertNil(diff(baseline: inserted, inserted: inserted, current: inserted))
    }

    func testInsertedRangePrefersOccurrenceEndingAtCaret() {
        let baseline = "ok ok ok"
        let range = CorrectionDiff.insertedRange(of: "ok", in: baseline, caret: 5)
        XCTAssertEqual(range, baseline.index(baseline.startIndex, offsetBy: 3)
                       ..< baseline.index(baseline.startIndex, offsetBy: 5))
    }

    func testInsertedRangeIgnoresPasteWhitespaceAndMissingCaret() {
        let baseline = "Some text. Hello world\n"
        let range = CorrectionDiff.insertedRange(of: " Hello world ", in: baseline, caret: nil)
        XCTAssertEqual(range.map { String(baseline[$0]) }, "Hello world")
    }

    func testPunctuationOnlyChangeIsNotACorrection() {
        let inserted = "can you also make an application tracking feature"
        XCTAssertNil(diff(baseline: inserted, inserted: inserted, current: inserted + "?"))
        XCTAssertNil(diff(baseline: inserted, inserted: inserted,
                          current: "can you also make an application tracking feature."))
        XCTAssertNil(diff(baseline: "我们明天开会", inserted: "我们明天开会", current: "我们明天开会。"))
    }

    func testCaseOnlyChangeIsKept() {
        let inserted = "open codex and hevy"
        XCTAssertEqual(diff(baseline: inserted, inserted: inserted, current: "open Codex and Hevy")?.corrected,
                       "open Codex and Hevy")
    }

    func testAppendingUnspokenWordsIsNotACorrection() {
        let inserted = "If you are using the Canadian French"
        XCTAssertNil(diff(baseline: inserted, inserted: inserted,
                          current: "If you are using the Canadian French (CSA), "))
        XCTAssertNil(diff(baseline: inserted, inserted: inserted,
                          current: "If you are using the Canadian French standard"))
        XCTAssertNil(diff(baseline: "我们明天开会", inserted: "我们明天开会", current: "我们明天下午开会"))
    }

    func testDeletingASpokenWordIsNotACorrection() {
        let inserted = "open the the hevy app"
        XCTAssertNil(diff(baseline: inserted, inserted: inserted, current: "open the hevy app"))
        XCTAssertNil(diff(baseline: "我们明天下午开会", inserted: "我们明天下午开会", current: "我们明天开会"))
    }

    func testInsertedLetterInsideAWordIsASubstitution() {
        let inserted = "open the hevy app"
        XCTAssertEqual(diff(baseline: inserted, inserted: inserted, current: "open the Heavy app")?.corrected,
                       "open the Heavy app")
    }

    func testEditDistance() {
        XCTAssertEqual(CorrectionDiff.editDistance(Array("hevy"), Array("Hevy")), 1)
        XCTAssertEqual(CorrectionDiff.editDistance(Array("have"), Array("Hevy")), 3)
        XCTAssertEqual(CorrectionDiff.editDistance([], Array("abc")), 3)
    }
}
