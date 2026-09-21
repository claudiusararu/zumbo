import Foundation

/// Deterministic post-processor: maps spoken aliases back to canonical developer
/// spellings, longest alias first, on word boundaries, case-insensitively.
struct Replacer {
    private let pairs: [(alias: String, canonical: String)]

    init(terms: [VocabTerm]) {
        var p: [(String, String)] = []
        for t in terms {
            p.append((t.text, t.text))
            for a in t.aliases { p.append((a, t.text)) }
        }
        // Longest alias first so "package dot jason" wins over "jason".
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

    func apply(_ input: String) -> String {
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
        return out
    }

    /// Word-boundary aware, case-insensitive phrase replacement. Spoken text has
    /// no reliable punctuation, so a boundary is any non-alphanumeric character.
    private static func replace(in text: String, phrase: String, with replacement: String) -> String {
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
