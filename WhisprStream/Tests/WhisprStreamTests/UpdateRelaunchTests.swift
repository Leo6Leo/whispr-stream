import XCTest
@testable import WhisprStream

final class UpdateRelaunchTests: XCTestCase {
    func testRelaunchesWhenAnUpdaterSpawnedUsAsItsChild() {
        let launchd: pid_t = 1
        let helper: pid_t = 4242
        // The pre-1.0.4 helper spawns the app as its own child. Measured with
        // a real 1.0.3 helper: the responsibility API then claims the app is
        // its own responsible process while TCC still denies it, so the
        // parent alone must be enough.
        XCTAssertTrue(UpdateRelaunch.isNeeded(launchedByUpdater: true, parentProcess: helper, isOwnResponsibleProcess: true))
        XCTAssertTrue(UpdateRelaunch.isNeeded(launchedByUpdater: true, parentProcess: helper, isOwnResponsibleProcess: false))
        XCTAssertTrue(UpdateRelaunch.isNeeded(launchedByUpdater: true, parentProcess: helper, isOwnResponsibleProcess: nil))
        // The current helper launches through LaunchServices (parent launchd):
        // nothing to repair unless responsibility is demonstrably foreign.
        XCTAssertFalse(UpdateRelaunch.isNeeded(launchedByUpdater: true, parentProcess: launchd, isOwnResponsibleProcess: true))
        XCTAssertFalse(UpdateRelaunch.isNeeded(launchedByUpdater: true, parentProcess: launchd, isOwnResponsibleProcess: nil))
        XCTAssertTrue(UpdateRelaunch.isNeeded(launchedByUpdater: true, parentProcess: launchd, isOwnResponsibleProcess: false))
        // A user launch is never touched, whatever its parent or responsibility.
        XCTAssertFalse(UpdateRelaunch.isNeeded(launchedByUpdater: false, parentProcess: helper, isOwnResponsibleProcess: false))
        XCTAssertFalse(UpdateRelaunch.isNeeded(launchedByUpdater: false, parentProcess: launchd, isOwnResponsibleProcess: true))
    }

    func testResponsibleProcessLookupResolvesForThisProcess() {
        let responsible = ProcessResponsibility.responsiblePID(for: getpid())
        XCTAssertNotNil(responsible, "the private responsibility symbol should resolve on macOS")
        XCTAssertGreaterThan(responsible ?? 0, 0)
    }

    func testHelperExitWaitIsLongerThanTheHelpersStabilityInterval() {
        // The helper confirms health two seconds after the signal and then
        // cleans up; a shorter wait would race it into a rollback.
        XCTAssertGreaterThanOrEqual(UpdateRelaunch.helperExitTimeout, 10)
    }
}
