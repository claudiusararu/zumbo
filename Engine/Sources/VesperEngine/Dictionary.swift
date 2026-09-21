import Foundation

/// A user- or starter-pack dictionary entry: a canonical developer spelling,
/// its spoken aliases, and whether it currently contributes to the vocabulary
/// fed to boosting and to `Replacer`.
public struct DictionaryTerm: Codable, Equatable, Sendable {
    public var text: String
    public var aliases: [String]
    public var enabled: Bool
    /// Per-term similarity floor, carried straight through to the boosting
    /// vocabulary. The starter pack sets it on common English words (104 of
    /// the 656 terms) so they only fire on a near-exact match.
    public var minSimilarity: Float?
    /// Which starter pack this term came from (`seeds/packs/*.json`'s file
    /// name). `nil` for a term the user taught themselves. See
    /// `UserDictionaryStore.enabledPacks`.
    public var pack: String?
    /// How this entry entered the dictionary: `"typed"` for a term added by
    /// hand in Settings > Dictionary > My words (the default), `"taught"` for
    /// one created from a history card's Teach popover. Decodes to `"typed"`
    /// when the key is missing, so dictionaries saved before this field
    /// existed still load.
    public var source: String
    /// When this entry was created, for "My words"'s newest-first ordering.
    /// Decodes to `.distantPast` when the key is missing, so dictionaries
    /// saved before this field existed still load and simply sort to the
    /// bottom instead of failing.
    public var addedAt: Date

    public init(
        text: String, aliases: [String], enabled: Bool = true, minSimilarity: Float? = nil,
        pack: String? = nil, source: String = "typed", addedAt: Date = Date()
    ) {
        self.text = text
        self.aliases = aliases
        self.enabled = enabled
        self.minSimilarity = minSimilarity
        self.pack = pack
        self.source = source
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case text, aliases, enabled, minSimilarity, pack, source, addedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        aliases = try container.decode([String].self, forKey: .aliases)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        minSimilarity = try container.decodeIfPresent(Float.self, forKey: .minSimilarity)
        pack = try container.decodeIfPresent(String.self, forKey: .pack)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "typed"
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? .distantPast
    }
}

/// Loads the shipped starter pack, persists the user's own dictionary as JSON
/// in Application Support, and merges the two into the plain `[VocabTerm]`
/// list `Transcriber` and `Replacer` consume.
public enum VesperDictionary {
    /// The shipped developer-vocabulary starter pack (`Resources/vocab-dev-starter.json`).
    public static func starterPack() -> [DictionaryTerm] {
        guard let url = Bundle.module.url(forResource: "vocab-dev-starter", withExtension: "json"),
              let file = VocabFile.load(from: url)
        else { return [] }
        return file.terms.map {
            DictionaryTerm(
                text: $0.text, aliases: $0.aliases, enabled: true, minSimilarity: $0.minSimilarity,
                pack: $0.pack)
        }
    }

    /// Drops terms whose pack isn't in `enabledPacks`. `nil` means every pack
    /// is enabled (the default - onboarding hasn't run, or ran with
    /// everything on); a term with no pack (user-taught) is never dropped.
    public static func filterByPacks(_ terms: [DictionaryTerm], enabledPacks: Set<String>?) -> [DictionaryTerm] {
        guard let enabledPacks else { return terms }
        return terms.filter { term in
            guard let pack = term.pack else { return true }
            return enabledPacks.contains(pack)
        }
    }

    public static func defaultStorageURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Vesper", isDirectory: true)
            .appendingPathComponent("dictionary.json")
    }

    public static func loadUserTerms(from url: URL = defaultStorageURL()) -> [DictionaryTerm] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DictionaryTerm].self, from: data)) ?? []
    }

    public static func saveUserTerms(_ terms: [DictionaryTerm], to url: URL = defaultStorageURL()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(terms)
        try data.write(to: url, options: .atomic)
    }

    /// Merges starter and user terms: a user entry with the same `text`
    /// (case-insensitive) replaces the starter entry entirely (aliases are the
    /// user's, not unioned - the user is expected to edit via "Teach", which
    /// starts from the starter entry's aliases). Disabled entries are dropped.
    /// Order: user-only terms first (most likely to be actively taught), then
    /// starter terms not overridden.
    public static func mergedVocabulary(starter: [DictionaryTerm], user: [DictionaryTerm]) -> [VocabTerm] {
        let userTextsLower = Set(user.map { $0.text.lowercased() })
        let keptStarter = starter.filter { !userTextsLower.contains($0.text.lowercased()) }
        let all = user + keptStarter
        return all.filter(\.enabled).map {
            VocabTerm(text: $0.text, aliases: $0.aliases, minSimilarity: $0.minSimilarity, pack: $0.pack)
        }
    }

    /// Writes a `[VocabTerm]` list to the JSON shape `Transcriber.enableBoosting`
    /// and `Replacer` expect: `{"terms":[{"text":...,"aliases":[...]}]}`.
    public static func writeVocabularyJSON(_ terms: [VocabTerm], to url: URL) throws {
        let data = try JSONEncoder().encode(VocabFile(terms: terms))
        try data.write(to: url, options: .atomic)
    }
}

/// Simple in-memory + on-disk store for the user's own dictionary entries,
/// for the app's Dictionary settings screen.
public final class UserDictionaryStore {
    private let storageURL: URL
    public private(set) var terms: [DictionaryTerm]

    /// Which starter packs currently contribute to the merged vocabulary.
    /// `nil` (the default) means every pack is enabled. The app sets this
    /// from onboarding once pack selection exists; until then, terms from
    /// every pack enter the candidate pool. User-authored terms (`pack ==
    /// nil`) are never filtered by this.
    public var enabledPacks: Set<String>?

    public init(storageURL: URL = VesperDictionary.defaultStorageURL()) {
        self.storageURL = storageURL
        self.terms = VesperDictionary.loadUserTerms(from: storageURL)
    }

    public func add(_ term: DictionaryTerm) throws {
        if let index = terms.firstIndex(where: { $0.text.caseInsensitiveCompare(term.text) == .orderedSame }) {
            terms[index] = term
        } else {
            terms.append(term)
        }
        try save()
    }

    public func remove(text: String) throws {
        terms.removeAll { $0.text.caseInsensitiveCompare(text) == .orderedSame }
        try save()
    }

    public func setEnabled(text: String, enabled: Bool) throws {
        guard let index = terms.firstIndex(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { return }
        terms[index].enabled = enabled
        try save()
    }

    public func save() throws {
        try VesperDictionary.saveUserTerms(terms, to: storageURL)
    }

    /// The merged vocabulary this store currently contributes, ready for
    /// `Transcriber.enableBoosting` / `RulesEngine`.
    public func mergedVocabulary(starter: [DictionaryTerm] = VesperDictionary.starterPack()) -> [VocabTerm] {
        let allowedStarter = VesperDictionary.filterByPacks(starter, enabledPacks: enabledPacks)
        return VesperDictionary.mergedVocabulary(starter: allowedStarter, user: terms)
    }
}
