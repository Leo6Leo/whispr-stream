import XCTest
@testable import WhisprStream

final class TextInserterTests: XCTestCase {
    func testEmptyTranscriptReleasesDeliveryActivity() {
        var completions = 0
        TextInserter.deliver("", insertAtCursor: true, copyToClipboard: true) {
            completions += 1
        }
        XCTAssertEqual(completions, 1)
    }

    func testDisabledOutputReleasesDeliveryActivity() {
        var completions = 0
        TextInserter.deliver("Transcript", insertAtCursor: false, copyToClipboard: false) {
            completions += 1
        }
        XCTAssertEqual(completions, 1)
    }

    func testEmptyInsertionReleasesDeliveryActivity() {
        var completions = 0
        TextInserter.deliver("Transcript", insertionText: "", insertAtCursor: true, copyToClipboard: false) {
            completions += 1
        }
        XCTAssertEqual(completions, 1)
    }

    func testLiteralShortcutDeliveryWaitsForCursorProbeToSettle() {
        var gate = TranscriptDeliveryGate()
        let shortcut = DeferredTranscriptDelivery(
            text: "Literal Shortcut Output",
            adjustForCursor: false
        )

        XCTAssertNil(
            gate.submit(shortcut, whileContextIsResolving: true)
        )
        XCTAssertEqual(gate.pending, shortcut)
        XCTAssertEqual(gate.takePending(), shortcut)
        XCTAssertNil(gate.pending)
    }

    func testDeliveryWithoutCursorProbeIsImmediate() {
        var gate = TranscriptDeliveryGate()
        let transcript = DeferredTranscriptDelivery(
            text: "Regular transcript",
            adjustForCursor: true
        )

        XCTAssertEqual(
            gate.submit(transcript, whileContextIsResolving: false),
            transcript
        )
        XCTAssertNil(gate.pending)
    }

    func testReadableCursorContextWinsOverStartSnapshot() {
        XCTAssertEqual(
            TextInserter.preferredTextBeforeCursor(
                readableText: "Current text ",
                fallback: "Earlier text "
            ),
            "Current text "
        )
    }

    func testStartSnapshotIsUsedWhenCursorContextBecomesUnreadable() {
        XCTAssertEqual(
            TextInserter.preferredTextBeforeCursor(
                readableText: nil,
                fallback: "Earlier text "
            ),
            "Earlier text "
        )
    }

    func testEmptyReadableContextDoesNotReuseStaleStartSnapshot() {
        XCTAssertEqual(
            TextInserter.preferredTextBeforeCursor(
                readableText: "",
                fallback: "Earlier text "
            ),
            ""
        )
    }

    func testUnknownCursorContextRemainsUnknown() {
        XCTAssertNil(
            TextInserter.preferredTextBeforeCursor(
                readableText: nil,
                fallback: nil
            )
        )
    }

    func testSuccessfulKeyboardCopyCollapsesSelectionBackToCaret() {
        XCTAssertTrue(
            TextInserter.shouldCollapseKeyboardSelection(
                pasteboardChanged: true
            )
        )
    }

    func testUnavailableKeyboardCopyDoesNotAdvanceEmptyLineCaret() {
        XCTAssertFalse(
            TextInserter.shouldCollapseKeyboardSelection(
                pasteboardChanged: false
            )
        )
    }
}
