import Foundation
import XCTest
@testable import WhisprStream

final class SpeechEngineWarmupGateTests: XCTestCase {
    func testFreshGateDoesNotWarmBeforeInitialReadyEvent() {
        let gate = SpeechEngineWarmupGate()

        XCTAssertFalse(gate.requiresWarmup(at: Date(timeIntervalSince1970: 1_000)))
    }

    func testReadinessLeaseExpiresAtIdleInterval() {
        let activity = Date(timeIntervalSince1970: 1_000)
        var gate = SpeechEngineWarmupGate()
        gate.markActivity(at: activity)

        XCTAssertFalse(gate.requiresWarmup(
            at: activity.addingTimeInterval(299),
            idleInterval: 300
        ))
        XCTAssertTrue(gate.requiresWarmup(
            at: activity.addingTimeInterval(300),
            idleInterval: 300
        ))
    }

    func testCompletedWarmupRenewsReadinessLease() {
        let firstActivity = Date(timeIntervalSince1970: 1_000)
        let warmedAt = firstActivity.addingTimeInterval(600)
        var gate = SpeechEngineWarmupGate()
        gate.markActivity(at: firstActivity)
        gate.markActivity(at: warmedAt)

        XCTAssertFalse(gate.requiresWarmup(
            at: warmedAt.addingTimeInterval(299),
            idleInterval: 300
        ))
    }

    func testResetRemovesStaleReadinessLease() {
        var gate = SpeechEngineWarmupGate()
        gate.markActivity(at: Date(timeIntervalSince1970: 1_000))
        gate.reset()

        XCTAssertFalse(gate.requiresWarmup(at: Date(timeIntervalSince1970: 10_000)))
    }
}
