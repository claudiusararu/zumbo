import AppKit
import SwiftUI
import VesperEngine

/// The expanded state, 720 wide. Two pages, switched by `page` (an
/// `ExpandedPage` on the model, not a different `NotchState`):
///
/// - History: search field, a row of app filter pills built from the
///   dictations on disk, then the transcription cards (row or grid).
/// - Settings: a back chevron, a left column of category pills, and the
///   bound controls for that category on the right.
struct ExpandedPanelView: View {

    @ObservedObject var history: HistoryStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var licenseState: LicenseState
    let page: ExpandedPage
    let historyLayout: HistoryLayout
    /// Set once by the `--settings-category` demo launch argument; `nil` in
    /// every normal run, which keeps the default `.general` selection.
    let initialSettingsCategory: String?
    /// Set once by the `--demo expanded-notes` screenshot path; `nil` in
    /// every normal run and every other demo, which keeps the default "All"
    /// selection.
    let initialKindFilter: EntryKind?
    /// For the Models category's status dot.
    let modelReady: Bool
    /// A key waiting to be pasted and activated (from `zumbo://activate`),
    /// consumed once by `LicenseSettingsView` then cleared via
    /// `onConsumePendingActivation`.
    let pendingActivationKey: String?
    let onConsumePendingActivation: () -> Void
    let onClose: () -> Void
    let onToggleLayout: () -> Void
    let onOpenSettings: () -> Void
    let onBack: () -> Void
    /// The card's text area was clicked (not an icon): open its detail panel.
    let onOpenDetail: (UUID) -> Void

    /// nil means "All". Otherwise the normalized app identity key (bundle id,
    /// or "Unknown app" for a system process / empty name) of the selected
    /// filter pill.
    @State private var selectedAppFilter: String?
    /// "Notes" or "Meetings" selected instead of "All" or an app pill. Mutually
    /// exclusive with `selectedAppFilter`: selecting either clears the other.
    @State private var kindFilter: EntryKind?
    /// The "Favorites" pill, combined with the app filter as an AND
    /// (favorites within the selected app).
    @State private var favoritesOnly = false
    /// The "Reminders" pill: every entry with a reminder still pending,
    /// soonest first. Mutually exclusive with `kindFilter`/`selectedAppFilter`,
    /// same as "Notes"/"Meetings".
    @State private var remindersOnly = false
    @State private var query = ""
    @State private var copiedID: UUID?
    @State private var settingsCategory: SettingsCategory
    @FocusState private var searchFocused: Bool
    /// Paging: the row layout always shows the newest 20, the grid starts at
    /// 60 and grows by 60 per "Show more" click. Search and filters apply
    /// before this cap, never after.
    @State private var gridVisibleCount = 60
    private let rowVisibleCount = 20

    init(
        history: HistoryStore, settings: AppSettings, licenseState: LicenseState, page: ExpandedPage, historyLayout: HistoryLayout,
        initialSettingsCategory: String? = nil, initialKindFilter: EntryKind? = nil, modelReady: Bool = false,
        pendingActivationKey: String? = nil, onConsumePendingActivation: @escaping () -> Void = {},
        onClose: @escaping () -> Void, onToggleLayout: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void, onBack: @escaping () -> Void,
        onOpenDetail: @escaping (UUID) -> Void
    ) {
        self.history = history
        self.settings = settings
        self.licenseState = licenseState
        self.page = page
        self.historyLayout = historyLayout
        self.initialSettingsCategory = initialSettingsCategory
        self.initialKindFilter = initialKindFilter
        self.modelReady = modelReady
        self.pendingActivationKey = pendingActivationKey
        self.onConsumePendingActivation = onConsumePendingActivation
        self.onClose = onClose
        self.onToggleLayout = onToggleLayout
        self.onOpenSettings = onOpenSettings
        self.onBack = onBack
        self.onOpenDetail = onOpenDetail
        _settingsCategory = State(
            initialValue: initialSettingsCategory.flatMap(SettingsCategory.init(rawValue:)) ?? .general)
        _kindFilter = State(initialValue: initialKindFilter)
    }

    private func filterKey(_ entry: DictationHistoryEntry) -> String {
        let identity = AppIdentity.displayName(for: entry)
        return identity.bundleID ?? identity.name
    }

    private var filteredEntries: [DictationHistoryEntry] {
        if remindersOnly {
            let ids = Set(history.filtered(by: query).map(\.id))
            return history.pendingReminders.filter { ids.contains($0.id) }
        }
        var base = history.filtered(by: query)
        if let kindFilter {
            base = base.filter { $0.kind == kindFilter }
        } else if let filter = selectedAppFilter {
            base = base.filter { $0.kind == .dictation && filterKey($0) == filter }
        }
        if favoritesOnly {
            base = base.filter(\.isFavorite)
        }
        return base
    }

    /// Paged for the current layout; search and filters already ran.
    private var pagedEntries: [DictationHistoryEntry] {
        let all = filteredEntries
        let limit = historyLayout == .grid ? gridVisibleCount : rowVisibleCount
        return Array(all.prefix(limit))
    }

    private var cardsToShow: [TranscriptionCard] {
        TranscriptionCard.cards(from: pagedEntries)
    }

    private var hasMoreToShow: Bool {
        historyLayout == .grid && filteredEntries.count > gridVisibleCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if page == .history {
                appFilterRow
                historyContent
            } else {
                SettingsPanelView(
                    history: history, settings: settings, licenseState: licenseState, category: $settingsCategory,
                    modelReady: modelReady, pendingActivationKey: pendingActivationKey,
                    onConsumePendingActivation: onConsumePendingActivation)
            }
            Spacer(minLength: 0)
        }
        .hoverTipLayer()
        .onChange(of: query) { _, _ in gridVisibleCount = 60 }
        .onChange(of: kindFilter) { _, _ in gridVisibleCount = 60 }
        .onChange(of: selectedAppFilter) { _, _ in gridVisibleCount = 60 }
        .onChange(of: favoritesOnly) { _, _ in gridVisibleCount = 60 }
        .onChange(of: remindersOnly) { _, _ in gridVisibleCount = 60 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if page == .settings {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .pointer()
                .hoverTip("Back")
                .accessibilityLabel("Back to history")

                Text("Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    TextField("Search transcriptions", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .focused($searchFocused)
                }
                .frame(width: 230, alignment: .leading)
                .onAppear {
                    // Wait for the panel to become key before grabbing focus.
                    Task {
                        try? await Task.sleep(for: .milliseconds(220))
                        searchFocused = true
                    }
                }
            }

            Spacer(minLength: 12)

            if page == .history {
                iconButton("gearshape", help: "Settings", action: onOpenSettings)
                iconButton(
                    historyLayout == .grid ? "rectangle.split.1x2" : "square.grid.2x2",
                    help: historyLayout == .grid ? "Show as a row" : "Show as a grid",
                    action: onToggleLayout
                )
            }
            iconButton("xmark", help: "Close", action: onClose)
        }
    }

    private func iconButton(_ symbol: String, help: String? = nil, action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(action == nil ? 0.5 : 0.9))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .pointer()
        .hoverTip(help ?? "")
    }

    // MARK: - App filter pills

    /// One pill per distinct app in the history, ordered by dictation count
    /// descending, "All" always first and selected by default. Clicking one
    /// filters the cards; the search field filters within that selection.
    private struct AppFilter: Identifiable {
        let id: String
        let name: String
        let count: Int
        let bundleID: String?
    }

    /// Grouped by the normalized identity, so a system process or an empty
    /// name from an old entry lands in the same "Unknown app" pill as a
    /// freshly captured one instead of its own raw process name.
    private var appFilters: [AppFilter] {
        var byKey: [String: AppFilter] = [:]
        for entry in history.entries where entry.kind == .dictation {
            let identity = AppIdentity.displayName(for: entry)
            let key = identity.bundleID ?? identity.name
            if let existing = byKey[key] {
                byKey[key] = AppFilter(
                    id: key, name: existing.name, count: existing.count + 1, bundleID: existing.bundleID)
            } else {
                byKey[key] = AppFilter(id: key, name: identity.name, count: 1, bundleID: identity.bundleID)
            }
        }
        return byKey.values.sorted {
            $0.count == $1.count
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.count > $1.count
        }
    }

    private var favoritesCount: Int {
        history.entries.filter(\.isFavorite).count
    }

    private var notesCount: Int {
        history.entries.filter { $0.kind == .note }.count
    }

    private var meetingsCount: Int {
        history.entries.filter { $0.kind == .meeting }.count
    }

    private var remindersCount: Int {
        history.pendingReminders.count
    }

    private var appFilterRow: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Anchor for "snap back to the start": the panel opens at the
                // union of its old and new widths and trims after the spring,
                // which used to leave this row scrolled a few points in.
                Color.clear.frame(width: 0, height: 0).id("filterRowStart")
                filterPill(name: "All", count: history.entries.count, bundleID: nil,
                           selected: selectedAppFilter == nil && kindFilter == nil && !remindersOnly) {
                    selectedAppFilter = nil
                    kindFilter = nil
                    remindersOnly = false
                }
                favoritesPill
                if notesCount > 0 {
                    kindPill(name: "Notes", count: notesCount, symbol: "note.text", kind: .note)
                }
                if meetingsCount > 0 {
                    kindPill(name: "Meetings", count: meetingsCount, symbol: "person.2.wave.2.fill", kind: .meeting)
                }
                if remindersCount > 0 {
                    remindersPill
                }
                if kindFilter == .note {
                    newNotePill
                }
                ForEach(appFilters) { filter in
                    filterPill(
                        name: filter.name, count: filter.count, bundleID: filter.bundleID,
                        selected: kindFilter == nil && selectedAppFilter == filter.id
                    ) {
                        kindFilter = nil
                        selectedAppFilter = filter.id
                        remindersOnly = false
                    }
                }
            }
            // A hair of room so the first pill's edge is never clipped by
            // the scroll view's own bounds.
            .padding(.horizontal, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onHover { NotchPanel.pointerOverHorizontalScroller = $0 }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { proxy.scrollTo("filterRowStart", anchor: .leading) }
                    .onChange(of: geo.size.width) { _, _ in
                        proxy.scrollTo("filterRowStart", anchor: .leading)
                    }
            })
        }
    }

    @ViewBuilder
    private func kindPill(name: String, count: Int, symbol: String, kind: EntryKind) -> some View {
        let selected = kindFilter == kind
        Button {
            kindFilter = selected ? nil : kind
            selectedAppFilter = nil
            remindersOnly = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? .black.opacity(0.4) : .white.opacity(0.4))
            }
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Color.white : Color.white.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
        .pointer()
    }

    /// Opens the detail panel on a fresh, empty note whose editor is focused,
    /// so the user can type or dictate straight into it.
    private var newNotePill: some View {
        Button {
            let id = history.createNote()
            onOpenDetail(id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Note")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip("New note")
    }

    /// Every entry with a reminder still pending, soonest first - shown only
    /// once at least one exists.
    private var remindersPill: some View {
        Button {
            let turningOn = !remindersOnly
            remindersOnly = turningOn
            if turningOn {
                kindFilter = nil
                selectedAppFilter = nil
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Reminders")
                    .font(.system(size: 12, weight: .medium))
                Text("\(remindersCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(remindersOnly ? .black.opacity(0.4) : .white.opacity(0.4))
            }
            .foregroundStyle(remindersOnly ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(remindersOnly ? Color.white : Color.white.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip("Notes and meetings with a reminder still pending")
    }

    private var favoritesPill: some View {
        Button {
            favoritesOnly.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                Text("Favorites")
                    .font(.system(size: 12, weight: .medium))
                Text("\(favoritesCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(favoritesOnly ? .black.opacity(0.4) : .white.opacity(0.4))
            }
            .foregroundStyle(favoritesOnly ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(favoritesOnly ? Color.white : Color.white.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
        .pointer()
    }

    @ViewBuilder
    private func filterPill(
        name: String, count: Int, bundleID: String?, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 14, height: 14)
                }
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? .black.opacity(0.4) : .white.opacity(0.4))
            }
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Color.white : Color.white.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
        .pointer()
    }

    // MARK: - History content

    @ViewBuilder
    private var historyContent: some View {
        switch historyLayout {
        case .row: cardsRow
        case .grid: cardsGrid
        }
    }

    private var cardsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if cardsToShow.isEmpty {
                    Text(history.entries.isEmpty
                         ? "No dictations yet. Hold Right Option to start one."
                         : "Nothing matches that search.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(height: 112, alignment: .center)
                } else {
                    ForEach(cardsToShow) { card in
                        TranscriptionCardView(
                            card: card, copied: copiedID == card.id,
                            onOpenDetail: { onOpenDetail(card.id) },
                            onCopy: { copy(card) },
                            onToggleFavorite: { history.toggleFavorite(id: card.id) })
                    }
                }
            }
            .padding(.bottom, 2)
        }
        .frame(height: NotchMetrics.expandedRowHeight)
    }

    /// Newest first (the same order `cardsToShow` already carries from
    /// `HistoryStore`), four columns, vertical scroll. `NotchPanel` bypasses
    /// its horizontal-scroll axis swap while this is on screen.
    private let gridColumnCount = 4
    private let gridSpacing: CGFloat = 10

    private var cardsGrid: some View {
        GeometryReader { proxy in
            OverlayScrollView {
                if cardsToShow.isEmpty {
                    Text(history.entries.isEmpty
                         ? "No dictations yet. Hold Right Option to start one."
                         : "Nothing matches that search.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(minWidth: proxy.size.width, minHeight: 112, alignment: .center)
                } else {
                    let cardWidth = gridCardWidth(for: proxy.size.width)
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing),
                            count: gridColumnCount),
                        spacing: gridSpacing
                    ) {
                        ForEach(cardsToShow) { card in
                            TranscriptionCardView(
                                card: card, width: cardWidth, copied: copiedID == card.id,
                                onOpenDetail: { onOpenDetail(card.id) },
                                onCopy: { copy(card) },
                                onToggleFavorite: { history.toggleFavorite(id: card.id) })
                        }
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
                    if hasMoreToShow {
                        showMoreButton
                            .frame(width: proxy.size.width)
                            .padding(.top, 4)
                    }
                    Color.clear.frame(height: 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: NotchMetrics.expandedGridHeight)
    }

    /// Cards fill the available width exactly, so four columns always fit
    /// regardless of the header's own horizontal padding.
    private func gridCardWidth(for availableWidth: CGFloat) -> CGFloat {
        let totalSpacing = gridSpacing * CGFloat(gridColumnCount - 1)
        return max(120, (availableWidth - totalSpacing) / CGFloat(gridColumnCount))
    }

    /// A centered pill under the grid, not a card-sized tile: it names how
    /// many more are waiting so the click is never a guess.
    private var showMoreButton: some View {
        let remaining = filteredEntries.count - gridVisibleCount
        let step = min(remaining, 60)
        return Button {
            gridVisibleCount += 60
        } label: {
            HStack(spacing: 5) {
                Text("Show \(step) more")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip("\(remaining) more in this list")
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func copy(_ card: TranscriptionCard) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.text, forType: .string)
        copiedID = card.id
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            if copiedID == card.id { copiedID = nil }
        }
    }

    // MARK: - Settings
    //
    // The category enum lives here because it is this view's own `@State`
    // type; everything else about the Settings page (the sidebar, the cards,
    // every category's content) is `SettingsPanelView.swift`.

    enum SettingsCategory: String, CaseIterable, Identifiable {
        case general = "General"
        case dictation = "Dictation"
        case dictionary = "Dictionary"
        case models = "Models"
        case license = "License"
        case feedback = "Feedback"
        case about = "About"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .dictation: return "waveform"
            case .dictionary: return "book"
            case .models: return "cpu"
            case .license: return "key"
            case .feedback: return "bubble.left.and.text.bubble.right"
            case .about: return "info.circle"
            }
        }

        /// One-sentence subtitle under the 15 pt page title in
        /// `SettingsPanelView`.
        var subtitle: String {
            switch self {
            case .general: return "How Zumbo starts and how you trigger it"
            case .dictation: return "What Zumbo cleans up after it hears you"
            case .dictionary: return "The words Zumbo spells the way you mean them"
            case .models: return "The speech engine running on this Mac"
            case .license: return "Your trial and license"
            case .feedback: return "Tell us what works, what does not, and what you wish Zumbo did."
            case .about: return "Version, updates and credits"
            }
        }
    }
}

// MARK: - Card

struct TranscriptionCard: Identifiable {
    let id: UUID
    let text: String
    let bundleID: String?
    let appName: String
    let relativeTime: String
    let words: Int
    let shortcut: String
    let isFavorite: Bool
    let kind: EntryKind
    let title: String?
    /// Short "Thu 7 PM" stamp for a pending reminder's bell chip, nil
    /// otherwise (no reminder, or one already done/missed).
    let reminderStamp: String?

    /// The first nine cards get the Control-number badge the reference shows;
    /// the shortcuts themselves are not bound yet. The app identity is
    /// normalized here, so an old entry captured before `AppIdentity` existed
    /// (or one from a system process) still renders as "Unknown app" with the
    /// generic icon instead of a raw process name.
    static func cards(from entries: [DictationHistoryEntry]) -> [TranscriptionCard] {
        entries.enumerated().map { index, entry in
            let identity = AppIdentity.displayName(for: entry)
            return TranscriptionCard(
                id: entry.id,
                text: entry.finalText,
                bundleID: identity.bundleID,
                appName: identity.name,
                relativeTime: Self.relative(entry.createdAt),
                words: entry.wordCount,
                shortcut: index < 9 ? "^\(index + 1)" : "",
                isFavorite: entry.isFavorite,
                kind: entry.kind,
                title: entry.title,
                reminderStamp: (entry.reminderState == .pending) ? Self.shortReminderStamp(entry.reminderAt) : nil
            )
        }
    }

    /// "Thu 7 PM" - the card's meta row is one tight fixed line, so this
    /// drops the minutes when they are :00, unlike the detail panel's fuller
    /// "Thu 7:00 PM".
    private static func shortReminderStamp(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: date)
        formatter.setLocalizedDateFormatFromTemplate(minute == 0 ? "EEE h a" : "EEE h:mm a")
        return formatter.string(from: date)
    }

    /// A fresh formatter per call: `RelativeDateTimeFormatter` is not
    /// `Sendable`, so a shared static would be concurrency-unsafe under Swift 6
    /// strict concurrency, and a handful of cards is cheap to format. Not
    /// private: the history detail panel's chip row reuses it.
    static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct TranscriptionCardView: View {

    let card: TranscriptionCard
    /// 168 in the row layout. The grid layout passes a narrower width so four
    /// columns fit the panel's fixed 720 pt width.
    var width: CGFloat = 168
    let copied: Bool
    /// The text area was clicked: open the detail panel.
    let onOpenDetail: () -> Void
    /// The corner copy icon was clicked.
    let onCopy: () -> Void
    let onToggleFavorite: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if card.kind != .dictation, let title = card.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(card.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineSpacing(2)
                    .lineLimit(card.kind != .dictation && card.title?.isEmpty == false ? 3 : 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)

            metaRow
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
        }
        .frame(width: width, height: 112)
        .background(
            Color.white.opacity(hovering ? 0.11 : 0.07),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(copied ? 0.25 : 0.07), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetail)
        .onHover { hovering = $0 }
        .pointer()
        .accessibilityLabel("\(card.appName), \(card.relativeTime), \(card.words) words")
    }

    /// A 12 pt corner icon, white at 55% opacity by default and full white on
    /// its own hover, always rendered (never gated behind the card's hover
    /// state) so the actions stay discoverable.
    private func cornerIcon(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        CornerIconButton(symbol: symbol, tint: tint, help: help, action: action)
    }

    // MARK: - Meta row

    /// Single fixed line, never wraps: app icon, time, word count, shortcut
    /// badge. `ViewThatFits` drops the badge first, then the word count, as
    /// the card narrows in the grid layout, instead of truncating or wrapping.
    @ViewBuilder
    private var metaRow: some View {
        if copied {
            HStack(spacing: 6) {
                Text("Copied")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                actionIcons
            }
        } else {
            ViewThatFits(in: .horizontal) {
                metaLine(showWords: true, showBadge: true)
                metaLine(showWords: true, showBadge: false)
                metaLine(showWords: false, showBadge: false)
            }
        }
    }

    /// The star and copy actions sit at the right end of the meta row, never
    /// over the text: on top of the transcript they were unreadable.
    private var actionIcons: some View {
        HStack(spacing: 4) {
            cornerIcon(card.isFavorite ? "star.fill" : "star", tint: card.isFavorite ? .yellow : .white,
                       help: card.isFavorite ? "Remove from favorites" : "Add to favorites",
                       action: onToggleFavorite)
            cornerIcon("doc.on.doc", tint: .white, help: "Copy", action: onCopy)
        }
    }

    /// The bell chip a card with a pending reminder shows in its meta row -
    /// same priority as the shortcut badge, so it drops first as the grid
    /// narrows rather than crowding the icons out.
    private func reminderBadge(_ stamp: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "bell.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(stamp)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(SettingsTheme.accent)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(SettingsTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func metaLine(showWords: Bool, showBadge: Bool) -> some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 14, height: 14)
            Text(card.relativeTime)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .fixedSize()
            if showWords {
                Spacer(minLength: 4)
                Text("\(card.words) words")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Spacer(minLength: 0)
            }
            if showBadge, !card.shortcut.isEmpty {
                Text(card.shortcut)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if showBadge, let reminderStamp = card.reminderStamp {
                reminderBadge(reminderStamp)
            }
            actionIcons
        }
    }

    /// A note or a meeting gets a small kind glyph instead of an app icon,
    /// since neither one was pasted into an app. Otherwise the real icon of
    /// the app the text went into, or a neutral glyph if that app is not
    /// installed. Never a faked stand-in.
    @ViewBuilder
    private var icon: some View {
        switch card.kind {
        case .note:
            Image(systemName: "note.text")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        case .meeting:
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        case .dictation:
            if let bundleID = card.bundleID,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

/// A card corner icon: 12 pt, white (or yellow when favorited) at 55%
/// opacity, full opacity on its own hover. Always visible, not shown only on
/// the card's hover, so favoriting and copying stay discoverable.
private struct CornerIconButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.55))
                .frame(width: 18, height: 18)
                .background(Color.black.opacity(hovering ? 0.25 : 0), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointer()
        .hoverTip(help)
        .accessibilityLabel(help)
    }
}
