import AppKit
import SwiftUI
import VesperEngine

/// The second black panel that opens below the expanded panel when a card's
/// text area is clicked, in the style of Supaste's clip detail view: a chip
/// row (app, time, words, duration) with right-aligned actions, then the
/// full text in an editable, non-monospaced 13 pt `TextEditor`. It is a
/// sibling rounded rectangle in the same `NotchPanel` window, drawn by
/// `NotchRootView`, never part of `NotchShape`.
struct HistoryDetailPanelView: View {

    @ObservedObject var history: HistoryStore
    let entryID: UUID
    let settings: AppSettings
    let reduceMotion: Bool
    let notificationsDenied: Bool
    let onClose: () -> Void
    let onInsertAgain: (String) -> Void
    let onSetReminder: (Date) -> Void
    let onCancelReminder: () -> Void
    /// `--demo expanded-teach` only: opens the Teach form on a synthetic
    /// selection (the entry's first word) instead of waiting for a real
    /// text drag, so the screenshot check can land on it directly.
    var demoOpenTeach: Bool = false

    @State private var text: String = ""
    @State private var reminderPickerOpen = false
    @State private var title: String = ""
    @State private var loadedID: UUID?
    @State private var deleteArmed = false
    @State private var copied = false
    @State private var inserted = false
    @State private var savedAsNote = false
    @State private var saveTask: Task<Void, Never>?
    @State private var titleSaveTask: Task<Void, Never>?
    @State private var deleteArmTask: Task<Void, Never>?
    @FocusState private var editorFocused: Bool

    // MARK: - Teach
    @State private var teachSelection: TeachSelection?
    @State private var teachPopoverOpen = false
    @State private var teachFlashText: String?
    @State private var teachFlashTask: Task<Void, Never>?

    private var entry: DictationHistoryEntry? {
        history.entries.first(where: { $0.id == entryID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry {
                VStack(alignment: .leading, spacing: 10) {
                    chipRow(entry)
                    if entry.kind != .dictation {
                        titleField
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { dismissTeach() }
                if reminderPickerOpen {
                    ReminderPickerView(
                        accent: SettingsTheme.accent,
                        reduceMotion: reduceMotion,
                        notificationsDenied: notificationsDenied,
                        onSet: { date in
                            onSetReminder(date)
                            reminderPickerOpen = false
                        },
                        onCancel: { reminderPickerOpen = false },
                        onOpenSystemSettings: { PermissionPanes.open(.notifications) })
                } else if teachPopoverOpen, let sel = teachSelection {
                    TeachFormView(
                        heard: sel.heard,
                        accent: SettingsTheme.accent,
                        reduceMotion: reduceMotion,
                        onReplaceHere: teachReplaceHere,
                        onReplaceEverywhere: teachReplaceEverywhere,
                        onReplaceAndTeach: teachReplaceAndTeach,
                        onClose: closeTeach)
                } else {
                    editor
                }
            } else {
                Spacer(minLength: 0)
                Text("This dictation was deleted.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(height: NotchMetrics.detailPanelHeight)
        .background(
            Color.black,
            in: RoundedRectangle(cornerRadius: NotchMetrics.detailPanelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NotchMetrics.detailPanelCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .onAppear { syncText(for: entry) }
        .onChange(of: entryID) { _, _ in syncText(for: entry) }
        .onDisappear { flush() }
        .hoverTipLayer()
    }

    // MARK: - Chip row

    @ViewBuilder
    private func chipRow(_ entry: DictationHistoryEntry) -> some View {
        HStack(spacing: 8) {
            appChip(entry)
            chip(text: TranscriptionCard.relative(entry.createdAt))
            chip(text: "\(entry.wordCount) words")
            chip(text: duration(entry.duration))
            if entry.kind != .dictation, entry.reminderState == .pending, let at = entry.reminderAt {
                reminderChip(at: at, taskText: ReminderParser.taskText(from: entry.finalText))
            }

            Spacer(minLength: 8)

            if entry.kind != .dictation {
                bellButton(entry)
            }
            actionButton("arrow.down.doc", help: "Insert again", flashed: inserted, flashLabel: "Inserted") {
                onInsertAgain(text)
                flashInserted()
            }
            actionButton("doc.on.doc", help: "Copy", flashed: copied, flashLabel: "Copied") {
                copyToPasteboard(text)
                flashCopied()
            }
            if entry.kind == .dictation {
                actionButton("note.text", help: "Save as note", flashed: savedAsNote, flashLabel: "Saved") {
                    history.convertToNote(id: entry.id)
                    flashSavedAsNote()
                }
            }
            starButton(entry)
            deleteButton(entry)
            closeButton
        }
    }

    private func appChip(_ entry: DictationHistoryEntry) -> some View {
        HStack(spacing: 5) {
            switch entry.kind {
            case .note:
                Image(systemName: "note.text").font(.system(size: 10))
                Text("Note").font(.system(size: 11, weight: .medium))
            case .meeting:
                Image(systemName: "person.2.wave.2.fill").font(.system(size: 10))
                Text("Meeting").font(.system(size: 11, weight: .medium))
            case .dictation:
                let identity = AppIdentity.displayName(for: entry)
                if let bundleID = identity.bundleID,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 10))
                }
                Text(identity.name).font(.system(size: 11, weight: .medium))
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
    }

    private func chip(text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
    }

    /// "Thu 7:00 PM" with a small x to cancel - a set reminder shown right in
    /// the chip row, same visual language as the app/time/words/duration
    /// chips beside it. Hovering the bell/time reads back what the reminder
    /// actually says (the note minus the "remind me..."/time-phrase
    /// scaffolding), since the chip itself only has room for the time.
    private func reminderChip(at date: Date, taskText: String) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
                Text(Self.stamp(date))
                    .font(.system(size: 11, weight: .medium))
            }
            .hoverTip(taskText)
            Button(action: onCancelReminder) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .pointer()
            .hoverTip("Cancel reminder")
            .accessibilityLabel("Cancel reminder")
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(SettingsTheme.accent.opacity(0.16), in: Capsule(style: .continuous))
    }

    /// Opens the inline picker. Filled and green once a reminder exists,
    /// translucent white otherwise, same on/off language as `MeetingToggle`.
    private func bellButton(_ entry: DictationHistoryEntry) -> some View {
        let hasReminder = entry.reminderState == .pending
        return Button {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.82)) {
                dismissTeach()
                reminderPickerOpen = true
            }
        } label: {
            Image(systemName: hasReminder ? "bell.fill" : "bell")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hasReminder ? SettingsTheme.accent : Color.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip("Set a reminder")
        .accessibilityLabel("Set a reminder")
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE h:mm a")
        return formatter.string(from: date)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Actions

    private func actionButton(
        _ symbol: String, help: String, flashed: Bool, flashLabel: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if flashed {
                    Text(flashLabel)
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, flashed ? 8 : 0)
            .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip(help)
        .accessibilityLabel(help)
    }

    private func starButton(_ entry: DictationHistoryEntry) -> some View {
        Button {
            history.toggleFavorite(id: entry.id)
        } label: {
            Image(systemName: entry.isFavorite ? "star.fill" : "star")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(entry.isFavorite ? Color.yellow.opacity(0.9) : .white.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip(entry.isFavorite ? "Remove from favorites" : "Add to favorites")
        .accessibilityLabel(entry.isFavorite ? "Remove from favorites" : "Add to favorites")
    }

    private func deleteButton(_ entry: DictationHistoryEntry) -> some View {
        Button {
            if deleteArmed {
                deleteArmTask?.cancel()
                history.remove(id: entry.id)
                onClose()
            } else {
                deleteArmed = true
                deleteArmTask?.cancel()
                deleteArmTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    deleteArmed = false
                }
            }
        } label: {
            Group {
                if deleteArmed {
                    Text("Sure?")
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(deleteArmed ? Color.black : Color.white.opacity(0.9))
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, deleteArmed ? 8 : 0)
            .background(
                deleteArmed ? Color(red: 1.0, green: 0.42, blue: 0.38) : Color.white.opacity(0.10),
                in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip(deleteArmed ? "Click again to delete" : "Delete")
        .accessibilityLabel(deleteArmed ? "Confirm delete" : "Delete")
    }

    private var closeButton: some View {
        Button(action: { flush(); onClose() }) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip("Close")
        .accessibilityLabel("Close detail panel")
    }

    // MARK: - Title (notes and meetings)

    private var titleField: some View {
        TextField("Title", text: $title)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .onChange(of: title) { _, newValue in
                scheduleTitleSave(newValue)
            }
    }

    // MARK: - Editor

    private var editor: some View {
        GeometryReader { proxy in
            SelectableTextView(
                text: $text,
                pointerRect: chipRect(in: proxy.size),
                highlightWords: entry?.corrections ?? [],
                highlightColor: NSColor(SettingsTheme.accent),
                onSelectionChange: { _, range, rect in
                    guard !teachPopoverOpen else { return }
                    let next = TeachSelection.build(text: text, rawRange: range, rect: rect)
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.1) : .easeOut(duration: 0.12)) {
                        teachSelection = next
                    }
                },
                onScroll: {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.1) : .easeIn(duration: 0.08)) {
                        teachSelection = nil
                        teachPopoverOpen = false
                    }
                }
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .focused($editorFocused)
            .onChange(of: text) { _, newValue in
                scheduleSave(newValue)
            }
            .overlay(alignment: .topLeading) { chipOverlay(in: proxy.size) }
            .overlay(alignment: .top) { flashOverlay }
        }
    }

    private let chipSize = CGSize(width: 74, height: 24)

    /// Where the chip sits in the editor's top-leading space: above the
    /// selection when there is room, otherwise right below it, never on top
    /// of the text (a first-line selection has no room above). Nil when no
    /// chip is showing. Also handed to the text view for the hand cursor.
    private func chipRect(in size: CGSize) -> CGRect? {
        guard let sel = teachSelection, !teachPopoverOpen else { return nil }
        let x = min(max(0, sel.rect.midX - chipSize.width / 2), max(0, size.width - chipSize.width))
        let above = sel.rect.minY - chipSize.height - 6
        let y = above >= 0 ? above : min(sel.rect.maxY + 6, max(0, size.height - chipSize.height))
        return CGRect(x: x, y: y, width: chipSize.width, height: chipSize.height)
    }

    @ViewBuilder
    private func chipOverlay(in size: CGSize) -> some View {
        if let rect = chipRect(in: size) {
            let x = rect.minX, y = rect.minY
            TeachChip {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.82)) {
                    teachPopoverOpen = true
                }
            }
            .frame(width: chipSize.width, height: chipSize.height, alignment: .center)
            .offset(x: x, y: y)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var flashOverlay: some View {
        if let flash = teachFlashText {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(flash)
                    .font(.system(size: 10.5, weight: .semibold))
                    .fixedSize()
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SettingsTheme.accent, in: Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                .padding(.top, 4)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Teach actions

    private func closeTeach() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.1) : .easeIn(duration: 0.08)) {
            teachPopoverOpen = false
            teachSelection = nil
        }
    }

    /// Click elsewhere in the panel (the chip row, the title field): dismiss
    /// the chip/popover without touching the text or the dictionary, same as
    /// Escape.
    private func dismissTeach() {
        reminderPickerOpen = false
        guard teachSelection != nil || teachPopoverOpen else { return }
        closeTeach()
    }

    private func teachReplaceHere(_ shouldBe: String) {
        guard let sel = teachSelection else { return }
        text = Teach.replaceRange(in: text, range: sel.range, with: shouldBe)
        history.addCorrection(id: entryID, word: shouldBe)
        closeTeach()
    }

    private func teachReplaceEverywhere(_ shouldBe: String) {
        guard let sel = teachSelection else { return }
        text = Teach.replaceEverywhere(in: text, heard: sel.heard, with: shouldBe)
        history.addCorrection(id: entryID, word: shouldBe)
        closeTeach()
    }

    private func teachReplaceAndTeach(_ shouldBeRaw: String, addToMyWords: Bool) {
        guard let sel = teachSelection else { return }
        let shouldBe = shouldBeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shouldBe.isEmpty else { closeTeach(); return }
        if shouldBe != sel.heard {
            text = Teach.replaceEverywhere(in: text, heard: sel.heard, with: shouldBe)
            history.addCorrection(id: entryID, word: shouldBe)
        }
        if addToMyWords {
            writeDictionaryEntry(heard: sel.heard, correct: shouldBe)
        }
        flashTaught(shouldBe)
        closeTeach()
    }

    private func writeDictionaryEntry(heard: String, correct: String) {
        guard let actions = settings.dictionaryActions else { return }
        let existing = actions.terms().first { $0.text.caseInsensitiveCompare(correct) == .orderedSame }
        let merged = Teach.mergedTerm(existing: existing, heard: heard, correct: correct)
        try? actions.add(merged)
    }

    private func flashTaught(_ word: String) {
        teachFlashText = "Taught: \(word)"
        teachFlashTask?.cancel()
        teachFlashTask = Task {
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            teachFlashText = nil
        }
    }

    // MARK: - Helpers

    private func syncText(for entry: DictationHistoryEntry?) {
        guard let entry, loadedID != entry.id else { return }
        teachSelection = nil
        teachPopoverOpen = false
        reminderPickerOpen = false
        text = entry.finalText
        title = entry.title ?? ""
        loadedID = entry.id
        if demoOpenTeach, let firstWord = text.split(separator: " ").first {
            let ns = text as NSString
            let range = ns.range(of: String(firstWord))
            if range.location != NSNotFound {
                teachSelection = TeachSelection(
                    heard: String(firstWord), range: range, rect: CGRect(x: 20, y: 44, width: 70, height: 16))
                teachPopoverOpen = true
            }
        }
        // A fresh empty note ("+ Note"): focus the editor once the panel has
        // become key, same delay the search field uses for the same reason.
        if entry.kind == .note, entry.finalText.isEmpty {
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                guard loadedID == entry.id else { return }
                editorFocused = true
            }
        }
    }

    private func scheduleTitleSave(_ newValue: String) {
        titleSaveTask?.cancel()
        titleSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            history.updateTitle(id: entryID, title: newValue)
        }
    }

    private func flashSavedAsNote() {
        savedAsNote = true
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            savedAsNote = false
        }
    }

    private func scheduleSave(_ newValue: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            history.updateText(id: entryID, finalText: newValue)
        }
    }

    /// Saves any unsaved edit immediately. Called from every close path via
    /// `onDisappear`, so an edit is never lost regardless of whether the
    /// panel closed through the X button, Escape or a click outside.
    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        titleSaveTask?.cancel()
        titleSaveTask = nil
        teachFlashTask?.cancel()
        teachFlashTask = nil
        teachSelection = nil
        teachPopoverOpen = false
        guard let entry else { return }
        if text != entry.finalText {
            history.updateText(id: entry.id, finalText: text)
        }
        if entry.kind != .dictation, title != (entry.title ?? "") {
            history.updateTitle(id: entry.id, title: title)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func flashInserted() {
        inserted = true
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            inserted = false
        }
    }
}
