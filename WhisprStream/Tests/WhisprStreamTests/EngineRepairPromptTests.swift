import XCTest
@testable import WhisprStream

@MainActor
final class EngineRepairPromptTests: XCTestCase {
    private typealias Phase = RuntimeManager.Phase

    func testOnlyBrokenPhasesCarryARepairReason() {
        XCTAssertEqual(Phase.failed("health check failed").repairReason, "health check failed")
        XCTAssertEqual(Phase.incompatible("modified").repairReason, "modified")
        XCTAssertNotNil(Phase.missing.repairReason)
        for phase in [Phase.ready, .checking, .checkingStorage, .downloading, .verifying, .installing,
                      .insufficientStorage(required: 2, available: 1)] {
            XCTAssertNil(phase.repairReason)
        }
    }

    func testPromptsWhenAWorkingOrCheckedEngineBreaks() {
        // The launch health check, a later integrity failure, and a state
        // that was already broken when observation began.
        XCTAssertTrue(RuntimeManager.shouldPromptForRepair(from: .checking, to: .failed("x")))
        XCTAssertTrue(RuntimeManager.shouldPromptForRepair(from: .ready, to: .incompatible("x")))
        XCTAssertTrue(RuntimeManager.shouldPromptForRepair(from: nil, to: .missing))
    }

    func testDoesNotPromptForInstallFailuresOrHealthyPhases() {
        // The installer UI already shows these inline.
        XCTAssertFalse(RuntimeManager.shouldPromptForRepair(from: .installing, to: .failed("x")))
        XCTAssertFalse(RuntimeManager.shouldPromptForRepair(from: .downloading, to: .missing))
        XCTAssertFalse(RuntimeManager.shouldPromptForRepair(from: .verifying, to: .failed("x")))
        XCTAssertFalse(RuntimeManager.shouldPromptForRepair(from: .checking, to: .ready))
        XCTAssertFalse(RuntimeManager.shouldPromptForRepair(from: .ready, to: .downloading))
        XCTAssertFalse(RuntimeManager.shouldPromptForRepair(from: .failed("x"), to: .checkingStorage))
    }
}
