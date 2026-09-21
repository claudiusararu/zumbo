import Foundation

/// Local, deterministic parsing of a time phrase inside dictated note text -
/// "Remind me to take out the trash this evening at 7 p.m.", "call Dana
/// tomorrow at 10", "in 20 minutes", "next Monday 3pm" - used to propose a
/// reminder right after a note is created or appended to. Pure and testable:
/// takes an explicit reference `Date` and `Calendar` so "today", "tomorrow"
/// and "a past time today rolls to tomorrow" are all deterministic. Never
/// touches the note's own text - it only reads it.
///
/// `NSDataDetector` runs first (it already understands plenty of the common
/// forms: "Friday at 3pm", "10/5 at noon", weekday names with a clock time),
/// then the rules below run over the same lowercased text for the phrases the
/// detector misses - "this evening", "tonight", "in 20 minutes", a bare
/// weekday with a daypart, "next <weekday>". When both produce a result, the
/// rule-based one wins: it is the one built to understand this app's specific
/// vocabulary ("this evening" = 18:00, not whatever the detector guesses).
public enum ReminderParser {

    /// What one parse produced.
    public enum Outcome: Equatable, Sendable {
        /// One unambiguous candidate reminder time.
        case date(Date)
        /// The same clock time read two ways - AM and PM - because the text
        /// gave a bare hour with no am/pm and no daypart word to disambiguate
        /// it ("call Dana tomorrow at 10"). The UI asks which one.
        case ambiguous(Date, Date)
        /// No time phrase found at all.
        case none
    }

    // MARK: - Entry point

    public static func parse(_ text: String, reference: Date = Date(), calendar: Calendar = .current) -> Outcome {
        let lower = text.lowercased()

        if let relative = parseRelative(lower, reference: reference) {
            return .date(relative)
        }

        let day = resolveDayWord(lower, reference: reference, calendar: calendar)

        if let explicit = parseExplicitClock(lower) {
            let base = day?.date ?? calendar.startOfDay(for: reference)
            let date = setTime(base, hour: explicit.hour, minute: explicit.minute, calendar: calendar)
            return .date(rollIfPast(date, reference: reference, weekly: day?.weekly ?? false, calendar: calendar))
        }

        if let bare = parseBareClock(lower) {
            let base = day?.date ?? calendar.startOfDay(for: reference)
            let weekly = day?.weekly ?? false
            if let daypartHour = dayPartHour(in: lower) {
                let date = setTime(base, hour: normalizeToDaypart(bare.hour, daypartHour: daypartHour), minute: bare.minute, calendar: calendar)
                return .date(rollIfPast(date, reference: reference, weekly: weekly, calendar: calendar))
            }
            // No am/pm, no daypart word anywhere in the text: ask.
            let am = setTime(base, hour: bare.hour % 12, minute: bare.minute, calendar: calendar)
            let pm = setTime(base, hour: (bare.hour % 12) + 12, minute: bare.minute, calendar: calendar)
            let amRolled = rollIfPast(am, reference: reference, weekly: weekly, calendar: calendar)
            let pmRolled = rollIfPast(pm, reference: reference, weekly: weekly, calendar: calendar)
            return .ambiguous(amRolled, pmRolled)
        }

        if let day, let impliedHour = day.impliedHour {
            let date = setTime(day.date, hour: impliedHour, minute: 0, calendar: calendar)
            return .date(rollIfPast(date, reference: reference, weekly: day.weekly, calendar: calendar))
        }

        return .none
    }

    // MARK: - Task text

    /// The note's text with the reminder scaffolding stripped, for the
    /// firing notice and the system notification body - "Remind me to get
    /// off my chair and stretch a bit in 3 minutes." reads back as "Get off
    /// my chair and stretch a bit." instead of repeating the whole sentence
    /// verbatim. Strips one leading phrase ("remind me to", "remind me",
    /// "reminder to", "set a reminder to"), removes the first time phrase
    /// found (same patterns `parse` itself scans), tidies the leftover
    /// spacing/punctuation and capitalizes the first letter. Falls back to
    /// the original text whenever stripping would leave nothing readable.
    public static func taskText(from text: String) -> String {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Longest phrase first, so "remind me to" never leaves a dangling "to".
        let leadingPhrases = ["set a reminder to", "remind me to", "reminder to", "remind me"]
        let lowered = working.lowercased()
        for phrase in leadingPhrases where lowered.hasPrefix(phrase) {
            let index = working.index(working.startIndex, offsetBy: phrase.count)
            working = String(working[index...])
            break
        }

        for pattern in taskTimePhrasePatterns {
            if let range = working.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                working.removeSubrange(range)
                break
            }
        }

        // No space before trailing punctuation, no doubled spaces, no stray
        // leading/trailing punctuation left where the phrase used to be.
        working = working.replacingOccurrences(of: #"\s+([.,!?])"#, with: "$1", options: .regularExpression)
        working = working.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        working = working.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
        working = working.trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing readable left (e.g. the whole sentence was the time
        // phrase) - the original text is still better than an empty string.
        guard working.rangeOfCharacter(from: .letters) != nil else { return text }
        return working.prefix(1).uppercased() + working.dropFirst()
    }

    private static let taskTimePhrasePatterns: [String] = [
        #"\bin\s+\d+\s*(?:minutes?|mins?)\b"#,
        #"\bin\s+\d+\s*(?:hours?|hrs?)\b"#,
        #"\bnext\s+(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday)(?:\s+(?:morning|afternoon|evening|night))?\b"#,
        #"\b(?:this\s+(?:evening|afternoon|morning)|tonight)\b"#,
        #"\btomorrow(?:\s+(?:morning|afternoon|evening|night))?\b"#,
        #"\b(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday)(?:\s+(?:morning|afternoon|evening|night))?\b"#,
        #"\bat\s+\d{1,2}(?::\d{2})?\s*(?:[ap]\.?\s?m\.?)?\b"#,
    ]

    // MARK: - Relative offsets

    private static func parseRelative(_ lower: String, reference: Date) -> Date? {
        if let n = firstMatch(#"\bin\s+(\d+)\s*(?:minutes?|mins?)\b"#, in: lower) {
            return reference.addingTimeInterval(TimeInterval(n) * 60)
        }
        if let n = firstMatch(#"\bin\s+(\d+)\s*(?:hours?|hrs?)\b"#, in: lower) {
            return reference.addingTimeInterval(TimeInterval(n) * 3600)
        }
        return nil
    }

    // MARK: - Day word

    private struct DayWord {
        let date: Date
        /// True when the phrase already names a time of day ("this evening",
        /// "tomorrow morning", "next Monday" defaults to 09:00). Nil when the
        /// day word alone (a bare weekday, or "tomorrow" combined with an
        /// explicit clock elsewhere) does not imply an hour by itself.
        let impliedHour: Int?
        /// True when the day was resolved from a weekday name (bare or
        /// "next"), so a past-time roll adds 7 days instead of 1.
        let weekly: Bool
    }

    private static let weekdayNames = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]

    private static func resolveDayWord(_ lower: String, reference: Date, calendar: Calendar) -> DayWord? {
        let today = calendar.startOfDay(for: reference)

        // "tomorrow [morning|afternoon|evening|night]"
        if lower.contains("tomorrow") {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            let hour = dayPartHour(in: lower) ?? 9
            return DayWord(date: tomorrow, impliedHour: hour, weekly: false)
        }

        // "this evening" / "tonight" / "this afternoon" / "this morning"
        if lower.contains("this evening") {
            return DayWord(date: today, impliedHour: 18, weekly: false)
        }
        if lower.contains("tonight") {
            return DayWord(date: today, impliedHour: 20, weekly: false)
        }
        if lower.contains("this afternoon") {
            return DayWord(date: today, impliedHour: 15, weekly: false)
        }
        if lower.contains("this morning") {
            return DayWord(date: today, impliedHour: 9, weekly: false)
        }

        // "next <weekday>": at least one full week if today already is that
        // weekday, otherwise the next future occurrence.
        if let range = lower.range(of: #"\bnext\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#, options: .regularExpression) {
            let word = lower[range].split(separator: " ").last.map(String.init) ?? ""
            guard let target = weekdayNames.firstIndex(of: word) else { return nil }
            guard let date = nextOccurrence(of: target + 1, from: today, calendar: calendar, minDaysAhead: 1, forceFullWeek: true) else { return nil }
            let hour = dayPartHour(in: lower) ?? 9
            return DayWord(date: date, impliedHour: hour, weekly: true)
        }

        // A bare weekday name ("Friday morning", "on Friday").
        for (index, name) in weekdayNames.enumerated() {
            guard lower.range(of: "\\b\(name)\\b", options: .regularExpression) != nil else { continue }
            guard let date = nextOccurrence(of: index + 1, from: today, calendar: calendar, minDaysAhead: 0, forceFullWeek: false) else { return nil }
            return DayWord(date: date, impliedHour: dayPartHour(in: lower), weekly: true)
        }

        return nil
    }

    /// 1 = Sunday ... 7 = Saturday (`Calendar.component(.weekday, ...)`).
    private static func nextOccurrence(
        of weekday: Int, from today: Date, calendar: Calendar, minDaysAhead: Int, forceFullWeek: Bool
    ) -> Date? {
        let todayWeekday = calendar.component(.weekday, from: today)
        var diff = (weekday - todayWeekday + 7) % 7
        if diff < minDaysAhead || (forceFullWeek && diff == 0) {
            diff += 7
        }
        return calendar.date(byAdding: .day, value: diff, to: today)
    }

    private static func dayPartHour(in lower: String) -> Int? {
        if lower.contains("morning") { return 9 }
        if lower.contains("afternoon") { return 15 }
        if lower.contains("evening") { return 18 }
        if lower.contains("night") { return 20 }
        return nil
    }

    /// Folds a bare 1...12 hour into the daypart's half of the day: morning
    /// stays AM (12 -> midnight left alone, an edge case not worth chasing),
    /// afternoon/evening/night become PM unless already a 13-23 hour word.
    private static func normalizeToDaypart(_ hour: Int, daypartHour: Int) -> Int {
        let isMorning = daypartHour == 9
        let base = hour % 12
        if isMorning { return base }
        return base + 12
    }

    // MARK: - Clock time

    private struct Clock { let hour: Int; let minute: Int }

    /// "7 p.m.", "7pm", "10:30 am", "19:00".
    private static func parseExplicitClock(_ lower: String) -> Clock? {
        guard let match = firstCaptures(
            #"\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s?m\.?\b"#, in: lower
        ) else { return nil }
        let hour12 = Int(match[0]) ?? 0
        let minute = match[1].isEmpty ? 0 : (Int(match[1]) ?? 0)
        let isPM = match[2] == "p"
        let hour = (hour12 % 12) + (isPM ? 12 : 0)
        return Clock(hour: hour, minute: minute)
    }

    /// "at 7", "at 10:30" - no am/pm, so the caller must disambiguate.
    private static func parseBareClock(_ lower: String) -> Clock? {
        guard let match = firstCaptures(#"\bat\s+(\d{1,2})(?::(\d{2}))?\b"#, in: lower) else { return nil }
        guard let hour = Int(match[0]), hour >= 1, hour <= 12 else { return nil }
        let minute = match[1].isEmpty ? 0 : (Int(match[1]) ?? 0)
        return Clock(hour: hour, minute: minute)
    }

    // MARK: - Helpers

    private static func setTime(_ day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour % 24, minute: minute, second: 0, of: day) ?? day
    }

    /// A resolved time earlier than `reference` rolls forward: a day at a
    /// time (1 day) unless the day itself came from a weekday name (7 days),
    /// so "call at 3pm" said at 5pm rolls to tomorrow 3pm, not today.
    private static func rollIfPast(_ date: Date, reference: Date, weekly: Bool, calendar: Calendar) -> Date {
        guard date < reference else { return date }
        let unit: Calendar.Component = .day
        let value = weekly ? 7 : 1
        return calendar.date(byAdding: unit, value: value, to: date) ?? date
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Int? {
        firstCaptures(pattern, in: text).flatMap { Int($0[0]) }
    }

    private static func firstCaptures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var captures: [String] = []
        for i in 1..<match.numberOfRanges {
            guard let r = Range(match.range(at: i), in: text) else {
                captures.append("")
                continue
            }
            captures.append(String(text[r]))
        }
        return captures
    }
}
