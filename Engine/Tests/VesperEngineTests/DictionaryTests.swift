import XCTest
@testable import VesperEngine

final class DictionaryTests: XCTestCase {
    func testStarterPackLoads() {
        let starter = VesperDictionary.starterPack()
        XCTAssertFalse(starter.isEmpty)
        XCTAssertTrue(starter.contains { $0.text == "kubectl" })
        XCTAssertTrue(starter.contains { $0.text == "PostgreSQL" })
    }

    func testStarterPackAliasesArePresent() {
        let starter = VesperDictionary.starterPack()
        let kubectl = starter.first { $0.text == "kubectl" }
        XCTAssertNotNil(kubectl)
        XCTAssertTrue(kubectl?.aliases.contains("cube c t l") ?? false)
    }

    func testMergeUserOverridesStarterByText() {
        let starter = [DictionaryTerm(text: "npm", aliases: ["n p m"])]
        let user = [DictionaryTerm(text: "NPM", aliases: ["and pee em"])]
        let merged = VesperDictionary.mergedVocabulary(starter: starter, user: user)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.text, "NPM")
        XCTAssertEqual(merged.first?.aliases, ["and pee em"])
    }

    func testMergeKeepsNonOverlappingStarterTerms() {
        let starter = [
            DictionaryTerm(text: "npm", aliases: ["n p m"]),
            DictionaryTerm(text: "Xcode", aliases: ["x code"]),
        ]
        let user = [DictionaryTerm(text: "Typesense", aliases: ["type sense"])]
        let merged = VesperDictionary.mergedVocabulary(starter: starter, user: user)
        let texts = Set(merged.map(\.text))
        XCTAssertEqual(texts, ["npm", "Xcode", "Typesense"])
    }

    func testMergeDropsDisabledTerms() {
        let starter = [
            DictionaryTerm(text: "npm", aliases: ["n p m"], enabled: true),
            DictionaryTerm(text: "Xcode", aliases: ["x code"], enabled: false),
        ]
        let merged = VesperDictionary.mergedVocabulary(starter: starter, user: [])
        XCTAssertEqual(merged.map(\.text), ["npm"])
    }

    func testWriteVocabularyJSONRoundTrips() throws {
        let terms = [VocabTerm(text: "Typesense", aliases: ["type sense"])]
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zumbo-test-vocab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try VesperDictionary.writeVocabularyJSON(terms, to: tmp)
        let loaded = VocabFile.load(from: tmp)
        XCTAssertEqual(loaded?.terms, terms)
    }

    func testUserDictionaryStoreAddRemovePersist() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zumbo-test-dictionary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = UserDictionaryStore(storageURL: tmp)
        try store.add(DictionaryTerm(text: "Typesense", aliases: ["type sense"]))
        XCTAssertEqual(store.terms.count, 1)

        // A fresh store reading the same file sees the persisted entry.
        let reloaded = UserDictionaryStore(storageURL: tmp)
        XCTAssertEqual(reloaded.terms.first?.text, "Typesense")

        try store.setEnabled(text: "Typesense", enabled: false)
        XCTAssertEqual(store.terms.first?.enabled, false)
        XCTAssertTrue(store.mergedVocabulary(starter: []).isEmpty)

        try store.remove(text: "Typesense")
        XCTAssertTrue(store.terms.isEmpty)
    }

    func testDictionaryTermDecodesMissingAddedAtAsDistantPast() throws {
        let json = """
        {"text":"kubectl","aliases":["cube c t l"],"enabled":true}
        """.data(using: .utf8)!
        let term = try JSONDecoder().decode(DictionaryTerm.self, from: json)
        XCTAssertEqual(term.addedAt, .distantPast)
    }

    func testUserDictionaryStoreAddIsCaseInsensitiveUpdate() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zumbo-test-dictionary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = UserDictionaryStore(storageURL: tmp)
        try store.add(DictionaryTerm(text: "Typesense", aliases: ["type sense"]))
        try store.add(DictionaryTerm(text: "typesense", aliases: ["type census"]))
        XCTAssertEqual(store.terms.count, 1)
        XCTAssertEqual(store.terms.first?.text, "typesense")
    }
}
