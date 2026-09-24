import FluidAudio
import Foundation
import os

/// The minimal engine surface the app drives: start capturing, stop and get
/// back the final text. This is the single declaration: the app shell imports
/// `VesperEngine` and uses this protocol (its own duplicate was deleted when
/// the package was wired into the app target).
@MainActor
public protocol DictationEngine: AnyObject {
    var levels: AsyncStream<Float> { get }
    func start() async throws
    func stop() async throws -> String
}

public enum DictationState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case done
    case failed(String)
}

/// Everything produced by one dictation, for history/debugging UI and for
/// `zumbo-cli transcribe`.
public struct DictationResult: Sendable {
    public let rawText: String
    public let finalText: String
    public let duration: TimeInterval
    public let transcriptionMs: Double
    public let devContextDecision: DevContextDecision
    /// Per-stage wall times for the run, in milliseconds. `boostingSetupMs` is
    /// zero when the vocabulary context was already warm, which is the normal
    /// case: it is built once at model load, not per session.
    public let asrMs: Double
    public let spotterMs: Double
    public let rescoreMs: Double
    public let boostingSetupMs: Double
    public let rulesMs: Double
    /// The `CandidateFilter` pass that narrows the vocabulary to plausible
    /// candidates before the spotter/rescorer run. Zero when boosting is off.
    public let filterMs: Double

    public init(
        rawText: String,
        finalText: String,
        duration: TimeInterval,
        transcriptionMs: Double,
        devContextDecision: DevContextDecision,
        asrMs: Double = 0,
        spotterMs: Double = 0,
        rescoreMs: Double = 0,
        boostingSetupMs: Double = 0,
        rulesMs: Double = 0,
        filterMs: Double = 0
    ) {
        self.rawText = rawText
        self.finalText = finalText
        self.duration = duration
        self.transcriptionMs = transcriptionMs
        self.devContextDecision = devContextDecision
        self.asrMs = asrMs
        self.spotterMs = spotterMs
        self.rescoreMs = rescoreMs
        self.boostingSetupMs = boostingSetupMs
        self.rulesMs = rulesMs
        self.filterMs = filterMs
    }
}

/// Orchestrates one full dictation: capture -> stop -> transcribe -> dev
/// context decision -> (conditionally) vocabulary boosting -> rules ->
/// paste. Owns one `AudioCapture`/`Transcriber` pair; not reentrant (one
/// recording at a time, matching the one-transcription-process-at-a-time rule).
@MainActor
public final class DictationSession: DictationEngine {
    private let capture: AudioCapture
    private nonisolated let transcriber: Transcriber
    private nonisolated let speechDetector: SpeechDetector
    private let devContext: DevContextGate
    private let dictionary: UserDictionaryStore
    private let textInserter: TextInserter
    private let boostedVocabularyPath: URL

    /// Read at the start of every `stop()` pipeline run, so the app can push
    /// the user's settings in at any time and the next dictation picks them up.
    public var rulesConfig: RulesConfig

    /// Auto/Always/Off topic gating, also read per dictation.
    public var developerMode: DeveloperMode {
        get { devContext.mode }
        set { devContext.mode = newValue }
    }

    /// Script hint for the v3 joint decoder, read at the start of every
    /// dictation and meeting chunk. `nil` = auto (multilingual, per-sentence
    /// detection). The app sets this from `AppSettings.language` /
    /// `.multilingual` in `apply(settings:)`; `nil` here until then, so a
    /// dictation before the first settings push still runs (Parakeet's own
    /// default), it just doesn't get the accuracy boost yet.
    public var language: Language?

    /// Sets `language` from `AppSettings`' plain-Swift persisted values, so
    /// the app target never has to name FluidAudio's `Language` type (it
    /// links `VesperEngine` only). `multilingual` true always wins: the
    /// engine then auto-detects per sentence and `code` is ignored.
    public func setLanguage(code: String, multilingual: Bool) {
        language = multilingual ? nil : .forSettingsCode(code)
    }

    /// Which starter packs feed the boost candidate pool. `nil` = every pack.
    /// The app sets this from settings (later from onboarding). Changing it
    /// changes the dictionary signature, so the boosting context is rebuilt.
    public var enabledPacks: Set<String>? {
        get { dictionary.enabledPacks }
        set { dictionary.enabledPacks = newValue }
    }

    /// How many dictionary terms (starter pack merged with the user's) the
    /// engine will boost with, for the app's Dictionary tab count.
    public var dictionaryTermCount: Int { dictionary.mergedVocabulary().count }

    /// The user's own dictionary (add/remove/list, persisted to
    /// `Application Support/Zumbo/dictionary.json`), for the app's
    /// Dictionary settings screen. Same instance the session boosts with:
    /// call `prepareBoostingIfNeeded()` after a change so the next dictation
    /// picks it up.
    public var userDictionary: UserDictionaryStore { dictionary }

    /// The same `Transcriber` actor instance this session transcribes with,
    /// for `MeetingSession` to share - the actor already serializes calls,
    /// so sharing it is what keeps "one transcription process at a time"
    /// true across a plain dictation and a live meeting chunk.
    public var sharedTranscriber: Transcriber { transcriber }

    public private(set) var state: DictationState = .idle {
        didSet {
            guard state != oldValue else { return }
            stateContinuation.yield(state)
        }
    }
    public private(set) var lastResult: DictationResult?

    /// Live state, so the notch can follow recording -> transcribing -> done
    /// without polling. Multicast is not needed: one consumer (the app's
    /// coordinator) reads it for the lifetime of the session object.
    public nonisolated let states: AsyncStream<DictationState>
    private nonisolated let stateContinuation: AsyncStream<DictationState>.Continuation

    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "session")
    private var recordingStart: Date?
    /// Signature of the vocabulary the warm boosting context was built from.
    /// Non-nil means the CTC models, spotter and vocabulary context are warm;
    /// a different dictionary changes the signature and triggers one rebuild,
    /// never inside a dictation.
    private var preparedVocabularySignature: Int?

    /// Hard cap on how many terms go into the boosting vocabulary. 0 means no
    /// cap. The CTC spotter's cost grows with the term count, so this is the
    /// lever if the starter pack keeps growing.
    public var maxBoostTerms = 0

    public init(
        capture: AudioCapture = AudioCapture(),
        transcriber: Transcriber = Transcriber(),
        speechDetector: SpeechDetector = SpeechDetector(),
        devContext: DevContextGate = DevContextGate(),
        dictionary: UserDictionaryStore = UserDictionaryStore(),
        textInserter: TextInserter = TextInserter(),
        rulesConfig: RulesConfig = RulesConfig(),
        language: Language? = nil
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.speechDetector = speechDetector
        self.devContext = devContext
        self.dictionary = dictionary
        self.textInserter = textInserter
        self.rulesConfig = rulesConfig
        self.language = language
        var continuation: AsyncStream<DictationState>.Continuation!
        self.states = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation = $0 }
        self.stateContinuation = continuation
        self.boostedVocabularyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("zumbo-session-vocab-\(UUID().uuidString).json")
    }

    public var levels: AsyncStream<Float> { capture.levels }

    public func start() async throws {
        state = .recording
        recordingStart = Date()
        try capture.start()
        Task { try? await transcriber.warmUp() }
        Task { await speechDetector.prepare() }
    }

    @discardableResult
    public func stop() async throws -> String {
        let samples = capture.stop()
        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        recordingStart = nil
        return try await transcribe(samples: samples, duration: duration)
    }

    /// Abandons the current recording: the microphone stops, the captured
    /// audio is dropped, nothing is transcribed or pasted.
    public func cancel() {
        guard state == .recording else { return }
        _ = capture.stop()
        recordingStart = nil
        state = .idle
    }

    /// The post-capture half of the pipeline, on samples from anywhere:
    /// transcribe -> dev context decision -> (conditional) boosting -> rules.
    /// `stop()` is this with the microphone's samples; the app's hidden
    /// `--transcribe-file` path is this with a WAV's samples.
    @discardableResult
    public func transcribe(samples: [Float], duration: TimeInterval) async throws -> String {
        state = .transcribing
        // No speech in the take: Parakeet would invent a short phrase
        // ("Thank you.") and it would be pasted. Empty text is what the app
        // already shows as "Nothing heard".
        guard await speechDetector.containsSpeech(samples) else {
            log.info("no speech in \(String(format: "%.1f", duration), privacy: .public) s of audio, nothing transcribed")
            state = .done
            return ""
        }
        do {
            // The boosting context is warm from `loadModel()`, so the plain
            // pass here already includes the spotter and the rescoring pass.
            // The dev-context gate then decides whether to keep that text or
            // fall back to the unboosted one, with no second model call.
            // The user's own dictionary entries always survive
            // `CandidateFilter`'s cap, even if they'd otherwise score below
            // the similarity threshold - the user explicitly taught them.
            let alwaysInclude = Set(dictionary.terms.map(\.text))
            let pass = try await transcriber.transcribe(
                samples: samples, alwaysIncludeTerms: alwaysInclude, language: language)
            let vocabulary = dictionary.mergedVocabulary()
            // The gate reads the plain text, exactly as before: the boosted
            // reading must not be able to talk itself into being kept.
            let dictionaryHits = countDictionaryHits(in: pass.plainText, vocabulary: vocabulary)
            let decision = devContext.evaluate(
                transcript: pass.plainText, dictionaryHits: dictionaryHits,
                frontmostBundleID: frontmostBundleID())

            let rulesStart = Date()
            let rules = RulesEngine(vocabulary: decision.shouldBoost ? vocabulary : [], config: rulesConfig)
            let finalText = rules.apply(decision.shouldBoost ? pass.text : pass.plainText)
            let rulesMs = Date().timeIntervalSince(rulesStart) * 1000
            let setupMs = await transcriber.lastBoostingSetupMs

            lastResult = DictationResult(
                rawText: pass.plainText, finalText: finalText, duration: duration,
                transcriptionMs: pass.ms, devContextDecision: decision,
                asrMs: pass.asrMs, spotterMs: pass.spotterMs, rescoreMs: pass.rescoreMs,
                boostingSetupMs: setupMs, rulesMs: rulesMs, filterMs: pass.filterMs)
            log.info(
                """
                session stages: audio \(String(format: "%.1f", duration), privacy: .public) s, \
                asr \(Int(pass.asrMs), privacy: .public) ms, \
                filter \(Int(pass.filterMs), privacy: .public) ms, \
                spotter \(Int(pass.spotterMs), privacy: .public) ms, \
                rescore \(Int(pass.rescoreMs), privacy: .public) ms, \
                rules \(Int(rulesMs), privacy: .public) ms, \
                boost setup \(Int(setupMs), privacy: .public) ms, \
                boost \(decision.shouldBoost ? "kept" : "dropped", privacy: .public)
                """)
            state = .done
            return finalText
        } catch {
            state = .failed("\(error)")
            throw error
        }
    }

    /// Pastes the given text into the frontmost app (call after `stop()`
    /// returns, typically with its result).
    public func insert(_ text: String) -> TextDeliveryResult {
        textInserter.insert(text)
    }

    /// Back to idle once the app has finished showing the result.
    public func reset() {
        state = .idle
    }

    /// Loads (or downloads) the speech model, then kicks off building the
    /// boosting vocabulary context. Safe to call more than once. The app
    /// calls this at launch.
    ///
    /// The CTC vocabulary setup (loading the CTC CoreML models plus
    /// tokenizing every dictionary term) does not run on this call's critical
    /// path: it is a fixed cost dominated by the CoreML model load, not by
    /// dictionary size - measured 0.7-4.6 s warm, up to ~10-15 s on a cold
    /// disk cache, the same whether the vocabulary is 40 terms or 1721 (see
    /// Engine/README.md). Running it in the background here means the app is
    /// interactive - plain-text dictation - as soon as the ASR model is warm,
    /// typically well under a second; `transcribe(samples:)` already falls
    /// back to unboosted text whenever the spotter/rescorer/vocabulary aren't
    /// ready yet, so the first dictation or two just won't have boosting if
    /// they land inside that window.
    public func loadModel() async throws {
        try await transcriber.warmUp()
        Task { await self.prepareBoostingIfNeeded() }
    }

    /// Rebuilds the warm boosting context when the dictionary has changed.
    /// Call after editing the dictionary; it is a no-op when nothing moved.
    public func prepareBoostingIfNeeded() async {
        let vocabulary = boostVocabulary()
        let signature = Self.signature(of: vocabulary)
        guard signature != preparedVocabularySignature else { return }
        do {
            let start = Date()
            try VesperDictionary.writeVocabularyJSON(vocabulary, to: boostedVocabularyPath)
            try await transcriber.enableBoosting(vocabularyPath: boostedVocabularyPath.path)
            preparedVocabularySignature = signature
            log.info(
                """
                boosting prepared off the dictation path: \
                \(vocabulary.count, privacy: .public) terms in \
                \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms
                """)
        } catch {
            log.error("boosting setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The terms that go to the boosting pass: the user's first, then the
    /// starter packs that are enabled (`enabledPacks`), capped by
    /// `maxBoostTerms` when that is set.
    private func boostVocabulary() -> [VocabTerm] {
        let all = dictionary.mergedVocabulary()
        guard maxBoostTerms > 0, all.count > maxBoostTerms else { return all }
        return Array(all.prefix(maxBoostTerms))
    }

    private static func signature(of terms: [VocabTerm]) -> Int {
        var hasher = Hasher()
        for term in terms {
            hasher.combine(term.text)
            hasher.combine(term.aliases)
            hasher.combine(term.minSimilarity)
        }
        return hasher.finalize()
    }

    /// Real fractional model download/compile progress, 0...1.
    public nonisolated var modelLoadProgress: AsyncStream<Double> {
        transcriber.modelLoadProgress
    }

    private func countDictionaryHits(in text: String, vocabulary: [VocabTerm]) -> Int {
        vocabulary.reduce(0) { count, term in
            let matchesTerm = ([term.text] + term.aliases).contains { Self.containsWord(text, $0) }
            return matchesTerm ? count + 1 : count
        }
    }

    private static func containsWord(_ text: String, _ phrase: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: "\\ ", with: "[ ]+")
        let pattern = "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let ns = text as NSString
        return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private func frontmostBundleID() -> String? {
        #if canImport(AppKit)
        return NSWorkspaceFrontmostApp.bundleIdentifier()
        #else
        return nil
        #endif
    }
}

#if canImport(AppKit)
import AppKit

/// Thin seam around `NSWorkspace` so `DictationSession` doesn't need
/// `@MainActor` just to read the frontmost app's bundle id.
enum NSWorkspaceFrontmostApp {
    static func bundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
#endif
