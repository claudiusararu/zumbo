import Foundation
import VesperEngine

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func loadVocabTerms(atPath path: String) -> [VocabTerm] {
    VocabFile.load(atPath: path)?.terms ?? []
}

/// Resolves the vocabulary JSON path to boost with: an explicit `--vocab`
/// file wins, otherwise the starter dictionary (no user entries - the CLI has
/// no UI to teach any) is written to a temp file.
func resolveVocabularyPath(explicit: String?) throws -> String {
    if let explicit { return explicit }
    let terms = VesperDictionary.mergedVocabulary(starter: VesperDictionary.starterPack(), user: [])
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zumbo-cli-vocab.json")
    try VesperDictionary.writeVocabularyJSON(terms, to: tmp)
    return tmp.path
}

struct BenchItem: Codable {
    let id: String
    let wav: String
    let expected: String
    let terms: [String]
}

struct BenchManifest: Codable {
    let items: [BenchItem]
}

func containsWord(_ text: String, _ word: String) -> Bool {
    let pattern = "(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: word))(?![A-Za-z0-9])"
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return text.localizedCaseInsensitiveContains(word)
    }
    let ns = text as NSString
    return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
}

func runTranscribe(_ args: [String]) async throws {
    var noBoost = false
    var vocabPath: String?
    var rulesOff = false
    var wavPath: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--no-boost": noBoost = true; i += 1
        case "--vocab": vocabPath = args[i + 1]; i += 2
        case "--rules": rulesOff = (args[i + 1] == "off"); i += 2
        default: wavPath = args[i]; i += 1
        }
    }
    guard let wavPath else {
        print("usage: zumbo-cli transcribe <wav> [--no-boost] [--vocab file] [--rules off]")
        return
    }

    let transcriber = Transcriber()
    let loadStart = Date()
    try await transcriber.warmUp()
    log("model load ms: \(Int(Date().timeIntervalSince(loadStart) * 1000))")

    var vocabTerms: [VocabTerm] = []
    var setupMs = 0.0
    if !noBoost {
        let path = try resolveVocabularyPath(explicit: vocabPath)
        vocabTerms = loadVocabTerms(atPath: path)
        let setupStart = Date()
        try await transcriber.enableBoosting(vocabularyPath: path)
        setupMs = Date().timeIntervalSince(setupStart) * 1000
    }

    let samples = try Transcriber.loadSamples(path: wavPath)
    // One model call: `plainText` is the pre-rescoring reading, `text` the
    // boosted one, so there is no second pass over the same audio.
    let pass = try await transcriber.transcribe(samples: samples)
    print("raw:      \(pass.plainText)")
    if !noBoost {
        print("boosted:  \(pass.text)")
    }

    let rules = RulesEngine(vocabulary: vocabTerms, config: rulesOff ? .allOff : RulesConfig())
    let rulesStart = Date()
    let finalText = rules.apply(noBoost ? pass.plainText : pass.text)
    let rulesMs = Date().timeIntervalSince(rulesStart) * 1000
    print("final:    \(finalText)")
    print("audio s: \(String(format: "%.1f", Double(samples.count) / 16000))")
    print("boost terms: \(vocabTerms.count), boosting setup ms: \(Int(setupMs))")
    print(
        "stage ms: asr \(Int(pass.asrMs)), filter \(Int(pass.filterMs)), spotter \(Int(pass.spotterMs)), "
        + "rescore \(Int(pass.rescoreMs)), rules \(Int(rulesMs)), total \(Int(pass.ms))")
}

func runBench(_ args: [String]) async throws {
    var manifestPath: String?
    var languageCode: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--language": languageCode = args[i + 1]; i += 2
        default: manifestPath = args[i]; i += 1
        }
    }
    guard let manifestPath else {
        print("usage: zumbo-cli bench <manifest.json> [--language <code>]")
        return
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
    let manifest = try JSONDecoder().decode(BenchManifest.self, from: data)

    let vocabTerms = VesperDictionary.mergedVocabulary(starter: VesperDictionary.starterPack(), user: [])
    let vocabURL = FileManager.default.temporaryDirectory.appendingPathComponent("zumbo-bench-vocab.json")
    try VesperDictionary.writeVocabularyJSON(vocabTerms, to: vocabURL)
    let replacer = Replacer(terms: vocabTerms)

    let transcriber = Transcriber()
    try await transcriber.warmUp()
    try await transcriber.enableBoosting(vocabularyPath: vocabURL.path)

    var totalExpected = 0
    var correct = 0
    var falseInsertions = 0
    var msValues: [Double] = []
    var asrValues: [Double] = []
    var filterValues: [Double] = []
    var spotterValues: [Double] = []
    var rescoreValues: [Double] = []

    for item in manifest.items {
        let samples = try Transcriber.loadSamples(path: item.wav)
        let result = try await transcriber.transcribe(samples: samples, languageCode: languageCode)
        let used = replacer.apply(result.text)
        msValues.append(result.ms)
        asrValues.append(result.asrMs)
        filterValues.append(result.filterMs)
        spotterValues.append(result.spotterMs)
        rescoreValues.append(result.rescoreMs)

        for term in item.terms {
            totalExpected += 1
            if containsWord(used, term) { correct += 1 }
        }
        // A false insertion: a vocabulary term not among this item's expected
        // terms, and not present in the ground-truth `expected` text either,
        // shows up in the output anyway.
        for term in vocabTerms {
            let isExpectedHere = item.terms.contains { $0.caseInsensitiveCompare(term.text) == .orderedSame }
            guard !isExpectedHere else { continue }
            if containsWord(used, term.text), !containsWord(item.expected, term.text) {
                falseInsertions += 1
            }
        }
        log("\(item.id): \(used)")
    }

    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    let recall = totalExpected == 0 ? 0 : Double(correct) / Double(totalExpected) * 100
    let precision = (correct + falseInsertions) == 0 ? 0 : Double(correct) / Double(correct + falseInsertions) * 100

    print("items: \(manifest.items.count)")
    print("term recall: \(correct)/\(totalExpected) = \(String(format: "%.1f", recall))%")
    print("term precision: \(correct)/\(correct + falseInsertions) = \(String(format: "%.1f", precision))% (\(falseInsertions) false insertions)")
    print("median ms: \(Int(median(msValues)))")
    print(
        "median stage ms: asr \(Int(median(asrValues))), filter \(Int(median(filterValues))), "
        + "spotter \(Int(median(spotterValues))), rescore \(Int(median(rescoreValues)))")
}

/// Feeds a WAV through the live meeting pipeline (VAD chunker + Transcriber +
/// Sortformer diarizer + `SpeakerAligner`) in ~100 ms batches, exactly as
/// `MeetingSession` consumes live microphone audio, so this exercises the
/// same code the app runs - not a re-implementation of it. Prints each
/// paragraph as it closes, then a latency/turn summary.
@MainActor
func runMeeting(_ args: [String]) async throws {
    var noLabels = false
    var wavPath: String?
    var addOnDir: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--no-labels": noLabels = true; i += 1
        case "--addon-dir": addOnDir = args[i + 1]; i += 2
        default: wavPath = args[i]; i += 1
        }
    }
    guard let wavPath else {
        print("usage: zumbo-cli meeting <wav> [--no-labels] [--addon-dir <path>]")
        return
    }

    let transcriber = Transcriber()
    let loadStart = Date()
    try await transcriber.warmUp()
    log("model load ms: \(Int(Date().timeIntervalSince(loadStart) * 1000))")

    let dictionary = UserDictionaryStore()
    let speakerModel = SpeakerModelManager(addOnDirectory: addOnDir.map { URL(fileURLWithPath: $0) })
    let session = MeetingSession(
        transcriber: transcriber, dictionary: dictionary, rulesConfig: RulesConfig(), speakerModel: speakerModel)

    if !noLabels && !speakerModel.isReady {
        log(
            "speaker labels add-on not installed, run the app's Settings > Models download or pass "
                + "--addon-dir <path> (see: zumbo-cli addon install speaker-labels)")
    }

    let printTask = Task {
        for await update in session.paragraphUpdates {
            let prefix = update.isNewParagraph ? "\n[new] " : "[merge] "
            let speaker = update.speakerLabel.map { "\($0): " } ?? ""
            print("\(prefix)\(speaker)\(update.text)")
        }
    }

    try await session.startForTesting(labelSpeakers: !noLabels)
    log("label availability: \(session.labelAvailability)")

    let samples = try Transcriber.loadSamples(path: wavPath)
    // 100 ms batches, matching roughly what AVAudioEngine's tap delivers.
    let batchSize = 1600
    let wallStart = Date()
    var offset = 0
    while offset < samples.count {
        let end = min(offset + batchSize, samples.count)
        await session.feedForTesting(Array(samples[offset..<end]))
        offset = end
    }
    let (wordCount, duration) = await session.finishForTesting()
    let wallMs = Date().timeIntervalSince(wallStart) * 1000

    try? await Task.sleep(nanoseconds: 100_000_000)
    printTask.cancel()

    print("\n--- summary ---")
    print("audio seconds: \(String(format: "%.1f", duration))")
    print("word count: \(wordCount)")
    print("chunks: \(session.chunkTimings.count)")
    for (index, timing) in session.chunkTimings.enumerated() {
        print("  chunk \(index + 1): \(String(format: "%.1f", timing.audioSeconds))s audio, \(Int(timing.transcriptionMs)) ms transcribe")
    }
    print("total wall time: \(Int(wallMs)) ms")
}

/// Drives `AddOnStore` from the terminal (`zumbo-cli addon install speaker-labels`),
/// with progress printed as it downloads - the same store the app's Settings > Models
/// row uses, so this is a real end-to-end check of the bucket, not a separate path.
@MainActor
func runAddon(_ args: [String]) async throws {
    guard args.count >= 2, args[0] == "install" else {
        print("usage: zumbo-cli addon install <id>")
        return
    }
    let addOnID = args[1]
    let store = AddOnStore(addOnID: addOnID)
    if store.isReady {
        print("\(addOnID) is already installed")
        return
    }

    let printTask = Task {
        for await status in store.statusUpdates {
            switch status {
            case .notDownloaded:
                break
            case .downloading(let fraction, let received, let total):
                let mb = { (bytes: Int64) in String(format: "%.0f", Double(bytes) / 1_000_000) }
                print("downloading \(mb(received)) MB of \(mb(total)) MB (\(Int(fraction * 100))%)")
            case .ready(let size):
                print("installed, \(size / 1_000_000) MB on disk")
            case .cancelled:
                print("cancelled")
            case .failed(let message):
                print("failed: \(message)")
            }
        }
    }

    let start = Date()
    await store.install()
    printTask.cancel()
    let elapsed = Date().timeIntervalSince(start)

    guard store.isReady else {
        print("install did not complete")
        exit(1)
    }
    if case .ready(let size) = store.status {
        let seconds = max(elapsed, 0.001)
        let mbps = (Double(size) / 1_000_000) / seconds
        print("done in \(String(format: "%.1f", elapsed))s, \(String(format: "%.1f", mbps)) MB/s")
    }
}

@main
struct ZumboCLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            print("usage: zumbo-cli transcribe <wav> [--no-boost] [--vocab file] [--rules off]")
            print("       zumbo-cli bench <manifest.json>")
            print("       zumbo-cli meeting <wav> [--no-labels] [--addon-dir <path>]")
            print("       zumbo-cli addon install <id>")
            return
        }
        args.removeFirst()
        do {
            switch command {
            case "transcribe": try await runTranscribe(args)
            case "bench": try await runBench(args)
            case "meeting": try await runMeeting(args)
            case "addon": try await runAddon(args)
            default: print("unknown command: \(command)")
            }
        } catch {
            log("error: \(error)")
            exit(1)
        }
    }
}
