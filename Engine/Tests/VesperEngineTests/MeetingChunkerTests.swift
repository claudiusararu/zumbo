import XCTest
@testable import VesperEngine

/// Pure, model-free: drives `MeetingChunker` with a synthetic VAD event
/// sequence (sample indices only, no audio, no VAD model) and checks where
/// chunks close.
final class MeetingChunkerTests: XCTestCase {
    private let sr: Double = 16_000

    private func samples(_ seconds: Double) -> Int { Int(seconds * sr) }

    func testDoesNotCloseOnShortSpeechBelowMinimum() {
        var chunker = MeetingChunker(config: MeetingChunkerConfig(sampleRate: sr))
        // 1 s of speech (below the 2 s minimum), then silence: should not close.
        XCTAssertNil(chunker.handle(.speechStart(sampleIndex: samples(0))))
        XCTAssertNil(chunker.handle(.speechEnd(sampleIndex: samples(1))))
    }

    func testClosesOnSilenceOnceMinimumSpeechAccumulated() {
        var chunker = MeetingChunker(config: MeetingChunkerConfig(sampleRate: sr))
        XCTAssertNil(chunker.handle(.speechStart(sampleIndex: samples(0))))
        // 2.5 s of speech clears the 2 s minimum.
        let boundary = chunker.handle(.speechEnd(sampleIndex: samples(2.5)))
        XCTAssertEqual(boundary, MeetingChunkBoundary(startSample: 0, endSample: samples(2.5), closedBySilence: true))
    }

    func testAccumulatesSpeechAcrossMultipleTurnsBeforeClosing() {
        var chunker = MeetingChunker(config: MeetingChunkerConfig(sampleRate: sr))
        // Two 1.2 s speech bursts, separated by a short non-closing gap:
        // neither burst alone reaches 2 s, but together they do.
        XCTAssertNil(chunker.handle(.speechStart(sampleIndex: samples(0))))
        XCTAssertNil(chunker.handle(.speechEnd(sampleIndex: samples(1.2))))
        XCTAssertNil(chunker.handle(.speechStart(sampleIndex: samples(1.5))))
        let boundary = chunker.handle(.speechEnd(sampleIndex: samples(2.7)))
        XCTAssertNotNil(boundary)
        XCTAssertTrue(boundary!.closedBySilence)
        XCTAssertEqual(boundary!.endSample, samples(2.7))
    }

    func testForceClosesAtMaxDurationDuringContinuousSpeech() {
        var chunker = MeetingChunker(config: MeetingChunkerConfig(maxChunkDuration: 30, sampleRate: sr))
        XCTAssertNil(chunker.handle(.speechStart(sampleIndex: samples(0))))
        // No speechEnd ever arrives (one long uninterrupted sentence); the
        // periodic `advance` call must still force-close at 30 s.
        for t in stride(from: 1.0, through: 29.0, by: 1.0) {
            XCTAssertNil(chunker.advance(toSample: samples(t)))
        }
        let boundary = chunker.advance(toSample: samples(30.0))
        XCTAssertNotNil(boundary)
        XCTAssertFalse(boundary!.closedBySilence)
        XCTAssertEqual(boundary!.endSample, samples(30.0))
    }

    func testForceCloseDuringSilenceAlsoWorks() {
        var chunker = MeetingChunker(config: MeetingChunkerConfig(maxChunkDuration: 30, sampleRate: sr))
        // Some speech under the minimum, then dead air past the cap.
        XCTAssertNil(chunker.handle(.speechStart(sampleIndex: samples(0))))
        XCTAssertNil(chunker.handle(.speechEnd(sampleIndex: samples(0.5))))
        let boundary = chunker.advance(toSample: samples(31.0))
        XCTAssertNotNil(boundary)
        XCTAssertFalse(boundary!.closedBySilence)
    }

    func testNextChunkStartsRightAfterThePreviousBoundary() {
        var chunker = MeetingChunker(config: MeetingChunkerConfig(sampleRate: sr))
        XCTAssertNil(chunker.handle(.speechStart(sampleIndex: samples(0))))
        let first = chunker.handle(.speechEnd(sampleIndex: samples(2.5)))
        XCTAssertNotNil(first)

        XCTAssertNil(chunker.handle(.speechStart(sampleIndex: samples(3.0))))
        let second = chunker.handle(.speechEnd(sampleIndex: samples(5.5)))
        XCTAssertNotNil(second)
        XCTAssertEqual(second!.startSample, first!.endSample)
    }

    func testMaxDurationCapResetsAfterAForceClose() {
        var chunker = MeetingChunker(config: MeetingChunkerConfig(maxChunkDuration: 10, sampleRate: sr))
        XCTAssertNil(chunker.handle(.speechStart(sampleIndex: samples(0))))
        let forced = chunker.advance(toSample: samples(10))
        XCTAssertNotNil(forced)
        // The cap is relative to the new chunk's own start, not the meeting's.
        XCTAssertNil(chunker.advance(toSample: samples(15)))
        let second = chunker.advance(toSample: samples(20))
        XCTAssertNotNil(second)
        XCTAssertEqual(second!.startSample, samples(10))
    }
}
