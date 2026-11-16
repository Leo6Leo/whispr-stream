import Foundation
import XCTest
@testable import WhisprStream

final class SpeechEngineStartupTimeoutTests: XCTestCase {
    private let small = ASRModel.small.rawValue
    private let large = ASRModel.large.rawValue

    func testDefaultSmallModelKeepsTwentySeconds() {
        XCTAssertEqual(ASRService.startupTimeout(model: small, engine: .qwen3, finalModel: nil), 20)
        // The app passes "" through the environment for "no final model".
        XCTAssertEqual(ASRService.startupTimeout(model: small, engine: .qwen3, finalModel: ""), 20)
    }

    func testLargeModelAloneGetsLargerBudget() {
        XCTAssertEqual(ASRService.startupTimeout(model: large, engine: .qwen3, finalModel: nil), 40)
    }

    func testMixedModeAddsBothModelsBudgets() {
        XCTAssertEqual(ASRService.startupTimeout(model: small, engine: .qwen3, finalModel: large), 60)
    }

    func testFinalModelEqualToPreviewModelLoadsOnce() {
        XCTAssertEqual(ASRService.startupTimeout(model: small, engine: .qwen3, finalModel: small), 20)
        XCTAssertEqual(ASRService.startupTimeout(model: large, engine: .qwen3, finalModel: large), 40)
    }

    func testFinalModelIgnoredForWhisperLikeTheSidecar() {
        XCTAssertEqual(
            ASRService.startupTimeout(model: "mlx-community/whisper-large-v3-turbo", engine: .whisper, finalModel: large),
            40
        )
    }

    func testUnknownOrOverriddenModelsUseLargerBudget() {
        XCTAssertEqual(ASRService.startupTimeout(model: "/Users/me/models/custom", engine: .qwen3, finalModel: nil), 40)
        // The 0.6B id under the Whisper engine is not the known 0.6B load.
        XCTAssertEqual(ASRService.startupTimeout(model: small, engine: .whisper, finalModel: nil), 40)
    }

    func testServiceCarriesTimeoutForWhatItLaunches() {
        let script = URL(fileURLWithPath: "/nonexistent/asr_server.py")
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        let single = ASRService(
            python: python, script: script, model: small, engine: .qwen3, bits: 8,
            context: "", shortUtteranceLanguage: .english
        )
        let mixed = ASRService(
            python: python, script: script, model: small, engine: .qwen3, bits: 8,
            context: "", shortUtteranceLanguage: .english, finalModel: large
        )
        XCTAssertEqual(single.startupTimeout, 20)
        XCTAssertEqual(mixed.startupTimeout, 60)
    }
}
