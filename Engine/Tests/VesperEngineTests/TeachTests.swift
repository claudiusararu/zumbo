import XCTest
@testable import VesperEngine

final class TeachTests: XCTestCase {

    // MARK: - replaceEverywhere

    func testReplaceEverywhereWholeWordCaseInsensitive() {
        let text = "The Cat sat near the cat door, CAT."
        let result = Teach.replaceEverywhere(in: text, heard: "cat", with: "dog")
        XCTAssertEqual(result, "The dog sat near the dog door, dog.")
    }

    func testReplaceEverywhereDoesNotTouchPartialWord() {
        let text = "The cat browsed a category of category items."
        let result = Teach.replaceEverywhere(in: text, heard: "cat", with: "dog")
        XCTAssertEqual(result, "The dog browsed a category of category items.")
    }

    func testReplaceEverywherePhrase() {
        let text = "Open a pull request, then open pull requests daily."
        let result = Teach.replaceEverywhere(in: text, heard: "pull request", with: "PR")
        XCTAssertEqual(result, "Open a PR, then open pull requests daily.")
    }

    func testReplaceEverywhereBlankHeardIsNoOp() {
        let text = "Nothing changes here."
        XCTAssertEqual(Teach.replaceEverywhere(in: text, heard: "   ", with: "x"), text)
    }

    // MARK: - replaceRange

    func testReplaceRangeReplacesOnlyThatOccurrence() {
        let text = "cat and cat"
        // Second "cat" starts at UTF-16 offset 8, length 3.
        let range = NSRange(location: 8, length: 3)
        let result = Teach.replaceRange(in: text, range: range, with: "dog")
        XCTAssertEqual(result, "cat and dog")
    }

    // MARK: - stripLeadingPrefix

    func testStripsLeadingTimestamp() {
        let (cleaned, prefix) = Teach.stripLeadingPrefix(from: "10:32  a custom 1")
        XCTAssertEqual(cleaned, "a custom 1")
        XCTAssertEqual(prefix, "10:32  ")
    }

    func testStripsLeadingSpeakerLabel() {
        let (cleaned, prefix) = Teach.stripLeadingPrefix(from: "Speaker 1: kubectl apply")
        XCTAssertEqual(cleaned, "kubectl apply")
        XCTAssertEqual(prefix, "Speaker 1: ")
    }

    func testNoPrefixLeavesTextUntouched() {
        let (cleaned, prefix) = Teach.stripLeadingPrefix(from: "kubectl apply")
        XCTAssertEqual(cleaned, "kubectl apply")
        XCTAssertNil(prefix)
    }

    // MARK: - expandToWord

    func testExpandToWordExpandsPartialSelectionInSingleToken() {
        let text = "a category of items"
        // "ateg" inside "category": category starts at offset 2, "ateg" at offset 4, length 4.
        let range = NSRange(location: 4, length: 4)
        let expanded = Teach.expandToWord(in: text, range: range)
        XCTAssertEqual((text as NSString).substring(with: expanded), "category")
    }

    func testExpandToWordLeavesPhraseSelectionAlone() {
        let text = "open a pull request now"
        let range = NSRange(location: 7, length: 12) // "pull request"
        let expanded = Teach.expandToWord(in: text, range: range)
        XCTAssertEqual(expanded, range)
    }

    // MARK: - mergedTerm

    func testMergedTermCreatesNewEntryFromScratch() {
        let term = Teach.mergedTerm(existing: nil, heard: "cube cuttle", correct: "kubectl")
        XCTAssertEqual(term.text, "kubectl")
        XCTAssertEqual(term.aliases, ["cube cuttle"])
        XCTAssertEqual(term.source, "taught")
        XCTAssertTrue(term.enabled)
    }

    func testMergedTermAppendsMissingAliasToExistingEntry() {
        let existing = DictionaryTerm(text: "kubectl", aliases: ["cube c t l"], minSimilarity: 0.8, pack: "devtools")
        let term = Teach.mergedTerm(existing: existing, heard: "cube cuttle", correct: "kubectl")
        XCTAssertEqual(term.aliases, ["cube c t l", "cube cuttle"])
        XCTAssertEqual(term.minSimilarity, 0.8)
        XCTAssertEqual(term.pack, "devtools")
        // The word was already known (typed/pack); teaching an alias doesn't
        // reclassify it as newly taught.
        XCTAssertEqual(term.source, "typed")
    }

    func testMergedTermDoesNotDuplicateExistingAliasCaseInsensitive() {
        let existing = DictionaryTerm(text: "kubectl", aliases: ["cube cuttle"])
        let term = Teach.mergedTerm(existing: existing, heard: "Cube Cuttle", correct: "kubectl")
        XCTAssertEqual(term.aliases, ["cube cuttle"])
    }

    // MARK: - DictionaryTerm source decoding

    func testDictionaryTermDecodesMissingSourceAsTyped() throws {
        let json = """
        {"text":"kubectl","aliases":["cube c t l"],"enabled":true}
        """.data(using: .utf8)!
        let term = try JSONDecoder().decode(DictionaryTerm.self, from: json)
        XCTAssertEqual(term.source, "typed")
    }

    func testDictionaryTermRoundTripsSource() throws {
        let term = DictionaryTerm(text: "kubectl", aliases: ["cube cuttle"], source: "taught")
        let data = try JSONEncoder().encode(term)
        let decoded = try JSONDecoder().decode(DictionaryTerm.self, from: data)
        XCTAssertEqual(decoded.source, "taught")
    }
}
