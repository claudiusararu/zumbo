import Foundation

/// A dictionary entry: a canonical developer spelling plus the spoken aliases
/// that should be rewritten back to it. Matches the JSON shape Transcriber's
/// vocabulary boosting and Replacer both consume: `{"terms":[{"text":...,"aliases":[...]}]}`.
public struct VocabTerm: Codable, Equatable, Sendable {
    public let text: String
    public let aliases: [String]
    /// Per-term similarity floor for the boosting pass. FluidAudio 0.15.7
    /// decodes this key per entry (`CustomVocabularyEntry.minSimilarity`) and
    /// prefers it over the vocabulary-wide value, which is how a common English
    /// word like "Jest" or "Rust" can be boosted only on a near-exact match.
    /// Optional, so it is omitted from the JSON when nil.
    public let minSimilarity: Float?
    /// Which starter pack (`seeds/packs/*.json`'s file name, e.g. "ai",
    /// "devtools") this term came from. `nil` for a user-taught term (there is
    /// no pack to disable it by). Carried through so `enabledPacks` can drop
    /// whole packs from the candidate pool before boosting ever sees them.
    public let pack: String?

    public init(text: String, aliases: [String], minSimilarity: Float? = nil, pack: String? = nil) {
        self.text = text
        self.aliases = aliases
        self.minSimilarity = minSimilarity
        self.pack = pack
    }
}

/// Top-level shape of a vocabulary JSON file.
public struct VocabFile: Codable, Sendable {
    public let terms: [VocabTerm]

    public init(terms: [VocabTerm]) {
        self.terms = terms
    }

    public static func load(atPath path: String) -> VocabFile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(VocabFile.self, from: data)
    }

    public static func load(from url: URL) -> VocabFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VocabFile.self, from: data)
    }
}

/// Deterministic post-processor: maps spoken aliases back to canonical developer
/// spellings, longest alias first, on word boundaries, case-insensitively.
///
/// Ported from the dictation-spike's `seeds/Replacement.swift` (bug-fixed version:
/// canonical spellings that contain punctuation, such as `package.json`, are
/// protected once produced, so a later standalone-term rule can't match a
/// substring of an already-correct canonical span and mangle it).
public struct Replacer {
    private let pairs: [(alias: String, canonical: String)]
    /// Lowercased canonical spellings, for the echoed-suffix cleanup.
    private let canonicalSet: Set<String>

    public init(terms: [VocabTerm]) {
        var p: [(String, String)] = []
        for t in terms {
            // Terms that are also ordinary English words (marked minSimilarity
            // >= 0.9 in the packs: Terminal, Linear, Signal...) are never
            // rewritten by text match: "the terminal" must stay lowercase.
            // Boosting may still pick them on a near-exact acoustic match.
            if let m = t.minSimilarity, m >= 0.9 { continue }
            p.append((t.text, t.text))
            for a in t.aliases { p.append((a, t.text)) }
        }
        // Longest alias first so "package dot jason" wins over "jason".
        canonicalSet = Set(terms.map { $0.text.lowercased() })
        pairs = p.sorted { lhs, rhs in
            if lhs.0.count != rhs.0.count { return lhs.0.count > rhs.0.count }
            return lhs.0 < rhs.0
        }.map { (alias: $0.0, canonical: $0.1) }
    }

    private static let punctuation: [(String, String)] = [
        ("open paren", "("), ("close paren", ")"),
        ("open parenthesis", "("), ("close parenthesis", ")"),
        ("new line", "\n"), ("newline", "\n"),
    ]

    /// A canonical spelling that contains punctuation (e.g. "package.json") creates a
    /// span that a later, unrelated standalone-term rule can match a substring of (e.g.
    /// the "JSON" rule's "json" alias matching the "json" inside "package.json", which
    /// already is canonical and must not be touched again). Terms whose canonical text
    /// is plain letters/digits/spaces cannot create that trap, since word-boundary
    /// matching already keeps single words from bleeding into each other.
    private static func hasInternalPunctuation(_ text: String) -> Bool {
        text.contains { !($0.isLetter || $0.isNumber || $0 == " ") }
    }

    public func apply(_ input: String) -> String {
        var out = input
        let protectedPairs = pairs.filter { Replacer.hasInternalPunctuation($0.canonical) }
        let normalPairs = pairs.filter { !Replacer.hasInternalPunctuation($0.canonical) }

        // Canonicalize punctuated terms first ("package dot json" -> "package.json").
        for (alias, canonical) in protectedPairs {
            out = Replacer.replace(in: out, phrase: alias, with: canonical)
        }

        // Mask the resulting canonical spans so no later rule (standalone-term or
        // punctuation) can fire inside them.
        var placeholders: [(placeholder: String, canonical: String)] = []
        for canonical in Set(protectedPairs.map { $0.canonical }) where out.contains(canonical) {
            let placeholder = "\u{0}PROTECTED\(placeholders.count)\u{0}"
            out = out.replacingOccurrences(of: canonical, with: placeholder)
            placeholders.append((placeholder, canonical))
        }

        for (alias, canonical) in normalPairs {
            out = Replacer.replace(in: out, phrase: alias, with: canonical)
        }
        for (phrase, symbol) in Replacer.punctuation {
            out = Replacer.replace(in: out, phrase: phrase, with: symbol)
        }
        out = Replacer.replace(in: out, phrase: "dash dash", with: "--")

        for (placeholder, canonical) in placeholders {
            out = out.replacingOccurrences(of: placeholder, with: canonical)
        }
        out = dropEchoedSuffix(in: out)
        return out
    }

    /// Boosting can canonicalize the first part of a spoken term and leave the
    /// tail behind: "Postgres SQL" -> "PostgreSQL SQL". When a canonical term
    /// is followed by a word that is a suffix of that same term (case-
    /// insensitive, at least two characters), the echoed word is dropped.
    /// Only canonical dictionary spellings qualify as the head, so ordinary
    /// English ("this is") is never touched.
    func dropEchoedSuffix(in text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count > 1 else { return text }
        var out: [String] = []
        var i = 0
        while i < words.count {
            let head = words[i]
            if i + 1 < words.count, canonicalSet.contains(head.lowercased()) {
                let next = words[i + 1]
                let core = next.trimmingCharacters(in: .punctuationCharacters)
                if core.count >= 2, core.count < head.count, head.lowercased().hasSuffix(core.lowercased()) {
                    // keep the head, carry any trailing punctuation of the echoed word
                    let trailing = next.hasSuffix(core) ? "" : String(next.drop(while: { !$0.isPunctuation }))
                    out.append(head + trailing)
                    i += 2
                    continue
                }
            }
            out.append(head)
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// Word-boundary aware, case-insensitive phrase replacement. Spoken text has
    /// no reliable punctuation, so a boundary is any non-alphanumeric character.
    static func replace(in text: String, phrase: String, with replacement: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
            .replacingOccurrences(of: "\\ ", with: "[ ]+")
            .replacingOccurrences(of: " ", with: "[ ]+")
        let pattern = "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        let body = NSRegularExpression.escapedTemplate(for: replacement)
        return re.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: body)
    }
}
