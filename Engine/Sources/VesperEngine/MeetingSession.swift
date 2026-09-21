import FluidAudio
import Foundation
import os

/// One paragraph of text ready to append to the meeting's history entry.
public struct MeetingParagraphUpdate: Sendable, Equatable {
    /// "Speaker 1", nil when labels are off or unavailable for this meeting.
    public let speakerLabel: String?
    public let text: String
    /// True when this should start a new "H:mm  [Speaker N:] text" paragraph;
    /// false when it should be appended (with a space) to the paragraph this
    /// update stream most recently emitted - the "consecutive chunks, same
    /// speaker, same recording run merge into one paragraph" rule.
    public let isNewParagraph: Bool
}

/// Whether a running meeting can label speakers.
public enum MeetingLabelAvailability: Sendable, Equatable {
    /// "Label speakers" is off in Settings.
    case disabled
    /// Wanted, but the speaker model was not ready when this meeting started
    /// (missing or still downloading). The meeting runs the whole way
    /// through without labels; the caller should note this once, at the end.
    case unavailable
    case active
}

/// Orchestrates one meeting recording: mic audio in, chunked live
/// transcription and (optionally) speaker-labeled paragraphs out.
///
/// Ties together, per CLAUDE.md's meeting mode spec:
/// - `AudioCapture` in streaming mode (bounded memory: nothing is retained
///   once a chunk has been transcribed).
/// - FluidAudio's Silero VAD streaming API (`VadManager` + `MeetingChunker`)
///   to split the stream into ~2-30 s chunks at silences.
/// - The same `Transcriber` instance a plain dictation uses (one
///   transcription process at a time, serialized by the actor).
/// - FluidAudio's streaming Sortformer diarizer, run in parallel, and
///   `SpeakerAligner` to label each chunk's words once it is transcribed.
///
/// `@MainActor` to match `DictationSession`/the app's other coordinators;
/// the actual model calls (`Transcriber`, `VadManager`) are actors and do
/// their own off-main work.
@MainActor
public final class MeetingSession {
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "meeting")

    private let transcriber: Transcriber
    private let dictionary: UserDictionaryStore
    private let speakerModel: SpeakerModelManager
    public var rulesConfig: RulesConfig
    /// Same script hint as `DictationSession.language` - meeting chunks get
    /// the same accuracy boost as a plain dictation. `nil` = auto.
    public var language: Language?

    private let capture = AudioCapture()
    private var vad: VadManager?
    private var diarizer: SortformerDiarizer?
    private var numbering: SpeakerNumbering?

    private var chunker = MeetingChunker()
    /// Total samples ingested since this meeting started (pause excluded):
    /// the one clock `MeetingChunker` boundaries and diarizer offsets share.
    private var cursor = 0
    private var vadFeedBuffer: [Float] = []
    private var vadState = VadStreamState.initial()
    /// Not-yet-transcribed audio, trimmed after every closed chunk - this is
    /// what keeps memory bounded instead of growing for the whole meeting.
    private var pendingAudio: [Float] = []
    private var pendingAudioBase = 0
    /// The speaker label of the paragraph most recently emitted, so the next
    /// chunk knows whether to merge into it or start a new one. Double
    /// optional: outer nil = no paragraph emitted yet this recording run.
    private var lastParagraphSpeaker: String??
    private var ingestTask: Task<Void, Never>?

    public private(set) var isPaused = false
    public private(set) var wordCount = 0
    public private(set) var recordedDuration: TimeInterval = 0
    public private(set) var labelAvailability: MeetingLabelAvailability = .disabled
    /// One entry per closed chunk: (audio seconds, transcription wall ms).
    /// For `zumbo-cli meeting`'s latency report; empty in the app.
    public private(set) var chunkTimings: [(audioSeconds: Double, transcriptionMs: Double)] = []

    public nonisolated let paragraphUpdates: AsyncStream<MeetingParagraphUpdate>
    private nonisolated let paragraphContinuation: AsyncStream<MeetingParagraphUpdate>.Continuation

    /// Microphone level for the notch waveform, owned by the session so the
    /// coordinator subscribes once: the capture is stopped and restarted on
    /// every Pause/Record, and each restart is forwarded into this stream.
    public nonisolated let levels: AsyncStream<Float>
    private nonisolated let levelContinuation: AsyncStream<Float>.Continuation
    private var levelForwardTask: Task<Void, Never>?

    public init(
        transcriber: Transcriber, dictionary: UserDictionaryStore, rulesConfig: RulesConfig,
        speakerModel: SpeakerModelManager, language: Language? = nil
    ) {
        self.transcriber = transcriber
        self.dictionary = dictionary
        self.rulesConfig = rulesConfig
        self.speakerModel = speakerModel
        self.language = language
        var continuation: AsyncStream<MeetingParagraphUpdate>.Continuation!
        self.paragraphUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation = $0 }
        self.paragraphContinuation = continuation
        var levelCont: AsyncStream<Float>.Continuation!
        self.levels = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { levelCont = $0 }
        self.levelContinuation = levelCont
    }

    /// Arms the meeting: prepares the VAD and the diarizer but leaves the
    /// microphone off. Nothing is recorded until `resume()` (the Record
    /// button or the hotkey). If `labelSpeakers` is true but the speaker
    /// model is not ready yet, this meeting simply runs without labels (a
    /// download starts in the background for next time); it never blocks
    /// on the download, per spec.
    public func start(labelSpeakers: Bool) async throws {
        try await prepareSession(labelSpeakers: labelSpeakers)
        isPaused = true
    }

    private func startCapture() throws {
        guard !capture.isCapturing else { return }
        let levelStream = capture.levels
        try capture.start(streaming: true)
        ingestTask = Task { [weak self] in await self?.ingestLoop() }
        levelForwardTask = Task { [levelContinuation] in
            for await level in levelStream { levelContinuation.yield(level) }
        }
    }

    private func stopCapture() {
        ingestTask?.cancel()
        ingestTask = nil
        levelForwardTask?.cancel()
        levelForwardTask = nil
        _ = capture.stop()
    }

    /// Shared by `start()` (live microphone) and `startForTesting()`
    /// (`zumbo-cli meeting`, feeding a WAV's samples directly): resets all
    /// per-meeting state and decides whether this meeting can label speakers.
    private func prepareSession(labelSpeakers: Bool) async throws {
        chunker = MeetingChunker()
        cursor = 0
        vadFeedBuffer = []
        vadState = .initial()
        pendingAudio = []
        pendingAudioBase = 0
        lastParagraphSpeaker = nil
        wordCount = 0
        recordedDuration = 0
        isPaused = false
        diarizer = nil
        numbering = nil

        if labelSpeakers {
            if speakerModel.isReady, let built = await speakerModel.makeDiarizer() {
                diarizer = built
                numbering = SpeakerNumbering()
                labelAvailability = .active
            } else {
                // Per spec, meeting mode never starts an add-on download on
                // its own - only Settings > Models' switch does. This
                // meeting just runs without labels.
                labelAvailability = .unavailable
            }
        } else {
            labelAvailability = .disabled
        }

        try await ensureVadReady()
    }

    /// Test-only entry point (`zumbo-cli meeting`): runs the exact same
    /// chunker/diarizer/transcribe pipeline `start()` drives, but the caller
    /// feeds samples directly with `feedForTesting` instead of the
    /// microphone - so the real-audio verification exercises this file's
    /// actual alignment and chunk-closing logic, not a re-implementation.
    public func startForTesting(labelSpeakers: Bool) async throws {
        try await prepareSession(labelSpeakers: labelSpeakers)
    }

    public func feedForTesting(_ samples: [Float]) async {
        await ingest(batch: samples)
    }

    public func finishForTesting() async -> (wordCount: Int, duration: TimeInterval) {
        if !pendingAudio.isEmpty {
            await transcribeAndEmit(samples: pendingAudio, chunkStartSample: pendingAudioBase)
            pendingAudio = []
        }
        if let diarizer {
            _ = try? diarizer.finalizeSession()
        }
        return (wordCount, recordedDuration)
    }

    /// Hotkey or the Pause button: audio keeps arriving from the mic (so
    /// resuming is instant) but is dropped, not fed to the pipeline or the
    /// diarizer, and not counted toward the timer.
    public func pause() async {
        guard !isPaused else { return }
        isPaused = true
        stopCapture()
        if !pendingAudio.isEmpty {
            let samples = pendingAudio
            let base = pendingAudioBase
            pendingAudio = []
            pendingAudioBase = cursor
            await transcribeAndEmit(samples: samples, chunkStartSample: base)
        }
        vadFeedBuffer = []
        vadState = .initial()
        chunker.restart(atSample: cursor)
    }

    /// Hotkey or the Resume button. The diarizer session (and its speaker
    /// numbering) stays alive across the gap; only the text starts a fresh
    /// paragraph, so the gap is visible in the note.
    public func resume() throws {
        guard isPaused else { return }
        lastParagraphSpeaker = nil
        vadFeedBuffer = []
        try startCapture()
        isPaused = false
    }

    /// Ends the meeting: stops capture, transcribes whatever audio is still
    /// pending as a final chunk, finalizes the diarizer (reconciling any
    /// still-tentative labels), and returns the totals for the "Meeting
    /// saved, N words, m:ss" notice.
    public func stop() async -> (wordCount: Int, duration: TimeInterval) {
        stopCapture()
        levelContinuation.finish()

        if !pendingAudio.isEmpty {
            await transcribeAndEmit(samples: pendingAudio, chunkStartSample: pendingAudioBase)
            pendingAudio = []
        }
        if let diarizer {
            _ = try? diarizer.finalizeSession()
        }
        return (wordCount, recordedDuration)
    }

    // MARK: - Ingest

    private func ensureVadReady() async throws {
        guard vad == nil else { return }
        // Silero is bundled as well; `VadManager` resolves its own cache
        // directory, so the copy has to be in place before it looks.
        BundledModels.installIfNeeded()
        vad = try await VadManager(config: .default)
    }

    private func ingestLoop() async {
        for await batch in capture.sampleBatches {
            if Task.isCancelled { break }
            guard !isPaused else { continue }
            await ingest(batch: batch)
        }
    }

    private func ingest(batch: [Float]) async {
        pendingAudio.append(contentsOf: batch)
        recordedDuration += Double(batch.count) / 16_000.0
        cursor += batch.count

        if let diarizer {
            try? diarizer.addAudio(batch, sourceSampleRate: nil)
            _ = try? diarizer.process()
        }

        vadFeedBuffer.append(contentsOf: batch)
        while vadFeedBuffer.count >= VadManager.chunkSize {
            let frame = Array(vadFeedBuffer.prefix(VadManager.chunkSize))
            vadFeedBuffer.removeFirst(VadManager.chunkSize)
            await processVadFrame(frame)
        }

        if let boundary = chunker.advance(toSample: cursor) {
            await closeChunk(boundary)
        }
    }

    private func processVadFrame(_ frame: [Float]) async {
        guard let vad else { return }
        let config = VadSegmentationConfig(minSilenceDuration: 0.7)
        guard let result = try? await vad.processStreamingChunk(frame, state: vadState, config: config) else {
            return
        }
        vadState = result.state
        guard let event = result.event else { return }
        let chunkerEvent: MeetingChunkerEvent =
            event.isStart ? .speechStart(sampleIndex: event.sampleIndex) : .speechEnd(sampleIndex: event.sampleIndex)
        if let boundary = chunker.handle(chunkerEvent) {
            await closeChunk(boundary)
        }
    }

    private func closeChunk(_ boundary: MeetingChunkBoundary) async {
        let startRel = boundary.startSample - pendingAudioBase
        let endRel = min(boundary.endSample - pendingAudioBase, pendingAudio.count)
        guard startRel >= 0, endRel > startRel else { return }
        let chunkSamples = Array(pendingAudio[startRel..<endRel])
        pendingAudio.removeFirst(endRel)
        pendingAudioBase = boundary.endSample
        await transcribeAndEmit(samples: chunkSamples, chunkStartSample: boundary.startSample)
    }

    /// Parakeet needs at least ~300 ms of audio; a sliver shorter than that
    /// (e.g. the final flush right after a pause) is dropped rather than
    /// sent to the model.
    private static let minTranscribableSamples = Int(0.3 * 16_000)

    private func transcribeAndEmit(samples: [Float], chunkStartSample: Int) async {
        guard samples.count >= Self.minTranscribableSamples else { return }
        let chunkStart = Date()
        do {
            let alwaysInclude = Set(dictionary.terms.map(\.text))
            let pass = try await transcriber.transcribe(
                samples: samples, alwaysIncludeTerms: alwaysInclude, language: language)
            chunkTimings.append(
                (audioSeconds: Double(samples.count) / 16_000.0, transcriptionMs: Date().timeIntervalSince(chunkStart) * 1000))
            let words = pass.wordTimings ?? []
            let chunkOffset = Double(chunkStartSample) / 16_000.0

            var finalizedSegments: [DiarizerSegment] = []
            var tentativeSegments: [DiarizerSegment] = []
            if let diarizer {
                for (_, speaker) in diarizer.timeline.speakers {
                    finalizedSegments.append(contentsOf: speaker.finalizedSegments)
                    tentativeSegments.append(contentsOf: speaker.tentativeSegments)
                }
            }

            let rawParagraphs: [SpeakerAligner.AlignedParagraph]
            if words.isEmpty {
                let text = pass.text.trimmingCharacters(in: .whitespacesAndNewlines)
                rawParagraphs =
                    text.isEmpty ? [] : [SpeakerAligner.AlignedParagraph(speakerLabel: nil, text: text, startTime: chunkOffset)]
            } else {
                rawParagraphs = SpeakerAligner.align(
                    words: words, chunkOffset: chunkOffset, finalizedSegments: finalizedSegments,
                    tentativeSegments: tentativeSegments, numbering: numbering)
            }

            let rules = RulesEngine(vocabulary: dictionary.mergedVocabulary(), config: rulesConfig)
            for raw in rawParagraphs {
                let text = rules.apply(raw.text)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let isNew = lastParagraphSpeaker == nil || lastParagraphSpeaker! != raw.speakerLabel
                lastParagraphSpeaker = raw.speakerLabel
                wordCount += text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                paragraphContinuation.yield(
                    MeetingParagraphUpdate(speakerLabel: raw.speakerLabel, text: text, isNewParagraph: isNew))
            }
        } catch {
            log.error("meeting chunk transcription failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
