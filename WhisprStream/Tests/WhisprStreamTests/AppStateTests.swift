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

    func testPerformanceNoticeAppearsOnlyAfterSlowWait() async throws {
        let state = AppState()
        state.updatePerformanceCondition(.memoryPressure)

        state.beginTranscriptionWait(noticeDelay: 0.01)

        XCTAssertNil(state.performanceNoticeText)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(
            state.performanceNoticeText,
            "Memory pressure is high · Transcription may be slower"
        )
    }

    func testReturningToNormalHidesPerformanceNotice() async throws {
        let state = AppState()
        state.updatePerformanceCondition(.thermalPressure)
        state.beginTranscriptionWait(noticeDelay: 0.01)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotNil(state.performanceNoticeText)

        state.updatePerformanceCondition(.normal)

        XCTAssertNil(state.performanceNoticeText)
    }

    func testFairThermalStateDoesNotWarn() {
        XCTAssertEqual(
            SystemPerformanceCondition(memoryPressure: false, thermalState: .fair),
            .normal
        )
        XCTAssertEqual(
            SystemPerformanceCondition(memoryPressure: false, thermalState: .serious),
            .thermalPressure
        )
        XCTAssertEqual(
            SystemPerformanceCondition(memoryPressure: true, thermalState: .critical),
            .memoryAndThermalPressure
        )
    }

    func testNormalPressureNeverWarns() async throws {
        let state = AppState()
        state.beginTranscriptionWait(noticeDelay: 0.01)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(state.performanceNoticeText)
    }

    func testResetHidesPerformanceNotice() async throws {
        let state = AppState()
        state.updatePerformanceCondition(.memoryPressure)
        state.beginTranscriptionWait(noticeDelay: 0.01)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotNil(state.performanceNoticeText)
        state.reset()
        XCTAssertNil(state.performanceNoticeText)
    }
}
