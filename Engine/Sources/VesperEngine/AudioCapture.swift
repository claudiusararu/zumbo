import AVFoundation
import Foundation
import os

/// Errors `AudioCapture` can throw. Lifted concept from OpenSuperWhisper's
/// `AudioRecorder`/`PCMRecordingSession`, trimmed to what a single-shot
/// dictation capture needs (no device picker, no playback).
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
/// `start()` and `stop()` are called on the main thread (both sessions are
/// `@MainActor`); restarts after a device change run there too.
public final class AudioCapture {
    /// Replaced at every `start()` and after every device change while
    /// recording. An engine keeps the input format of the microphone it first
    /// saw, so after the default input changes (AirPods connecting, a USB mic
    /// unplugged) an old engine reports the previous device's format and
    /// `installTap` raises on the mismatch. A fresh engine reads the current
    /// device.
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.zumbo.audiocapture")
    /// Watches the engine in use for a device change while recording.
    private var configurationObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "audio-capture")
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
        samples.removeAll()
        smoothedLevel = 0
        lastEmit = .distantPast
        try startEngine()
        isCapturing = true
    }

    /// Builds a fresh engine on the current default microphone, taps it and
    /// starts it. Runs at `start()` and again mid-recording when the
    /// microphone changes; `samples` and the level smoothing carry over, so a
    /// switch mid-sentence still ends as one recording.
    private func startEngine() throws {
        stopObservingConfiguration()
        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputAvailable
        }
        // A device switch landing between the line above and the tap makes
        // `installTap` raise; refuse up front instead, the caller shows
        // "Could not start the microphone".
        guard input.inputFormat(forBus: 0).sampleRate == inputFormat.sampleRate else {
            throw AudioCaptureError.noInputAvailable
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
        else {
            throw AudioCaptureError.converterCreationFailed
        }
        // One converter per engine, owned by its tap: a restart never swaps
        // the converter under a buffer that is still being converted.
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }

        try catchingObjCException {
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.process(buffer: buffer, converter: converter, inputFormat: inputFormat, outputFormat: outputFormat)
            }
        }
        do {
            try Self.start(engine)
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        observeConfiguration(of: engine)
    }

    /// `prepare()` and `start()` report most failures as a thrown error, but
    /// some device states make them raise instead.
    private static func start(_ engine: AVAudioEngine) throws {
        var startError: Error?
        try catchingObjCException {
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if let startError { throw startError }
    }

    /// A device change (AirPods connecting mid-dictation, a USB mic pulled)
    /// stops the engine and posts this. Recording then resumes on the new
    /// microphone instead of going silent for the rest of the take.
    private func observeConfiguration(of observed: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: observed, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func stopObservingConfiguration() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
    }

    private func handleConfigurationChange() {
        // Only while recording, and only when the engine really stopped, which
        // is what a device change does to it; a notice that left it running
        // needs nothing.
        guard isCapturing, !engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        do {
            try startEngine()
            log.info("microphone changed while recording, capture resumed")
        } catch {
            // No usable microphone right now. What was captured is kept and
            // `stop()` still returns it.
            log.error("microphone changed while recording, restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops capture and returns the full 16 kHz mono Float32 recording.
    @discardableResult
    public func stop() -> [Float] {
        guard isCapturing else { return [] }
        stopObservingConfiguration()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        levelContinuation?.finish()
        levelContinuation = nil
        batchContinuation?.finish()
        batchContinuation = nil
        return queue.sync { samples }
    }

    private func process(
        buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
        inputFormat: AVAudioFormat, outputFormat: AVAudioFormat
    ) {
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
        // Copied here, on the tap thread: `outBuffer` is freed when this
        // function returns, so the queue below must never read through
        // `channelData`.
        let chunk = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        queue.async { [weak self] in
            guard let self else { return }
            if self.streamingMode {
                self.batchContinuation?.yield(chunk)
            } else {
                self.samples.append(contentsOf: chunk)
            }
            var sumSquares: Float = 0
            for sample in chunk { sumSquares += sample * sample }
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
