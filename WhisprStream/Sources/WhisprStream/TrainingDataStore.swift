import Combine
import Foundation

/// A confirmed audio/transcript pair that can be consumed by a future trainer.
/// Stage one only creates `.pending` samples; the version fields make the on-disk
/// schema forward-compatible with adapter training and rollback.
struct TrainingSample: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let rawTranscript: String
    let suggestedTranscript: String
    var correctedTranscript: String
    let audioFileName: String
    let audioSampleRate: Int
    let audioChannels: Int
    let audioBitsPerSample: Int
    let audioFrameCount: Int
    let audioDurationSeconds: Double
    let modelID: String
    let modelEngine: String
    var includedInAdapterVersion: Int?
    var includedAt: Date?
    /// How the sample was collected, e.g. "passive-edit" for a correction the
    /// user typed into the destination field. Absent for reviewed samples.
    var origin: String? = nil

    var isPendingTraining: Bool { includedInAdapterVersion == nil }
}

enum TrainingDataStoreError: LocalizedError, Equatable {
    case emptyAudio
    case emptyRawTranscript
    case emptyCorrectedTranscript
    case sampleNotFound

    var errorDescription: String? {
        switch self {
        case .emptyAudio: return "The reviewed recording contains no audio."
        case .emptyRawTranscript: return "The speech model returned no transcript."
        case .emptyCorrectedTranscript: return "Enter the text that should have been recognized."
        case .sampleNotFound: return "That training sample no longer exists."
        }
    }
}

/// Thread-safe, in-memory PCM retention for the current utterance.
///
/// Audio accumulates only between `begin(retaining: true)` and the next
/// `snapshot()` or `discard()`. With retention off, `append` keeps nothing, so
/// a user who never turned on correction capture never holds a dictation's
/// PCM in memory.
final class ReviewAudioBuffer {
    private let lock = NSLock()
    private var pcm = Data()
    private var isRetaining = false

    func begin(retaining: Bool) {
        lock.lock()
        isRetaining = retaining
        pcm.removeAll(keepingCapacity: retaining)
        lock.unlock()
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isRetaining { pcm.append(data) }
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return pcm
    }

    /// Drops held audio and stops retaining until the next `begin`, so a
    /// buffer that arrives after a failure or a final result is not kept.
    func discard() {
        lock.lock()
        isRetaining = false
        pcm.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

@MainActor
final class TrainingDataStore: ObservableObject {
    static let shared = TrainingDataStore()

    private struct Manifest: Codable {
        let schemaVersion: Int
        var samples: [TrainingSample]
    }

    @Published private(set) var samples: [TrainingSample] = []
    @Published private(set) var loadError: String?

    let storageRootURL: URL
    private let audioDirectoryURL: URL
    private let manifestURL: URL
    private let fileManager: FileManager

    var pendingCount: Int { samples.filter(\.isPendingTraining).count }

    convenience init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.init(
            rootURL: applicationSupport
                .appendingPathComponent("WhisprStream", isDirectory: true)
                .appendingPathComponent("TrainingData", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        )
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.storageRootURL = rootURL
        self.audioDirectoryURL = rootURL.appendingPathComponent("audio", isDirectory: true)
        self.manifestURL = rootURL.appendingPathComponent("manifest.json")
        self.fileManager = fileManager
        load()
    }

    @discardableResult
    func addSample(
        rawTranscript: String,
        suggestedTranscript: String,
        correctedTranscript: String,
        pcm16Mono16k: Data,
        model: ASRModel,
        createdAt: Date = Date(),
        origin: String? = nil
    ) throws -> TrainingSample {
        guard !pcm16Mono16k.isEmpty else { throw TrainingDataStoreError.emptyAudio }
        guard !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrainingDataStoreError.emptyRawTranscript
        }
        guard !correctedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrainingDataStoreError.emptyCorrectedTranscript
        }

        try prepareDirectories()
        let id = UUID()
        let audioFileName = "\(id.uuidString.lowercased()).wav"
        let audioURL = audioDirectoryURL.appendingPathComponent(audioFileName)
        let audioFrameCount = pcm16Mono16k.count / MemoryLayout<Int16>.size
        let sample = TrainingSample(
            schemaVersion: TrainingSample.currentSchemaVersion,
            id: id,
            createdAt: createdAt,
            rawTranscript: rawTranscript,
            suggestedTranscript: suggestedTranscript,
            correctedTranscript: correctedTranscript,
            audioFileName: audioFileName,
            audioSampleRate: 16_000,
            audioChannels: 1,
            audioBitsPerSample: 16,
            audioFrameCount: audioFrameCount,
            audioDurationSeconds: Double(audioFrameCount) / 16_000,
            modelID: model.id,
            modelEngine: model.engine.rawValue,
            includedInAdapterVersion: nil,
            includedAt: nil,
            origin: origin
        )

        do {
            try Self.wavData(pcm16Mono16k: pcm16Mono16k).write(to: audioURL, options: .atomic)
            try setPrivateFilePermissions(at: audioURL)
        } catch {
            try? fileManager.removeItem(at: audioURL)
            throw error
        }
        let previous = samples
        samples.insert(sample, at: 0)
        do {
            try persistManifest()
        } catch {
            samples = previous
            try? fileManager.removeItem(at: audioURL)
            throw error
        }
        Log.write("training sample saved id=\(id) audioBytes=\(pcm16Mono16k.count)")
        return sample
    }

    func deleteSample(id: UUID) throws {
        guard let index = samples.firstIndex(where: { $0.id == id }) else {
            throw TrainingDataStoreError.sampleNotFound
        }
        let sample = samples[index]
        let previous = samples
        let audioURL = audioDirectoryURL.appendingPathComponent(sample.audioFileName)
        let savedAudio: Data?
        if fileManager.fileExists(atPath: audioURL.path) {
            savedAudio = try Data(contentsOf: audioURL)
            try fileManager.removeItem(at: audioURL)
        } else {
            savedAudio = nil
        }
        samples.remove(at: index)
        do {
            try persistManifest()
        } catch {
            samples = previous
            if let savedAudio {
                try? savedAudio.write(to: audioURL, options: .atomic)
                try? setPrivateFilePermissions(at: audioURL)
            }
            throw error
        }
        Log.write("training sample deleted id=\(id)")
    }

    func updateCorrectedTranscript(id: UUID, correctedTranscript: String) throws {
        let correction = correctedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correction.isEmpty else {
            throw TrainingDataStoreError.emptyCorrectedTranscript
        }
        guard let index = samples.firstIndex(where: { $0.id == id }) else {
            throw TrainingDataStoreError.sampleNotFound
        }
        guard samples[index].correctedTranscript != correction else { return }

        let previous = samples
        samples[index].correctedTranscript = correction
        // A correction changed after training is new learning data. Keeping the
        // old adapter status would incorrectly imply that it already learned it.
        samples[index].includedInAdapterVersion = nil
        samples[index].includedAt = nil
        do {
            try persistManifest()
        } catch {
            samples = previous
            throw error
        }
        Log.write("training sample correction updated id=\(id)")
    }

    func deleteAll() throws {
        if fileManager.fileExists(atPath: storageRootURL.path) {
            try fileManager.removeItem(at: storageRootURL)
        }
        samples = []
        loadError = nil
        try prepareDirectories()
        try persistManifest()
        Log.write("all training samples deleted")
    }

    func audioURL(for sample: TrainingSample) -> URL {
        audioDirectoryURL.appendingPathComponent(sample.audioFileName)
    }

    private func load() {
        do {
            try prepareDirectories()
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                try persistManifest()
                return
            }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try Self.decoder.decode(Manifest.self, from: data)
            guard manifest.schemaVersion == TrainingSample.currentSchemaVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            samples = manifest.samples.sorted { $0.createdAt > $1.createdAt }
            loadError = nil
        } catch {
            samples = []
            loadError = "Learning data could not be loaded. Existing files were left unchanged."
            Log.write("training data manifest load failed")
        }
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(
            at: audioDirectoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: storageRootURL.path
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: audioDirectoryURL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = storageRootURL
        try? root.setResourceValues(values)
    }

    private func persistManifest() throws {
        let manifest = Manifest(
            schemaVersion: TrainingSample.currentSchemaVersion,
            samples: samples
        )
        let data = try Self.encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        try setPrivateFilePermissions(at: manifestURL)
    }

    private func setPrivateFilePermissions(at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func wavData(pcm16Mono16k pcm: Data) throws -> Data {
        guard !pcm.isEmpty else { throw TrainingDataStoreError.emptyAudio }
        guard pcm.count <= Int(UInt32.max) - 36 else {
            throw CocoaError(.fileWriteOutOfSpace)
        }

        var wav = Data()
        wav.appendASCII("RIFF")
        wav.appendLittleEndian(UInt32(36 + pcm.count))
        wav.appendASCII("WAVE")
        wav.appendASCII("fmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))       // PCM
        wav.appendLittleEndian(UInt16(1))       // mono
        wav.appendLittleEndian(UInt32(16_000))
        wav.appendLittleEndian(UInt32(32_000))  // bytes per second
        wav.appendLittleEndian(UInt16(2))       // block alignment
        wav.appendLittleEndian(UInt16(16))
        wav.appendASCII("data")
        wav.appendLittleEndian(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
