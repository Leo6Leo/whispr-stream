import AudioToolbox
import CoreAudio
import Foundation

/// Captures the default input and delivers mono 16 kHz Int16 buffers.
///
/// Built on AudioQueue rather than AVAudioEngine. With AirPods as the input,
/// `AVAudioEngine.inputNode` blocks for ~3.4 s negotiating a Bluetooth format
/// before the first sample; AudioQueue delivers its first buffer in ~0.5 s
/// and converts to the sidecar's 16 kHz Int16 format itself.
final class AudioCapture {
    private static let recoveryDelay: TimeInterval = 0.25
    private static let maximumRecoveryAttempts = 20
    /// 100 ms per buffer at 16 kHz Int16 mono.
    private static let bufferBytes: UInt32 = 3_200
    private static let bufferCount = 3

    private static let format = AudioStreamBasicDescription(
        mSampleRate: 16_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 16,
        mReserved: 0
    )

    /// Owns every queue operation so the hotkey handler never waits on the
    /// audio device. Serial, so a stop always runs after its start.
    private let controlQueue = DispatchQueue(
        label: "com.whisprstream.microphone",
        qos: .userInitiated
    )
    private let bufferQueue = DispatchQueue(
        label: "com.whisprstream.microphone.buffers",
        qos: .userInitiated
    )
    private var queue: AudioQueueRef?
    private var isCapturing = false
    private var recoveryWork: DispatchWorkItem?
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    /// Called on an audio thread with converted PCM and a 0...1 level estimate.
    var onBuffer: ((Data, Float) -> Void)?

    /// Called on the main queue when the input cannot start or be recovered.
    var onFailure: ((Error) -> Void)?

    init() {
        // An AudioQueue stays bound to the device it was created on, so a new
        // default input (AirPods connecting or leaving) needs a new queue.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultInputChange()
        }
        defaultInputListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            controlQueue,
            listener
        )
    }

    deinit {
        if let defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                controlQueue,
                defaultInputListener
            )
        }
        recoveryWork?.cancel()
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
    }

    /// Returns immediately; failures arrive through `onFailure`.
    func start() {
        let requestedAt = Date()
        controlQueue.async { [self] in
            recoveryWork?.cancel()
            isCapturing = true
            do {
                try startFreshQueue()
                let waited = Date().timeIntervalSince(requestedAt)
                if waited > 0.3 {
                    Log.write("microphone took \(Int(waited * 1000))ms to start")
                }
            } catch {
                isCapturing = false
                stopCurrentQueue()
                Log.write("microphone failed to start: \(error.localizedDescription)")
                DispatchQueue.main.async { self.onFailure?(error) }
            }
        }
    }

    func stop() {
        controlQueue.async { [self] in
            isCapturing = false
            recoveryWork?.cancel()
            recoveryWork = nil
            stopCurrentQueue()
        }
    }

    private func startFreshQueue() throws {
        stopCurrentQueue()

        var format = Self.format
        var created: AudioQueueRef?
        var status = AudioQueueNewInputWithDispatchQueue(
            &created,
            &format,
            0,
            bufferQueue
        ) { [weak self] queue, buffer, _, _, _ in
            self?.handle(buffer.pointee)
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
        guard status == noErr, let created else {
            throw CaptureError.queueFailed("create", status)
        }
        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(created, Self.bufferBytes, &buffer)
            if status == noErr, let buffer {
                status = AudioQueueEnqueueBuffer(created, buffer, 0, nil)
            }
            guard status == noErr else {
                AudioQueueDispose(created, true)
                throw CaptureError.queueFailed("allocate", status)
            }
        }
        status = AudioQueueStart(created, nil)
        guard status == noErr else {
            AudioQueueDispose(created, true)
            throw CaptureError.queueFailed("start", status)
        }
        queue = created
    }

    private func stopCurrentQueue() {
        guard let queue else { return }
        self.queue = nil
        AudioQueueStop(queue, true)
        // Let callbacks already dispatched finish re-enqueueing before the
        // queue they reference is freed.
        bufferQueue.sync {}
        AudioQueueDispose(queue, true)
    }

    private func handleDefaultInputChange() {
        guard isCapturing else { return }
        Log.write("default audio input changed; rebuilding capture queue")
        stopCurrentQueue()
        scheduleRecovery(attempt: 1)
    }

    private func scheduleRecovery(attempt: Int) {
        recoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recover(attempt: attempt)
        }
        recoveryWork = work
        controlQueue.asyncAfter(
            deadline: .now() + Self.recoveryDelay,
            execute: work
        )
    }

    private func recover(attempt: Int) {
        guard isCapturing else { return }
        do {
            try startFreshQueue()
            recoveryWork = nil
            Log.write("audio input recovered after device change")
        } catch {
            guard attempt < Self.maximumRecoveryAttempts else {
                isCapturing = false
                recoveryWork = nil
                Log.write("audio input recovery failed: \(error.localizedDescription)")
                DispatchQueue.main.async { self.onFailure?(error) }
                return
            }
            scheduleRecovery(attempt: attempt + 1)
        }
    }

    private func handle(_ buffer: AudioQueueBuffer) {
        let byteCount = Int(buffer.mAudioDataByteSize)
        guard byteCount > 0 else { return }
        let data = Data(bytes: buffer.mAudioData, count: byteCount)
        let level = data.withUnsafeBytes { raw in
            Self.level(of: raw.bindMemory(to: Int16.self))
        }
        onBuffer?(data, level)
    }

    /// RMS on converted samples, mapped to a perceptually useful 0...1.
    static func level(of samples: UnsafeBufferPointer<Int16>) -> Float {
        var sum: Double = 0
        for s in samples { let v = Double(s) / 32768.0; sum += v * v }
        let rms = (sum / Double(max(samples.count, 1))).squareRoot()
        return Float(min(1.0, max(0.0, (rms * 12).squareRoot())))
    }

    private enum CaptureError: LocalizedError {
        case queueFailed(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case let .queueFailed(step, status):
                return "The microphone could not \(step) its audio queue (status \(status))"
            }
        }
    }
}
