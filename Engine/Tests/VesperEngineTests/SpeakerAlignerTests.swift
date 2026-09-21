import FluidAudio
import XCTest
@testable import VesperEngine

/// Pure, model-free: builds plain `WordTiming`/`DiarizerSegment` value types
/// by hand (no CoreML, no real diarizer) and checks the alignment output.
final class SpeakerAlignerTests: XCTestCase {

    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> WordTiming {
        WordTiming(word: text, startTime: start, endTime: end)
    }

    private func segment(_ speaker: Int, _ start: Float, _ end: Float) -> DiarizerSegment {
        DiarizerSegment(speakerIndex: speaker, startTime: start, endTime: end, finalized: true, frameDurationSeconds: 0.08)
    }

    func testSingleSpeakerYieldsOneLabeledParagraph() {
        let words = [word("hello", 0, 0.4), word("there", 0.4, 0.9)]
        let numbering = SpeakerNumbering()
        let result = SpeakerAligner.align(
            words: words, chunkOffset: 10, finalizedSegments: [segment(0, 10, 20)], tentativeSegments: [],
            numbering: numbering)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(result[0].text, "hello there")
        XCTAssertEqual(result[0].startTime, 10.0, accuracy: 0.001)
    }

    func testSpeakerChangeSplitsIntoTwoParagraphs() {
        // Chunk covers meeting time 10...12; speaker 0 talks 10...11, speaker
        // 1 takes over at 11.
        let words = [
            word("first", 0, 0.4),     // absolute 10.0-10.4 -> speaker 0
            word("part", 0.4, 0.9),    // absolute 10.4-10.9 -> speaker 0
            word("second", 1.1, 1.6),  // absolute 11.1-11.6 -> speaker 1
            word("part", 1.6, 2.0),    // absolute 11.6-12.0 -> speaker 1
        ]
        let numbering = SpeakerNumbering()
        let result = SpeakerAligner.align(
            words: words, chunkOffset: 10,
            finalizedSegments: [segment(0, 10, 11), segment(1, 11, 12)],
            tentativeSegments: [], numbering: numbering)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(result[0].text, "first part")
        XCTAssertEqual(result[1].speakerLabel, "Speaker 2")
        XCTAssertEqual(result[1].text, "second part")
    }

    func testWordStraddlingABoundaryResolvesByMidpoint() {
        // Word spans 10.8...11.4 (straddling the 11.0 boundary); its midpoint
        // (11.1) falls in speaker 1's segment, so the whole word goes there.
        let words = [word("straddle", 0.8, 1.4)]
        let numbering = SpeakerNumbering()
        let result = SpeakerAligner.align(
            words: words, chunkOffset: 10,
            finalizedSegments: [segment(0, 10, 11), segment(1, 11, 12)],
            tentativeSegments: [], numbering: numbering)
        XCTAssertEqual(result.count, 1)
        // Speaker index 1 is the only one this fresh numbering has ever
        // seen, so it gets display number 1 regardless of its raw index.
        XCTAssertEqual(result[0].speakerLabel, "Speaker 1")
    }

    func testChunkWithNoSpeakerSegmentFallsBackToUnlabeledText() {
        let words = [word("no", 0, 0.2), word("speaker", 0.2, 0.6), word("here", 0.6, 0.9)]
        let numbering = SpeakerNumbering()
        let result = SpeakerAligner.align(
            words: words, chunkOffset: 5, finalizedSegments: [], tentativeSegments: [], numbering: numbering)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].speakerLabel)
        XCTAssertEqual(result[0].text, "no speaker here")
    }

    func testTentativeSegmentIsUsedWhenNoFinalizedSegmentCovers() {
        let words = [word("tentative", 0, 0.5)]
        let numbering = SpeakerNumbering()
        let result = SpeakerAligner.align(
            words: words, chunkOffset: 0, finalizedSegments: [],
            tentativeSegments: [segment(2, 0, 1)], numbering: numbering)
        XCTAssertEqual(result[0].speakerLabel, "Speaker 1")
    }

    func testNumberingIsStableAndOrderedByFirstAppearanceAcrossChunks() {
        let numbering = SpeakerNumbering()
        // First chunk: speaker index 3 talks first.
        let first = SpeakerAligner.align(
            words: [word("hi", 0, 0.3)], chunkOffset: 0,
            finalizedSegments: [segment(3, 0, 1)], tentativeSegments: [], numbering: numbering)
        XCTAssertEqual(first[0].speakerLabel, "Speaker 1")

        // Second chunk: a new speaker index 0 appears, then index 3 again.
        let second = SpeakerAligner.align(
            words: [word("new", 0, 0.3), word("again", 1.3, 1.6)], chunkOffset: 10,
            finalizedSegments: [segment(0, 10, 11), segment(3, 11, 12)], tentativeSegments: [], numbering: numbering)
        XCTAssertEqual(second[0].speakerLabel, "Speaker 2")
        XCTAssertEqual(second[1].speakerLabel, "Speaker 1")
    }

    func testNilNumberingDisablesLabelsEntirely() {
        let words = [word("plain", 0, 0.4), word("text", 0.4, 0.8)]
        let result = SpeakerAligner.align(
            words: words, chunkOffset: 0, finalizedSegments: [segment(0, 0, 1)], tentativeSegments: [],
            numbering: nil)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].speakerLabel)
        XCTAssertEqual(result[0].text, "plain text")
    }

    func testEmptyWordsYieldsNoParagraphs() {
        let result = SpeakerAligner.align(
            words: [], chunkOffset: 0, finalizedSegments: [], tentativeSegments: [], numbering: SpeakerNumbering())
        XCTAssertTrue(result.isEmpty)
    }
}
