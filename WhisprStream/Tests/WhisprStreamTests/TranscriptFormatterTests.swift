import XCTest
@testable import WhisprStream

final class TranscriptFormatterTests: XCTestCase {
    func testUnknownCursorContextKeepsTheTrailingSeparator() {
        XCTAssertEqual(TranscriptFormatter.textForInsertion("Hello world."), "Hello world. ")
        XCTAssertEqual(TranscriptFormatter.textForInsertion("Hello world. "), "Hello world. ")
        XCTAssertEqual(TranscriptFormatter.textForInsertion(""), "")
    }

    func testNoSeparatorAtALineStartOrAfterWhitespace() {
        for preceding in ["", "Notes\n", "- ", "is there a simple way ", "\t"] {
            XCTAssertEqual(TranscriptFormatter.textForInsertion("for me to export", precedingText: preceding),
                           "for me to export", "after \(preceding.debugDescription)")
        }
    }

    func testOneSpaceAfterALatinWordOrSentencePunctuation() {
        for preceding in ["is there a simple way", "Hello.", "Hello,", "Done!", "Really?", "Item 2", "(see note)"] {
            XCTAssertEqual(TranscriptFormatter.textForInsertion("next words", precedingText: preceding),
                           " next words", "after \(preceding.debugDescription)")
        }
    }

    func testNoSeparatorAfterOpeningBracketsOrAttachingSymbols() {
        for preceding in ["(", "[", "{", "“", "see: #", "price: $", "well-", "snake_", "path/"] {
            XCTAssertEqual(TranscriptFormatter.textForInsertion("next", precedingText: preceding),
                           "next", "after \(preceding.debugDescription)")
        }
    }

    func testNoSeparatorBeforeClosingPunctuation() {
        XCTAssertEqual(TranscriptFormatter.textForInsertion(", and more", precedingText: "Hello"), ", and more")
        XCTAssertEqual(TranscriptFormatter.textForInsertion(") done", precedingText: "see note"), ") done")
    }

    func testCJKTextNeverGetsASpaceOnEitherSide() {
        XCTAssertEqual(TranscriptFormatter.textForInsertion("去吃饭", precedingText: "我们今天"), "去吃饭")
        XCTAssertEqual(TranscriptFormatter.textForInsertion("Then we test", precedingText: "我用Codex。"), "Then we test")
        XCTAssertEqual(TranscriptFormatter.textForInsertion("你好", precedingText: "Hello."), "你好")
        XCTAssertEqual(TranscriptFormatter.textForInsertion("next", precedingText: "（"), "next")
    }

    func testSeparatorIsOnlyEverOneSpace() {
        XCTAssertEqual(TranscriptFormatter.textForInsertion(" already padded", precedingText: "Hello"), " already padded")
    }
}
