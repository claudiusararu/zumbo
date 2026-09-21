import AppKit
import Foundation
import os

/// What kind of thing an entry is. `dictation` is the original, pasted kind;
/// `note` and `meeting` are recorded through Zumbo itself and never pasted.
/// Defaults to `.dictation` on decode, so a `history.json` written before
/// this field existed still loads as a plain dictation list.
enum EntryKind: String, Codable, Equatable, Hashable, Sendable {
    case dictation
    case note
    case meeting
}

/// A reminder's life: waiting to fire, fired and cleared, or fired while the
/// app was asleep or not running (surfaced once more at next launch, marked
/// "Missed", then cleared the same as `done`).
enum ReminderState: String, Codable, Equatable, Hashable, Sendable {
    case pending
    case done
    case missed
}

/// One finished dictation, note or meeting, as it is written to disk.
struct DictationHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// Text after dictionary + rules, i.e. what was pasted for a dictation.
    /// For a note or a meeting this is the note body / the meeting's
    /// timestamped paragraphs, never pasted. Editable from the detail panel,
    /// so not `let`.
    var finalText: String
    /// Text straight out of the model, before any post-processing. For a
    /// note or meeting this mirrors `finalText` as it grows (append-only, no
    /// post-processing distinct from what was said).
    var rawText: String
    let createdAt: Date
    /// The app the text went into, captured when the session started (Zumbo
    /// never activates, so the frontmost app at that moment is the target).
    /// Normalized at capture time by `AppIdentity.normalize`, so this is
    /// never a system process id and never empty. Always nil for a note or a
    /// meeting.
    let bundleID: String?
    let appName: String?
    var wordCount: Int
    /// Seconds of recording (the last recording, for a meeting).
    var duration: TimeInterval
    /// Starred from a card's corner icon or the detail panel. Defaults to
    /// false on decode, so history.json written before it existed still
    /// loads.
    var isFavorite: Bool = false
    /// `.dictation` for everything captured before this field existed.
    var kind: EntryKind = .dictation
    /// A note's or meeting's title, shown as the card's first line and the
    /// detail panel's title field. Nil for a plain dictation.
    var title: String?
    /// Set when a meeting is turned off (meeting mode toggled off). Nil for
    /// a running meeting, and for every other kind.
    var endedAt: Date?
    /// Words corrected through Teach in this entry, shown with a dashed
    /// green underline in the detail panel so the fix stays visible.
    var corrections: [String] = []
    /// A date and time to notify about this note, set from the voice-parsed
    /// proposal or the hand picker. Nil for no reminder (the normal case).
    var reminderAt: Date?
    /// Nil until `reminderAt` is set; then `.pending` until it fires, `.done`
    /// once cleared (by the user or the notice's "Done"), `.missed` if it
    /// fired while the app was asleep or not running and is being surfaced
    /// once more at next launch.
    var reminderState: ReminderState?

    init(
        id: UUID = UUID(),
        finalText: String,
        rawText: String,
        createdAt: Date = Date(),
        bundleID: String?,
        appName: String?,
        duration: TimeInterval,
        isFavorite: Bool = false,
        kind: EntryKind = .dictation,
        title: String? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.finalText = finalText
        self.rawText = rawText
        self.createdAt = createdAt
        self.bundleID = bundleID
        self.appName = appName
        self.wordCount = Self.countWords(finalText)
        self.duration = duration
        self.isFavorite = isFavorite
        self.kind = kind
        self.title = title
        self.endedAt = endedAt
    }

    static func countWords(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Favorites, notes, meetings and a note with a pending reminder are
    /// never purged by retention and are dropped last when the on-disk cap
    /// is hit - a reminder that never fired because its note aged out would
    /// be a silently broken promise.
    var isProtected: Bool { isFavorite || kind != .dictation || reminderState == .pending }

    private enum CodingKeys: String, CodingKey {
        case id, finalText, rawText, createdAt, bundleID, appName, wordCount, duration, isFavorite,
             kind, title, endedAt, corrections, reminderAt, reminderState
    }

    /// Custom decode so every field added after the first shipped history
    /// format defaults sensibly on an old file instead of failing to decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        finalText = try container.decode(String.self, forKey: .finalText)
        rawText = try container.decode(String.self, forKey: .rawText)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        kind = try container.decodeIfPresent(EntryKind.self, forKey: .kind) ?? .dictation
        title = try container.decodeIfPresent(String.self, forKey: .title)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        corrections = try container.decodeIfPresent([String].self, forKey: .corrections) ?? []
        reminderAt = try container.decodeIfPresent(Date.self, forKey: .reminderAt)
        reminderState = try container.decodeIfPresent(ReminderState.self, forKey: .reminderState)
    }
}

/// Maps a captured (bundle id, app name) pair to something safe to show.
/// System processes that are never a real paste target - the notification
/// center agent, the login window - and an empty bundle id or name all
/// collapse to the same "Unknown app" identity with no bundle id, so the
/// card grid shows one generic icon and one filter pill for all of them
/// instead of a handful of ugly raw process names.
enum AppIdentity {
    private static let systemProcessNames: Set<String> = [
        "UserNotificationCenter", "loginwindow", "NotificationCenter", "Notification Center",
    ]

    static func normalize(bundleID: String?, name: String?) -> (bundleID: String?, name: String) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEmptyBundleID = trimmedBundleID?.isEmpty ?? true
        let isEmptyName = trimmedName?.isEmpty ?? true
        let isSystemProcess = systemProcessNames.contains(trimmedName ?? "")
            || trimmedBundleID?.hasPrefix("com.apple.notificationcenterui") == true

        if isSystemProcess || (isEmptyBundleID && isEmptyName) {
            return (nil, "Unknown app")
        }
        if isEmptyName {
            return (trimmedBundleID, "Unknown app")
        }
        return (isEmptyBundleID ? nil : trimmedBundleID, trimmedName!)
    }

    /// Same normalization, applied when rendering an entry that was captured
    /// before this mapping existed (or by an older build).
    static func displayName(for entry: DictationHistoryEntry) -> (bundleID: String?, name: String) {
        normalize(bundleID: entry.bundleID, name: entry.appName)
    }
}

/// Newest-first list of dictations, notes and meetings, persisted as one JSON
/// file in Application Support. Deliberately dumb: read once at launch and
/// rewritten after each mutation. Hard-capped at 5000 entries on disk;
/// favorites, notes and meetings are dropped last when the cap is hit.
/// Retention (`AppSettings.retentionDays`) purges everything else past the
/// window, at launch and once a day.
@MainActor
final class HistoryStore: ObservableObject {

    static let cap = 5000

    @Published private(set) var entries: [DictationHistoryEntry] = []

    private let url: URL
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "history")

    /// Read once per purge; wired by `AppDelegate` to `AppSettings.retentionDays`
    /// after both objects exist. Nil (never configured, e.g. in a unit test)
    /// means "never purge".
    var retentionDaysProvider: (() -> Int)?
    private var retentionTimer: Timer?

    init(url: URL = HistoryStore.defaultURL()) {
        self.url = url
        load()
    }

    static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Zumbo/history.json")
    }

    // MARK: - Mutation

    func add(_ entry: DictationHistoryEntry) {
        entries.insert(entry, at: 0)
        enforceCap()
        save()
    }

    func toggleFavorite(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFavorite.toggle()
        save()
    }

    /// Edits from the detail panel's text editor, saved on close or after a
    /// second of idle typing. Recomputes the word count so the card and the
    /// detail chip row stay accurate.
    func updateText(id: UUID, finalText: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].finalText != finalText else { return }
        entries[index].finalText = finalText
        entries[index].wordCount = DictationHistoryEntry.countWords(finalText)
        save()
    }

    /// Records a Teach correction on an entry (deduplicated, case-insensitive).
    func addCorrection(id: UUID, word: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !entries[index].corrections.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        entries[index].corrections.append(trimmed)
        save()
    }

    func updateTitle(id: UUID, title: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = trimmed.isEmpty ? nil : trimmed
        guard entries[index].title != newValue else { return }
        entries[index].title = newValue
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    // MARK: - Reminders

    /// Sets (or replaces) an entry's reminder, from either the voice
    /// proposal or the hand picker. Always lands in `.pending`.
    func setReminder(id: UUID, at date: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].reminderAt = date
        entries[index].reminderState = .pending
        save()
    }

    /// The detail panel's chip "x", or the "No" pill on the proposal notice.
    func cancelReminder(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].reminderAt = nil
        entries[index].reminderState = nil
        save()
    }

    /// The firing notice's "Done", or a missed reminder acknowledged at
    /// launch: clears it so it never fires or shows again.
    func completeReminder(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].reminderState = .done
        save()
    }

    /// A reminder that fired while the Mac was asleep or the app was not
    /// running, to be surfaced once more (marked "Missed") at next launch.
    func markReminderMissed(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].reminderState == .pending else { return }
        entries[index].reminderState = .missed
        save()
    }

    /// The firing notice's "Snooze 10 min": pushes the reminder forward and
    /// puts it back to pending.
    func snoozeReminder(id: UUID, by seconds: TimeInterval) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let base = entries[index].reminderAt ?? Date()
        entries[index].reminderAt = base.addingTimeInterval(seconds)
        entries[index].reminderState = .pending
        save()
    }

    /// Every entry with a reminder still waiting to fire, soonest first -
    /// the History page's "Reminders" filter pill.
    var pendingReminders: [DictationHistoryEntry] {
        entries
            .filter { $0.reminderState == .pending }
            .sorted { ($0.reminderAt ?? .distantFuture) < ($1.reminderAt ?? .distantFuture) }
    }

    /// Reminders whose time already passed while nothing was watching for
    /// them (asleep, or the app was not running) - checked once at launch.
    var overdueReminders: [DictationHistoryEntry] {
        let now = Date()
        return entries.filter { $0.reminderState == .pending && ($0.reminderAt ?? .distantFuture) <= now }
    }

    func entry(id: UUID) -> DictationHistoryEntry? {
        entries.first { $0.id == id }
    }

    /// Live substring filter for the search field. Matches the final text, the
    /// raw text, the title and the app name, case and diacritic insensitive.
    func filtered(by query: String) -> [DictationHistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.finalText, entry.rawText, entry.appName ?? "", entry.title ?? ""].contains { field in
                field.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    // MARK: - Notes

    /// First up to 6 words of `text`, used as a note's title when one is not
    /// supplied explicitly (e.g. dictated straight into a note).
    static func autoTitle(from text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return nil }
        return words.prefix(6).joined(separator: " ")
    }

    /// A fresh note. Empty text with a nil title is the "+ Note" path: the
    /// detail panel opens on it with the editor focused so the user can type
    /// or dictate into it.
    @discardableResult
    func createNote(title: String? = nil, text: String = "") -> UUID {
        let entry = DictationHistoryEntry(
            finalText: text, rawText: text, bundleID: nil, appName: nil, duration: 0,
            kind: .note, title: title ?? Self.autoTitle(from: text))
        entries.insert(entry, at: 0)
        enforceCap()
        save()
        return entry.id
    }

    /// Appends dictated text to an existing note (the detail-panel-focused
    /// dictation path), a blank line between paragraphs like a meeting's
    /// timestamped lines, minus the timestamp.
    func appendToNote(id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].kind == .note else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if entries[index].finalText.isEmpty {
            entries[index].finalText = trimmed
        } else {
            entries[index].finalText += "\n\n" + trimmed
        }
        entries[index].rawText = entries[index].finalText
        entries[index].wordCount = DictationHistoryEntry.countWords(entries[index].finalText)
        if entries[index].title == nil {
            entries[index].title = Self.autoTitle(from: entries[index].finalText)
        }
        save()
    }

    /// Converts a dictation into a note in place ("Save as note" in the
    /// detail panel): same entry, same id, kind flips and a title is filled
    /// in if there isn't one already.
    func convertToNote(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].kind == .dictation else { return }
        entries[index].kind = .note
        if entries[index].title == nil {
            entries[index].title = Self.autoTitle(from: entries[index].finalText)
        }
        save()
    }

    // MARK: - Meetings

    /// Starts a new meeting entry, e.g. "Meeting, Sep 18 10:32". Returns its
    /// id so the caller (the coordinator) can append to it and close it later.
    @discardableResult
    func createMeeting(title: String) -> UUID {
        let entry = DictationHistoryEntry(
            finalText: "", rawText: "", bundleID: nil, appName: nil, duration: 0,
            kind: .meeting, title: title)
        entries.insert(entry, at: 0)
        enforceCap()
        save()
        return entry.id
    }

    func endMeeting(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].endedAt = Date()
        save()
    }

    /// Live chunked path: appends one closed chunk's text as it is
    /// transcribed, instead of one paragraph per whole recording.
    /// `newParagraph` (decided by the caller, `DictationCoordinator`, from
    /// whether the speaker changed or a pause just ended) starts a fresh
    /// "H:mm  [Speaker N:] text" paragraph; otherwise the text is appended
    /// (with a space) to the paragraph this call most recently started, so
    /// consecutive same-speaker chunks read as one paragraph instead of one
    /// per chunk. Returns the entry's total word count after the append, for
    /// the "Saved, N words" notice.
    @discardableResult
    func appendMeetingChunk(
        id: UUID, text: String, speakerLabel: String?, at date: Date, newParagraph: Bool
    ) -> Int? {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].kind == .meeting else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries[index].wordCount }

        if newParagraph || entries[index].finalText.isEmpty {
            let stamp = Self.timeFormatter.string(from: date)
            let speakerPrefix = speakerLabel.map { "\($0): " } ?? ""
            let line = "\(stamp)  \(speakerPrefix)\(trimmed)"
            entries[index].finalText =
                entries[index].finalText.isEmpty ? line : entries[index].finalText + "\n\n" + line
        } else {
            entries[index].finalText += " " + trimmed
        }
        entries[index].rawText = entries[index].finalText
        entries[index].wordCount = DictationHistoryEntry.countWords(entries[index].finalText)
        save()
        return entries[index].wordCount
    }

    /// One-line footer appended when a meeting ran without speaker labels
    /// because the model was missing or still downloading.
    func appendMeetingFooter(id: UUID, note: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].kind == .meeting else { return }
        entries[index].finalText += entries[index].finalText.isEmpty ? note : "\n\n" + note
        entries[index].rawText = entries[index].finalText
        save()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        return formatter
    }()

    // MARK: - Retention

    /// Removes every non-protected (not favorite, not a note or a meeting)
    /// entry older than the retention window. `0` from the provider means
    /// "forever", i.e. never purge. Called at launch and once a day.
    func purgeExpired() {
        guard let days = retentionDaysProvider?(), days > 0 else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        let before = entries.count
        entries.removeAll { !$0.isProtected && $0.createdAt < cutoff }
        if entries.count != before {
            log.info("retention purge: removed \(before - self.entries.count, privacy: .public) entries")
            save()
        }
    }

    func startRetentionTimer() {
        retentionTimer?.invalidate()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.purgeExpired() }
        }
    }

    /// "Clear history": removes everything except favorites, notes and
    /// meetings, or literally everything when `includingProtected` is true
    /// (the "Everything" menu option).
    func clearHistory(includingProtected: Bool = false) {
        if includingProtected {
            entries.removeAll()
        } else {
            entries.removeAll { !$0.isProtected }
        }
        save()
    }

    /// Oldest non-protected entries are dropped first; if every entry is
    /// somehow protected and still over the cap, the oldest overall goes
    /// (newest-first list, so that is the tail).
    private func enforceCap() {
        guard entries.count > Self.cap else { return }
        var overflow = entries.count - Self.cap
        var index = entries.count - 1
        while overflow > 0, index >= 0 {
            if !entries[index].isProtected {
                entries.remove(at: index)
                overflow -= 1
            }
            index -= 1
        }
        while entries.count > Self.cap {
            entries.removeLast()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let decoded = try JSONDecoder.zumbo.decode([DictationHistoryEntry].self, from: data)
            entries = Array(decoded.prefix(Self.cap))
        } catch {
            log.error("history unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let snapshot = entries
        let destination = url
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.zumbo.encode(snapshot)
            try data.write(to: destination, options: .atomic)
        } catch {
            log.error("history write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension JSONEncoder {
    static var zumbo: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }
}

extension JSONDecoder {
    static var zumbo: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
