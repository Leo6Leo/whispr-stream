import Foundation
import XCTest
@testable import WhisprStream

@MainActor
final class TrainingDataStoreTests: XCTestCase {
    func testAddPersistsReloadsAndDeletesReviewedSample() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(rootURL: root)
        let pcm = Data([0x00, 0x00, 0x01, 0x00, 0xff, 0x7f, 0x00, 0x80])
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let sample = try store.addSample(
            rawTranscript: "hello whirl",
            suggestedTranscript: "Hello whirl.",
            correctedTranscript: "Hello world.",
            pcm16Mono16k: pcm,
            model: .small,
            createdAt: createdAt
        )

        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertTrue(sample.isPendingTraining)
        XCTAssertEqual(sample.audioFrameCount, 4)
        XCTAssertEqual(sample.audioDurationSeconds, 4.0 / 16_000, accuracy: 0.000_001)

        let audioURL = store.audioURL(for: sample)
        let wav = try Data(contentsOf: audioURL)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(wav.suffix(pcm.count), pcm)
        XCTAssertEqual(try permissions(at: audioURL), 0o600)
        XCTAssertEqual(
            try permissions(at: root.appendingPathComponent("manifest.json")),
            0o600
        )

        let reloaded = TrainingDataStore(rootURL: root)
        XCTAssertEqual(reloaded.samples, [sample])
        XCTAssertNil(reloaded.loadError)

        try reloaded.deleteSample(id: sample.id)
        XCTAssertTrue(reloaded.samples.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))

        let afterDeletion = TrainingDataStore(rootURL: root)
        XCTAssertTrue(afterDeletion.samples.isEmpty)
    }

    func testInvalidSamplesNeverCreateTrainingData() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(rootURL: root)
        let pcm = Data([0x00, 0x00])

        XCTAssertThrowsError(try store.addSample(
            rawTranscript: "",
            suggestedTranscript: "Suggestion",
            correctedTranscript: "Correction",
            pcm16Mono16k: pcm,
            model: .small
        )) { error in
            XCTAssertEqual(error as? TrainingDataStoreError, .emptyRawTranscript)
        }
        XCTAssertThrowsError(try store.addSample(
            rawTranscript: "Raw",
            suggestedTranscript: "Suggestion",
            correctedTranscript: "   ",
            pcm16Mono16k: pcm,
            model: .small
        )) { error in
            XCTAssertEqual(error as? TrainingDataStoreError, .emptyCorrectedTranscript)
        }
        XCTAssertThrowsError(try store.addSample(
            rawTranscript: "Raw",
            suggestedTranscript: "Suggestion",
            correctedTranscript: "Correction",
            pcm16Mono16k: Data(),
            model: .small
        )) { error in
            XCTAssertEqual(error as? TrainingDataStoreError, .emptyAudio)
        }

        XCTAssertTrue(store.samples.isEmpty)
    }

    func testCorrectionCanBeEditedWithoutChangingAudioOrImmutableMetadata() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(rootURL: root)
        let pcm = Data([0x00, 0x00, 0x01, 0x00])
        let sample = try store.addSample(
            rawTranscript: "hello whirl",
            suggestedTranscript: "Hello whirl.",
            correctedTranscript: "Hello world.",
            pcm16Mono16k: pcm,
            model: .small
        )
        let audioBefore = try Data(contentsOf: store.audioURL(for: sample))

        try store.updateCorrectedTranscript(
            id: sample.id,
            correctedTranscript: "  Hello, world!  \n"
        )

        let updated = try XCTUnwrap(store.samples.first)
        XCTAssertEqual(updated.correctedTranscript, "Hello, world!")
        XCTAssertEqual(updated.rawTranscript, sample.rawTranscript)
        XCTAssertEqual(updated.audioFileName, sample.audioFileName)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: updated)), audioBefore)

        let reloaded = TrainingDataStore(rootURL: root)
        XCTAssertEqual(reloaded.samples.first?.correctedTranscript, "Hello, world!")
    }

    func testCorrectionEditRejectsEmptyTextAndUnknownSample() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(rootURL: root)

        XCTAssertThrowsError(try store.updateCorrectedTranscript(
            id: UUID(),
            correctedTranscript: "   "
        )) { error in
            XCTAssertEqual(error as? TrainingDataStoreError, .emptyCorrectedTranscript)
        }
        XCTAssertThrowsError(try store.updateCorrectedTranscript(
            id: UUID(),
            correctedTranscript: "Valid correction"
        )) { error in
            XCTAssertEqual(error as? TrainingDataStoreError, .sampleNotFound)
        }
    }

    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisprStreamTrainingDataTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
