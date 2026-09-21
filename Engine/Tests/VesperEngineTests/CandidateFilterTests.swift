import XCTest
@testable import VesperEngine

/// `CandidateFilter`'s threshold (0.5) is deliberately loose - it only has to
/// get the plausible candidates down to `maxCandidates` before the real
/// acoustic spotter/rescorer runs, not achieve final precision on text alone.
/// A generic English word can still score >= 0.5 against an unrelated
/// vocabulary term by Jaro-Winkler alone (e.g. sharing two letters in a
/// medium-length word) - that's expected and is why precision is verified
/// end-to-end against real audio in the bench (`zumbo-cli bench`, see
/// Engine/README.md), not by asserting zero text-only noise here.
final class CandidateFilterTests: XCTestCase {
    private func index(_ terms: [(String, [String])]) -> CandidateFilter.Index {
        CandidateFilter.Index(terms: terms)
    }

    func testSelectsAPlausibleAlias() {
        let idx = index([("useEffect", ["use effect"]), ("Kubernetes", ["kubernetes"])])
        let kept = CandidateFilter.select(
            transcript: "I moved the fetch into use effect and kept the counter", index: idx)
        XCTAssertTrue(kept.contains("useEffect"))
    }

    func testExactAliasAlwaysWins() {
        let idx = index([("Kubernetes", ["kubernetes"]), ("Xcode", ["x code"])])
        let kept = CandidateFilter.select(transcript: "run kubectl against kubernetes", index: idx)
        XCTAssertTrue(kept.contains("Kubernetes"))
    }

    func testAlwaysIncludeSurvivesRegardlessOfScore() {
        let idx = index([("Kubernetes", ["kubernetes"])])
        let kept = CandidateFilter.select(
            transcript: "let's grab coffee later today", index: idx, alwaysInclude: ["Kubernetes"])
        XCTAssertEqual(kept, ["Kubernetes"])
    }

    func testEmptyTranscriptSelectsOnlyAlwaysInclude() {
        let idx = index([("Kubernetes", ["kubernetes"]), ("Xcode", ["x code"])])
        let kept = CandidateFilter.select(transcript: "", index: idx, alwaysInclude: ["Xcode"])
        XCTAssertEqual(kept, ["Xcode"])
    }

    func testCapsAtMaxCandidates() {
        // Every term's alias is a plausible match for a 1-word transcript
        // ("term0".."term99" all close in edit distance to "term"), so this
        // exercises the maxCandidates cap rather than the similarity gate.
        let terms = (0..<100).map { ("term\($0)", ["term\($0)"]) }
        let idx = index(terms)
        let kept = CandidateFilter.select(transcript: "term", index: idx)
        XCTAssertLessThanOrEqual(kept.count, CandidateFilter.maxCandidates)
    }

    func testJaroWinklerIdentityAndEmpty() {
        XCTAssertEqual(jaroWinkler(Array("kubectl"), Array("kubectl")), 1.0)
        XCTAssertEqual(jaroWinkler(Array(""), Array("kubectl")), 0.0)
        XCTAssertGreaterThan(jaroWinkler(Array("kubectl"), Array("cube c t l")), 0.5)
    }
}
