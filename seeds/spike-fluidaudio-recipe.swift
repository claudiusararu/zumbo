import AVFoundation
import Foundation
import FluidAudio

struct VocabTerm: Codable { let text: String; let aliases: [String] }
struct VocabFile: Codable { let terms: [VocabTerm] }
struct ManifestItem: Codable {
    let id: String; let voice: String; let lang: String
    let wav: String; let spoken: String; let expected: String; let terms: [String]
}
struct Manifest: Codable { let items: [ManifestItem]; let latency: [String: String] }

func loadVocabTerms(_ path: String?) -> [VocabTerm] {
    guard let path, let d = FileManager.default.contents(atPath: path) else { return [] }
    return (try? JSONDecoder().decode(VocabFile.self, from: d))?.terms ?? []
}

func jsonString(_ s: String) -> String {
    let d = try! JSONEncoder().encode([s])
    var t = String(data: d, encoding: .utf8)!
    t.removeFirst(); t.removeLast()
    return t
}

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// Batch Parakeet TDT v3 plus the FluidAudio CTC vocabulary-boosting pass.
actor Engine {
    private let manager: AsrManager
    private let decoderLayers: Int
    private var spotter: CtcKeywordSpotter?
    private var rescorer: VocabularyRescorer?
    private var vocabulary: CustomVocabularyContext?
    private var cbw: Float = 0
    private var minSimilarity: Float = 0

    init(manager: AsrManager, decoderLayers: Int) {
        self.manager = manager
        self.decoderLayers = decoderLayers
    }

    func enableBoosting(vocabPath: String, tuning: TuningConfig) async throws {
        var (vocab, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: vocabPath)
        let blankId = ctcModels.vocabulary.count
        let s = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
        let sizeCfg = ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)

        if let minTermLength = tuning.minTermLength, minTermLength != vocab.minTermLength {
            vocab = CustomVocabularyContext(
                terms: vocab.terms, alpha: vocab.alpha, minCtcScore: vocab.minCtcScore,
                minSimilarity: vocab.minSimilarity, minCombinedConfidence: vocab.minCombinedConfidence,
                minTermLength: minTermLength)
        }

        let rescorerConfig = VocabularyRescorer.Config(
            spotterRescueMinSimilarity: tuning.spotterRescueMinSimilarity ?? ContextBiasingConstants.defaultSpotterRescueMinSimilarity,
            spotterRescueEnabled: tuning.spotterRescueEnabled ?? ContextBiasingConstants.defaultSpotterRescueEnabled)

        rescorer = try await VocabularyRescorer.create(
            spotter: s, vocabulary: vocab, config: rescorerConfig,
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant))
        spotter = s
        vocabulary = vocab
        cbw = tuning.cbw ?? sizeCfg.cbw
        minSimilarity = tuning.minSimilarity ?? sizeCfg.minSimilarity
        log("boosting enabled with \(vocab.terms.count) terms, cbw \(cbw), minSimilarity \(minSimilarity), "
            + "minTermLength \(vocab.minTermLength), spotterRescueEnabled \(rescorerConfig.spotterRescueEnabled), "
            + "spotterRescueMinSimilarity \(rescorerConfig.spotterRescueMinSimilarity)")
    }

    func transcribe(samples: [Float]) async throws -> (text: String, ms: Double) {
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let t0 = Date()
        var result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        if let spotter, let rescorer, let vocabulary {
            let spot = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: vocabulary, minScore: nil)
            if let timings = result.tokenTimings, !timings.isEmpty, !spot.logProbs.isEmpty {
                let out = rescorer.ctcTokenRescore(
                    transcript: result.text, tokenTimings: timings, logProbs: spot.logProbs,
                    frameDuration: spot.frameDuration, cbw: cbw,
                    marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                    minSimilarity: minSimilarity)
                if out.wasModified {
                    result = ASRResult(
                        text: out.text, confidence: result.confidence, duration: result.duration,
                        processingTime: result.processingTime, tokenTimings: result.tokenTimings)
                }
            }
        }
        return (result.text, Date().timeIntervalSince(t0) * 1000)
    }
}

func samples(_ path: String) throws -> [Float] {
    try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
}

/// Boosting knobs exposed on the CLI, layered over the library's own
/// vocabulary-size-aware defaults (`nil` means "use the default").
struct TuningConfig {
    var minSimilarity: Float?
    var minTermLength: Int?
    var cbw: Float?
    var spotterRescueEnabled: Bool?
    var spotterRescueMinSimilarity: Float?

    /// Also loadable whole from a JSON file via --tuning-config, so a grid
    /// sweep can be driven from a set of small config files instead of long
    /// argv lines.
    struct File: Codable {
        let minSimilarity: Float?
        let minTermLength: Int?
        let cbw: Float?
        let spotterRescueEnabled: Bool?
        let spotterRescueMinSimilarity: Float?
    }

    mutating func merge(fromFile path: String) throws {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        let f = try JSONDecoder().decode(File.self, from: d)
        if let v = f.minSimilarity { minSimilarity = v }
        if let v = f.minTermLength { minTermLength = v }
        if let v = f.cbw { cbw = v }
        if let v = f.spotterRescueEnabled { spotterRescueEnabled = v }
        if let v = f.spotterRescueMinSimilarity { spotterRescueMinSimilarity = v }
    }
}

func parseBool(_ s: String) -> Bool? {
    switch s.lowercased() {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return nil
    }
}

@main
struct Spike {
    static func main() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else { print("usage: spike transcribe|bench|latency"); return }
        args.removeFirst()
        var vocabPath: String? = nil
        var useReplace = false
        var tuning = TuningConfig()
        var positional: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--vocab": vocabPath = args[i + 1]; i += 2
            case "--replace": useReplace = true; i += 1
            case "--min-similarity": tuning.minSimilarity = Float(args[i + 1]); i += 2
            case "--min-term-length": tuning.minTermLength = Int(args[i + 1]); i += 2
            case "--cbw": tuning.cbw = Float(args[i + 1]); i += 2
            case "--spotter-rescue": tuning.spotterRescueEnabled = parseBool(args[i + 1]); i += 2
            case "--spotter-min-sim": tuning.spotterRescueMinSimilarity = Float(args[i + 1]); i += 2
            case "--tuning-config": try tuning.merge(fromFile: args[i + 1]); i += 2
            default: positional.append(args[i]); i += 1
            }
        }
        let replacer = Replacer(terms: loadVocabTerms(vocabPath ?? positional.last))

        let t0 = Date()
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asrConfig = ASRConfig(
            tdtConfig: TdtConfig(blankId: AsrModelVersion.v3.blankId),
            encoderHiddenSize: AsrModelVersion.v3.encoderHiddenSize)
        let manager = AsrManager(config: asrConfig)
        try await manager.loadModels(models)
        let engine = Engine(manager: manager, decoderLayers: await manager.decoderLayerCount)
        let loadMs = Int(Date().timeIntervalSince(t0) * 1000)
        if let vocabPath { try await engine.enableBoosting(vocabPath: vocabPath, tuning: tuning) }
        let bootMs = Int(Date().timeIntervalSince(t0) * 1000)
        log("model load ms: \(loadMs)  boot incl vocab ms: \(bootMs)")

        switch cmd {
        case "transcribe":
            let (text, ms) = try await engine.transcribe(samples: try samples(positional[0]))
            print("raw:      \(text)")
            print("replaced: \(replacer.apply(text))")
            print("load ms \(loadMs)  transcribe ms \(Int(ms))")
        case "bench":
            let m = try JSONDecoder().decode(
                Manifest.self, from: FileManager.default.contents(atPath: positional[0])!)
            print("{\"kind\":\"meta\",\"loadMs\":\(loadMs),\"bootMs\":\(bootMs),\"vocab\":\(vocabPath != nil)}")
            for item in m.items {
                let (text, ms) = try await engine.transcribe(samples: try samples(item.wav))
                let rep = replacer.apply(text)
                print("{\"kind\":\"item\",\"id\":\(jsonString(item.id)),\"raw\":\(jsonString(text)),\"replaced\":\(jsonString(rep)),\"used\":\(jsonString(useReplace ? rep : text)),\"ms\":\(Int(ms))}")
                fflush(stdout)
            }
        case "latency":
            let m = try JSONDecoder().decode(
                Manifest.self, from: FileManager.default.contents(atPath: positional[0])!)
            for (name, path) in m.latency.sorted(by: { $0.key < $1.key }) {
                let s = try samples(path)
                var times: [Double] = []
                for _ in 0..<3 { times.append(try await engine.transcribe(samples: s).ms) }
                times.sort()
                print("{\"kind\":\"lat\",\"clip\":\"\(name)\",\"vocab\":\(vocabPath != nil),\"loadMs\":\(loadMs),\"median\":\(Int(times[1])),\"all\":[\(times.map { String(Int($0)) }.joined(separator: ","))]}")
                fflush(stdout)
            }
        default: print("unknown command: \(cmd)")
        }
    }
}
