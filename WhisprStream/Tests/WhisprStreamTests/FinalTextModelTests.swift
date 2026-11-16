import XCTest
@testable import WhisprStream

final class FinalTextModelTests: XCTestCase {
    func testLargeModelWritesTheFinalTextOnlyBesideTheSmallModel() {
        XCTAssertEqual(
            Settings.finalTextModel(enabled: true, selected: .small, largeInstalled: true),
            .large
        )
        // Off by default, and never a silent multi-gigabyte download.
        XCTAssertNil(Settings.finalTextModel(enabled: false, selected: .small, largeInstalled: true))
        XCTAssertNil(Settings.finalTextModel(enabled: true, selected: .small, largeInstalled: false))
        // With the large model selected it already writes everything.
        XCTAssertNil(Settings.finalTextModel(enabled: true, selected: .large, largeInstalled: true))
        let custom = ASRModel(engine: .whisper, source: .huggingFace, location: "mlx-community/whisper-tiny")
        XCTAssertNil(Settings.finalTextModel(enabled: true, selected: custom, largeInstalled: true))
    }
}
