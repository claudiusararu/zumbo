import AppKit
import SwiftUI
import VesperEngine

/// The Settings page's own visual language: black, white text at a few fixed
/// alphas, translucent pills and chips, tight radii - the same language the
/// History page already uses for its filter pills, just organized into
/// cards. One accent color, used in exactly three jobs: a toggle's "on"
/// track, the selected option in `SettingsSegmented`, and a status dot.
/// Selection everywhere else (sidebar rows, pill buttons) stays the existing
/// white-pill treatment.
enum SettingsTheme {
    /// A clean, saturated green - the panel's one signal color. Never mixed
    /// with a second accent hue.
    static let accent = Color(red: 0.19, green: 0.82, blue: 0.35)
}

/// Settings, redesigned: a left column of category rows (icon + label,
/// selected = white pill) and a right column of cards (white 6% fill, 12 pt
/// radius, 1 px white 7% border), each grouping related rows behind a 12 pt
/// semibold title. Same overall height as before
/// (`NotchMetrics.expandedSettingsBodyHeight`); only the right column
/// scrolls, through the panel's existing thin overlay scroller.
struct SettingsPanelView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var licenseState: LicenseState
    @Binding var category: ExpandedPanelView.SettingsCategory
    let modelReady: Bool
    var pendingActivationKey: String? = nil
    var onConsumePendingActivation: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            sidebar
            OverlayScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
            // A fresh identity per category so the scroll view (and its
            // offset) is rebuilt at the top instead of keeping whatever
            // offset the previous category's page was scrolled to.
            .id(category)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: NotchMetrics.expandedSettingsBodyHeight, alignment: .top)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ExpandedPanelView.SettingsCategory.allCases) { item in
                sidebarRow(item)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 148, alignment: .leading)
    }

    private func sidebarRow(_ item: ExpandedPanelView.SettingsCategory) -> some View {
        let selected = category == item
        return Button {
            category = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 15)
                Text(item.rawValue)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Color.white : Color.white.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
        .pointer()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            categoryHeader
            categoryBody
        }
    }

    /// 15 pt semibold page title plus an 11 pt muted one-sentence subtitle,
    /// same for every category, from `SettingsCategory.rawValue`/`.subtitle`.
    private var categoryHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(category.rawValue)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
            Text(category.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var categoryBody: some View {
        switch category {
        case .general: GeneralSettingsView(settings: settings, history: history)
        case .dictation: DictationSettingsView(settings: settings)
        case .dictionary: DictionarySettingsView(settings: settings)
        case .models: ModelsSettingsView(modelReady: modelReady, settings: settings)
        case .license:
            LicenseSettingsView(
                licenseState: licenseState, pendingActivationKey: pendingActivationKey,
                onConsumePendingActivation: onConsumePendingActivation)
        case .feedback: FeedbackSettingsView(licenseState: licenseState)
        case .about: AboutSettingsView(settings: settings)
        }
    }
}

// MARK: - Shared chrome

/// White 6% fill, 12 pt radius, 14 pt padding, 1 px white 7% border, a 12 pt
/// semibold title, and whatever rows the caller supplies.
struct SettingsCard<Content: View, Trailing: View>: View {
    let title: String
    let trailing: Trailing
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) where Trailing == EmptyView {
        self.title = title
        self.trailing = EmptyView()
        self.content = content()
    }

    /// Same card, with an optional control (currently only "My words"'s
    /// "Add" pill) on the title's line, right-aligned.
    init(title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

/// One settings row: a 12 pt label, an optional one-line 10.5 pt muted
/// description under it, and a right-aligned control.
struct SettingsRow<Control: View>: View {
    let label: String
    var description: String?
    let control: Control

    init(label: String, description: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.description = description
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.92))
                if let description {
                    Text(description)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 10)
            control
        }
        .padding(.vertical, 8)
    }
}

/// 1 px white 6% line between rows in a card.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }
}

/// A disabled control with a "soon"/"coming next" `hoverTip`, dimmed so the
/// disabled state reads at a glance, not just on hover.
private struct SoonModifier: ViewModifier {
    let text: String
    func body(content: Content) -> some View {
        content
            .disabled(true)
            .opacity(0.45)
            .hoverTip(text)
    }
}

extension View {
    fileprivate func soon(_ text: String = "soon") -> some View {
        modifier(SoonModifier(text: text))
    }
}

/// Small translucent pill button, the same chip language as the header icons
/// and the history filter pills, used for every secondary text button in
/// Settings (Activate, Re-download, Check for updates, chip presets...).
private struct PillButton: View {
    let title: String
    var filled = false
    /// The one green-accent pill (Settings > License's "Buy Zumbo"):
    /// `SettingsTheme.accent` fill, black text, same size as `filled`.
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle((filled || accent) ? Color.black : Color.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(accent ? SettingsTheme.accent : (filled ? Color.white : Color.white.opacity(0.10)))
                )
        }
        .buttonStyle(.plain)
        .pointer()
    }
}

/// Custom 34x20 pill switch: track white 22% off (so the off state stays
/// obviously visible on black, not just barely-there), `SettingsTheme.accent`
/// on, a white-85% knob with a soft shadow, spring-animated.
struct PillToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? SettingsTheme.accent : Color.white.opacity(0.22))
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .padding(2)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
            }
            .frame(width: 34, height: 20)
        }
        .buttonStyle(.plain)
        .pointer()
    }
}

/// Pill menu for a single choice from a short named list - the "Main
/// language" row's control. Same chrome as `PillButton` (translucent white
/// capsule) with a chevron, opens a native `Menu` of every
/// `DictationLanguageOption` in `VesperEngine`'s menu order, the current
/// choice checkmarked.
struct LanguagePickerMenu: View {
    @Binding var code: String

    private var selectedName: String {
        DictationLanguageOption.menuOptions.first { $0.code == code }?.displayName ?? "English"
    }

    var body: some View {
        Menu {
            ForEach(DictationLanguageOption.menuOptions) { option in
                Button {
                    code = option.code
                } label: {
                    if option.code == code {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selectedName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointer()
    }
}

/// Segmented control. The selected option fills with `SettingsTheme.accent`
/// (one of its three jobs), unselected options stay the translucent track.
struct SettingsSegmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Color.black : Color.white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? SettingsTheme.accent : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointer()
            }
        }
    }
}

// MARK: - General

/// Live status for the three permissions Zumbo asks onboarding for, so a
/// permission revoked (or never finished) after onboarding is visible and
/// fixable without re-running setup. Polls every 2 s while this page is on
/// screen, plus once whenever the app becomes active (System Settings
/// closing after a grant), so the marks never go stale.
private struct PermissionsCard: View {
    @State private var micState: OnboardingMarkState = .notAsked
    @State private var accessibilityState: OnboardingMarkState = .notAsked
    @State private var inputMonitoringState: OnboardingMarkState = .notAsked

    var body: some View {
        SettingsCard(title: "Permissions") {
            VStack(spacing: 0) {
                permissionRow(
                    state: micState, name: "Microphone",
                    description: "Hears you while you hold or toggle the shortcut.",
                    pane: .microphone)
                SettingsDivider()
                permissionRow(
                    state: accessibilityState, name: "Accessibility",
                    description: "Types the text where your cursor is.",
                    pane: .accessibility)
                SettingsDivider()
                permissionRow(
                    state: inputMonitoringState, name: "Input Monitoring",
                    description: "Lets Escape cancel a recording and your shortcut work in every app.",
                    note: "No restart needed; if macOS offers to quit and reopen, choose Later.",
                    pane: .inputMonitoring)
            }
        }
        .task { await pollWhileVisible() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .onAppear { refresh() }
    }

    private func permissionRow(
        state: OnboardingMarkState, name: String, description: String, note: String? = nil, pane: PermissionPanes
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            OnboardingMark(state: state)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.92))
                Text(description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
                if state != .granted, let note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 10)
            if state != .granted {
                PillButton(title: "Open System Settings") { PermissionPanes.open(pane) }
            }
        }
        .padding(.vertical, 8)
    }

    private func refresh() {
        micState = MicrophonePermission.isAuthorized() ? .granted : .notAsked
        accessibilityState = TextInserter.isAccessibilityTrusted() ? .granted : .notAsked
        inputMonitoringState = CGPreflightListenEventAccess() ? .granted : .notAsked
    }

    private func pollWhileVisible() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PermissionsCard()
            SettingsCard(title: "Shortcut") {
                VStack(spacing: 12) {
                    ShortcutRecorderRow(settings: settings)
                    SettingsDivider()
                    ShortcutRecorderRow(settings: settings, isNote: true)
                }
            }
            HistoryRetentionCard(history: history, settings: settings)
            SettingsCard(title: "Behavior") {
                VStack(spacing: 0) {
                    SettingsRow(
                        label: "Launch at login",
                        description: settings.launchAtLoginNeedsApproval
                            ? "Approve Zumbo in System Settings > General > Login Items"
                            : "Open Zumbo automatically when you sign in."
                    ) {
                        if settings.launchAtLoginNeedsApproval {
                            PillButton(title: "Open Settings") { LaunchAtLogin.openLoginItemsSettings() }
                        } else {
                            PillToggle(isOn: $settings.launchAtLogin)
                        }
                    }
                    SettingsDivider()
                    SettingsRow(
                        label: "Play sounds", description: "A short tone when a dictation starts and finishes, and when a reminder fires."
                    ) {
                        PillToggle(isOn: $settings.playSounds)
                    }
                    SettingsDivider()
                    SettingsRow(
                        label: "Show menu bar icon", description: "Hide the waveform icon; the shortcut still works."
                    ) {
                        PillToggle(isOn: $settings.showMenuBarIcon)
                    }
                    SettingsDivider()
                    SettingsRow(
                        label: "Hide Dock icon",
                        description: "Keep Zumbo out of the Dock; it lives in the notch and the menu bar."
                    ) {
                        PillToggle(isOn: $settings.hideDockIcon)
                    }
                }
            }
        }
    }
}

/// "Keep dictations for" segmented control plus "Clear history". Favorites,
/// notes and meetings are exempt from both retention and the plain clear.
private struct HistoryRetentionCard: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var settings: AppSettings

    @State private var clearArmed = false
    @State private var clearArmTask: Task<Void, Never>?

    private let options: [(value: Int, label: String)] = [
        (7, "7 days"), (30, "30 days"), (90, "90 days"), (0, "Forever"),
    ]

    var body: some View {
        SettingsCard(title: "History") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsSegmented(options: options, selection: $settings.retentionDays)
                Text("Favorites, notes and meetings are always kept.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
                SettingsDivider()
                SettingsRow(
                    label: "Clear history",
                    description: "Removes everything except favorites, notes and meetings."
                ) {
                    HStack(spacing: 6) {
                        clearButton
                        Menu {
                            Button("Everything", role: .destructive) {
                                history.clearHistory(includingProtected: true)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.08), in: Circle())
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .pointer()
                        .hoverTip("More options")
                    }
                }
            }
        }
    }

    private var clearButton: some View {
        Button {
            if clearArmed {
                clearArmTask?.cancel()
                clearArmed = false
                history.clearHistory(includingProtected: false)
            } else {
                clearArmed = true
                clearArmTask?.cancel()
                clearArmTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    clearArmed = false
                }
            }
        } label: {
            Text(clearArmed ? "Sure?" : "Clear")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(clearArmed ? Color.black : Color.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    clearArmed ? Color(red: 1.0, green: 0.42, blue: 0.38) : Color.white.opacity(0.10),
                    in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .pointer()
        .hoverTip(clearArmed ? "Click again to clear" : "Clear history")
    }
}

// MARK: - Dictation

struct DictationSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Language") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(spacing: 0) {
                        SettingsRow(label: "Main language") {
                            LanguagePickerMenu(code: $settings.language)
                                .hoverTip("The language you dictate in most")
                        }
                        SettingsDivider()
                        SettingsRow(
                            label: "I also dictate in other languages",
                            description: "Lets the engine guess the language per sentence. Slightly less accurate in your main language."
                        ) {
                            PillToggle(isOn: $settings.multilingual)
                                .hoverTip("Auto-detect the language per sentence")
                        }
                    }
                    Text("Zumbo writes only in your main language's alphabet, so English never comes out in Cyrillic.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            SettingsCard(title: "Clean speech") {
                SettingsRow(
                    label: "Clean speech",
                    description: "Drops filler words (um, uh, like), trims false starts, and collapses repeated words."
                ) {
                    PillToggle(isOn: rulesBinding(\.cleanSpeech))
                }
            }

            SettingsCard(title: "Formatting") {
                VStack(spacing: 0) {
                    SettingsRow(label: "Numbers", description: "\u{201c}two hundred\u{201d} becomes \u{201c}200\u{201d}") {
                        PillToggle(isOn: rulesBinding(\.numbers))
                    }
                    SettingsDivider()
                    SettingsRow(label: "Currency", description: "\u{201c}two hundred bucks\u{201d} becomes \u{201c}$200\u{201d}") {
                        PillToggle(isOn: rulesBinding(\.currency))
                    }
                    SettingsDivider()
                    SettingsRow(
                        label: "Spoken punctuation", description: "\u{201c}dash dash force\u{201d} becomes \u{201c}--force\u{201d}"
                    ) {
                        PillToggle(isOn: rulesBinding(\.spokenPunctuation))
                    }
                    SettingsDivider()
                    SettingsRow(
                        label: "End punctuation", description: "Adds a period or question mark when you don't say one"
                    ) {
                        PillToggle(isOn: rulesBinding(\.endPunctuation))
                    }
                    SettingsDivider()
                    SettingsRow(label: "Contractions", description: "\u{201c}gonna\u{201d} becomes \u{201c}going to\u{201d}") {
                        PillToggle(isOn: rulesBinding(\.contractions))
                    }
                }
            }

            SettingsCard(title: "Developer mode") {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsSegmented(
                        options: [(DeveloperMode.auto, "Auto"), (.always, "Always"), (.off, "Off")],
                        selection: developerModeBinding
                    )
                    Text("Auto boosts developer vocabulary only when the frontmost app or your words look technical.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            SettingsCard(title: "Meeting mode") {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsRow(
                        label: "Label speakers",
                        description: addOnInstalled
                            ? "Every voice gets a number, e.g. \u{201c}Speaker 1: Let\u{2019}s ship Friday. "
                                + "Speaker 2: Agreed.\u{201d}"
                            : "Turn on the add-on in Settings > Models first"
                    ) {
                        PillToggle(isOn: $settings.labelSpeakers)
                            .disabled(!addOnInstalled)
                            .opacity(addOnInstalled ? 1 : 0.45)
                    }
                }
            }
        }
    }

    /// Mirrors Settings > Models' "Speaker labels" row: this switch only
    /// does anything once the add-on is actually on disk.
    private var addOnInstalled: Bool {
        if case .ready = settings.speakerModelStatus { return true }
        return false
    }

    private func rulesBinding(_ keyPath: WritableKeyPath<RulesConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.rules[keyPath: keyPath] },
            set: { settings.rules[keyPath: keyPath] = $0 }
        )
    }

    private var developerModeBinding: Binding<DeveloperMode> {
        Binding(get: { settings.developerMode }, set: { settings.developerMode = $0 })
    }
}

// MARK: - Dictionary

struct DictionarySettingsView: View {
    @ObservedObject var settings: AppSettings

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    @State private var words: [DictionaryTerm] = []
    @State private var showingAddForm = false
    @State private var editingText: String?
    @State private var newWord = ""
    @State private var newSpokenForms = ""
    @State private var spokenFormsEditedByHand = false
    @State private var searchQuery = ""
    /// Paging: the list starts at the newest 10; this pill expands it to
    /// everything. Resets whenever the Settings page is left, because
    /// `.id(category)` in `SettingsPanelView` rebuilds this view (and its
    /// `@State`) fresh each time the Dictionary category is entered.
    @State private var showingAllWords = false

    private var formOpen: Bool { showingAddForm || editingText != nil }

    private var searchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `words` filtered by the search query (text or any alias, case
    /// insensitive), over the full list regardless of paging.
    private var searchMatches: [DictionaryTerm] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return words }
        return words.filter { term in
            term.text.lowercased().contains(q) || term.aliases.contains { $0.lowercased().contains(q) }
        }
    }

    /// What the list actually renders: every match while searching (paging
    /// is off), otherwise the newest `visibleWordLimit` or everything, per `showingAllWords`.
    private var visibleWords: [DictionaryTerm] {
        if searchActive { return searchMatches }
        return showingAllWords ? words : Array(words.prefix(Self.visibleWordLimit))
    }

    /// Newest words shown before "Show all" (owner's choice, 2026-09-18).
    static let visibleWordLimit = 3

    private var showPagingControl: Bool { !searchActive && words.count > Self.visibleWordLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "My words", trailing: {
                HStack(spacing: 8) {
                    if !formOpen && words.count > Self.visibleWordLimit {
                        dictionarySearchField
                    }
                    if !formOpen {
                        PillButton(title: "Add") { beginAdd() }
                    }
                }
            }) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsDivider()
                    if showingAddForm {
                        wordForm(existing: nil)
                        SettingsDivider()
                    }
                    if words.isEmpty && !showingAddForm {
                        Text("Words you teach Zumbo appear here")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.vertical, 8)
                    } else {
                        wordsList
                    }
                }
            }

            SettingsCard(title: "Packs") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Each pack teaches Zumbo how to spell the terms of a field, so they come out right the first time. Turn on the ones you use. Packs you do not need just add noise.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        PillButton(title: "Developer preset") { settings.enabledPacks = AppSettings.defaultPacks }
                        PillButton(title: "All") { settings.enabledPacks = Set(AppSettings.allPacks) }
                        Spacer(minLength: 0)
                    }
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(PackCatalog.all, id: \.id) { pack in
                            PackTile(pack: pack, isOn: packBinding(pack.id))
                        }
                    }
                }
            }
        }
        .onAppear { reloadWords() }
    }

    private func packBinding(_ pack: String) -> Binding<Bool> {
        Binding(
            get: { settings.enabledPacks.contains(pack) },
            set: { on in
                if on { settings.enabledPacks.insert(pack) } else { settings.enabledPacks.remove(pack) }
            }
        )
    }

    // MARK: - My words

    private var spokenFormsBinding: Binding<String> {
        Binding(
            get: { newSpokenForms },
            set: { newSpokenForms = $0; spokenFormsEditedByHand = true }
        )
    }

    private func beginAdd() {
        newWord = ""
        newSpokenForms = ""
        spokenFormsEditedByHand = false
        editingText = nil
        showingAddForm = true
    }

    /// Pencil on a row: same form as Add, prefilled from the existing entry.
    /// Only one row edits at a time, and it closes the Add form if that was
    /// open.
    private func beginEdit(_ term: DictionaryTerm) {
        newWord = term.text
        newSpokenForms = term.aliases.joined(separator: ", ")
        spokenFormsEditedByHand = true
        showingAddForm = false
        editingText = term.text
    }

    private func cancelForm() {
        showingAddForm = false
        editingText = nil
    }

    /// `existing` nil means the Add form; otherwise the entry being edited,
    /// whose `source`, `enabled` and `minSimilarity` carry over unchanged.
    /// A changed word text is a remove-then-add (the store keys entries by
    /// text), so it never leaves the old spelling behind under a new one.
    private func saveForm(existing: DictionaryTerm?) {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let aliases = newSpokenForms
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let term = DictionaryTerm(
            text: word,
            aliases: aliases.isEmpty ? [word.lowercased()] : aliases,
            enabled: existing?.enabled ?? true,
            minSimilarity: existing?.minSimilarity,
            pack: existing?.pack,
            source: existing?.source ?? "typed",
            addedAt: existing?.addedAt ?? Date())
        if let existing, existing.text.caseInsensitiveCompare(word) != .orderedSame {
            try? settings.dictionaryActions?.remove(existing.text)
        }
        try? settings.dictionaryActions?.add(term)
        reloadWords()
        showingAddForm = false
        editingText = nil
    }

    private func deleteWord(_ term: DictionaryTerm) {
        try? settings.dictionaryActions?.remove(term.text)
        reloadWords()
    }

    /// Newest first, then by text, so a fresh Add or Teach always lands at
    /// the top.
    private func reloadWords() {
        let all = settings.dictionaryActions?.terms() ?? []
        words = all.sorted { lhs, rhs in
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
            return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending
        }
    }

    private func wordForm(existing: DictionaryTerm?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            dictionaryFormField(label: "Word", placeholder: "NSPanel", text: $newWord)
                .onChange(of: newWord) { _, newValue in
                    if !spokenFormsEditedByHand { newSpokenForms = SpokenFormSuggestion.suggest(for: newValue) }
                }
            dictionaryFormField(label: "How you say it", placeholder: "n s panel, ns panel", text: spokenFormsBinding)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                PillButton(title: "Cancel") { cancelForm() }
                    .keyboardShortcut(.cancelAction)
                PillButton(title: "Save", filled: true) { saveForm(existing: existing) }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .onExitCommand { cancelForm() }
    }

    private func dictionaryFormField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private var wordsList: some View {
        VStack(spacing: 0) {
            if searchActive && visibleWords.isEmpty {
                Text("No words match.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(visibleWords.enumerated()), id: \.element.text) { index, term in
                    if index > 0 { SettingsDivider() }
                    if editingText == term.text {
                        wordForm(existing: term)
                    } else {
                        wordRow(term)
                    }
                }
            }
            if showPagingControl {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    PillButton(title: showingAllWords ? "Show fewer" : "Show all \(words.count) words") {
                        showingAllWords.toggle()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
        }
    }

    /// Same look as the History search field in `ExpandedPanelView`'s
    /// header: a magnifying glass plus a plain text field, no box of its
    /// own. Shown only once there are more than `visibleWordLimit` words to search through.
    private var dictionarySearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            TextField("Search my words", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
        }
        .frame(width: 140, alignment: .leading)
    }

    private func wordRow(_ term: DictionaryTerm) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(term.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.92))
                if !term.aliases.isEmpty {
                    Text(term.aliases.joined(separator: ", "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 8)
            // 24 pt hit areas with the pointing hand, so the two small icons
            // are easy to hit and obviously clickable.
            Button { beginEdit(term) } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointer()
            .hoverTip("Edit this word")
            Button { deleteWord(term) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointer()
            .hoverTip("Delete")
        }
        .padding(.vertical, 8)
    }
}

/// Prefills the "How you say it" field from a canonical spelling: splits on
/// camelCase/digit boundaries, spells an all-caps token (an acronym, e.g.
/// "NS") letter by letter, and lowercases an ordinary token as one word
/// (e.g. "Panel" -> "panel"), then offers that plus the same tokens read as
/// whole words - "NSPanel" -> "n s panel, ns panel". A single-token word
/// like "kubectl" yields just the one guess (the two forms coincide). The
/// user can always edit or replace the result by hand.
enum SpokenFormSuggestion {
    static func tokens(for word: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let chars = Array(word)
        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        for i in chars.indices {
            let c = chars[i]
            if c == "_" || c == "-" || c == " " {
                flush()
                continue
            }
            if c.isNumber {
                if let last = current.last, !last.isNumber { flush() }
                current.append(c)
                continue
            }
            if let last = current.last, last.isNumber { flush() }
            if c.isUppercase, !current.isEmpty {
                let prevIsLower = current.last?.isLowercase ?? false
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                let prevIsUpper = current.last?.isUppercase ?? false
                if prevIsLower || (nextIsLower && prevIsUpper) { flush() }
            }
            current.append(c)
        }
        flush()
        return tokens
    }

    private static func isAcronym(_ token: String) -> Bool {
        token.count > 1 && token == token.uppercased() && token.contains { $0.isLetter }
    }

    static func suggest(for word: String) -> String {
        let toks = tokens(for: word)
        guard !toks.isEmpty else { return "" }
        let spelled = toks.map { token -> String in
            isAcronym(token) ? token.map { String($0).lowercased() }.joined(separator: " ") : token.lowercased()
        }.joined(separator: " ")
        let asWords = toks.map { $0.lowercased() }.joined(separator: " ")
        return spelled == asWords ? spelled : "\(spelled), \(asWords)"
    }
}

private struct PackTile: View {
    let pack: PackCatalog.Pack
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(pack.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("\(pack.termCount) terms")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 6)
                PillToggle(isOn: $isOn)
            }
            Text(pack.description)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        // Full description always; the grid row takes the tallest tile so
        // tiles in a row stay equal in height without cutting text.
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .hoverTip(pack.sampleTerms.joined(separator: ", "))
    }
}

// MARK: - Models

struct ModelsSettingsView: View {
    let modelReady: Bool
    @ObservedObject var settings: AppSettings
    @State private var removeConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Speech engine") {
                VStack(spacing: 0) {
                    SettingsRow(
                        label: "Zumbo engine",
                        description: "Turns your voice into text in about a fifth of a second, entirely on this Mac. "
                            + "Learns the way you talk: every word you teach or correct is recognised next time, "
                            + "so it gets better the more you use it."
                    ) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(modelReady ? SettingsTheme.accent : Color.white.opacity(0.25))
                                .frame(width: 7, height: 7)
                            Text(modelReady ? "Ready" : "Loading")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    SettingsDivider()
                    SettingsRow(label: "Storage", description: "1.0 GB on disk. Nothing you say leaves this Mac, ever.") {
                        EmptyView()
                    }
                    SettingsDivider()
                    SettingsRow(label: "Re-download", description: "Fetch the engine again if it is ever missing or damaged.") {
                        PillButton(title: "Re-download", action: {}).soon()
                    }
                }
            }

            SettingsCard(title: "Add-ons") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Optional features you download once. Everything runs on this Mac.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                    SettingsRow(
                        label: "Speaker labels",
                        description: "Tells voices apart in a meeting note and numbers them, e.g. Speaker 1, Speaker 2. "
                            + "About 220 MB, downloaded once."
                    ) {
                        speakerLabelsControl
                    }
                }
            }
        }
    }

    /// Not installed always renders the toggle off, regardless of a stale
    /// `labelSpeakers` value left over from a previous install: turning it
    /// on both sets the setting and starts the download, so the two stay in
    /// lockstep the moment the install finishes.
    private var installToggleBinding: Binding<Bool> {
        Binding(
            get: { false },
            set: { newValue in
                guard newValue else { return }
                settings.labelSpeakers = true
                settings.downloadSpeakerModelRequest?()
            }
        )
    }

    private func mb(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_000_000)
    }

    @ViewBuilder
    private var speakerLabelsControl: some View {
        switch settings.speakerModelStatus {
        case .notDownloaded, .cancelled:
            PillToggle(isOn: installToggleBinding)

        case .downloading(let fraction, let receivedBytes, let totalBytes):
            VStack(alignment: .trailing, spacing: 5) {
                AddOnProgressBar(fraction: fraction)
                    .frame(width: 120)
                Text("\(mb(receivedBytes)) MB of \(mb(max(totalBytes, receivedBytes))) MB")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                Button("Cancel") { settings.cancelSpeakerModelDownloadRequest?() }
                    .buttonStyle(.plain)
                    .pointer()
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

        case .ready(let sizeBytes):
            VStack(alignment: .trailing, spacing: 5) {
                PillToggle(isOn: $settings.labelSpeakers)
                Text("Installed, \(mb(sizeBytes)) MB")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                if removeConfirming {
                    HStack(spacing: 8) {
                        Text("Remove \(mb(sizeBytes)) MB?")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                        Button("Keep") { removeConfirming = false }
                            .buttonStyle(.plain)
                            .pointer()
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                        Button("Remove") {
                            settings.removeSpeakerModelRequest?()
                            removeConfirming = false
                        }
                        .buttonStyle(.plain)
                        .pointer()
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.85))
                    }
                } else {
                    Button("Remove") { removeConfirming = true }
                        .buttonStyle(.plain)
                        .pointer()
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

        case .failed:
            VStack(alignment: .trailing, spacing: 5) {
                Text("Download failed. Check your connection.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .multilineTextAlignment(.trailing)
                PillButton(title: "Retry") { settings.downloadSpeakerModelRequest?() }
            }
        }
    }
}

/// Thin 4 pt rounded progress bar for an add-on download - deliberately
/// slimmer than `TrialProgressBar`'s 6 pt so it reads as a small in-row
/// indicator, not a page-level meter.
private struct AddOnProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(SettingsTheme.accent)
                    .frame(width: proxy.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - License

struct LicenseSettingsView: View {
    @ObservedObject var licenseState: LicenseState
    var pendingActivationKey: String? = nil
    var onConsumePendingActivation: () -> Void = {}

    @State private var licenseKey = ""
    @State private var deactivateConfirming = false
    @FocusState private var keyFieldFocused: Bool

    private var canActivate: Bool { LicenseKeyFormatter.isActivatable(licenseKey) && !licenseState.isActivating }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusCard
            if licenseState.status.isLicensed {
                activatedCard
            } else {
                keyCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard let pendingActivationKey else { return }
            onConsumePendingActivation()
            if pendingActivationKey.isEmpty {
                // The notch's locked-state "Enter key" pill: just focus the
                // field, nothing to activate yet.
                keyFieldFocused = true
            } else {
                licenseKey = pendingActivationKey
                Task { await licenseState.activate(rawKey: pendingActivationKey) }
            }
        }
    }

    // MARK: Status row

    private var statusCard: some View {
        SettingsCard(title: "Status") {
            HStack(spacing: 8) {
                Circle()
                    .fill(licenseState.statusIsHealthy ? SettingsTheme.accent : Color(red: 0.95, green: 0.35, blue: 0.32))
                    .frame(width: 7, height: 7)
                Text(licenseState.statusLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                if !licenseState.status.isLicensed {
                    PillButton(title: "Buy a license", accent: true) {
                        NSWorkspace.shared.open(licenseState.endpoints.checkoutURL)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Key entry (trial or ended)

    private var keyCard: some View {
        SettingsCard(title: "License key") {
            VStack(alignment: .leading, spacing: 10) {
                TextField(LicenseKeyFormatter.placeholder, text: Binding(
                    get: { licenseKey },
                    set: { newValue in
                        licenseKey = newValue
                        licenseState.activationError = nil
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .focused($keyFieldFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .pointer()

                if let error = licenseState.activationError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.42))
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await licenseState.activate(rawKey: licenseKey) }
                    } label: {
                        HStack(spacing: 6) {
                            if licenseState.isActivating {
                                ProgressView().controlSize(.small).tint(.black)
                            }
                            Text("Activate")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(canActivate ? Color.black : Color.white.opacity(0.4))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous).fill(canActivate ? Color.white : Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .pointer()
                    .disabled(!canActivate)
                    .hoverTip("Activates this key on this Mac")
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Activated (licensed)

    private var activatedCard: some View {
        SettingsCard(title: "This Mac") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activated on this Mac")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(licenseState.machineName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                if deactivateConfirming {
                    HStack(spacing: 10) {
                        Text("Deactivate this Mac?")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                        Button("Yes, deactivate") {
                            deactivateConfirming = false
                            Task { await licenseState.deactivate() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.42))
                        .pointer()
                        Button("Cancel") { deactivateConfirming = false }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                            .pointer()
                    }
                } else {
                    Button("Deactivate this Mac") { deactivateConfirming = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .underline()
                        .pointer()
                        .hoverTip("Frees this Mac's activation slot")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var acknowledgementsExpanded = false
    @State private var acknowledgementsLinkHovering = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private struct Credit { let name: String; let license: String; let line: String }
    private let credits: [Credit] = [
        Credit(name: "OpenSuperWhisper", license: "MIT", line: "Copyright (c) 2024 OpenSuperWhisper"),
        Credit(name: "OpenDictation", license: "MIT", line: "Copyright (c) 2025 Kenny"),
        Credit(name: "FluidAudio", license: "Apache License 2.0", line: "FluidInference"),
        Credit(name: "NVIDIA Parakeet", license: "CC BY 4.0", line: "NVIDIA Corporation"),
        Credit(name: "Sparkle", license: "MIT", line: "Copyright (c) 2006 Andy Matuschak and contributors"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Zumbo") {
                VStack(spacing: 0) {
                    SettingsRow(label: "Version", description: "Local dictation, no cloud, no subscription.") {
                        Text(version)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    SettingsDivider()
                    SettingsRow(label: "Check for updates", description: "Zumbo checks once a day. Updates download only when you say so.") {
                        PillButton(title: "Check") { settings.checkForUpdatesRequest?() }
                    }
                }
            }
            SettingsCard(title: "Setup") {
                SettingsRow(label: "Run setup again", description: "Shows the first-launch steps again. Nothing is deleted.") {
                    PillButton(title: "Run setup") { settings.runSetupAgainRequest?() }
                }
            }
            acknowledgementsLink
            if acknowledgementsExpanded {
                acknowledgementsList
            }
        }
    }

    /// Small muted text link at the very bottom of the page, not a card row:
    /// the credits are reference material, not something every visitor
    /// needs to see.
    private var acknowledgementsLink: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { acknowledgementsExpanded.toggle() }
        } label: {
            Text("Open-source acknowledgements")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
                .underline(acknowledgementsLinkHovering)
        }
        .buttonStyle(.plain)
        .onHover { acknowledgementsLinkHovering = $0 }
        .pointer()
    }

    private var acknowledgementsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(credits, id: \.name) { credit in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(credit.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(credit.license)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Text(credit.line)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }
}
