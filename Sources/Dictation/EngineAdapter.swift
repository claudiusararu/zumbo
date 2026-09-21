import AppKit
import Foundation
import VesperEngine
import os

/// What the app needs from a speech engine, on top of `VesperEngine`'s own
/// `DictationEngine` protocol (levels / start / stop).
///
/// There is exactly one `DictationEngine` declaration now, the package's; the
/// app's identical copy was deleted when the package was wired in. This
/// protocol only adds the things the panel and history need: the full result,
/// a state stream, pasting, settings and model readiness. `MockEngine` and
/// `EngineAdapter` both conform, so `--demo` still runs with no model.
@MainActor
protocol DictationDriver: DictationEngine {
    /// recording -> transcribing -> done, for the notch.
    var states: AsyncStream<DictationState> { get }
    /// Raw text, final text, duration, transcription ms, dev-context decision.
    var lastResult: DictationResult? { get }
    /// Real fractional model download/compile progress, 0...1.
    var modelLoadProgress: AsyncStream<Double> { get }
    /// True once the speech model is loaded and a dictation can actually start.
    var isModelReady: Bool { get }
    /// Dictionary terms the engine would boost with, for the Dictionary tab.
    var dictionaryTermCount: Int { get }
    /// The user's own taught words, newest first, for the Dictionary tab's
    /// "My words" list.
    var userDictionaryTerms: [DictionaryTerm] { get }

    func loadModel() async
    /// Teaches Zumbo a word: a canonical spelling and its spoken forms.
    /// Persists to disk and re-warms boosting so the next dictation uses it.
    func addDictionaryTerm(_ term: DictionaryTerm) throws
    /// Forgets a taught word (case-insensitive match on its spelling).
    func removeDictionaryTerm(text: String) throws
    /// Pastes into the frontmost app through the engine's `TextInserter`.
    func insert(_ text: String) -> TextDeliveryResult
    /// Drops the current recording without transcribing or pasting.
    func cancel()
    /// Pushes the user's persisted settings into the engine. Called right
    /// before every session starts.
    func apply(settings: AppSettings)
    /// Back to idle after the app has shown the result.
    func reset()
    /// Full pipeline on a WAV instead of the microphone (hidden
    /// `--transcribe-file` path).
    func transcribeFile(at url: URL) async throws -> String

    /// A fresh orchestrator for one meeting recording (chunked live
    /// transcription, optional speaker labels). Cheap to create - the
    /// expensive model loads are memoized on the shared `Transcriber` and
    /// `SpeakerModelManager` this reuses, not per meeting.
    func makeMeetingSession() -> MeetingSession
    var speakerModelStatus: SpeakerModelStatus { get }
    var speakerModelStatusUpdates: AsyncStream<SpeakerModelStatus> { get }
    var speakerModelIsReady: Bool { get }
    func startSpeakerModelDownloadIfNeeded()
    func cancelSpeakerModelDownload()
    func removeSpeakerModel() throws
}

/// Wraps the package's `DictationSession` so the app can hold one object that
/// owns the model, the session and the paste step.
///
/// The session and the transcriber are both `@MainActor`/actor-isolated in the
/// package, so nothing here has to hop queues by hand: the adapter is
/// `@MainActor` and awaits the engine, which does its work off the main thread.
@MainActor
final class EngineAdapter: DictationDriver {

    private let session: DictationSession
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "engine")

    private(set) var isModelReady = false
    private var loadTask: Task<Void, Never>?
    private let speakerModel = SpeakerModelManager()

    init() {
        session = DictationSession()
    }

    func makeMeetingSession() -> MeetingSession {
        MeetingSession(
            transcriber: session.sharedTranscriber, dictionary: session.userDictionary,
            rulesConfig: session.rulesConfig, speakerModel: speakerModel, language: session.language)
    }

    var speakerModelStatus: SpeakerModelStatus { speakerModel.status }
    var speakerModelStatusUpdates: AsyncStream<SpeakerModelStatus> { speakerModel.statusUpdates }
    var speakerModelIsReady: Bool { speakerModel.isReady }
    func startSpeakerModelDownloadIfNeeded() { speakerModel.startDownloadIfNeeded() }
    func cancelSpeakerModelDownload() { speakerModel.cancelDownload() }
    func removeSpeakerModel() throws { try speakerModel.remove() }

    var levels: AsyncStream<Float> { session.levels }
    var states: AsyncStream<DictationState> { session.states }
    var lastResult: DictationResult? { session.lastResult }
    var modelLoadProgress: AsyncStream<Double> { session.modelLoadProgress }
    var dictionaryTermCount: Int { session.dictionaryTermCount }
    var userDictionaryTerms: [DictionaryTerm] { session.userDictionary.terms.reversed() }

    func start() async throws {
        try await session.start()
    }

    func stop() async throws -> String {
        try await session.stop()
    }

    func insert(_ text: String) -> TextDeliveryResult {
        session.insert(text)
    }

    func cancel() {
        session.cancel()
    }

    func reset() {
        session.reset()
    }

    func apply(settings: AppSettings) {
        session.rulesConfig = settings.rules
        session.developerMode = settings.developerMode
        session.setLanguage(code: settings.language, multilingual: settings.multilingual)
        let packsChanged = session.enabledPacks != settings.enabledPacks
        session.enabledPacks = settings.enabledPacks
        if packsChanged, isModelReady {
            Task { [session] in await session.prepareBoostingIfNeeded() }
        }
    }

    /// Loads Parakeet in the background. Idempotent, and a second call awaits
    /// the first load rather than starting a competing one (one transcription
    /// process at a time).
    func loadModel() async {
        if isModelReady { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.loadModel()
                self.isModelReady = true
                self.log.info("speech model ready")
            } catch {
                self.log.error("model load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    func transcribeFile(at url: URL) async throws -> String {
        let samples = try Transcriber.loadSamples(path: url.path)
        let duration = Double(samples.count) / 16_000.0
        return try await session.transcribe(samples: samples, duration: duration)
    }

    func addDictionaryTerm(_ term: DictionaryTerm) throws {
        try session.userDictionary.add(term)
        rewarmBoosting()
    }

    func removeDictionaryTerm(text: String) throws {
        try session.userDictionary.remove(text: text)
        rewarmBoosting()
    }

    /// Rebuilds the warm boosting context off the dictation path so a term
    /// just taught (or forgotten) is boosted on the next dictation, not this
    /// one. No-op until the model has loaded once.
    private func rewarmBoosting() {
        guard isModelReady else { return }
        Task { [session] in await session.prepareBoostingIfNeeded() }
    }
}
