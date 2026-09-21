import Foundation

/// Pure-Swift pre-filter that narrows a (possibly large) boosting vocabulary
/// down to the handful of terms that could plausibly be present in one
/// transcript, before the CTC spotter and rescorer ever run.
///
/// This is what makes boosting affordable with the full 1721-term starter
/// pack: the spotter and rescorer's cost scales with vocabulary size (738 ms
/// + 2544 ms at 1721 terms vs 234 ms + 56 ms at 40 terms, Debug - see
/// Engine/README.md), so cutting the list to at most `maxCandidates`
/// plausible candidates before they run is the fix.
///
/// Scoring runs the plain transcript's word n-grams (1-4 words) against every
/// alias and the canonical text of every term, lowercase, using the larger of
/// a Jaro-Winkler string similarity and a consonant-skeleton comparison (a
/// cheap phonetic proxy: strips vowels, so e.g. "colonel" and "kernel" share
/// a skeleton). No model, no I/O, no allocHeavy work beyond arrays - safe to
/// call on every dictation.
public enum CandidateFilter {
    /// Terms scoring at or above this on any alias/n-gram pair are candidates.
    public static let threshold: Double = 0.5
    /// Hard cap on how many non-forced candidates are kept, ranked by score.
    /// Terms in `alwaysInclude` (the user's own dictionary) are added on top
    /// of this cap, never dropped by it.
    public static let maxCandidates = 40

    /// Precomputed per-term data so filtering never re-lowercases or
    /// re-derives a skeleton on the hot path. Built once when the boosting
    /// vocabulary is (re)loaded, keyed by the term's canonical `text` so
    /// callers can map selected keys back to their own term objects.
    public struct Index: Sendable {
        struct Variant {
            let chars: [Character]
            let skeleton: [Character]
            let wordCount: Int
        }
        struct Entry {
            let key: String
            let variants: [Variant]
        }
        let entries: [Entry]

        public init(terms: [(text: String, aliases: [String])]) {
            entries = terms.map { term in
                let all = [term.text] + term.aliases
                let variants = all.map { alias -> Variant in
                    let lower = Array(alias.lowercased())
                    let skel = CandidateFilter.skeleton(lower)
                    let wordCount = alias.split(separator: " ").count
                    return Variant(chars: lower, skeleton: skel, wordCount: max(1, wordCount))
                }
                return Entry(key: term.text, variants: variants)
            }
        }

        public var isEmpty: Bool { entries.isEmpty }
    }

    /// Strips non-letters and vowels, keeping consonants only, as a cheap
    /// phonetic proxy (no dependency on a full metaphone implementation).
    static func skeleton(_ chars: [Character]) -> [Character] {
        chars.filter { $0.isLetter && !"aeiouy".contains($0) }
    }

    private static func skeleton(_ s: String) -> [Character] { skeleton(Array(s)) }

    /// `text` keys (matching `Index.Entry.key`) of the terms to keep: every
    /// key in `alwaysInclude`, plus up to `maxCandidates` more ranked by best
    /// n-gram similarity across all their aliases and the canonical text.
    public static func select(
        transcript: String, index: Index, alwaysInclude: Set<String> = []
    ) -> Set<String> {
        guard !index.isEmpty else { return alwaysInclude }
        let words = transcript.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)

        var result = alwaysInclude
        guard !words.isEmpty else { return result }

        // n-grams of 1...4 words, each pre-split into [Character] once.
        var ngrams: [(chars: [Character], skeleton: [Character], wordCount: Int)] = []
        ngrams.reserveCapacity(words.count * 4)
        let upper = min(4, words.count)
        for n in 1...upper {
            for i in 0...(words.count - n) {
                let phrase = Array(words[i..<(i + n)].joined(separator: " "))
                ngrams.append((phrase, skeleton(phrase), n))
            }
        }

        var scored: [(key: String, score: Double)] = []
        scored.reserveCapacity(64)
        for entry in index.entries {
            if alwaysInclude.contains(entry.key) { continue }
            var best = 0.0
            outer: for variant in entry.variants {
                for ngram in ngrams {
                    // Cheap reject before the O(n*m) Jaro-Winkler call: word
                    // count and character length must be in the same ballpark.
                    guard abs(ngram.wordCount - variant.wordCount) <= 1 else { continue }
                    let lenDiff = abs(ngram.chars.count - variant.chars.count)
                    guard lenDiff <= max(4, variant.chars.count / 2) else { continue }

                    let sim = jaroWinkler(ngram.chars, variant.chars)
                    if sim > best { best = sim }
                    // The skeleton (consonants only) is a much shorter string,
                    // so Jaro-Winkler saturates fast on it - two 4-letter
                    // skeletons sharing 2 characters already score ~0.5. Only
                    // trust it when both skeletons carry enough information
                    // (>= 3 consonants) and hold it to a higher bar than the
                    // direct text comparison.
                    if best < threshold, ngram.skeleton.count >= 3, variant.skeleton.count >= 3 {
                        let skelSim = jaroWinkler(ngram.skeleton, variant.skeleton)
                        if skelSim > best, skelSim >= threshold + 0.15 { best = skelSim }
                    }
                    if best > 0.999 { break outer }
                }
            }
            if best >= threshold { scored.append((entry.key, best)) }
        }

        scored.sort { $0.score > $1.score }
        for s in scored {
            guard result.count - alwaysInclude.count < maxCandidates else { break }
            result.insert(s.key)
        }
        return result
    }
}

/// Normalized Jaro-Winkler similarity in [0, 1]. Pure Swift, operating on
/// `[Character]` so callers can precompute/reuse arrays instead of
/// re-decoding `String`s in the hot loop.
///
/// The match bitmaps are `UInt64`s, not heap-allocated `[Bool]` arrays: this
/// runs O(vocabulary size) times per dictation (see `CandidateFilter`), so
/// avoiding an allocation per call is what keeps 1721 terms under budget.
/// Vocabulary terms and transcript n-grams are always well under 64
/// characters, so the fallback path is never hit in practice but is kept for
/// correctness on pathological input.
func jaroWinkler(_ a: [Character], _ b: [Character]) -> Double {
    if a == b { return 1.0 }
    let aLen = a.count, bLen = b.count
    if aLen == 0 || bLen == 0 { return 0 }
    if aLen > 64 || bLen > 64 { return jaroWinklerUnbounded(a, b) }

    let matchDistance = max(0, max(aLen, bLen) / 2 - 1)
    var aMatches: UInt64 = 0
    var bMatches: UInt64 = 0
    var matches = 0
    for i in 0..<aLen {
        let start = max(0, i - matchDistance)
        let end = min(i + matchDistance + 1, bLen)
        guard start < end else { continue }
        for j in start..<end {
            let bit: UInt64 = 1 << j
            if bMatches & bit == 0, a[i] == b[j] {
                aMatches |= (1 << i)
                bMatches |= bit
                matches += 1
                break
            }
        }
    }
    guard matches > 0 else { return 0 }
    var transpositions = 0
    var k = 0
    for i in 0..<aLen where (aMatches >> i) & 1 == 1 {
        while (bMatches >> k) & 1 == 0 { k += 1 }
        if a[i] != b[k] { transpositions += 1 }
        k += 1
    }
    let m = Double(matches)
    let jaro = (m / Double(aLen) + m / Double(bLen) + (m - Double(transpositions / 2)) / m) / 3
    var prefix = 0
    for i in 0..<min(4, min(aLen, bLen)) {
        if a[i] == b[i] { prefix += 1 } else { break }
    }
    return jaro + Double(prefix) * 0.1 * (1 - jaro)
}

/// Same algorithm as `jaroWinkler`, with heap-allocated `[Bool]` match
/// tracking for the (never hit in this codebase) case of a term or n-gram
/// longer than 64 characters.
private func jaroWinklerUnbounded(_ a: [Character], _ b: [Character]) -> Double {
    let aLen = a.count, bLen = b.count
    let matchDistance = max(0, max(aLen, bLen) / 2 - 1)
    var aMatches = [Bool](repeating: false, count: aLen)
    var bMatches = [Bool](repeating: false, count: bLen)
    var matches = 0
    for i in 0..<aLen {
        let start = max(0, i - matchDistance)
        let end = min(i + matchDistance + 1, bLen)
        guard start < end else { continue }
        for j in start..<end where !bMatches[j] && a[i] == b[j] {
            aMatches[i] = true
            bMatches[j] = true
            matches += 1
            break
        }
    }
    guard matches > 0 else { return 0 }
    var transpositions = 0
    var k = 0
    for i in 0..<aLen where aMatches[i] {
        while !bMatches[k] { k += 1 }
        if a[i] != b[k] { transpositions += 1 }
        k += 1
    }
    let m = Double(matches)
    let jaro = (m / Double(aLen) + m / Double(bLen) + (m - Double(transpositions / 2)) / m) / 3
    var prefix = 0
    for i in 0..<min(4, min(aLen, bLen)) {
        if a[i] == b[i] { prefix += 1 } else { break }
    }
    return jaro + Double(prefix) * 0.1 * (1 - jaro)
}
