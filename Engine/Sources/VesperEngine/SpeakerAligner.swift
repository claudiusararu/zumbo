import FluidAudio
import Foundation

/// Assigns a stable, meeting-wide 1-based speaker number to each diarizer
/// speaker index, in order of first appearance. Sortformer tracks up to 4
/// speaker slots (0...3); this turns "slot 2" into "Speaker 1" the first time
/// it is ever seen, "Speaker 2" the next new slot, and so on, and never
/// reassigns a number once given (a speaker who goes quiet and comes back
/// keeps their number).
public final class SpeakerNumbering {
    private var displayNumbers: [Int: Int] = [:]
    private var nextNumber = 1

    public init() {}

    /// The stable "Speaker N" label for a diarizer speaker index, assigning a
    /// fresh number the first time this index is seen.
    public func label(for speakerIndex: Int) -> String {
        "Speaker \(number(for: speakerIndex))"
    }

    public func number(for speakerIndex: Int) -> Int {
        if let existing = displayNumbers[speakerIndex] { return existing }
        let assigned = nextNumber
        displayNumbers[speakerIndex] = assigned
        nextNumber += 1
        return assigned
    }
}

/// Aligns one chunk's ASR word timings (chunk-relative) against the
/// diarizer's speaker timeline (meeting-relative) to produce labeled
/// paragraphs, and merges consecutive same-speaker chunks/paragraphs into one
/// paragraph rather than one per chunk.
///
/// Pure and model-free: it only reads `WordTiming` and `DiarizerSegment`
/// (plain FluidAudio value types, no CoreML), so it is fully unit-testable.
public enum SpeakerAligner {

    /// One paragraph's worth of aligned text, ready to hand to
    /// `HistoryStore.appendMeetingParagraph`.
    public struct AlignedParagraph: Sendable, Equatable {
        /// "Speaker 1", or nil when no segment (finalized or tentative)
        /// covers this text - diarization not ready yet, or labels are off.
        public let speakerLabel: String?
        public let text: String
        /// Meeting-relative start time of the first word in the paragraph.
        public let startTime: TimeInterval
    }

    /// - Parameters:
    ///   - words: Word timings from this chunk's transcription, relative to
    ///     the chunk's own start (0 = the chunk's first sample).
    ///   - chunkOffset: The chunk's start time within the whole meeting, so
    ///     word times can be compared against the diarizer's meeting-relative
    ///     segments.
    ///   - finalizedSegments: Diarizer segments already finalized.
    ///   - tentativeSegments: Diarizer segments not yet finalized - used as a
    ///     fallback where no finalized segment covers a word, per spec.
    ///   - numbering: Nil disables labeling entirely (speaker labels off, or
    ///     the diarizer is unavailable): every paragraph comes back with a
    ///     nil `speakerLabel`, split only on silence (never split on
    ///     speaker, since there is no speaker signal).
    public static func align(
        words: [WordTiming],
        chunkOffset: TimeInterval,
        finalizedSegments: [DiarizerSegment],
        tentativeSegments: [DiarizerSegment],
        numbering: SpeakerNumbering?
    ) -> [AlignedParagraph] {
        guard !words.isEmpty else { return [] }

        guard let numbering else {
            let text = words.map(\.word).joined(separator: " ")
            return [AlignedParagraph(speakerLabel: nil, text: text, startTime: chunkOffset + words[0].startTime)]
        }

        // Resolve each word to a speaker index (or nil), using the midpoint
        // of the word so a word whose span straddles a segment boundary
        // still lands on the segment that covers most of it.
        let resolved: [(word: WordTiming, speakerIndex: Int?)] = words.map { word in
            let absoluteMid = chunkOffset + (word.startTime + word.endTime) / 2
            let index = speakerIndex(at: absoluteMid, finalized: finalizedSegments, tentative: tentativeSegments)
            return (word, index)
        }

        var paragraphs: [AlignedParagraph] = []
        var currentSpeaker: Int??  // Optional<Optional<Int>>: nil = no run started yet
        var currentWords: [String] = []
        var currentStart: TimeInterval = 0

        func flush() {
            guard !currentWords.isEmpty else { return }
            let label = (currentSpeaker.flatMap { $0 }).map { numbering.label(for: $0) }
            paragraphs.append(
                AlignedParagraph(speakerLabel: label, text: currentWords.joined(separator: " "), startTime: currentStart))
            currentWords = []
        }

        for (word, speakerIndex) in resolved {
            if currentSpeaker == nil || currentSpeaker! != speakerIndex {
                flush()
                currentSpeaker = speakerIndex
                currentStart = chunkOffset + word.startTime
            }
            currentWords.append(word.word)
        }
        flush()

        return paragraphs
    }

    /// A word within this many seconds of a segment's edge, but not covered
    /// by any segment, still counts as that segment's speaker - the
    /// diarizer's frame rate (80 ms) and its confirm latency at a chunk's
    /// very first words otherwise leave a stray unlabeled word or two ahead
    /// of every speaker change.
    private static let nearestMatchToleranceSeconds: Double = 0.6

    /// The speaker whose segment covers `time`, preferring a finalized
    /// segment; falls back to a tentative one when no finalized segment
    /// covers it (diarization for the tail of the chunk not confirmed yet);
    /// falls back further to the nearest segment edge within
    /// `nearestMatchToleranceSeconds`. Nil when nothing is close enough -
    /// the chunk truly has no speaker segment.
    private static func speakerIndex(
        at time: TimeInterval, finalized: [DiarizerSegment], tentative: [DiarizerSegment]
    ) -> Int? {
        if let match = finalized.first(where: { covers($0, time) }) {
            return match.speakerIndex
        }
        if let match = tentative.first(where: { covers($0, time) }) {
            return match.speakerIndex
        }
        let all = finalized + tentative
        guard !all.isEmpty else { return nil }
        let nearest = all.min { edgeDistance($0, time) < edgeDistance($1, time) }
        guard let nearest, edgeDistance(nearest, time) <= nearestMatchToleranceSeconds else { return nil }
        return nearest.speakerIndex
    }

    private static func edgeDistance(_ segment: DiarizerSegment, _ time: TimeInterval) -> Double {
        let start = Double(segment.startTime), end = Double(segment.endTime)
        if time < start { return start - time }
        if time > end { return time - end }
        return 0
    }

    private static func covers(_ segment: DiarizerSegment, _ time: TimeInterval) -> Bool {
        Double(segment.startTime) <= time && time < Double(segment.endTime)
    }
}
