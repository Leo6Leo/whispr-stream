import XCTest
@testable import WhisprStream

final class LiveTextAnimationTests: XCTestCase {
    func testEarlierWordsKeepTheirArrivalAcrossFastPreviews() {
        var animation = LiveTextAnimation(stableText: "Earlier words")
        let now = Date()
        animation.update(to: "Earlier words one", at: now)
        animation.update(to: "Earlier words one two", at: now.addingTimeInterval(0.2))
        XCTAssertEqual(animation.runs, [
            .init(text: "Earlier words", startedAt: nil),
            .init(text: " one", startedAt: now),
            .init(text: " two", startedAt: now.addingTimeInterval(0.2))
        ])
        animation.settle(at: now.addingTimeInterval(0.31))
        XCTAssertEqual(animation.runs.first, .init(text: "Earlier words one", startedAt: nil))
    }

    func testCorrectionsLeaveUnchangedTextSettled() {
        var animation = LiveTextAnimation(stableText: "We meet Monday, then review the plan.")
        animation.update(to: "We meet Tuesday, then review the plan. Bring notes.", at: .now)
        XCTAssertTrue(animation.runs.contains { $0.startedAt == nil && $0.text.contains(", then review the plan") })
        XCTAssertEqual(animation.runs.map(\.text).joined(), animation.text)
        animation.update(to: "", at: .now)
        XCTAssertTrue(animation.runs.isEmpty)
    }

    func testNewWordsSpringInOrderWhileEarlierWordsStaySettled() {
        var animation = LiveTextAnimation(stableText: "So today ")
        let now = Date()
        animation.update(to: "So today I want to", at: now)
        let words = animation.words(committedCount: 3)
        XCTAssertEqual(words.map(\.text), ["So ", "today ", "I ", "want ", "to"])
        XCTAssertEqual(words.map(\.isCommitted), [true, false, false, false, false])
        XCTAssertEqual(words.map(\.startsAt), [
            nil, nil,
            now,
            now.addingTimeInterval(0.025),
            now.addingTimeInterval(0.05)
        ])
    }

    func testRevisedWordReplaysButItsNeighboursDoNot() {
        var animation = LiveTextAnimation(stableText: "we meet Monday then")
        let now = Date()
        animation.update(to: "we meet Tuesday then", at: now)
        let fresh = animation.words(committedCount: 0).filter { $0.startsAt != nil }.map(\.text)
        XCTAssertEqual(fresh, ["Tuesday "])
    }

    func testCJKAnimatesPerCharacterAndKeepsEnglishWordsWhole() {
        let characters = Array("我们明天 review 一下，好吗")
        let units = LiveTextAnimation.wordRanges(in: characters, splittingAt: 0)
            .map { String(characters[$0]) }
        XCTAssertEqual(units, ["我", "们", "明", "天 ", "review ", "一", "下，", "好", "吗"])
        let contraction = Array("don't stop")
        XCTAssertEqual(
            LiveTextAnimation.wordRanges(in: contraction, splittingAt: 0).map { String(contraction[$0]) },
            ["don't ", "stop"]
        )
    }

    func testLargeResultsCapTheStagger() {
        var animation = LiveTextAnimation()
        let now = Date()
        animation.update(to: (1...20).map { "w\($0)" }.joined(separator: " "), at: now)
        let last = animation.words(committedCount: 0).last?.startsAt
        XCTAssertEqual(last, now.addingTimeInterval(LiveTextAnimation.maximumStagger))
    }
}
