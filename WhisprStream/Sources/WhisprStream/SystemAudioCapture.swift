import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Captures everything the Mac is playing (内录) and delivers mono 16 kHz Int16
/// buffers, the same contract as `AudioCapture`.
///
/// ScreenCaptureKit is the only public route to system output on macOS 14
/// without a virtual audio driver. Only the audio output type is registered;
/// the 2×2 video surface the API requires is never read. WhisprStream's own
/// start/finish sounds are excluded so they never end up in the transcript.
final class SystemAudioCapture: NSObject {
    enum CaptureError: LocalizedError {
        case permissionUnavailable(String)
        case noDisplay
        case streamFailed(String)

        var errorDescription: String? {
            switch self {
            case let .permissionUnavailable(message):
                return "Screen & System Audio Recording is not allowed: \(message)"
            case .noDisplay:
                return "No display is available for system audio capture"
            case let .streamFailed(message):
                return "System audio stream failed: \(message)"
            }
        }
    }

    private let callbackQueue = DispatchQueue(
        label: "com.whisprstream.system-audio",
        qos: .userInitiated
    )
    private let converter = PCM16Converter()
    private let lock = NSLock()
    private var stream: SCStream?
    private var output: Output?
    /// Bumped by every start/stop so a slow async start can tell it was
    /// cancelled by a key release that arrived first.
    private var generation = 0
    private var acceptingSamples = false

    /// Called on an audio thread with converted PCM and a 0...1 level estimate.
    var onBuffer: ((Data, Float) -> Void)?

    /// Called on the main queue when the stream cannot start or stops early.
    var onFailure: ((Error) -> Void)?

    /// Returns immediately; the stream comes up asynchronously (~100–200 ms).
    func start() {
        stopStream()
        generation &+= 1
        let token = generation
        callbackQueue.async { [converter] in converter.reset() }
        Task { @MainActor [weak self] in
            do {
                try await self?.startStream(token: token)
            } catch {
                guard let self, self.generation == token else { return }
                Log.write("system audio capture failed: \(error.localizedDescription)")
                self.onFailure?(error)
            }
        }
    }

    func stop() {
        generation &+= 1
        stopStream()
    }

    @MainActor
    private func startStream(token: Int) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.permissionUnavailable(error.localizedDescription)
        }
        guard generation == token else { return }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let ownApp = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApp,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 2
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let output = Output(owner: self)
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: callbackQueue)
            try await newStream.startCapture()
        } catch {
            throw CaptureError.streamFailed(error.localizedDescription)
        }

        // The key may have been released while the stream was starting.
        guard generation == token else {
            try? await newStream.stopCapture()
            return
        }
        stream = newStream
        self.output = output
        setAccepting(true)
        Log.write("system audio capture started")
    }

    private func stopStream() {
        setAccepting(false)
        guard let stream else { return }
        self.stream = nil
        output = nil
        stream.stopCapture { _ in }
    }

    private func setAccepting(_ value: Bool) {
        lock.lock(); acceptingSamples = value; lock.unlock()
    }

    private var isAccepting: Bool {
        lock.lock(); defer { lock.unlock() }
        return acceptingSamples
    }

    fileprivate func receive(_ sampleBuffer: CMSampleBuffer) {
        guard isAccepting, let pcm = converter.convert(sampleBuffer: sampleBuffer) else { return }
        let level = pcm.withUnsafeBytes { raw in
            AudioCapture.level(of: raw.bindMemory(to: Int16.self))
        }
        onBuffer?(pcm, level)
    }

    fileprivate func streamDidStop(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isAccepting else { return }
            self.setAccepting(false)
            self.stream = nil
            self.output = nil
            self.onFailure?(CaptureError.streamFailed(error.localizedDescription))
        }
    }

    private final class Output: NSObject, SCStreamOutput, SCStreamDelegate {
        weak var owner: SystemAudioCapture?

        init(owner: SystemAudioCapture) { self.owner = owner }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            guard type == .audio else { return }
            owner?.receive(sampleBuffer)
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            owner?.streamDidStop(error)
        }
    }
}

/// Converts ScreenCaptureKit sample buffers to mono 16 kHz Int16 without
/// assuming interleaving, channel count, or sample rate. One converter lives
/// for the whole stream: recreating it per packet discards the resampler's
/// filter history and drops samples at every boundary.
final class PCM16Converter {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private var converter: AVAudioConverter?

    func reset() { converter = nil }

    func convert(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: asbd)
        else { return nil }

        var listSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard status == noErr, listSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        // Must outlive the no-copy PCM buffer below.
        var retainedBlockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr, retainedBlockBuffer != nil,
              let input = AVAudioPCMBuffer(
                  pcmFormat: inputFormat,
                  bufferListNoCopy: bufferList,
                  deallocator: nil
              )
        else { return nil }
        return withExtendedLifetime(retainedBlockBuffer) { convert(input) }
    }

    func convert(_ input: AVAudioPCMBuffer) -> Data? {
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: Self.targetFormat)
            converter?.primeMethod = .none
        }
        let ratio = Self.targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity)
        else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0,
              let channel = output.int16ChannelData
        else { return nil }
        return Data(buffer: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
