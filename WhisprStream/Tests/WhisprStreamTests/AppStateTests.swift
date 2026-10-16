import XCTest
@testable import WhisprStream

@MainActor
final class AppStateTests: XCTestCase {
    func testLimitWarningShowsCountdown() {
        let state = AppState()
        state.phase = .listening
        let limit = AppState.dictationLimitSeconds
        let warningStart = limit - AppState.dictationWarningLeadTimeSeconds

        state.dictationElapsedSeconds = warningStart - 0.1
        XCTAssertFalse(state.isApproachingDictationLimit)

        state.dictationElapsedSeconds = warningStart
        XCTAssertTrue(state.isApproachingDictationLimit)
        XCTAssertEqual(
            state.dictationCountdownLabel,
            "\(Int(AppState.dictationWarningLeadTimeSeconds))s"
        )

        state.dictationElapsedSeconds = limit
        XCTAssertEqual(state.dictationCountdownLabel, "0s")

        state.phase = .thinking
        XCTAssertFalse(state.isApproachingDictationLimit)
    }

    func testNoticeClearsItselfAndOnReset() {
        let state = AppState()
        state.phase = .listening

        state.showNotice("Grant it in Settings", for: 0.05)
        XCTAssertEqual(state.notice, "Grant it in Settings")

        let cleared = expectation(description: "notice clears after its duration")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { cleared.fulfill() }
        wait(for: [cleared], timeout: 2)
        XCTAssertNil(state.notice)

        // A new dictation must never inherit a stale notice.
        state.showNotice("Still here", for: 10)
        state.reset()
        XCTAssertNil(state.notice)
    }
}
