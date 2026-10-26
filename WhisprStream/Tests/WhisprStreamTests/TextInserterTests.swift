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
    func testElectronUsesManualAccessibility() {
        XCTAssertEqual(
            TextInserter.webAccessibilityAttribute(manualSettable: true, enhancedSettable: true),
            TextInserter.manualAccessibilityAttribute
        )
    }

    func testChromiumFallsBackToEnhancedUserInterface() {
        // Chrome and the ChatGPT desktop app report AXManualAccessibility as
        // unsupported; without this fallback their composer is never found.
        XCTAssertEqual(
            TextInserter.webAccessibilityAttribute(manualSettable: false, enhancedSettable: true),
            TextInserter.enhancedUserInterfaceAttribute
        )
    }

    func testNoWebAccessibilitySwitchWhenNeitherIsSettable() {
        XCTAssertNil(TextInserter.webAccessibilityAttribute(manualSettable: false, enhancedSettable: false))
    }

    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("WhisprStreamTests.\(UUID().uuidString)"))
    }

    func testInsertionWritesThePasteboardOnceAndKeepsWhatWasPasted() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("previous", forType: .string)
        let before = pasteboard.changeCount
        var pastes = 0
        let delivered = expectation(description: "delivered")
        TextInserter.deliver(
            "Hello world", insertionText: " Hello world", insertAtCursor: true, copyToClipboard: true,
            transport: .init(pasteboard: pasteboard, pressPaste: { _ in pastes += 1 })
        ) { delivered.fulfill() }
        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(pastes, 1)
        XCTAssertEqual(pasteboard.changeCount - before, 1, "clipboard history must see one entry")
        XCTAssertEqual(pasteboard.string(forType: .string), " Hello world")
    }

    func testInsertionRestoresThePreviousClipboardWhenRetentionIsOff() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("previous", forType: .string)
        let before = pasteboard.changeCount
        let delivered = expectation(description: "delivered")
        TextInserter.deliver(
            "Hello world", insertionText: "Hello world ", insertAtCursor: true, copyToClipboard: false,
            transport: .init(pasteboard: pasteboard, pressPaste: { _ in })
        ) { delivered.fulfill() }
        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(pasteboard.changeCount - before, 2, "one write for the paste, one restore")
        XCTAssertEqual(pasteboard.string(forType: .string), "previous")
    }
}
