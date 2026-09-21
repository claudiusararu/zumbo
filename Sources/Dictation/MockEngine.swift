import Foundation
import VesperEngine

/// Stand-in engine so the panel can be built and demoed with no microphone and
/// no model. Emits a sine-ish level with a little jitter and returns a fixed
/// transcript. Kept for the `--demo` launch arguments and the Debug menu.
@MainActor
final class MockEngine: DictationDriver {

    private let stream: AsyncStream<Float>
    private let continuation: AsyncStream<Float>.Continuation
    private let stateStream: AsyncStream<DictationState>
    private let stateContinuation: AsyncStream<DictationState>.Continuation
    private var emitter: Task<Void, Never>?

    private(set) var lastResult: DictationResult?

    /// Isolated from the real dictionary the same way `--demo` isolates
    /// history: a demo run must never write into the user's real taught
    /// words.
    private let dictionaryStore = UserDictionaryStore(storageURL: MockEngine.demoDictionaryURL())

    init() {
        let (stream, continuation) = AsyncStream<Float>.makeStream(
            of: Float.self, bufferingPolicy: .bufferingNewest(2))
        self.stream = stream
        self.continuation = continuation
        let (states, stateContinuation) = AsyncStream<DictationState>.makeStream(
            of: DictationState.self, bufferingPolicy: .bufferingNewest(8))
        self.stateStream = states
        self.stateContinuation = stateContinuation
    }

    var levels: AsyncStream<Float> { stream }
    var states: AsyncStream<DictationState> { stateStream }

    /// The mock is always "ready": nothing to load.
    var isModelReady: Bool { true }
    var dictionaryTermCount: Int { 0 }
    var userDictionaryTerms: [DictionaryTerm] { dictionaryStore.terms.reversed() }
    var modelLoadProgress: AsyncStream<Double> {
        AsyncStream { continuation in
            continuation.yield(1)
            continuation.finish()
        }
    }

    func loadModel() async {}
    func apply(settings: AppSettings) {}

    func start() async throws {
        stateContinuation.yield(.recording)
        let continuation = self.continuation
        emitter?.cancel()
        emitter = Task.detached(priority: .utility) {
            var t = 0.0
            while !Task.isCancelled {
                // Two beating sines read like speech rather than a metronome.
                let carrier = (sin(t * 5.4) + 1) / 2
                let envelope = 0.55 + 0.45 * (sin(t * 1.3) + 1) / 2
                let jitter = Double.random(in: -0.06...0.06)
                // Scaled into the range the real capture emits (RMS * 4 of
                // speech sits around 0.04...0.12), so the demo waveform reads
                // like the live one instead of saturating.
                let value = min(max(carrier * envelope + jitter, 0), 1) * 0.12
                continuation.yield(Float(value))
                t += 0.033
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func cancel() {
        emitter?.cancel()
        emitter = nil
    }

    func stop() async throws -> String {
        emitter?.cancel()
        emitter = nil
        continuation.yield(0)
        stateContinuation.yield(.transcribing)
        try? await Task.sleep(for: .milliseconds(300))
        let text = "Placeholder transcript"
        lastResult = DictationResult(
            rawText: text, finalText: text, duration: 0, transcriptionMs: 0,
            devContextDecision: DevContextDecision(shouldBoost: false, score: 0, reason: "mock"))
        stateContinuation.yield(.done)
        return text
    }

    /// The mock never touches the pasteboard: a demo run must not overwrite
    /// what the owner has copied.
    func insert(_ text: String) -> TextDeliveryResult { .copiedOnly }

    func reset() {
        stateContinuation.yield(.idle)
    }

    func transcribeFile(at url: URL) async throws -> String {
        try await stop()
    }

    /// A demo run still builds a real `MeetingSession` (meeting mode was
    /// never part of the `--demo` screenshot flow the mock otherwise fakes),
    /// backed by its own real `Transcriber`/`SpeakerModelManager` so it does
    /// not touch the app's real dictionary or model state.
    private lazy var demoSpeakerModel = SpeakerModelManager()

    func makeMeetingSession() -> MeetingSession {
        MeetingSession(
            transcriber: Transcriber(), dictionary: dictionaryStore, rulesConfig: RulesConfig(),
            speakerModel: demoSpeakerModel)
    }

    var speakerModelStatus: SpeakerModelStatus { demoSpeakerModel.status }
    var speakerModelStatusUpdates: AsyncStream<SpeakerModelStatus> { demoSpeakerModel.statusUpdates }
    var speakerModelIsReady: Bool { demoSpeakerModel.isReady }
    func startSpeakerModelDownloadIfNeeded() { demoSpeakerModel.startDownloadIfNeeded() }
    func cancelSpeakerModelDownload() { demoSpeakerModel.cancelDownload() }
    func removeSpeakerModel() throws { try demoSpeakerModel.remove() }

    func addDictionaryTerm(_ term: DictionaryTerm) throws {
        try dictionaryStore.add(term)
    }

    func removeDictionaryTerm(text: String) throws {
        try dictionaryStore.remove(text: text)
    }

    private static func demoDictionaryURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Zumbo/demo-dictionary.json")
    }
}
