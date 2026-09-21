import Foundation

/// Splits a continuous meeting recording into transcribable chunks from a
/// stream of VAD speech-start/speech-end events, plus a hard time cap.
///
/// Pure and model-free: it knows nothing about audio samples, only sample
/// *indices* (absolute position in the stream the caller is feeding). The
/// caller (`MeetingSession`) drives it with FluidAudio's Silero VAD streaming
/// events (`VadStreamEvent`, `minSilenceDuration` configured to the ~0.7 s
/// close threshold, so a `speechEnd` event already means "silence has held
/// for about 0.7 s").
///
/// Rules (see CLAUDE.md meeting mode spec):
/// - A chunk closes on a `speechEnd` event once it holds at least
///   `minChunkSpeechDuration` (~2 s) of speech.
/// - A chunk closes at `maxChunkDuration` (30 s) regardless of speech/silence,
///   via `advance(toSample:)`, called periodically as audio keeps arriving
///   even with no VAD events (e.g. one long uninterrupted sentence).
public struct MeetingChunkerConfig: Sendable, Equatable {
    public var minChunkSpeechDuration: TimeInterval
    public var maxChunkDuration: TimeInterval
    public var sampleRate: Double

    public init(
        minChunkSpeechDuration: TimeInterval = 2.0,
        maxChunkDuration: TimeInterval = 30.0,
        sampleRate: Double = 16_000
    ) {
        self.minChunkSpeechDuration = minChunkSpeechDuration
        self.maxChunkDuration = maxChunkDuration
        self.sampleRate = sampleRate
    }
}

public enum MeetingChunkerEvent: Sendable, Equatable {
    case speechStart(sampleIndex: Int)
    case speechEnd(sampleIndex: Int)
}

/// One closed chunk, as a half-open sample range `[startSample, endSample)`
/// into the caller's continuous audio stream.
public struct MeetingChunkBoundary: Sendable, Equatable {
    public let startSample: Int
    public let endSample: Int
    /// True when the chunk closed because of a silence gap; false when it hit
    /// the 30 s cap mid-speech (or mid-silence).
    public let closedBySilence: Bool

    public var sampleCount: Int { endSample - startSample }

    public init(startSample: Int, endSample: Int, closedBySilence: Bool) {
        self.startSample = startSample
        self.endSample = endSample
        self.closedBySilence = closedBySilence
    }
}

public struct MeetingChunker: Sendable {
    public let config: MeetingChunkerConfig

    private var chunkStartSample: Int
    private var speechSamplesInChunk: Int = 0
    private var inSpeech = false
    private var speechStartSample: Int?

    public init(config: MeetingChunkerConfig = MeetingChunkerConfig(), startingAtSample start: Int = 0) {
        self.config = config
        self.chunkStartSample = start
    }

    /// Feed one VAD event. Returns a boundary if this event closes a chunk.
    public mutating func handle(_ event: MeetingChunkerEvent) -> MeetingChunkBoundary? {
        switch event {
        case .speechStart(let sampleIndex):
            inSpeech = true
            speechStartSample = sampleIndex
            return checkForceClose(at: sampleIndex)

        case .speechEnd(let sampleIndex):
            if inSpeech, let start = speechStartSample {
                speechSamplesInChunk += max(0, sampleIndex - start)
            }
            inSpeech = false
            speechStartSample = nil
            let minSpeechSamples = Int(config.minChunkSpeechDuration * config.sampleRate)
            if speechSamplesInChunk >= minSpeechSamples {
                return closeChunk(at: sampleIndex, closedBySilence: true)
            }
            return checkForceClose(at: sampleIndex)
        }
    }

    /// Called as audio keeps arriving with no VAD event, so a chunk that is
    /// all speech (or all silence, e.g. dead air) still force-closes at the
    /// 30 s cap. `sample` is the absolute count of samples processed so far.
    public mutating func advance(toSample sample: Int) -> MeetingChunkBoundary? {
        checkForceClose(at: sample)
    }

    /// Resets to a fresh chunk starting at `sample`, without touching
    /// accumulated speech duration semantics - used when the caller (a pause
    /// in the recording) wants the next audio to start a brand-new chunk
    /// rather than possibly force-closing across a gap that was never fed.
    public mutating func restart(atSample sample: Int) {
        chunkStartSample = sample
        speechSamplesInChunk = 0
        inSpeech = false
        speechStartSample = nil
    }

    private mutating func checkForceClose(at sample: Int) -> MeetingChunkBoundary? {
        let maxSamples = Int(config.maxChunkDuration * config.sampleRate)
        guard sample - chunkStartSample >= maxSamples else { return nil }
        if inSpeech, let start = speechStartSample {
            speechSamplesInChunk += max(0, sample - start)
            speechStartSample = sample
        }
        return closeChunk(at: sample, closedBySilence: false)
    }

    private mutating func closeChunk(at sample: Int, closedBySilence: Bool) -> MeetingChunkBoundary {
        let boundary = MeetingChunkBoundary(
            startSample: chunkStartSample, endSample: sample, closedBySilence: closedBySilence)
        chunkStartSample = sample
        speechSamplesInChunk = 0
        return boundary
    }
}
