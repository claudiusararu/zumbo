import XCTest
@testable import VesperEngine

final class DevContextTests: XCTestCase {
    func testModeOffNeverBoosts() {
        let gate = DevContextGate(mode: .off)
        let decision = gate.evaluate(transcript: "deploy the kubectl config to the cluster")
        XCTAssertFalse(decision.shouldBoost)
    }

    func testModeAlwaysAlwaysBoosts() {
        let gate = DevContextGate(mode: .always)
        let decision = gate.evaluate(transcript: "what should I have for lunch")
        XCTAssertTrue(decision.shouldBoost)
    }

    func testAutoModeBoostsOnDevHeavyTranscript() {
        let gate = DevContextGate(mode: .auto)
        let decision = gate.evaluate(
            transcript: "deploy the function config to the endpoint and check the database query")
        XCTAssertTrue(decision.shouldBoost)
        XCTAssertGreaterThanOrEqual(decision.score, gate.threshold)
    }

    func testAutoModeDoesNotBoostOnPlainTranscriptWithNoHistory() {
        let gate = DevContextGate(mode: .auto)
        let decision = gate.evaluate(transcript: "let's get pizza for dinner tonight")
        XCTAssertFalse(decision.shouldBoost)
    }

    func testDictionaryHitsContributeToScore() {
        let gate = DevContextGate(mode: .auto)
        let decision = gate.evaluate(transcript: "open the file please", dictionaryHits: 2)
        XCTAssertTrue(decision.shouldBoost)
    }

    func testMemoryKeepsTopicStickyAfterOneNeutralDictation() {
        // Per NOTES.md: "stays dev until speech drifts away for several
        // dictations" - one neutral sentence right after a dev-heavy one
        // should still lean dev, thanks to decayed memory.
        let gate = DevContextGate(mode: .auto)
        _ = gate.evaluate(transcript: "deploy the function config to the endpoint and check the query")
        let second = gate.evaluate(transcript: "sounds good, let's do that")
        XCTAssertGreaterThan(second.score, 0)
    }

    func testMemoryDecaysAwayAfterSeveralNeutralDictations() {
        let gate = DevContextGate(mode: .auto)
        _ = gate.evaluate(transcript: "deploy the function config to the endpoint and check the query")
        var last = DevContextDecision(shouldBoost: false, score: 0, reason: "")
        for _ in 0..<6 {
            last = gate.evaluate(transcript: "let's get pizza for dinner")
        }
        XCTAssertFalse(last.shouldBoost)
    }

    func testFrontmostAppIsATieBreakerNotADecider() {
        let gate = DevContextGate(mode: .auto)
        let withoutBonus = gate.evaluate(transcript: "let's get pizza for dinner", frontmostBundleID: nil)
        let withBonus = gate.evaluate(transcript: "let's get pizza for dinner", frontmostBundleID: "com.apple.dt.Xcode")
        // The bonus nudges the score but never crosses the threshold on its own.
        XCTAssertGreaterThan(withBonus.score, withoutBonus.score)
        XCTAssertFalse(withBonus.shouldBoost)
    }

    func testResetMemoryClearsStickiness() {
        let gate = DevContextGate(mode: .auto)
        _ = gate.evaluate(transcript: "deploy the function config to the endpoint and check the query")
        gate.resetMemory()
        let after = gate.evaluate(transcript: "let's get pizza for dinner")
        XCTAssertFalse(after.shouldBoost)
    }
}
