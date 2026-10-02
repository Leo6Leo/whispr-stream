import Darwin
import Foundation

/// Drives the Python ASR sidecar over newline-delimited JSON.
///
/// The model load takes several seconds and must happen exactly once, so the
/// process is started at launch and kept alive for the lifetime of the app.
/// After its one startup warm-up, it waits for commands without idle inference.
final class ASRService {
    enum Event {
        case ready(ms: Int)
        case partial(committed: String, tail: String)
        case final(text: String, secs: Double, ms: Int, review: DictationReview? = nil)
        case error(String)
        case terminated(String)
    }

    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private var buffer = Data()
    private let queue = DispatchQueue(label: "asr.stdout")
    private let writerQueue = DispatchQueue(label: "asr.stdin")
    private let commandStateLock = NSLock()
    private var acceptsCommands = true
    private var shutdownRequested = false

    var onEvent: ((Event) -> Void)?

    init(
        python: URL,
        script: URL,
        model: String,
        engine: ASREngine = .qwen3,
        bits: Int,
        context: String,
        shortUtteranceLanguage: ShortUtteranceLanguage,
        learnedContext: String = ""
    ) {
        process.executableURL = python
        process.arguments = PythonProcessEnvironment.scriptArguments(script: script)
        process.standardInput = inPipe
        process.standardOutput = outPipe
        // A sidecar can exit while a queued audio write is in flight. Suppress
        // SIGPIPE for this descriptor so that becomes a handled EPIPE instead
        // of terminating the whole app.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Keep stderr: without it a failing sidecar is silent and undebuggable.
        process.standardError = ASRService.makeLogHandle() ?? FileHandle.nullDevice

        process.environment = PythonProcessEnvironment.sanitized(additions: [
            "WHISPR_MODEL": model,
            "WHISPR_ENGINE": engine.rawValue,
            "WHISPR_BITS": String(bits),
            "WHISPR_CONTEXT": context,
            "WHISPR_LEARNED_CONTEXT": learnedContext,
            "WHISPR_SHORT_UTTERANCE_LANGUAGE":
                shortUtteranceLanguage.fixedModelLanguage ?? "",
        ])
    }

    /// ~/Library/Logs/WhisprStream.log — where sidecar stderr goes.
    static var logURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WhisprStream.log")
    }

    private static func makeLogHandle() -> FileHandle? {
        let url = logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    func start() throws {
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.ingest(data) }
        }
        process.terminationHandler = { [weak self] process in
            guard let self, self.handleProcessTermination() else { return }
            Log.write("speech engine exited unexpectedly: status=\(process.terminationStatus)")
            DispatchQueue.main.async {
                self.onEvent?(.terminated("Speech engine stopped unexpectedly"))
            }
        }
        try process.run()
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = buffer[buffer.index(after: nl)...]
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            let event: Event
            switch type {
            case "ready":
                event = .ready(ms: obj["ms"] as? Int ?? 0)
            case "partial":
                event = .partial(
                    committed: obj["committed"] as? String ?? "",
                    tail: obj["tail"] as? String ?? ""
                )
            case "final":
                let seconds = obj["secs"] as? Double ?? 0
                let inferenceMS = obj["ms"] as? Int ?? 0
                let totalMS = obj["total_ms"] as? Int ?? inferenceMS
                let waitMS = obj["wait_ms"] as? Int ?? 0
                let mode = obj["mode"] as? String ?? "legacy"
                let unseenMS = obj["unseen_ms"] as? Int ?? 0
                let language = obj["language"] as? String ?? "unknown"
                Log.write(
                    "asr final: audio=\(String(format: "%.2f", seconds))s "
                    + "visible=\(totalMS)ms wait=\(waitMS)ms inference=\(inferenceMS)ms "
                    + "mode=\(mode) unseen=\(unseenMS)ms language=\(language)"
                )
                event = .final(
                    text: obj["text"] as? String ?? "",
                    secs: seconds,
                    ms: inferenceMS,
                    review: DictationReview.parse(obj["review"], transcript: obj["text"] as? String ?? "")
                )
            default:
                let message = obj["message"] as? String ?? "unknown"
                Log.write("asr error: \(message)")
                event = .error(message)
            }
            DispatchQueue.main.async { self.onEvent?(event) }
        }
    }

    private func send(_ dict: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        data.append(0x0A)
        guard isAcceptingCommands else { return }
        writerQueue.async { [weak self] in
            guard let self, self.isAcceptingCommands else { return }
            self.writeToSidecar(data)
        }
    }

    private func writeToSidecar(_ data: Data) {
        let descriptor = inPipe.fileHandleForWriting.fileDescriptor
        let completed = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result == -1 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        if !completed { stopWritingAfterFailure() }
    }

    private var isAcceptingCommands: Bool {
        commandStateLock.lock()
        defer { commandStateLock.unlock() }
        return acceptsCommands
    }

    private func stopWritingAfterFailure() {
        commandStateLock.lock()
        acceptsCommands = false
        commandStateLock.unlock()
    }

    /// Returns true only for an unexpected process exit. `shutdown()` marks
    /// the service first so its termination handler stays silent.
    private func handleProcessTermination() -> Bool {
        commandStateLock.lock()
        defer { commandStateLock.unlock() }
        acceptsCommands = false
        return !shutdownRequested
    }

    func beginUtterance(shortUtteranceLanguage: String?) {
        var command: [String: Any] = ["cmd": "start"]
        if let shortUtteranceLanguage {
            command["short_utterance_language"] = shortUtteranceLanguage
        }
        send(command)
    }

    func setLearnedContext(_ text: String) { send(["cmd": "learned_context", "text": text]) }
    func stopUtterance() { send(["cmd": "stop"]) }

    /// Push edited vocabulary to the resident sidecar. The model is not reloaded,
    /// so this is cheap enough to call on every keystroke in Settings.
    func setContext(_ terms: String) { send(["cmd": "context", "text": terms]) }

    /// `pcm` must be mono 16 kHz signed 16-bit.
    func sendAudio(_ pcm: Data) {
        send(["cmd": "audio", "pcm": pcm.base64EncodedString()])
    }

    func shutdown() {
        commandStateLock.lock()
        shutdownRequested = true
        acceptsCommands = false
        commandStateLock.unlock()
        if process.isRunning { process.terminate() }
    }
}
