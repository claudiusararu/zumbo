import AVFoundation
import Foundation

/// Errors `AudioCapture` can throw. Lifted concept from OpenSuperWhisper's
/// `AudioRecorder`/`PCMRecordingSession`, trimmed to what a single-shot
/// dictation capture needs (no device switching, no playback).
public enum AudioCaptureError: Error, Equatable {
    case noInputAvailable
    case converterCreationFailed
    case alreadyCapturing
}

/// Microphone permission check/request, lifted from OpenSuperWhisper's
/// `PermissionsManager` (microphone half only - `TextInserter` and
/// `HotkeyMonitor` own the accessibility / input-monitoring checks).
public enum MicrophonePermission {
    public static func isAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func request(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default:
            completion(false)
        }
    }
}

/// Captures microphone input via an `AVAudioEngine` tap, converts it to
/// 16 kHz mono Float32 (what FluidAudio/Transcriber expects), and exposes a
/// live level stream for the notch waveform. One capture session at a time.
public final class AudioCapture {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.zumbo.audiocapture")
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var smoothedLevel: Float = 0
    private var lastEmit = Date.distantPast
    private let emitInterval: TimeInterval = 1.0 / 30.0
    /// Meeting mode's live pipeline consumes audio through this instead of
    /// the accumulating `samples` array, so a long recording never grows an
    /// unbounded in-memory buffer. Set (non-nil) only while `streaming` was
    /// passed to `start()`.
    private var batchContinuation: AsyncStream<[Float]>.Continuation?
    private var streamingMode = false

    public private(set) var isCapturing = false

    public init() {}

    /// Smoothed RMS input level, 0...1, emitted at ~30 Hz while capturing.
    /// A fresh stream is created each time this is read; read it once per
    /// recording session (e.g. right before `start()`).
    public var levels: AsyncStream<Float> {
        AsyncStream { continuation in
            self.levelContinuation = continuation
        }
    }

    /// Raw 16 kHz mono batches as they are captured, in order, with nothing
    /// held back. Only yields anything when `start(streaming: true)` was
    /// used; read it once per recording session, before `start()`.
    public var sampleBatches: AsyncStream<[Float]> {
        AsyncStream { continuation in
            self.batchContinuation = continuation
        }
    }

    /// - Parameter streaming: When true (meeting mode), captured samples are
    ///   delivered only through `sampleBatches` and are never appended to the
    ///   internal buffer `stop()` returns - the caller (`MeetingSession`) owns
    ///   its own bounded, per-chunk buffer instead. When false (plain
    ///   dictation, notes), behavior is unchanged: `stop()` returns the whole
    ///   recording.
    public func start(streaming: Bool) throws {
        try startCapturing(streaming: streaming)
    }

    public func start() throws {
        try startCapturing(streaming: false)
    }

    private func startCapturing(streaming: Bool) throws {
        guard !isCapturing else { throw AudioCaptureError.alreadyCapturing }
        streamingMode = streaming
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputAvailable
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
        else {
            throw AudioCaptureError.converterCreationFailed
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        self.converter = converter
        samples.removeAll()
        smoothedLevel = 0
        lastEmit = .distantPast

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, inputFormat: inputFormat, outputFormat: outputFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isCapturing = true
    }

    /// Stops capture and returns the full 16 kHz mono Float32 recording.
    @discardableResult
    public func stop() -> [Float] {
        guard isCapturing else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        levelContinuation?.finish()
        levelContinuation = nil
        batchContinuation?.finish()
        batchContinuation = nil
        return queue.sync { samples }
    }

    private func process(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, statusPointer in
            if consumed {
                statusPointer.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPointer.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil,
              let channelData = outBuffer.floatChannelData?[0]
        else { return }
        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0 else { return }

        queue.async { [weak self] in
            guard let self else { return }
            var sumSquares: Float = 0
            var batch: [Float] = self.streamingMode ? [Float](repeating: 0, count: frameCount) : []
            if !self.streamingMode { self.samples.reserveCapacity(self.samples.count + frameCount) }
            for i in 0..<frameCount {
                let sample = channelData[i]
                if self.streamingMode {
                    batch[i] = sample
                } else {
                    self.samples.append(sample)
                }
                sumSquares += sample * sample
            }
            if self.streamingMode {
                self.batchContinuation?.yield(batch)
            }
            let rms = sqrtf(sumSquares / Float(frameCount))
            let normalized = min(rms * 4, 1.0)
            self.smoothedLevel = self.smoothedLevel * 0.7 + normalized * 0.3
            let now = Date()
            guard now.timeIntervalSince(self.lastEmit) >= self.emitInterval else { return }
            self.lastEmit = now
            self.levelContinuation?.yield(self.smoothedLevel)
        }
    }
}
