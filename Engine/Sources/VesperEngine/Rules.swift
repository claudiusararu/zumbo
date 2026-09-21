import Foundation

/// Which deterministic post-processing rule groups run, per NOTES.md. Every
/// group is independently toggleable so the app can offer per-group switches
/// and so "off" gives verbatim mode.
public struct RulesConfig: Equatable, Sendable {
    /// Fillers (uh/um/er/hmm/standalone "like") dropped, repeats collapsed,
    /// false starts trimmed. On by default.
    public var cleanSpeech: Bool
    /// "gotta"/"wanna"/"kinda"/"gonna" expanded to their full form. Off by default.
    public var contractions: Bool
    /// Number words -> digits ("two hundred" -> "200"). On by default.
    public var numbers: Bool
    /// "bucks"/"dollars" -> "$", "euros" -> "€", "pounds" -> "£", "percent" -> "%".
    /// On by default. Depends on `numbers` having already digitized the amount.
    public var currency: Bool
    /// "dash dash force" -> "--force", "colon" before a number -> ":",
    /// "new line" -> "\n", "open paren"/"close paren" -> "("/")" .
    public var spokenPunctuation: Bool
    /// A dictation never ends without a terminal mark: "." is appended when
    /// the text ends in a letter or digit, "?" when it reads as a question.
    /// On by default.
    public var endPunctuation: Bool

    public init(
        cleanSpeech: Bool = true,
        contractions: Bool = false,
        numbers: Bool = true,
        currency: Bool = true,
        spokenPunctuation: Bool = true,
        endPunctuation: Bool = true
    ) {
        self.cleanSpeech = cleanSpeech
        self.contractions = contractions
        self.numbers = numbers
        self.currency = currency
        self.spokenPunctuation = spokenPunctuation
        self.endPunctuation = endPunctuation
    }

    /// Verbatim mode: every group off, dictionary replacement still runs.
    public static let allOff = RulesConfig(
        cleanSpeech: false, contractions: false, numbers: false, currency: false, spokenPunctuation: false,
        endPunctuation: false)
}

/// Deterministic, zero-latency post-processor. Runs the dictionary
/// (`Replacer`) first so vocabulary aliases and their spoken-punctuation
/// forms (e.g. "dash dash force" -> "--force" via the dictionary entry) win
/// over the generic rule groups, then applies each enabled rule group in a
/// fixed order: cleanSpeech, contractions, numbers, currency, spokenPunctuation.
public struct RulesEngine {
    public let config: RulesConfig
    private let replacer: Replacer

    public init(vocabulary: [VocabTerm] = [], config: RulesConfig = RulesConfig()) {
        self.replacer = Replacer(terms: vocabulary)
        self.config = config
    }

    public func apply(_ input: String) -> String {
        var text = replacer.apply(input)
        if config.cleanSpeech { text = CleanSpeechRule.apply(text) }
        if config.contractions { text = ContractionsRule.apply(text) }
        if config.numbers { text = NumbersRule.apply(text) }
        if config.currency { text = CurrencyRule.apply(text) }
        if config.spokenPunctuation { text = SpokenPunctuationRule.apply(text) }
        text = RulesEngine.collapseWhitespace(text)
        if config.endPunctuation { text = EndPunctuationRule.apply(text) }
        return text
    }

    static func collapseWhitespace(_ text: String) -> String {
        var out = text.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: " ([,.!?;:])", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "(^ +| +$)", with: "", options: .regularExpression)
        return out
    }
}

// MARK: - Clean speech

enum CleanSpeechRule {
    private static let simpleFillers: Set<String> = ["uh", "um", "er", "erm", "hmm"]

    /// "like" is only a filler when it isn't the verb "like" - excluded right
    /// after a subject or modal that makes it a verb ("I'd like", "would like",
    /// "I like", "they like", ...), so "I'd like it to be" survives intact
    /// while a genuinely standalone "like" ("it's, like, on by default") is
    /// dropped.
    private static let likeVerbPrecedents: Set<String> = [
        "i'd", "you'd", "we'd", "they'd", "he'd", "she'd", "would",
        "i", "you", "we", "they", "he", "she", "it", "that",
    ]

    static func apply(_ text: String) -> String {
        // Fillers first: a leading "uh" before a false start would otherwise
        // shift the sentence-initial prefix trimFalseStarts looks for.
        var out = removeFillers(text)
        out = trimFalseStarts(out)
        out = collapseRepeats(out)
        return RulesEngine.collapseWhitespace(out)
    }

    static func removeFillers(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        for (index, word) in words.enumerated() {
            let core = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if simpleFillers.contains(core) { continue }
            if core == "like" {
                let previous = index > 0
                    ? words[index - 1].lowercased().trimmingCharacters(in: .punctuationCharacters) : ""
                if likeVerbPrecedents.contains(previous) {
                    result.append(word)
                }
                continue
            }
            result.append(word)
        }
        return result.joined(separator: " ")
    }

    /// Collapses an immediately repeated word ("the the" -> "the", "it it it" -> "it").
    static func collapseRepeats(_ text: String) -> String {
        let pattern = "\\b(\\w+)(\\s+\\1\\b)+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        return re.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "$1")
    }

    /// A repeated prefix separated by one of these words is far more likely to
    /// be a legitimate parallel construction ("two hundred bucks versus two
    /// hundred euros") than an abandoned, restarted clause - false starts don't
    /// introduce a comparison, they just repeat themselves.
    private static let parallelConstructionWords: Set<String> = [
        "and", "or", "versus", "vs", "vs.", "than", "but", "nor",
    ]

    /// Trims a false start: a repeated 2-4 word prefix within a sentence. If the
    /// first N words (N = 4, 3, then 2) reappear verbatim later in the same
    /// sentence, everything before that later occurrence is dropped -
    /// "I'd like them to I'd like it to be" -> "I'd like it to be". Conservative:
    /// only fires on an exact word-for-word repeat, never a fuzzy match, and
    /// never when the words in between look like a parallel construction
    /// rather than an abandoned clause.
    static func trimFalseStarts(_ text: String) -> String {
        splitSentences(text).map(trimFalseStart).joined(separator: " ")
    }

    private static func splitSentences(_ text: String) -> [String] {
        let pattern = "(?<=[.!?])\\s+"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let ns = text as NSString
        var result: [String] = []
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        result.append(ns.substring(from: last))
        return result.filter { !$0.isEmpty }
    }

    private static func trimFalseStart(_ sentence: String) -> String {
        let words = sentence.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return sentence }
        for n in stride(from: 4, through: 2, by: -1) {
            guard words.count >= n + 1 else { continue }
            let prefix = words[0..<n].map(normalize)
            // Start the search at `n`, not 1: an occurrence starting before
            // that would overlap the prefix itself (e.g. "it it it" matching
            // "it it" at index 1), which collapseRepeats already handles and
            // which would make the words[n..<i] gap slice below invalid.
            var i = n
            while i + n <= words.count {
                if Array(words[i..<i + n]).map(normalize) == prefix {
                    let gap = words[n..<i].map(normalize)
                    if !gap.contains(where: parallelConstructionWords.contains) {
                        return words[i...].joined(separator: " ")
                    }
                }
                i += 1
            }
        }
        return sentence
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

// MARK: - Contractions (off by default)

enum ContractionsRule {
    private static let expansions: [(String, String)] = [
        ("gonna", "going to"),
        ("gotta", "got to"),
        ("wanna", "want to"),
        ("kinda", "kind of"),
    ]

    static func apply(_ text: String) -> String {
        var out = text
        for (contraction, expansion) in expansions {
            out = replaceRegexPreservingCase(out, word: contraction, with: expansion)
        }
        return out
    }
}

// MARK: - Numbers

enum NumberWords {
    static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Int] = ["hundred": 100, "thousand": 1000, "million": 1_000_000]

    static func isCoreNumberWord(_ word: String) -> Bool {
        let w = word.lowercased()
        return ones[w] != nil || teens[w] != nil || tens[w] != nil || scales[w] != nil
    }

    static func isConnector(_ word: String) -> Bool {
        let w = word.lowercased()
        return w == "and" || w == "point"
    }

    static func isNumberWord(_ word: String) -> Bool {
        isCoreNumberWord(word) || isConnector(word)
    }

    /// Classic accumulator parse: "twelve thousand" = 12 * 1000; "two hundred and
    /// one" = 2*100 + 1; "three thousand four hundred" = 3*1000 + 4*100.
    static func parseInteger(_ words: [String]) -> Int? {
        var total = 0
        var current = 0
        var any = false
        for w in words {
            let lw = w.lowercased()
            if lw == "and" { continue }
            if let v = ones[lw] {
                current += v
                any = true
            } else if let v = teens[lw] {
                current += v
                any = true
            } else if let v = tens[lw] {
                current += v
                any = true
            } else if let v = scales[lw] {
                any = true
                if v == 100 {
                    current = max(current, 1) * v
                } else {
                    total += max(current, 1) * v
                    current = 0
                }
            } else {
                return nil
            }
        }
        return any ? total + current : nil
    }

    /// Converts a run of number words (may include a "point" decimal marker) to
    /// its digit string: "three point five" -> "3.5", "twelve thousand" -> "12000".
    static func convert(_ words: [String]) -> String? {
        guard let pointIndex = words.firstIndex(where: { $0.lowercased() == "point" }) else {
            guard let value = parseInteger(words) else { return nil }
            return String(value)
        }
        let left = Array(words[..<pointIndex])
        let right = Array(words[(pointIndex + 1)...])
        guard !right.isEmpty else { return nil }
        let leftValue = left.isEmpty ? 0 : parseInteger(left)
        guard let leftValue else { return nil }
        var digits = ""
        for w in right {
            guard let d = ones[w.lowercased()], d <= 9 else { return nil }
            digits += String(d)
        }
        return "\(leftValue).\(digits)"
    }
}

enum NumbersRule {
    /// Units, currencies and plural measure nouns: a single number word in
    /// front of one of these is a quantity, so it becomes a digit.
    /// "two seconds" -> "2 seconds", but "two of us" stays words.
    static let measureNouns: Set<String> = [
        "dollars", "dollar", "bucks", "euros", "euro", "pounds", "pound", "cents", "percent",
        "ms", "milliseconds", "seconds", "minutes", "hours", "days", "weeks", "months", "years",
        "times", "items", "users", "pixels", "points", "px", "pt",
        "kb", "mb", "gb", "tb", "kilobytes", "megabytes", "gigabytes", "terabytes",
    ]

    /// Nouns that index a thing: what follows is a label, so digits read
    /// better. "version two" -> "version 2", "step one" -> "step 1".
    /// Deliberately short: "chapter one" reads better as words and the brief
    /// asks for it to stay.
    static let indexNouns: Set<String> = ["version", "step", "page"]

    /// Words that end in "s" without being a plural noun, so a number in
    /// front of them is not a count.
    static let notPlurals: Set<String> = [
        "is", "was", "has", "does", "its", "as", "us", "this", "thus", "yes", "plus",
        "versus", "vs", "less", "unless", "else", "his", "hers", "theirs", "ours",
        "always", "perhaps", "across", "gets", "goes", "looks", "seems",
    ]

    /// A plural count noun: "two dogs", "three cats", "five requests". Kept
    /// deliberately crude (a trailing "s") because the alternative is a noun
    /// list that will never be complete, and the cost of a miss is one word
    /// that stays spelled out.
    private static func isPluralNoun(_ word: String) -> Bool {
        let w = word.lowercased()
        guard w.count >= 3, w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us") else { return false }
        return !notPlurals.contains(w)
    }

    /// A number right after one of these is an amount.
    static let currencyWords: Set<String> = ["usd", "eur", "gbp", "dollars", "euros", "pounds"]
    static let currencySymbols: Set<Character> = ["$", "\u{20AC}", "\u{00A3}"]

    /// "one" on its own is almost always a pronoun or a determiner ("a custom
    /// one", "one day", "one of them"), so it only converts as part of a
    /// chain ("one hundred", "one point five"), after an index noun, or after
    /// a currency marker. Every other single number word converts in front of
    /// a measure noun.
    private static func shouldConvert(
        run: [(word: String, range: NSRange)],
        previousWord: String?,
        previousSymbol: Character?,
        nextWord: String?
    ) -> Bool {
        if run.count >= 2 { return true }
        guard let single = run.first?.word.lowercased() else { return false }

        if let previousSymbol, currencySymbols.contains(previousSymbol) { return true }
        if let previousWord, currencyWords.contains(previousWord.lowercased()) { return true }
        if let previousWord, indexNouns.contains(previousWord.lowercased()) { return true }

        if single == "one" { return false }
        if let nextWord, measureNouns.contains(nextWord.lowercased()) || isPluralNoun(nextWord) {
            return true
        }
        return false
    }

    static func apply(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z]+") else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = ""
        var cursor = 0
        var i = 0
        while i < matches.count {
            let word = ns.substring(with: matches[i].range)
            guard NumberWords.isCoreNumberWord(word) else {
                i += 1
                continue
            }
            var run: [(word: String, range: NSRange)] = [(word, matches[i].range)]
            var j = i + 1
            while j < matches.count {
                let prevEnd = run.last!.range.location + run.last!.range.length
                let gapRange = NSRange(location: prevEnd, length: matches[j].range.location - prevEnd)
                let gap = ns.substring(with: gapRange)
                // Spaces or a single hyphen join number words: the recognizer
                // writes "ninety-nine" for "ninety nine".
                guard gap.trimmingCharacters(in: .whitespaces).isEmpty || gap == "-", !gap.contains("\n") else { break }
                let w = ns.substring(with: matches[j].range)
                guard NumberWords.isNumberWord(w) else { break }
                run.append((w, matches[j].range))
                j += 1
            }
            // Trailing connector ("and"/"point") without a following number is not
            // part of the number - trim it back off.
            while let last = run.last, NumberWords.isConnector(last.word) {
                run.removeLast()
                j -= 1
            }
            let previousMatch = matches[..<i].last
            let previousWord = previousMatch.map { ns.substring(with: $0.range) }
            let runStart = run.first!.range.location
            let previousSymbol = Self.nonSpaceCharacter(before: runStart, in: ns)
            let nextWord = j < matches.count ? ns.substring(with: matches[j].range) : nil

            guard Self.shouldConvert(
                run: run, previousWord: previousWord,
                previousSymbol: previousSymbol, nextWord: nextWord)
            else {
                i += 1
                continue
            }

            if let converted = NumberWords.convert(run.map(\.word)) {
                result += ns.substring(with: NSRange(location: cursor, length: run.first!.range.location - cursor))
                result += converted
                cursor = run.last!.range.location + run.last!.range.length
                i = j
            } else {
                i += 1
            }
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// The nearest non-whitespace character before an index, so "$ five" and
    /// "$five" both read as an amount.
    private static func nonSpaceCharacter(before index: Int, in ns: NSString) -> Character? {
        var cursor = index - 1
        while cursor >= 0 {
            let character = Character(ns.substring(with: NSRange(location: cursor, length: 1)))
            if !character.isWhitespace { return character }
            cursor -= 1
        }
        return nil
    }
}

// MARK: - Currency (depends on `numbers` having run first)

enum CurrencyRule {
    private static let rules: [(pattern: String, template: String)] = [
        ("(\\d+(?:\\.\\d+)?)\\s+(?:bucks|dollars)\\b", "\\$$1"),
        ("(\\d+(?:\\.\\d+)?)\\s+euros?\\b", "\u{20AC}$1"),
        ("(\\d+(?:\\.\\d+)?)\\s+pounds?\\b", "\u{00A3}$1"),
        ("(\\d+(?:\\.\\d+)?)\\s+percent\\b", "$1%"),
    ]

    static func apply(_ text: String) -> String {
        var out = text
        for (pattern, template) in rules {
            out = replaceRegex(out, pattern: pattern, template: template, caseInsensitive: true)
        }
        return out
    }
}

// MARK: - Spoken punctuation

enum SpokenPunctuationRule {
    // `Replacer` (which always runs before the rule groups) already turns a
    // literal "dash dash" into "--" unconditionally, so by the time this rule
    // runs there is no "dash dash <word>" text left to match - only a "--"
    // possibly followed by a stray space before the flag name, which this
    // merges: "-- force" -> "--force".
    private static let rules: [(pattern: String, template: String)] = [
        ("--\\s+(\\w[\\w-]*)", "--$1"),
        ("\\s+colon\\s+(?=\\d)", ":"),
        ("\\bnew\\s+line\\b", "\n"),
        ("\\bopen\\s+paren(?:thesis)?\\b", "("),
        ("\\bclose\\s+paren(?:thesis)?\\b", ")"),
    ]

    static func apply(_ text: String) -> String {
        var out = text
        for (pattern, template) in rules {
            out = replaceRegex(out, pattern: pattern, template: template, caseInsensitive: true)
        }
        return out
    }
}

// MARK: - Shared regex helpers

func replaceRegex(_ text: String, pattern: String, template: String, caseInsensitive: Bool = false) -> String {
    var options: NSRegularExpression.Options = []
    if caseInsensitive { options.insert(.caseInsensitive) }
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
    let ns = text as NSString
    return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
}

/// Word-boundary, case-insensitive replace that capitalizes the replacement's
/// first letter when the matched word was capitalized ("Gonna" -> "Going to").
func replaceRegexPreservingCase(_ text: String, word: String, with replacement: String) -> String {
    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
    let ns = text as NSString
    var result = ""
    var cursor = 0
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
        let matched = ns.substring(with: m.range)
        if let first = matched.first, first.isUppercase {
            result += replacement.prefix(1).uppercased() + replacement.dropFirst()
        } else {
            result += replacement
        }
        cursor = m.range.location + m.range.length
    }
    result += ns.substring(from: cursor)
    return result
}


// MARK: - End punctuation

/// Every finished dictation ends with a terminal mark. The recognizer often
/// drops the last one, so: text ending in a letter, digit, or a closing
/// quote/bracket right after one gets "." appended, or "?" when the first
/// word is an interrogative. Text that already ends in . ! ? … : ; , or a
/// newline, and text that is a single code-like token (path, flag, URL,
/// identifier with punctuation), is left alone.
enum EndPunctuationRule {
    private static let questionStarters: Set<String> = [
        "what", "why", "how", "when", "where", "who", "whom", "whose", "which",
        "is", "are", "am", "was", "were", "do", "does", "did", "can", "could",
        "should", "would", "will", "shall", "may", "might", "have", "has", "had",
        "isn't", "aren't", "don't", "doesn't", "didn't", "can't", "couldn't",
        "shouldn't", "wouldn't", "won't",
    ]

    static func apply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return text }
        if last == "\n" { return text }
        if ".!?…:;,".contains(last) { return text }
        // Single code-like token: leave it (a path, a flag, an identifier).
        let words = trimmed.split(separator: " ")
        if words.count == 1, trimmed.contains(where: { "/\\-_.:@#$".contains($0) }) { return text }
        var core = trimmed
        var closers = ""
        while let c = core.last, ")]}\"'”’".contains(c) {
            closers.insert(c, at: closers.startIndex)
            core.removeLast()
        }
        guard let coreLast = core.last, coreLast.isLetter || coreLast.isNumber else { return text }
        let firstWord = words.first.map { String($0).lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        let mark = questionStarters.contains(firstWord) ? "?" : "."
        return core + mark + closers
    }
}
