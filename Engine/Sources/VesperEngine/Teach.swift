import Foundation

/// Pure logic behind the history-panel "Teach" popover (see
/// `Sources/Notch/TeachPopoverView.swift`): text replacement and the
/// dictionary entry it writes. No SwiftUI/AppKit dependency, so it is fully
/// unit-testable without a view hierarchy.
public enum Teach {

    /// Replaces every case-insensitive, whole-word (or whole-phrase)
    /// occurrence of `heard` in `text` with `correct`. "Whole" means the
    /// match cannot sit inside a longer word on either side, so teaching
    /// "cat" never touches "category". Returns `text` unchanged if `heard`
    /// is empty or whitespace-only.
    public static func replaceEverywhere(in text: String, heard: String, with correct: String) -> String {
        let trimmedHeard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHeard.isEmpty else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: trimmedHeard)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive])
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: correct)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Replaces exactly the given `range` (a UTF-16 `NSRange` into `text`,
    /// matching `NSTextView`'s selection) with `replacement`. Used by
    /// "Replace here", which touches only the occurrence the person selected.
    /// Returns `text` unchanged if `range` does not fall inside it.
    public static func replaceRange(in text: String, range: NSRange, with replacement: String) -> String {
        guard let swiftRange = Range(range, in: text) else { return text }
        var result = text
        result.replaceSubrange(swiftRange, with: replacement)
        return result
    }

    /// Strips a leading timestamp ("10:32  ", one or two digits, a colon, two
    /// digits, then two spaces) or speaker label ("Speaker 1: ", any number of
    /// digits) from a raw text-view selection. Used to build "Heard as" and to
    /// keep that prefix out of both replacement and the taught alias. Returns
    /// the cleaned text and, only when one was found, the stripped prefix.
    public static func stripLeadingPrefix(from text: String) -> (cleaned: String, prefix: String?) {
        if let end = firstMatchEnd(in: text, pattern: "^\\d{1,2}:\\d{2}  ") {
            return (String(text[end...]), String(text[..<end]))
        }
        if let end = firstMatchEnd(in: text, pattern: "^Speaker \\d+: ?") {
            return (String(text[end...]), String(text[..<end]))
        }
        return (text, nil)
    }

    /// Expands a selection that sits entirely inside one word (no space or
    /// newline in it) out to that word's full boundaries, so a drag that only
    /// grabs part of "category" still teaches the whole word. A selection
    /// that already spans more than one token (a phrase) is returned as-is.
    /// `range` and the result are UTF-16 offsets into `text`, matching
    /// `NSTextView.selectedRange()`.
    public static func expandToWord(in text: String, range: NSRange) -> NSRange {
        let ns = text as NSString
        guard range.length > 0, range.location != NSNotFound,
              range.location + range.length <= ns.length
        else { return range }

        let selected = ns.substring(with: range)
        guard !selected.contains(" "), !selected.contains("\n") else { return range }

        func isWordChar(_ code: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(code) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }

        var start = range.location
        var end = range.location + range.length
        while start > 0, isWordChar(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, isWordChar(ns.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Merges a taught correction into the existing dictionary entry for
    /// `correct`, if any: appends `heard` as an alias when it is not already
    /// present (case-insensitive), keeping every other alias, `minSimilarity`
    /// and `pack` untouched. With no existing entry, creates a fresh one
    /// whose only alias is `heard`, sourced `"taught"`. Editing an existing
    /// entry keeps that entry's own `source` - it was already known, teaching
    /// just adds a way it gets misheard.
    public static func mergedTerm(existing: DictionaryTerm?, heard: String, correct: String) -> DictionaryTerm {
        let trimmedHeard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let existing else {
            let aliases = trimmedHeard.isEmpty ? [] : [trimmedHeard]
            return DictionaryTerm(text: correct, aliases: aliases, enabled: true, source: "taught", addedAt: Date())
        }
        var aliases = existing.aliases
        if !trimmedHeard.isEmpty,
           !aliases.contains(where: { $0.caseInsensitiveCompare(trimmedHeard) == .orderedSame }) {
            aliases.append(trimmedHeard)
        }
        return DictionaryTerm(
            text: correct, aliases: aliases, enabled: true, minSimilarity: existing.minSimilarity,
            pack: existing.pack, source: existing.source, addedAt: existing.addedAt)
    }

    private static func firstMatchEnd(in text: String, pattern: String) -> String.Index? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(result.range, in: text)
        else { return nil }
        return swiftRange.upperBound
    }
}
