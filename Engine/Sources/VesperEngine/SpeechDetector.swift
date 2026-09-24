import FluidAudio
import Foundation
import os

/// Answers one question before a dictation is transcribed: did anyone
/// speak? Parakeet invents a short phrase for a take with no speech in it
/// ("Thank you." for silence, "Yeah." for the start tone alone), and that
/// phrase would be pasted. Silero VAD, the model meeting mode already uses,
/// tells the two apart cleanly. Measured on 30 real dictations plus single
/// words and speech at 3 percent volume, every take peaks at probability
/// 1.0; silence, room noise and the start tone stay at or under 0.3. The
/// pass costs 1 to 10 ms.
public actor SpeechDetector {
    /// Silero's usual cut-off, clear of both sides of the measurement above.
    static let threshold: Float = 0.5

    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "speech-detector")
    private var loading: Task<VadManager?, Never>?

    public init() {}

    /// Loads the model ahead of the first recording. Safe to call again.
    public func prepare() async {
        _ = await manager()
    }

    /// False only when the model ran and found no speech anywhere. Any
    /// failure answers true: a real dictation must never be dropped because
    /// the detector broke.
    public func containsSpeech(_ samples: [Float]) async -> Bool {
        guard !samples.isEmpty else { return false }
        guard let vad = await manager() else { return true }
        do {
            let results = try await vad.process(samples)
            return results.contains { $0.probability >= Self.threshold }
        } catch {
            log.error("speech check failed, keeping the take: \(error.localizedDescription, privacy: .public)")
            return true
        }
    }

    /// One load shared by every caller; a failed load is retried next time.
    private func manager() async -> VadManager? {
        if let loading { return await loading.value }
        let log = log
        let task = Task { () -> VadManager? in
            do {
                return try await VadManager(config: .default)
            } catch {
                log.error("speech detector unavailable: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        loading = task
        let vad = await task.value
        if vad == nil { loading = nil }
        return vad
    }
}
