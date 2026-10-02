import XCTest

final class ReleaseLifecycleTests: XCTestCase {
    func testStaleHUDCallbacksCannotDismissANewRecording() {
        ReleaseLifecycleChecks.hud { XCTAssertTrue($0, $1) }
    }

    func testAutomaticUpdatesWaitForDictationAndRemainRetryable() {
        ReleaseLifecycleChecks.updatePrompt { XCTAssertTrue($0, $1) }
    }
}
