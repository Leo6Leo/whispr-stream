import Foundation
import XCTest
@testable import WhisprStream

final class ASRServiceTests: XCTestCase {
    func testSelectedEngineIsPassedToSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisprStream-ASRServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("engine_sidecar.py")
        try """
        import json
        import os
        import time

        print(json.dumps({"type": "error", "message": os.environ.get("WHISPR_ENGINE")}), flush=True)
        time.sleep(0.2)
        """.write(to: script, atomically: true, encoding: .utf8)

        let service = ASRService(
            python: URL(fileURLWithPath: "/usr/bin/python3"),
            script: script,
            model: "unused",
            engine: .whisper,
            bits: 8,
            context: "",
            shortUtteranceLanguage: .english
        )
        let received = expectation(description: "engine reaches sidecar")
        service.onEvent = { event in
            if case let .error(message) = event, message == "whisper" {
                received.fulfill()
            }
        }
        try service.start()
        defer { service.shutdown() }

        wait(for: [received], timeout: 2)
    }

    func testDictationDuringStartupPreservesAudioAndCommandOrderWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisprStream-ASRServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("delayed_sidecar.py")
        try """
        import base64
        import json
        import sys
        import time

        time.sleep(1.5)
        print(json.dumps({"type": "ready", "ms": 1500}), flush=True)
        started = False
        chunks = 0
        for line in sys.stdin:
            message = json.loads(line)
            command = message.get("cmd")
            if command == "start":
                assert not started and chunks == 0
                assert message["short_utterance_language"] == "English"
                started = True
            elif command == "audio":
                assert started
                assert base64.b64decode(message["pcm"]) == bytes([chunks]) * 8192
                chunks += 1
            elif command == "stop":
                assert started and chunks == 16
                print(json.dumps({"type": "final", "text": "all audio received in order"}), flush=True)
            elif command == "quit":
                break
            else:
                raise AssertionError(command)
        """.write(to: script, atomically: true, encoding: .utf8)

        let service = ASRService(
            python: URL(fileURLWithPath: "/usr/bin/python3"),
            script: script,
            model: "unused",
            bits: 8,
            context: "",
            shortUtteranceLanguage: .english
        )
        let ready = expectation(description: "delayed sidecar becomes ready")
        let final = expectation(description: "queued dictation completes after startup")
        service.onEvent = { event in
            switch event {
            case .ready:
                ready.fulfill()
            case let .final(text, _, _, _):
                XCTAssertEqual(text, "all audio received in order")
                final.fulfill()
            case let .error(message), let .terminated(message):
                XCTFail(message)
            default:
                break
            }
        }
        try service.start()
        defer { service.shutdown() }

        // This is larger than a typical OS pipe buffer. Synchronous writes
        // block until the delayed process starts reading; queued writes return
        // without stalling either the audio callback or the app's main thread.
        let startedAt = ProcessInfo.processInfo.systemUptime
        service.beginUtterance(shortUtteranceLanguage: "English")
        for index in 0..<16 {
            service.sendAudio(Data(repeating: UInt8(index), count: 8_192))
        }
        service.stopUtterance()
        let enqueueSeconds = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertLessThan(enqueueSeconds, 0.75)
        wait(for: [ready, final], timeout: 4, enforceOrder: true)
    }

    func testUnexpectedSidecarExitHasDistinctLifecycleEvent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisprStream-ASRServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("exiting_sidecar.py")
        try """
        import json
        import sys
        import time

        print(json.dumps({"type": "ready", "ms": 1}), flush=True)
        time.sleep(0.1)
        sys.exit(7)
        """.write(to: script, atomically: true, encoding: .utf8)

        let service = ASRService(
            python: URL(fileURLWithPath: "/usr/bin/python3"),
            script: script,
            model: "unused",
            bits: 8,
            context: "",
            shortUtteranceLanguage: .english
        )
        let ready = expectation(description: "sidecar becomes ready")
        let terminated = expectation(description: "unexpected exit is reported")
        service.onEvent = { event in
            switch event {
            case .ready:
                ready.fulfill()
            case .terminated:
                terminated.fulfill()
            default:
                break
            }
        }
        try service.start()
        defer { service.shutdown() }

        wait(for: [ready, terminated], timeout: 3, enforceOrder: true)
    }
}
