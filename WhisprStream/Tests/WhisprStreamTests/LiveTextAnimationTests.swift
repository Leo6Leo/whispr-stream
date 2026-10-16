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
        var animation = LiveTextAnimation(stableText: "Start ")
        let now = Date()
        animation.update(to: "Start " + (1...20).map { "w\($0)" }.joined(separator: " "), at: now)
        let last = animation.words(committedCount: 0).last?.startsAt
        XCTAssertEqual(last, now.addingTimeInterval(LiveTextAnimation.maximumStagger))
    }

    func testFirstPreviewOfAnUtteranceAppearsAtOnce() throws {
        var animation = LiveTextAnimation()
        let now = Date()
        animation.update(to: "hello there world", at: now)
        XCTAssertNil(animation.animationEnd, "the first words must not wait on a stagger or a spring")
        XCTAssertTrue(animation.words(committedCount: 0).allSatisfy { $0.startsAt == nil })
        XCTAssertEqual(animation.text, "hello there world")

        // Everything after the first preview still springs in word by word.
        animation.update(to: "hello there world again", at: now.addingTimeInterval(0.2))
        let words = animation.words(committedCount: 0)
        XCTAssertNil(words.first?.startsAt)
        XCTAssertEqual(words.last?.text, "again")
        let arrival = now.addingTimeInterval(0.2)
        let startsAt = try XCTUnwrap(words.last?.startsAt)
        XCTAssertGreaterThanOrEqual(startsAt, arrival)
        XCTAssertLessThanOrEqual(startsAt, arrival.addingTimeInterval(LiveTextAnimation.maximumStagger))
    }

    func testAppendingAWordDoesNotReplayItsPredecessor() {
        var animation = LiveTextAnimation(stableText: "hello there")
        let now = Date()
        animation.update(to: "hello there world", at: now)
        let words = animation.words(committedCount: 0)
        XCTAssertEqual(words.map(\.text), ["hello ", "there ", "world"])
        // "there " gained its trailing space with this preview; the word the
        // user already read must not blink because of it.
        XCTAssertEqual(words.map(\.startsAt), [nil, nil, now])
    }

    func testRevisedWordsRefreshInPlaceWhileNewWordsArrive() {
        // A word that grew keeps its letters: a revision, not an arrival.
        var grown = LiveTextAnimation(stableText: "I want to go")
        grown.update(to: "I want to going there", at: .now)
        var words = grown.words(committedCount: 0)
        XCTAssertEqual(words.map(\.text), ["I ", "want ", "to ", "going ", "there"])
        XCTAssertEqual(words.map(\.isRevision), [false, false, false, true, false])
        XCTAssertEqual(words.map { $0.startsAt != nil }, [false, false, false, true, true])

        // A respelled word shares letters with its predecessor: a revision.
        var respelled = LiveTextAnimation(stableText: "we meet Monday then")
        respelled.update(to: "we meet Tuesday then", at: .now)
        words = respelled.words(committedCount: 0)
        XCTAssertEqual(words.filter(\.isRevision).map(\.text), ["Tuesday "])

        // A word replaced outright still counts as a revision of what was there.
        var swapped = LiveTextAnimation(stableText: "a cat sat")
        swapped.update(to: "a dog sat", at: .now)
        words = swapped.words(committedCount: 0)
        XCTAssertEqual(words.filter(\.isRevision).map(\.text), ["dog "])

        // Appending alone is an arrival: the new word fades in from nothing.
        var appended = LiveTextAnimation(stableText: "hello there")
        appended.update(to: "hello there world", at: .now)
        words = appended.words(committedCount: 0)
        XCTAssertEqual(words.map(\.isRevision), [false, false, false])
        XCTAssertNotNil(words.last?.startsAt)
    }

    func testPunctuationAddedLaterDoesNotReplayTheWord() {
        var animation = LiveTextAnimation(stableText: "we meet Monday")
        animation.update(to: "we meet Monday.", at: .now)
        XCTAssertTrue(animation.words(committedCount: 0).allSatisfy { $0.startsAt == nil })

        var cjk = LiveTextAnimation(stableText: "我们明天")
        cjk.update(to: "我们明天，", at: .now)
        XCTAssertTrue(cjk.words(committedCount: 0).allSatisfy { $0.startsAt == nil })
    }
}
