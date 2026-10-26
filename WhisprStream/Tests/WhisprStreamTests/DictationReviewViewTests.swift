import XCTest
@testable import WhisprStream

final class DictationReviewViewTests: XCTestCase {
    func testShortGapBetweenWordsIsKept() {
        XCTAssertEqual(DictationReviewView.middleContext(" and then "), " and then ")
    }

    func testLongGapBetweenWordsKeepsBothEnds() {
        let head = String(repeating: "a", count: 70)
        let tail = String(repeating: "z", count: 70)
        let gap = head + " " + String(repeating: "m ", count: 400) + tail
        let shown = DictationReviewView.middleContext(gap)
        XCTAssertLessThan(shown.count, 140)
        XCTAssertTrue(shown.contains(" … "))
        XCTAssertTrue(shown.hasPrefix("aaaa"))
        XCTAssertTrue(shown.hasSuffix("zzzz"))
    }
}
