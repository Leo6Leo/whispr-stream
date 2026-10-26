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

    // MARK: Document editors: the rest of the field keeps changing while the span is fixed.

    private let document = "# PRD\n\n- Goals\n"
    private let spoken = "We will run it on the Raspberry Py with the Engineering NAS."
    private let fixedSpoken = "We will run it on the Raspberry Pi with the Engineering MaaS."

    func testFixSurvivesEnterAfterTheSpan() {
        XCTAssertEqual(diff(baseline: document + spoken + " ", inserted: spoken,
                            current: document + fixedSpoken + " \n")?.corrected, fixedSpoken)
    }

    func testFixSurvivesANewBulletTypedBelow() {
        XCTAssertEqual(diff(baseline: document + spoken + " ", inserted: spoken,
                            current: document + fixedSpoken + " \n- next item")?.corrected, fixedSpoken)
    }

    func testFixSurvivesASecondSentenceTypedAfterTheSpan() {
        XCTAssertEqual(diff(baseline: document + spoken + " ", inserted: spoken,
                            current: document + fixedSpoken + " It ships in May.")?.corrected, fixedSpoken)
    }

    func testFixSurvivesALivePreviewMarkerChangeOnTheSameLine() {
        XCTAssertEqual(diff(baseline: "- " + spoken + " ", inserted: spoken,
                            current: "\u{2022} " + fixedSpoken + " ")?.corrected, fixedSpoken)
    }

    func testFixSurvivesAnotherLineReRendering() {
        XCTAssertEqual(diff(baseline: "PRD\n" + spoken + " ", inserted: spoken,
                            current: "# PRD\n" + fixedSpoken + " ")?.corrected, fixedSpoken)
    }

    func testFixSurvivesAScrolledEditorViewport() {
        XCTAssertEqual(diff(baseline: "line A\nline B\n" + spoken + " ", inserted: spoken,
                            current: "line B\n" + fixedSpoken + " \nline D")?.corrected, fixedSpoken)
    }

    func testFixSurvivesTypingBeforeTheSpan() {
        XCTAssertEqual(diff(baseline: "Notes\n" + spoken, inserted: spoken,
                            current: "Notes today\n" + fixedSpoken)?.corrected, fixedSpoken)
    }

    func testTextTypedAfterAnUnpaddedSpanIsNotAbsorbedIntoTheCorrection() {
        // No trailing space in the field: the next bullet used to be glued
        // onto the corrected transcript.
        XCTAssertEqual(diff(baseline: document + spoken, inserted: spoken,
                            current: document + fixedSpoken + "\n- next item")?.corrected, fixedSpoken)
    }

    func testLettersTypedAgainstTheLastWordStayInTheCorrection() {
        let inserted = "run Py on the NAS"
        XCTAssertEqual(diff(baseline: inserted, inserted: inserted, current: "run Pi on the NASA")?.corrected,
                       "run Pi on the NASA")
    }

    func testUnchangedSpanInAnEditedDocumentIsNotACorrection() {
        XCTAssertNil(diff(baseline: document + spoken + " ", inserted: spoken,
                          current: "# PRD v2\n\n- Goals\n- Scope\n" + spoken + " \nmore"))
    }

    func testSpanWhoseLineDisappearedYieldsNothing() {
        XCTAssertNil(diff(baseline: document + spoken + " ", inserted: spoken, current: document))
    }

    func testCurrentSpanFollowsALineThatMoved() {
        let baseline = Array("a\nb\nHello world\n")
        let current = Array("b\nHello world\nc\n")
        let span = 4..<15
        XCTAssertEqual(String(baseline[span]), "Hello world")
        let located = CorrectionDiff.currentSpan(baseline: baseline, span: span, current: current)
        XCTAssertEqual(located.map { String(current[$0]) }, "Hello world")
    }

    func testCaretJustAfterTheSpanIsStillInside() {
        let span = 10..<30
        XCTAssertFalse(CorrectionDiff.caretLeftSpan(caret: 30, span: span))
        XCTAssertFalse(CorrectionDiff.caretLeftSpan(caret: 31, span: span))
        XCTAssertFalse(CorrectionDiff.caretLeftSpan(caret: 15, span: span))
        XCTAssertTrue(CorrectionDiff.caretLeftSpan(caret: 32, span: span))
        XCTAssertTrue(CorrectionDiff.caretLeftSpan(caret: 9, span: span))
    }

    func testAccessibilityCaretIsConvertedFromUTF16() {
        // Two emoji are four UTF-16 units but two Characters.
        let field = "👍👍 nice. Hello world"
        let span = 9..<20
        XCTAssertEqual(String(Array(field)[span]), "Hello world")
        let caret = CorrectionDiff.characterOffset(utf16: field.utf16.count, in: field)
        XCTAssertEqual(caret, 20)
        XCTAssertFalse(CorrectionDiff.caretLeftSpan(caret: caret!, span: span))

        // CRLF is one Character and two units.
        let lines = "one\r\ntwo\r\nHello"
        XCTAssertEqual(CorrectionDiff.characterOffset(utf16: lines.utf16.count, in: lines), Array(lines).count)
        // A position inside a surrogate pair resolves to that character's start.
        XCTAssertEqual(CorrectionDiff.characterOffset(utf16: 1, in: "👍a"), 0)
        XCTAssertNil(CorrectionDiff.characterOffset(utf16: 99, in: "abc"))
    }
}
