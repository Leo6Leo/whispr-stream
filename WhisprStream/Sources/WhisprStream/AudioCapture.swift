import AVFoundation

/// Captures the default input and delivers mono 16 kHz Int16 buffers.
///
/// The hardware format is whatever the mic reports (usually 44.1/48 kHz float),
/// so everything goes through an AVAudioConverter into the format the ASR
/// sidecar expects.
final class AudioCapture {
    private static let recoveryDelay: TimeInterval = 0.25
    private static let maximumRecoveryAttempts = 20

    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var recoveryWork: DispatchWorkItem?
    private var isCapturing = false
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    /// Called on an audio thread with converted PCM and a 0...1 level estimate.
    var onBuffer: ((Data, Float) -> Void)?

    /// Called on the main queue when an input route cannot be recovered.
    var onFailure: ((Error) -> Void)?

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleConfigurationChange(notification)
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        recoveryWork?.cancel()
    }

    func start() throws {
        recoveryWork?.cancel()
        isCapturing = true
        do {
            try startFreshEngine()
        } catch {
            isCapturing = false
            stopCurrentEngine()
            throw error
        }
    }

    func stop() {
        isCapturing = false
        recoveryWork?.cancel()
        recoveryWork = nil
        stopCurrentEngine()
    }

    private func startFreshEngine() throws {
        stopCurrentEngine()

        // A new engine is intentional. After the default device changes, an
        // existing input node can retain the old device's channel count and
        // sample rate even after reset(), especially while AirPods are moving
        // between their playback and headset profiles.
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw CaptureError.inputNotReady
        }
        guard let converter = AVAudioConverter(from: inFormat, to: targetFormat) else {
            throw CaptureError.unsupportedInputFormat
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            self?.handle(buf, inFormat: inFormat, converter: converter)
        }
        engine = newEngine
        newEngine.prepare()
        try newEngine.start()
    }

    private func stopCurrentEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func handleConfigurationChange(_ notification: Notification) {
        guard isCapturing,
              let engine,
              let changedEngine = notification.object as? AVAudioEngine,
              changedEngine === engine
        else { return }

        Log.write("audio input configuration changed; rebuilding capture engine")
        stopCurrentEngine()
        scheduleRecovery(attempt: 1)
    }

    private func scheduleRecovery(attempt: Int) {
        recoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recover(attempt: attempt)
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.recoveryDelay,
            execute: work
        )
    }

    private func recover(attempt: Int) {
        guard isCapturing else { return }
        do {
            try startFreshEngine()
            recoveryWork = nil
            Log.write("audio input recovered after device change")
        } catch {
            guard attempt < Self.maximumRecoveryAttempts else {
                isCapturing = false
                recoveryWork = nil
                Log.write("audio input recovery failed: \(error.localizedDescription)")
                onFailure?(error)
                return
            }
            scheduleRecovery(attempt: attempt + 1)
        }
    }

    private func handle(
        _ buffer: AVAudioPCMBuffer,
        inFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) {

        let ratio = targetFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0,
              let channel = out.int16ChannelData
        else { return }

        let count = Int(out.frameLength)
        let samples = UnsafeBufferPointer(start: channel[0], count: count)

        let data = Data(buffer: samples)
        onBuffer?(data, Self.level(of: samples))
    }

    /// RMS on converted samples, mapped to a perceptually useful 0...1.
    static func level(of samples: UnsafeBufferPointer<Int16>) -> Float {
        var sum: Double = 0
        for s in samples { let v = Double(s) / 32768.0; sum += v * v }
        let rms = (sum / Double(max(samples.count, 1))).squareRoot()
        return Float(min(1.0, max(0.0, (rms * 12).squareRoot())))
    }

    private enum CaptureError: LocalizedError {
        case inputNotReady
        case unsupportedInputFormat

        var errorDescription: String? {
            switch self {
            case .inputNotReady:
                return "The selected microphone is not ready"
            case .unsupportedInputFormat:
                return "The selected microphone format is unsupported"
            }
        }
    }
}
