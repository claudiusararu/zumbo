import Foundation
import XCTest
@testable import VesperEngine

/// A take with no speech must come back as "no speech" so nothing gets
/// transcribed and pasted; a take with even one short word must not.
/// Needs the Silero model in FluidAudio's cache (the app copies it there on
/// first launch); skipped otherwise, so the suite never downloads.
final class SpeechDetectorTests: XCTestCase {
    private let rate = 16_000

    override func setUpWithError() throws {
        let model = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models/silero-vad-coreml")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model.path), "Silero VAD model not in cache")
    }

    func testEmptyTakeHasNoSpeech() async {
        let hasSpeech = await SpeechDetector().containsSpeech([])
        XCTAssertFalse(hasSpeech)
    }

    func testSilenceHasNoSpeech() async {
        let hasSpeech = await SpeechDetector().containsSpeech([Float](repeating: 0, count: rate * 2))
        XCTAssertFalse(hasSpeech)
    }

    /// The app's start tone (C5 then E5, 70 ms each) over quiet room noise:
    /// what the microphone hears when someone presses record and says nothing.
    func testStartToneOverRoomNoiseHasNoSpeech() async {
        var generator = SystemRandomNumberGenerator()
        var samples = (0..<(rate * 2)).map { _ in Float.random(in: -0.01...0.01, using: &generator) }
        let noteFrames = Int(0.070 * Double(rate))
        for (n, hz) in [523.0, 659.0].enumerated() {
            for i in 0..<noteFrames {
                let t = Double(i) / Double(rate)
                samples[n * noteFrames + i] += Float(sin(2 * .pi * hz * t) * 0.18)
            }
        }
        let hasSpeech = await SpeechDetector().containsSpeech(samples)
        XCTAssertFalse(hasSpeech)
    }

    func testOneShortWordIsSpeech() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("zumbo-speech-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "Yes."]
        try say.run()
        say.waitUntilExit()
        try XCTSkipUnless(say.terminationStatus == 0, "say could not render speech")

        let word = try Transcriber.loadSamples(path: file.path)
        let pad = [Float](repeating: 0, count: rate / 2)
        let hasSpeech = await SpeechDetector().containsSpeech(pad + word + pad)
        XCTAssertTrue(hasSpeech)
    }
}
