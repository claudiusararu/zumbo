import AVFoundation
import FluidAudio
import Foundation
import os

/// A single transcription's raw text plus how long the model call took.
public struct TranscriptionResult: Sendable {
    /// The boosted text when a vocabulary is loaded, otherwise the plain one.
    public let text: String
    /// The plain ASR text, before the rescoring pass. Same as `text` when
    /// boosting is off, so one model call yields both readings and the
    /// dev-context gate can still choose between them.
    public let plainText: String
    /// Total wall time of the call: the ASR pass plus, when boosting is on,
    /// the CTC spotter and the rescoring pass.
    public let ms: Double
    /// The Parakeet TDT pass alone.
    public let asrMs: Double
    /// CTC keyword spotting over the same samples (grows with vocabulary size).
    public let spotterMs: Double
    /// The post-hoc rescoring pass over the transcript (includes rebuilding
    /// the CTC rescorer for that call's filtered candidate list - see
    /// `CandidateFilter` - which is cheap: the CTC models and per-term
    /// tokenization stay warm from `enableBoosting`, only a small tokenizer
    /// JSON is re-read).
    public let rescoreMs: Double
    /// The pure-Swift `CandidateFilter` pass that narrows the full vocabulary
    /// down to plausible candidates before the spotter/rescorer run. Zero
    /// when boosting is off.
    public let filterMs: Double
    /// Word-level timings for this call's audio, relative to the start of
    /// the samples passed in (0 = their first sample). Meeting mode uses
    /// these to align words to diarizer speaker segments; nil when the model
    /// did not return timings.
    public let wordTimings: [WordTiming]?

    public init(
        text: String, plainText: String? = nil, ms: Double,
        asrMs: Double = 0, spotterMs: Double = 0, rescoreMs: Double = 0, filterMs: Double = 0,
        wordTimings: [WordTiming]? = nil
    ) {
        self.text = text
        self.plainText = plainText ?? text
        self.ms = ms
        self.asrMs = asrMs
        self.spotterMs = spotterMs
        self.rescoreMs = rescoreMs
        self.filterMs = filterMs
        self.wordTimings = wordTimings
    }
}

/// Loads Parakeet TDT v3 via FluidAudio 0.15.7 (`AsrModels.downloadAndLoad`,
/// `AsrManager`, exactly as in `seeds/spike-fluidaudio-recipe.swift`), keeps
/// the model warm across calls, and applies the FluidAudio CTC
/// vocabulary-boosting pass as a post-hoc rescoring step over the plain
/// transcript when a vocabulary is loaded.
///
/// `minSimilarity` defaults to 0.8: 0.75 won at 40 terms, 0.8 wins on the
/// 641-term developer pack set (2026-09-17 rescore, 93% recall, 90% precision);
/// `dictation-spike/recordings/TUNING_RESULTS.md` (94.3% recall / 97.1%
/// precision on human speech, everything else at the library default).
public actor Transcriber {
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "transcriber")
    /// Milliseconds the last `enableBoosting` call spent building the CTC
    /// models, the spotter and the vocabulary context. Zero once warm.
    public private(set) var lastBoostingSetupMs: Double = 0
    private var manager: AsrManager?
    private var decoderLayers = 0
    private var spotter: CtcKeywordSpotter?
    private var vocabulary: CustomVocabularyContext?
    private var minSimilarity: Float
    /// The context-biasing weight, sized once from the *full* vocabulary's
    /// term count (`ContextBiasingConstants.rescorerConfig(forVocabSize:)`),
    /// not the filtered candidate list. That sizing heuristic assumes a small
    /// vocab is a deliberately curated one and boosts it more aggressively;
    /// `CandidateFilter`'s output is a filtered *subset* of a large dictionary,
    /// not a curated small one, so reusing the small-vocab cbw per call was
    /// measured to hurt precision (more false insertions) - see Engine/README.md.
    private var cbw: Float = 0
    /// Rebuilt per call from the filtered candidate list - see
    /// `enableBoosting`'s doc comment on why this is cheap.
    private var ctcModelDirectory: URL?
    private var rescorerConfig: VocabularyRescorer.Config?
    /// Precomputed lowercase aliases/skeletons for every term in `vocabulary`,
    /// so `CandidateFilter.select` never re-derives them per dictation.
    private var candidateIndex: CandidateFilter.Index?

    private let progressContinuation: AsyncStream<Double>.Continuation
    /// Model download progress in [0, 1], for the onboarding screen. FluidAudio
    /// 0.15.7's `AsrModels.downloadAndLoad(progressHandler:)` reports a real
    /// fractional progress (listing/downloading/compiling phases all map to a
    /// single 0...1 value), so this is not an indeterminate placeholder.
    public nonisolated let modelLoadProgress: AsyncStream<Double>

    public init(minSimilarity: Float = 0.8) {
        self.minSimilarity = minSimilarity
        var continuation: AsyncStream<Double>.Continuation!
        self.modelLoadProgress = AsyncStream { continuation = $0 }
        self.progressContinuation = continuation
    }

    /// Downloads (if needed) and loads the model, keeping it warm for
    /// subsequent `transcribe` calls. Safe to call more than once; a no-op
    /// once loaded.
    public func warmUp() async throws {
        guard manager == nil else { return }
        // The DMG ships Parakeet inside the app bundle so dictation works
        // offline from the first launch. This moves it into the cache
        // directory FluidAudio resolves on its own, before the call below
        // decides anything is missing. A no-op on every later launch.
        BundledModels.installIfNeeded()
        let progressContinuation = progressContinuation
        let models = try await AsrModels.downloadAndLoad(
            version: .v3,
            progressHandler: { progress in
                progressContinuation.yield(progress.fractionCompleted)
            })
        let config = ASRConfig(
            tdtConfig: TdtConfig(blankId: AsrModelVersion.v3.blankId),
            encoderHiddenSize: AsrModelVersion.v3.encoderHiddenSize)
        let loaded = AsrManager(config: config)
        try await loaded.loadModels(models)
        manager = loaded
        decoderLayers = await loaded.decoderLayerCount
        progressContinuation.yield(1.0)
        progressContinuation.finish()
    }

    /// Enables vocabulary boosting from a JSON file shaped
    /// `{"terms":[{"text":...,"aliases":[...]}]}` (see `VocabFile`).
    ///
    /// This is the one-time expensive step (measured 15.3 s for the full
    /// 1721-term starter pack): it loads/compiles the CTC CoreML models and
    /// tokenizes every term. It is *not* repeated per dictation. Instead,
    /// `transcribe(samples:)` runs `CandidateFilter` first and, per call,
    /// filters the already-tokenized `vocabulary.terms` down to the
    /// candidates (a cheap in-memory `Array.filter`, no re-tokenization, no
    /// CTC model reload) and rebuilds only the lightweight `VocabularyRescorer`
    /// wrapper around that filtered list (which just re-reads a small
    /// tokenizer JSON - single-digit ms, not the 15 s setup). Measured: see
    /// Engine/README.md.
    public func enableBoosting(vocabularyPath: String, minSimilarity: Float? = nil) async throws {
        let setupStart = Date()
        // Same reason as `warmUp`: the CTC booster is bundled too, and
        // `loadWithCtcTokens` resolves its own cache directory with no
        // override to pass a bundle path through.
        BundledModels.installIfNeeded()
        let (vocab, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: vocabularyPath)
        let blankId = ctcModels.vocabulary.count
        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
        // The spotter-anchored acoustic rescue pass (FluidAudio's own
        // VocabularyRescorer+TokenRescoring.swift) only runs when the
        // *filtered* vocabulary it's handed has <= 10 terms
        // (ContextBiasingConstants.largeVocabThreshold), on the assumption
        // that a vocabulary that small is a deliberately curated list of
        // distinctive names. CandidateFilter's output is exactly that small
        // sometimes (a short sentence yields few plausible candidates), but
        // it is a filtered subset of a 1721-term dictionary, not a curated
        // list - FluidAudio's own docs call this rescue "the dominant source
        // of short-keyword over-firing" for that reason. Measured: leaving
        // it on dropped bench precision from 97.1% to 80.8% (15 false
        // insertions vs 2) with no recall benefit. Off, always.
        let rescorerConfig = VocabularyRescorer.Config(spotterRescueEnabled: false)
        self.spotter = spotter
        self.vocabulary = vocab
        self.ctcModelDirectory = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        self.rescorerConfig = rescorerConfig
        self.cbw = ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count).cbw
        self.candidateIndex = CandidateFilter.Index(
            terms: vocab.terms.map { ($0.text, $0.aliases ?? []) })
        if let minSimilarity { self.minSimilarity = minSimilarity }
        lastBoostingSetupMs = Date().timeIntervalSince(setupStart) * 1000
        let terms = vocab.terms.count
        let withOverride = vocab.terms.filter { $0.minSimilarity != nil }.count
        log.info(
            """
            boosting ready: \(terms, privacy: .public) terms             (\(withOverride, privacy: .public) with a per-term minSimilarity),             setup \(Int(self.lastBoostingSetupMs), privacy: .public) ms
            """)
    }

    public func disableBoosting() {
        spotter = nil
        vocabulary = nil
        candidateIndex = nil
        ctcModelDirectory = nil
        rescorerConfig = nil
        cbw = 0
    }

    /// `alwaysIncludeTerms` are canonical `text` values (case-sensitive, as
    /// they appear in the vocabulary JSON) that `CandidateFilter` must keep
    /// regardless of similarity score - the caller's own dictionary entries,
    /// which the user explicitly taught and expects to always fire.
    ///
    /// `language` is a script hint for the v3 joint decoder only (FluidAudio
    /// `TokenLanguageFilter`): it steers top-K token selection toward the
    /// language's alphabet during the ASR pass. It is never threaded into
    /// the boosting/rescoring pass below - FluidAudio's own comments warn
    /// that would either be a no-op or silently corrupt results, since
    /// `TokenLanguageFilter` only covers Latin/Cyrillic/Greek script
    /// filtering, not the CTC rescorer's candidate matching. `nil` = auto
    /// (multilingual, per-sentence detection, Parakeet's default).
    public func transcribe(
        samples: [Float], alwaysIncludeTerms: Set<String> = [], language: Language? = nil
    ) async throws -> TranscriptionResult {
        if manager == nil { try await warmUp() }
        guard let manager else { throw TranscriberError.modelNotLoaded }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let start = Date()
        var result = try await manager.transcribe(samples, decoderState: &state, language: language)
        let plainText = result.text
        let asrMs = Date().timeIntervalSince(start) * 1000
        var filterMs = 0.0
        var spotterMs = 0.0
        var rescoreMs = 0.0
        if let spotter, let vocabulary, let candidateIndex, let ctcModelDirectory, let rescorerConfig {
            let filterStart = Date()
            let keep = CandidateFilter.select(
                transcript: plainText, index: candidateIndex, alwaysInclude: alwaysIncludeTerms)
            let filteredTerms = vocabulary.terms.filter { keep.contains($0.text) }
            let filteredVocabulary = CustomVocabularyContext(
                terms: filteredTerms, alpha: vocabulary.alpha, minCtcScore: vocabulary.minCtcScore,
                minSimilarity: vocabulary.minSimilarity,
                minCombinedConfidence: vocabulary.minCombinedConfidence,
                minTermLength: vocabulary.minTermLength)
            filterMs = Date().timeIntervalSince(filterStart) * 1000

            let spotStart = Date()
            let spotted = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: filteredVocabulary, minScore: nil)
            spotterMs = Date().timeIntervalSince(spotStart) * 1000

            let rescoreStart = Date()
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter, vocabulary: filteredVocabulary, config: rescorerConfig,
                ctcModelDirectory: ctcModelDirectory)
            if let timings = result.tokenTimings, !timings.isEmpty, !spotted.logProbs.isEmpty {
                let rescored = rescorer.ctcTokenRescore(
                    transcript: result.text, tokenTimings: timings, logProbs: spotted.logProbs,
                    frameDuration: spotted.frameDuration, cbw: cbw,
                    marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                    minSimilarity: minSimilarity)
                if rescored.wasModified {
                    result = ASRResult(
                        text: rescored.text, confidence: result.confidence, duration: result.duration,
                        processingTime: result.processingTime, tokenTimings: result.tokenTimings)
                }
            }
            rescoreMs = Date().timeIntervalSince(rescoreStart) * 1000
        }
        let totalMs = Date().timeIntervalSince(start) * 1000
        log.info(
            """
            transcribe: asr \(Int(asrMs), privacy: .public) ms, filter             \(Int(filterMs), privacy: .public) ms, spotter \(Int(spotterMs), privacy: .public) ms,             rescore \(Int(rescoreMs), privacy: .public) ms, total \(Int(totalMs), privacy: .public) ms
            """)
        let wordTimings = result.tokenTimings.map(buildWordTimings(from:))
        return TranscriptionResult(
            text: result.text, plainText: plainText, ms: totalMs,
            asrMs: asrMs, spotterMs: spotterMs, rescoreMs: rescoreMs, filterMs: filterMs,
            wordTimings: wordTimings)
    }

    /// Same as `transcribe(samples:alwaysIncludeTerms:language:)`, but takes
    /// the language as a plain ISO code (or nil for auto) instead of
    /// FluidAudio's `Language` type - for callers like `zumbo-cli` that link
    /// `VesperEngine` only, not `FluidAudio` directly.
    public func transcribe(
        samples: [Float], alwaysIncludeTerms: Set<String> = [], languageCode: String?
    ) async throws -> TranscriptionResult {
        try await transcribe(
            samples: samples, alwaysIncludeTerms: alwaysIncludeTerms,
            language: languageCode.map { .forSettingsCode($0) })
    }

    /// Reads a WAV file and resamples it to 16 kHz mono Float32, same path
    /// `AudioCapture` produces live.
    public static func loadSamples(path: String) throws -> [Float] {
        try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
    }
}

public enum TranscriberError: Error {
    case modelNotLoaded
}
