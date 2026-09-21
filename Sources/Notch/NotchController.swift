import AppKit
import SwiftUI

/// The quick actions the hover state exposes. `.note` and `.meeting` are
/// hidden (replaced by the meeting-mode status row) while meeting mode is on.
enum NotchQuickAction {
    case dictate
    case note
    case meeting
    case history
    case settings
}

/// Which kind of thing the current recording (or the one about to start) is
/// for, so the panel and the coordinator agree on whether it pastes.
enum RecordingContext {
    case dictation
    case note
    /// The onboarding "Try it" step: never pastes, never saved to history,
    /// its result goes straight into `NotchModel.onboardingTryText`.
    case onboarding
}

/// A one-line message the panel can show: a missing permission, a model still
/// loading, a failure. `actionTitle` is the primary (white, filled) button
/// label, nil for no button. `secondaryActionTitle` adds a second, muted pill
/// beside it - used for the reminder proposal ("Set reminder" / "No"), the
/// ambiguous-time ask (two time pills), and the firing notice ("Done" /
/// "Snooze 10 min"). Nil for every other notice, which keeps its one pill.
struct NotchNotice: Equatable {
    let message: String
    let actionTitle: String?
    var secondaryActionTitle: String? = nil
    /// Adds a small "x" circle right of the primary pill (the trial-ending
    /// notices only): dismisses immediately instead of waiting for the
    /// 5 s hold, same as clicking elsewhere.
    var dismissible: Bool = false
    /// 0...1 while an update downloads or installs (`UpdateController`), nil
    /// for every other notice. Drawn as a thin line along the bottom edge of
    /// the notice, so it costs no height and never changes the measured
    /// width.
    var progress: Double? = nil
}

/// Everything the SwiftUI content reads.
@MainActor
final class NotchModel: ObservableObject {

    @Published var state: NotchState = .idle
    /// Set true a beat after the shape lands, so content can stagger in.
    @Published var contentVisible = false
    /// Smoothed 0..1 microphone level.
    @Published var level: Float = 0
    @Published var recordingStartedAt: Date?
    /// Live status line during a session: "Listening..." then "Transcribing...".
    @Published var liveText = "Listening..."
    /// What the current (or about to start) recording is for. Drives the
    /// small "Note" label that replaces `liveText` during a note recording.
    @Published var recordingContext: RecordingContext = .dictation
    /// True for the whole life of a meeting (recording or paused). Drives the
    /// `.meeting` notch state, the menu bar badge and the menu item text.
    @Published var meetingModeOn = false
    /// True while the meeting is paused between fragments: the timer holds,
    /// the row shows a pulsing dot instead of the waveform, and the pause
    /// button becomes a green Resume.
    @Published var meetingIsPaused = false
    /// Recorded seconds accumulated before the current (unpaused) run;
    /// `meetingRunStartedAt` is nil while paused, so the timer counts only
    /// time actually being recorded, never the paused gaps.
    @Published var meetingElapsedBase: TimeInterval = 0
    @Published var meetingRunStartedAt: Date?
    /// A transient "Saved, N words" (or similar) confirmation shown in the
    /// meeting row after a chunk lands, fading back to the live row.
    @Published var meetingSavedNotice: String?
    /// A message the panel is showing instead of a session, e.g. a missing
    /// permission. `nil` in every other state.
    @Published var notice: NotchNotice?
    /// False while the speech model is still loading, so the quick action and
    /// the menu can say so instead of starting a session that cannot run.
    @Published var modelReady = false
    /// Real counts from the engine for the expanded tabs.
    @Published var dictionaryCount = 0
    @Published var ruleCount = 0
    /// The History tab's card layout, row or grid. Persisted; the didSet does
    /// not fire for this default-value initialization, only for later toggles.
    @Published var historyLayout: HistoryLayout = HistoryLayout.persisted {
        didSet { historyLayout.persist() }
    }
    /// Which content the expanded panel shows: the history cards or Settings.
    /// Always reset to `.history` on collapse.
    @Published var expandedPage: ExpandedPage = .history
    /// The history entry whose detail panel is open below the expanded
    /// panel, nil when it is closed. Always reset to nil on collapse. A
    /// separate rounded rectangle in the same window, not a `NotchState`.
    @Published var detailEntryID: UUID?
    // MARK: - Onboarding

    /// 1...7, the step currently showing. `OnboardingCoordinator` owns the
    /// transitions between steps; this is just what the view reads.
    @Published var onboardingStep: Int = 1
    /// True while another app has focus during a permission step and the
    /// panel has compacted to the small row (see `NotchController.
    /// setOnboardingCompact(_:)` and docs/ARCHITECTURE.md).
    @Published var onboardingCompact: Bool = false
    @Published var onboardingMicState: OnboardingMarkState = .notAsked
    @Published var onboardingAccessibilityState: OnboardingMarkState = .notAsked
    @Published var onboardingInputMonitoringState: OnboardingMarkState = .notAsked
    @Published var onboardingHotkeyState: OnboardingMarkState = .notAsked
    @Published var onboardingTryState: OnboardingMarkState = .notAsked
    /// True for the duration of a step 4 hold (press to release), so the
    /// keycap can stay visually pressed for the whole hold, not just a tap.
    @Published var onboardingHotkeyHeld: Bool = false
    /// True while a step 6 "Try it" session is recording or transcribing
    /// (`DictationCoordinator.startOnboardingTry`/`stopOnboardingTry`).
    @Published var onboardingTryListening: Bool = false
    /// Areas picked on the "What you dictate most" step.
    @Published var onboardingPickedAreas: Set<OnboardingArea> = []
    /// The "Try it" step's read-only result and which of its words to
    /// underline (came from a pack or My words).
    @Published var onboardingTryText: String = ""
    @Published var onboardingTryHighlights: [String] = []
    @Published var onboardingLicenseKey: String = ""
    /// The step's own back/continue/skip actions, wired by
    /// `OnboardingCoordinator.start()`.
    var onboardingBackRequest: (() -> Void)?
    var onboardingContinueRequest: (() -> Void)?
    var onboardingSkipRequest: (() -> Void)?
    var onboardingAllowMicRequest: (() -> Void)?
    var onboardingOpenAccessibilityRequest: (() -> Void)?
    var onboardingOpenInputMonitoringRequest: (() -> Void)?
    var onboardingPickAreaRequest: ((OnboardingArea) -> Void)?
    var onboardingChangeShortcutRequest: (() -> Void)?
    var onboardingStartTrialRequest: (() -> Void)?
    var onboardingBuyRequest: (() -> Void)?
    var onboardingActivateRequest: ((String) -> Void)?
    var onboardingRestoreFromCompactRequest: (() -> Void)?

    /// Set once, before the panel first shows Settings, by the
    /// `--settings-category` demo launch argument (screenshot checks only).
    /// `ExpandedPanelView` reads it as its initial `@State`, not a live
    /// binding, so a later category click is never overridden.
    var initialSettingsCategory: String?
    /// Set once, before the panel first shows History, by the
    /// `--demo expanded-notes` launch argument (screenshot checks only).
    /// `ExpandedPanelView` reads it as its initial `@State`, not a live
    /// binding, same as `initialSettingsCategory`.
    var initialKindFilter: EntryKind?
    /// Set once, before the detail panel first appears, by the
    /// `--demo expanded-teach` launch argument (screenshot checks only).
    /// `HistoryDetailPanelView` reads it once on load to open the Teach form
    /// on a synthetic selection instead of a real text drag.
    var demoOpenTeach = false
    /// Hardware notch size, or the default footprint on a notchless display.
    @Published var base: CGSize = NotchMetrics.defaultIdleSize
    @Published var screenHasNotch = false
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// True once notification permission has been asked for and denied - the
    /// reminder picker shows one explanatory line and an "Open System
    /// Settings" pill instead of pretending "Set" will do anything. Set by
    /// `AppDelegate`, mirroring `ReminderScheduler.authorizationStatus`.
    @Published var notificationsDenied = false

    var metrics: NotchMetrics {
        NotchMetrics.metrics(
            for: state, base: base, hasNotch: screenHasNotch,
            historyLayout: historyLayout, expandedPage: expandedPage,
            noticeMessage: notice?.message ?? "", noticeHasSecondaryButton: notice?.secondaryActionTitle != nil,
            noticeDismissible: notice?.dismissible ?? false,
            onboardingCompact: onboardingCompact)
    }

    /// Exponential smoothing. The raw stream is jumpy at 30 Hz.
    func apply(level raw: Float) {
        let clamped = min(max(raw, 0), 1)
        level += (clamped - level) * 0.35
    }

    /// Real dictation history, shown by the expanded panel's History tab.
    let history: HistoryStore
    /// The user's settings, bound directly by the Settings page.
    let settings: AppSettings
    /// Trial/license status, read by Settings > License and the locked
    /// notch state.
    let licenseState: LicenseState

    init(history: HistoryStore, settings: AppSettings, licenseState: LicenseState) {
        self.history = history
        self.settings = settings
        self.licenseState = licenseState
    }

    var quickActions: ((NotchQuickAction) -> Void)?
    var collapseRequest: (() -> Void)?
    /// The grid icon in the expanded header.
    var toggleHistoryLayoutRequest: (() -> Void)?
    /// The gear icon and the Settings page's back chevron.
    var setExpandedPageRequest: ((ExpandedPage) -> Void)?
    /// A card's text area, to open its detail panel; nil closes it.
    var setDetailEntryRequest: ((UUID?) -> Void)?
    /// The detail panel's "Insert again" button. Set by `AppDelegate` to the
    /// coordinator's `insertIntoFrontmost(_:)`.
    var insertAgainRequest: ((String) -> Void)?
    /// The reminder picker's "Set" button (detail panel or a card's inline
    /// picker). Set by `AppDelegate` to `ReminderScheduler.setReminder(id:at:)`.
    var setReminderRequest: ((UUID, Date) -> Void)?
    /// A reminder chip's "x", or the picker's "Cancel" on an entry that
    /// already has one. Set by `AppDelegate` to
    /// `ReminderScheduler.cancelReminder(id:)`.
    var cancelReminderRequest: ((UUID) -> Void)?
    /// The notice's primary button, e.g. open the right System Settings pane,
    /// or a reminder notice's primary pill ("Set reminder", "Done", or the
    /// first time reading on an ambiguous ask).
    var noticeAction: (() -> Void)?
    /// The notice's secondary (muted) pill, when it has one: "No", "Snooze
    /// 10 min", or the second time reading on an ambiguous ask.
    var noticeSecondaryAction: (() -> Void)?
    /// `.locked`'s "Buy a license" pill: opens the checkout URL.
    var lockedBuyRequest: (() -> Void)?
    /// `.locked`'s "Enter key" pill: opens Settings > License with the key
    /// field focused.
    var lockedEnterKeyRequest: (() -> Void)?
    /// A key waiting to be handed to Settings > License: `""` means "just
    /// focus the field" (the locked state's "Enter key" pill), a real key
    /// means "fill it in and activate" (`zumbo://activate?key=...`). `nil`
    /// the rest of the time. Consumed once by `LicenseSettingsView`.
    @Published var pendingActivationKey: String?
    /// Clicking the recording panel stops the session, same path as the hotkey.
    var stopRequest: (() -> Void)?
    /// The meeting row's Pause/Resume button (and the hotkey, while a
    /// meeting is running).
    var meetingPauseToggleRequest: (() -> Void)?
    /// The meeting row's Stop button, after its "End meeting?" confirm.
    var meetingEndRequest: (() -> Void)?
}

/// Named subclass so a crash log or debugger identifies this panel's content
/// view by name rather than the generic `NSHostingView`. No behavioural
/// overrides: `intrinsicContentSize { .zero }` was tried as part of chasing
/// the meeting-mode crash below, then removed again once the real fix
/// (`DictationCoordinator.startMeeting()`'s reordering) was confirmed to
/// stop it on its own - adding an unverified override that measurably did
/// not help was not worth the layout risk.
final class NotchHostingView: NSHostingView<NotchRootView> {}

/// Owns the one panel, the state machine, hover hysteresis and which screen the
/// panel lives on.
@MainActor
final class NotchController {

    let model: NotchModel

    init(history: HistoryStore, settings: AppSettings, licenseState: LicenseState) {
        self.model = NotchModel(history: history, settings: settings, licenseState: licenseState)
    }

    private let panel = NotchPanel()
    private var screen: NSScreen?

    private var hoverEnter: Task<Void, Never>?
    private var hoverLeave: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?
    private var trimTask: Task<Void, Never>?
    private var doneTask: Task<Void, Never>?

    private var mouseMoveMonitor: Any?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?

    /// Whoever was frontmost when the expanded panel opened, so key status can
    /// go back where it came from.
    private var previousApp: NSRunningApplication?

    /// Hover quick actions are forwarded here.
    var onQuickAction: ((NotchQuickAction) -> Void)?

    /// Called when the user clicks the recording panel to stop it.
    var onStopRecording: (() -> Void)?
    /// The meeting row's Pause/Resume button, and the hotkey while a meeting
    /// is running (it pauses/resumes instead of dictating).
    var onToggleMeetingPause: (() -> Void)?
    /// The meeting row's Stop button, after its confirm step.
    var onEndMeeting: (() -> Void)?
    /// Holds the "Saved, N words" flash's auto-fade timer.
    private var savedNoticeTask: Task<Void, Never>?

    // MARK: - Animations

    private var expandAnimation: Animation {
        model.reduceMotion ? .easeInOut(duration: 0.14)
                           : .spring(response: 0.34, dampingFraction: 0.62)
    }

    private var collapseAnimation: Animation {
        model.reduceMotion ? .easeInOut(duration: 0.14)
                           : .spring(response: 0.26, dampingFraction: 1.0)
    }

    private var contentAnimation: Animation {
        model.reduceMotion ? .easeInOut(duration: 0.14)
                           : .spring(response: 0.3, dampingFraction: 0.82)
    }

    /// How long a shape move can still be overshooting.
    static let settleDelay: Duration = .milliseconds(620)
    private let contentStagger: Duration = .milliseconds(110)
    /// The expanded panel's spring (response 0.34) is visually at its size
    /// after about a quarter second; content waits for that.
    private let expandedContentStagger: Duration = .milliseconds(260)

    // MARK: - Lifecycle

    func start() {
        model.quickActions = { [weak self] action in
            self?.onQuickAction?(action)
        }
        model.collapseRequest = { [weak self] in
            self?.transition(to: .idle)
        }
        model.stopRequest = { [weak self] in
            guard let self, self.model.state == .recording else { return }
            self.onStopRecording?()
        }
        model.meetingPauseToggleRequest = { [weak self] in self?.onToggleMeetingPause?() }
        model.meetingEndRequest = { [weak self] in self?.onEndMeeting?() }
        model.toggleHistoryLayoutRequest = { [weak self] in
            guard let self else { return }
            self.setHistoryLayout(self.model.historyLayout == .grid ? .row : .grid)
        }
        model.setExpandedPageRequest = { [weak self] page in
            self?.setExpandedPage(page)
        }
        model.setDetailEntryRequest = { [weak self] id in
            self?.setDetailEntry(id)
        }
        model.onboardingRestoreFromCompactRequest = { [weak self] in
            self?.setOnboardingCompact(false)
        }

        let root = NotchRootView(model: model)
        let hosting = NotchHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        // No safe-area tracking: the panel sits over the menu bar and has no
        // safe area of its own, and NSHostingView's safe-area invalidation
        // during a window resize raised an AppKit layout exception
        // (_postWindowNeedsUpdateConstraints inside a layout pass) that
        // terminated the app when the expanded panel collapsed on click-outside.
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.usesVerticalScroll = model.historyLayout == .grid || model.expandedPage == .settings

        moveToPointerScreen()
        placeInitialFrame()
        panel.bringFront()

        installMouseMoveMonitor()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.moveToPointerScreen()
                self.applyWindowFrame(for: self.model.state, animate: false)
            }
        }

        // A Space switch, including entering or leaving an app's fullscreen
        // Space, can drop the panel behind the new Space's windows.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.moveToPointerScreen()
                self.applyWindowFrame(for: self.model.state, animate: false)
                self.panel.bringFront()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    // MARK: - State machine

    func transition(to next: NotchState) {
        guard next != model.state else { return }

        let previous = model.state
        doneTask?.cancel()
        contentTask?.cancel()
        trimTask?.cancel()

        // Always start a fresh onboarding entry at full size, never carrying
        // over a stale compact flag from a previous run (would starve the
        // union footprint the spring needs to grow into).
        if next == .onboarding, previous != .onboarding {
            model.onboardingCompact = false
        }

        // A state change always re-homes the panel on the pointer's screen. One
        // panel, one screen, never two.
        if previous == .idle || next == .idle {
            moveToPointerScreen()
        }

        let growing = weight(next) > weight(previous)

        // Give the window the union of both footprints first so the spring has
        // room, then tighten it once the shape has settled.
        let union = unionWindowSize(previous, next)
        setWindowFrame(size: union, animate: false)
        panel.bringFront()

        panel.ignoresMouseEvents = !next.acceptsMouse
        NotchPanel.pointerOverHorizontalScroller = false

        // Shape first, content second: whatever was showing goes away at
        // once, the black shape grows or shrinks on its own, and the new
        // content fades in only after the shape has landed. A big jump (to
        // the expanded panel) waits longer than a small one so the text never
        // appears on a shape that is still growing under it.
        model.contentVisible = false
        withAnimation(growing ? expandAnimation : collapseAnimation) {
            model.state = next
        }

        if growing || next != .idle {
            let stagger = next == .expanded ? expandedContentStagger : contentStagger
            contentTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: stagger)
                guard !Task.isCancelled, self.model.state == next else { return }
                withAnimation(self.contentAnimation) { self.model.contentVisible = true }
            }
        }

        trimTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, self.model.state == next else { return }
            self.applyWindowFrame(for: next, animate: false)
        }

        switch next {
        case .recording:
            model.recordingStartedAt = Date()
            model.liveText = "Listening..."
            model.notice = nil
        case .idle:
            model.recordingStartedAt = nil
            model.level = 0
            model.notice = nil
            model.recordingContext = .dictation
            // Reopening the panel should never land on Settings or a detail.
            model.expandedPage = .history
            model.detailEntryID = nil
            panel.usesVerticalScroll = model.historyLayout == .grid
        case .hover, .expanded:
            model.notice = nil
        case .meeting:
            model.notice = nil
        case .onboarding:
            model.notice = nil
            model.onboardingCompact = false
        case .locked:
            model.notice = nil
        case .done, .notice:
            break
        }

        if next == .expanded || next == .locked {
            takeKeyStatus()
            installExpandedMonitors()
        } else if next == .onboarding {
            // Key-capable so the inline shortcut recorder and the license
            // key field can type, but deliberately no click-outside/Escape
            // monitors: onboarding never dismisses itself (see NotchState
            // .onboarding's doc comment and docs/ARCHITECTURE.md).
            takeKeyStatus()
            removeExpandedMonitors()
        } else {
            releaseKeyStatus()
            removeExpandedMonitors()
        }
    }

    /// Recording finished: draw the check, hold, retract. Whole tail is ~0.9 s.
    func finish() {
        transition(to: .done)
        doneTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.transition(to: .idle)
        }
    }

    /// Shows a one-line message with an optional button, holds it, retracts.
    /// Used for a missing permission and for "Loading speech model": never a
    /// crash, never a modal. `returnTo` is where the button(s) and the
    /// timeout send the panel afterward - `.idle` for every ordinary notice,
    /// but `.meeting` for the meeting-mode disclosure, so dismissing it (by
    /// button or timeout) resumes the meeting row instead of incorrectly
    /// collapsing a still-running meeting to idle.
    func showNotice(
        _ notice: NotchNotice, holdFor seconds: Double = 4.5,
        action: (() -> Void)? = nil, secondaryAction: (() -> Void)? = nil,
        returnTo: NotchState = .idle
    ) {
        model.notice = notice
        model.noticeAction = { [weak self] in
            action?()
            self?.transition(to: returnTo)
        }
        model.noticeSecondaryAction = { [weak self] in
            secondaryAction?()
            self?.transition(to: returnTo)
        }
        if model.state == .notice {
            // Already showing one: just swap the text and restart the timer.
            doneTask?.cancel()
        } else {
            transition(to: .notice)
        }
        doneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            guard let self, self.model.state == .notice else { return }
            self.transition(to: returnTo)
        }
    }

    /// Rewrites the notice already on screen without running
    /// `transition(to:)` again: same state, new text, new progress. The
    /// updater's download line changes several times a second, and a full
    /// transition per change would restart the hold timer and re-run the
    /// panel's grow/shrink animation each time.
    func updateNoticeInPlace(_ notice: NotchNotice) {
        guard model.state == .notice else { return }
        model.notice = notice
        applyWindowFrame(for: .notice, animate: true)
    }

    /// A two-pill reminder notice: the "Note saved. Remind you...?" proposal,
    /// its ambiguous-time variant ("...at 7:00 AM or 7:00 PM?"), and the
    /// firing notice ("Reminder: ..." with Done / Snooze). Held for `seconds`
    /// (the caller passes the spec's ~6 s for a proposal, 30 s for firing)
    /// unless a pill is clicked first.
    func showReminderNotice(
        message: String, primaryTitle: String, secondaryTitle: String, holdFor seconds: Double,
        primaryAction: @escaping () -> Void, secondaryAction: @escaping () -> Void
    ) {
        showNotice(
            NotchNotice(message: message, actionTitle: primaryTitle, secondaryActionTitle: secondaryTitle),
            holdFor: seconds, action: primaryAction, secondaryAction: secondaryAction)
    }

    func toggleExpanded() {
        transition(to: model.state == .expanded ? .idle : .expanded)
    }

    /// The hard-gate state (NOTES.md: trial ended, no free tier). Persists
    /// until Escape/click-outside or one of its two pills - never
    /// auto-retracts, and re-showing it after a dismiss is just calling this
    /// again from the next gated action.
    func showLocked() {
        guard model.state != .locked else { return }
        transition(to: .locked)
    }

    /// Toggles the History tab's card layout. There is no `.grid` notch state
    /// (only the History tab's content changes), so this mirrors the resize
    /// dance `transition(to:)` does instead of reusing it outright: grow the
    /// window to the union of both footprints first, animate the content with
    /// the same spring a state transition uses, then trim the window once it
    /// has settled.
    func setHistoryLayout(_ layout: HistoryLayout) {
        guard layout != model.historyLayout else { return }

        guard model.state == .expanded else {
            // Not visible: no window to animate, just record the choice.
            model.historyLayout = layout
            panel.usesVerticalScroll = layout == .grid || model.expandedPage == .settings
            return
        }

        trimTask?.cancel()

        let previousSize = windowSize(for: .expanded)
        let newSize = windowSize(for: .expanded, historyLayout: layout)
        let union = CGSize(width: max(previousSize.width, newSize.width),
                            height: max(previousSize.height, newSize.height))
        setWindowFrame(size: union, animate: false)
        panel.bringFront()

        // Bypass the panel's horizontal axis swap the instant grid mode is
        // requested, not after the spring settles: the grid's ScrollView must
        // scroll vertically from the first frame it is visible.
        panel.usesVerticalScroll = layout == .grid || model.expandedPage == .settings

        let growing = newSize.height > previousSize.height
        withAnimation(growing ? expandAnimation : collapseAnimation) {
            model.historyLayout = layout
        }

        trimTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, self.model.state == .expanded,
                  self.model.historyLayout == layout else { return }
            self.applyWindowFrame(for: .expanded, animate: false)
        }
    }

    /// Meeting mode turning on: enters the persistent `.meeting` row
    /// immediately (recording starts right away - there is no separate
    /// "press the hotkey" step). Only `endMeetingUI()` or a state the app
    /// never reaches from here (idle via some other path) leaves it.
    func startMeetingUI() {
        model.meetingModeOn = true
        model.meetingIsPaused = true
        model.meetingElapsedBase = 0
        model.meetingRunStartedAt = nil
        model.meetingSavedNotice = nil
        transition(to: .meeting)
    }

    /// Pause/resume: the timer's clock (`meetingElapsedBase` +
    /// `meetingRunStartedAt`) is the single source of truth for "recorded
    /// time only" - paused holds `meetingRunStartedAt` at nil.
    func setMeetingPausedUI(_ paused: Bool) {
        guard paused != model.meetingIsPaused else { return }
        if paused {
            if let startedAt = model.meetingRunStartedAt {
                model.meetingElapsedBase += Date().timeIntervalSince(startedAt)
            }
            model.meetingRunStartedAt = nil
        } else {
            model.meetingRunStartedAt = Date()
        }
        model.meetingIsPaused = paused
    }

    /// Flashes a confirmation ("Saved, 42 words") in the meeting row, fading
    /// back to the live row after ~1.5 s.
    func showMeetingSaved(_ text: String) {
        model.meetingSavedNotice = text
        savedNoticeTask?.cancel()
        savedNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled else { return }
            self.model.meetingSavedNotice = nil
        }
    }

    /// Ends the meeting: retracts the row. The caller shows the final
    /// "Meeting saved..." flash (`showMeetingSaved`) and waits for it to be
    /// readable before calling this, so nothing here holds for a notice.
    func endMeetingUI() {
        savedNoticeTask?.cancel()
        hoverEnter?.cancel(); hoverEnter = nil
        hoverLeave?.cancel(); hoverLeave = nil
        model.meetingModeOn = false
        model.meetingIsPaused = false
        model.meetingRunStartedAt = nil
        model.meetingSavedNotice = nil
        transition(to: .idle)
    }

    /// Switches the expanded panel between its History and Settings pages.
    /// Mirrors `setHistoryLayout`'s resize dance: grow to the union first,
    /// animate, then trim once the spring has settled.
    func setExpandedPage(_ page: ExpandedPage) {
        guard page != model.expandedPage else { return }

        // The detail panel only ever shows a history card's text: leaving the
        // History page closes it.
        guard model.state == .expanded else {
            model.expandedPage = page
            model.detailEntryID = nil
            panel.usesVerticalScroll = page == .settings || model.historyLayout == .grid
            return
        }

        trimTask?.cancel()

        let previousSize = windowSize(for: .expanded)
        let newSize = windowSize(for: .expanded, expandedPage: page, detailOpen: false)
        let union = CGSize(width: max(previousSize.width, newSize.width),
                            height: max(previousSize.height, newSize.height))
        setWindowFrame(size: union, animate: false)
        panel.bringFront()

        // Settings' only scrollable content is vertical, same as the grid.
        panel.usesVerticalScroll = page == .settings || model.historyLayout == .grid

        // Same order as `transition`: old page out at once, shape resizes
        // alone, new page fades in once the shape has landed.
        contentTask?.cancel()
        model.contentVisible = false
        let growing = newSize.height > previousSize.height
        withAnimation(growing ? expandAnimation : collapseAnimation) {
            model.expandedPage = page
            model.detailEntryID = nil
        }
        contentTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.expandedContentStagger)
            guard !Task.isCancelled, self.model.state == .expanded,
                  self.model.expandedPage == page else { return }
            withAnimation(self.contentAnimation) { self.model.contentVisible = true }
        }

        trimTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, self.model.state == .expanded,
                  self.model.expandedPage == page else { return }
            self.applyWindowFrame(for: .expanded, animate: false)
        }
    }

    /// Opens or closes the history detail panel below the expanded panel.
    /// Mirrors `setHistoryLayout`/`setExpandedPage`'s resize dance: grow to
    /// the union first, animate, then trim once the spring has settled.
    func setDetailEntry(_ id: UUID?) {
        guard id != model.detailEntryID else { return }

        guard model.state == .expanded else {
            model.detailEntryID = id
            return
        }

        trimTask?.cancel()

        let previousSize = windowSize(for: .expanded, detailOpen: model.detailEntryID != nil)
        let newSize = windowSize(for: .expanded, detailOpen: id != nil)
        let union = CGSize(width: max(previousSize.width, newSize.width),
                            height: max(previousSize.height, newSize.height))
        setWindowFrame(size: union, animate: false)
        panel.bringFront()

        let growing = newSize.height > previousSize.height
        withAnimation(growing ? expandAnimation : collapseAnimation) {
            model.detailEntryID = id
        }

        trimTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, self.model.state == .expanded,
                  self.model.detailEntryID == id else { return }
            self.applyWindowFrame(for: .expanded, animate: false)
        }
    }

    private func weight(_ state: NotchState) -> Int {
        switch state {
        case .idle: return 0
        case .done: return 1
        case .hover: return 1
        case .notice: return 2
        case .recording: return 2
        case .meeting: return 2
        case .locked: return 3
        case .expanded: return 3
        case .onboarding: return 4
        }
    }

    /// Compacts or restores the onboarding panel while it stays in
    /// `.onboarding`. Mirrors `setHistoryLayout`'s resize dance: grow to the
    /// union first, animate, then trim once the spring has settled.
    func setOnboardingCompact(_ compact: Bool) {
        guard compact != model.onboardingCompact else { return }
        guard model.state == .onboarding else {
            model.onboardingCompact = compact
            return
        }

        trimTask?.cancel()

        let previousSize = windowSize(for: .onboarding, onboardingCompact: model.onboardingCompact)
        let newSize = windowSize(for: .onboarding, onboardingCompact: compact)
        let union = CGSize(width: max(previousSize.width, newSize.width),
                            height: max(previousSize.height, newSize.height))
        setWindowFrame(size: union, animate: false)
        panel.bringFront()

        contentTask?.cancel()
        model.contentVisible = false
        let growing = newSize.height > previousSize.height || newSize.width > previousSize.width
        withAnimation(growing ? expandAnimation : collapseAnimation) {
            model.onboardingCompact = compact
        }
        contentTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.contentStagger)
            guard !Task.isCancelled, self.model.state == .onboarding,
                  self.model.onboardingCompact == compact else { return }
            withAnimation(self.contentAnimation) { self.model.contentVisible = true }
        }

        trimTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, self.model.state == .onboarding,
                  self.model.onboardingCompact == compact else { return }
            self.applyWindowFrame(for: .onboarding, animate: false)
        }
    }

    // MARK: - Screens and frames

    private func moveToPointerScreen() {
        guard let target = NSScreen.withPointer else { return }
        screen = target
        let notch = target.hardwareNotchSize
        model.screenHasNotch = notch != .zero
        model.base = notch == .zero ? NotchMetrics.defaultIdleSize : notch
    }

    /// X of the middle of the hardware notch, or of the screen on notchless displays.
    private func topCenterX(of screen: NSScreen) -> CGFloat {
        guard screen.hasHardwareNotch,
              let left = screen.auxiliaryTopLeftArea?.width,
              let right = screen.auxiliaryTopRightArea?.width else {
            return screen.frame.midX
        }
        return screen.frame.minX + left + (screen.frame.width - left - right) / 2
    }

    private func windowSize(
        for state: NotchState, historyLayout: HistoryLayout? = nil, expandedPage: ExpandedPage? = nil,
        detailOpen: Bool? = nil, onboardingCompact: Bool? = nil
    ) -> CGSize {
        let layout = historyLayout ?? model.historyLayout
        let page = expandedPage ?? model.expandedPage
        let compact = onboardingCompact ?? model.onboardingCompact
        let m = NotchMetrics.metrics(
            for: state, base: model.base, hasNotch: model.screenHasNotch,
            historyLayout: layout, expandedPage: page,
            noticeMessage: model.notice?.message ?? "", noticeHasSecondaryButton: model.notice?.secondaryActionTitle != nil,
            noticeDismissible: model.notice?.dismissible ?? false,
            onboardingCompact: compact)
        let insets = NotchMetrics.windowInsets
        // The detail panel never changes the shape's own metrics, only the
        // window's height: it is a second rectangle drawn below the shape,
        // in the same window, so NotchShape itself never stretches over it.
        let open = detailOpen ?? (model.detailEntryID != nil)
        let detailExtra: CGFloat = (state == .expanded && open)
            ? NotchMetrics.detailPanelGap + NotchMetrics.detailPanelHeight : 0
        return CGSize(
            width: m.width + insets.left + insets.right,
            height: m.height + insets.bottom + detailExtra
        )
    }

    private func unionWindowSize(_ a: NotchState, _ b: NotchState) -> CGSize {
        let sa = windowSize(for: a), sb = windowSize(for: b)
        return CGSize(width: max(sa.width, sb.width), height: max(sa.height, sb.height))
    }

    private func applyWindowFrame(for state: NotchState, animate: Bool) {
        setWindowFrame(size: windowSize(for: state), animate: animate)
    }

    private func computeFrame(size: CGSize) -> CGRect? {
        guard let screen else { return nil }
        let width = min(size.width, screen.frame.width)
        let height = min(size.height, screen.frame.height)
        let centerX = topCenterX(of: screen)
        var x = centerX - width / 2
        x = min(max(x, screen.frame.minX), screen.frame.maxX - width)
        return CGRect(x: x, y: screen.frame.maxY - height, width: width, height: height)
    }

    private func placeInitialFrame() {
        setWindowFrame(size: windowSize(for: .idle), animate: false)
    }

    /// A queued, coalescing version of this was tried while chasing the
    /// meeting-mode crash below, on the theory that two `panel.setFrame`
    /// calls landing in the same run-loop turn (see `startMeeting()`'s old
    /// ordering) were what triggered AppKit's reentrant-layout guard.
    /// Deferring every call broke ordinary transitions instead - `--demo
    /// expanded` alone started crashing the same way, because the window no
    /// longer grew to the union size *before* `transition(to:)`'s own
    /// `withAnimation` started (the growth call and the animation are meant
    /// to land in that order, synchronously, in the same turn: see
    /// `transition(to:)`). Reverted to the original direct call; the actual
    /// fix was reordering `startMeeting()` so the two resizes never
    /// contend in the first place.
    private func setWindowFrame(size: CGSize, animate: Bool) {
        guard let frame = computeFrame(size: size) else { return }
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true, animate: animate)
    }

    /// The black shape in screen coordinates, for hit testing the hover zone.
    private func shapeRect(for state: NotchState) -> CGRect {
        guard let screen else { return .zero }
        let m = NotchMetrics.metrics(
            for: state, base: model.base, hasNotch: model.screenHasNotch,
            noticeMessage: model.notice?.message ?? "", noticeHasSecondaryButton: model.notice?.secondaryActionTitle != nil,
            noticeDismissible: model.notice?.dismissible ?? false)
        let centerX = topCenterX(of: screen)
        return CGRect(
            x: centerX - m.width / 2,
            y: screen.frame.maxY - m.height,
            width: m.width,
            height: m.height
        )
    }

    /// Invisible strip that listens for hover while idle.
    private func hotZone() -> CGRect {
        guard let screen else { return .zero }
        let size = NotchMetrics.hotZoneSize
        let width = max(size.width, model.base.width)
        let height = model.screenHasNotch ? max(model.base.height, size.height) : size.height
        let centerX = topCenterX(of: screen)
        return CGRect(
            x: centerX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    // MARK: - Hover hysteresis

    /// A global mouse-moved monitor rather than an NSTrackingArea: the panel
    /// ignores mouse events while idle, so it would never see a mouse-entered.
    /// Mouse monitors need no accessibility permission.
    private func installMouseMoveMonitor() {
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.pointerMoved()
            }
        }
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation

        // Following the pointer across displays only matters while idle.
        if model.state == .idle, let current = screen, !NSMouseInRect(point, current.frame, false) {
            moveToPointerScreen()
            applyWindowFrame(for: .idle, animate: false)
        }

        let inside = hotZone().contains(point)
            || shapeRect(for: model.state).insetBy(dx: -6, dy: -6).contains(point)

        switch model.state {
        case .idle where inside:
            hoverLeave?.cancel(); hoverLeave = nil
            guard hoverEnter == nil else { return }
            hoverEnter = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled else { return }
                self.hoverEnter = nil
                guard self.model.state == .idle else { return }
                self.transition(to: .hover)
            }
        case .idle:
            hoverEnter?.cancel(); hoverEnter = nil
        case .hover where !inside:
            hoverEnter?.cancel(); hoverEnter = nil
            guard hoverLeave == nil else { return }
            hoverLeave = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled else { return }
                self.hoverLeave = nil
                guard self.model.state == .hover else { return }
                self.transition(to: .idle)
            }
        case .hover:
            hoverLeave?.cancel(); hoverLeave = nil
        // Meeting mode's compact row never retracts to idle and never swaps
        // its content on hover: what is shown is what is happening. Only Stop
        // or the menu item ends it (`endMeetingUI()`).
        case .meeting:
            hoverEnter?.cancel(); hoverEnter = nil
            hoverLeave?.cancel(); hoverLeave = nil
        default:
            hoverEnter?.cancel(); hoverEnter = nil
            hoverLeave?.cancel(); hoverLeave = nil
        }
    }

    // MARK: - Key status, expanded only

    private func takeKeyStatus() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        panel.isKeyCapable = true
        // bringFront first: makeKeyAndOrderFront does not front a window while
        // the app is inactive, and Zumbo is always inactive.
        panel.bringFront()
        panel.makeKey()
    }

    private func releaseKeyStatus() {
        guard panel.isKeyCapable else { return }
        panel.isKeyCapable = false
        if panel.isKeyWindow {
            panel.resignKey()
        }
        if let previousApp, !previousApp.isActive {
            previousApp.activate()
        }
        previousApp = nil
    }

    // MARK: - Expanded dismissal

    private func installExpandedMonitors() {
        removeExpandedMonitors()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.model.state == .expanded || self.model.state == .locked else { return }
                let state = self.model.state
                let point = NSEvent.mouseLocation
                let inShape = self.shapeRect(for: state).contains(point)
                let inDetail = state == .expanded && self.model.detailEntryID != nil
                    && self.detailRect(for: .expanded).contains(point)
                if !inShape && !inDetail {
                    // Never resize the window from inside an event callback:
                    // AppKit may be mid-layout. Next run loop turn.
                    DispatchQueue.main.async { [weak self] in self?.transition(to: .idle) }
                }
            }
        }

        // Escape, delivered to us because the expanded/locked panel is key.
        // On the Settings page the first Escape goes back to History; only
        // the next one collapses the panel. `.locked` has no nested pages,
        // so Escape always collapses it straight to `.idle`.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let isEscape = event.keyCode == 53
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, isEscape else { return false }
                if self.model.state == .expanded {
                    self.handleEscape()
                    return true
                } else if self.model.state == .locked {
                    self.transition(to: .idle)
                    return true
                }
                return false
            }
            return handled ? nil : event
        }

        // Escape while some other window holds keys. Needs Accessibility trust;
        // the close button and click-outside work without it.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated { [weak self] in
                guard let self, event.keyCode == 53 else { return }
                guard self.model.state == .expanded || self.model.state == .locked else { return }
                if self.model.state == .locked {
                    self.transition(to: .idle)
                    return
                }
                self.handleEscape()
            }
        }
    }

    private func handleEscape() {
        guard model.state == .expanded else { return }
        if model.detailEntryID != nil {
            setDetailEntry(nil)
        } else if model.expandedPage == .settings {
            setExpandedPage(.history)
        } else {
            transition(to: .idle)
        }
    }

    /// The detail panel's rect in screen coordinates, directly below the
    /// expanded shape (same width, `detailPanelGap` further down), for hit
    /// testing clicks outside both panels. `.zero` when it is closed.
    private func detailRect(for state: NotchState) -> CGRect {
        guard model.detailEntryID != nil else { return .zero }
        let shape = shapeRect(for: state)
        return CGRect(
            x: shape.minX,
            y: shape.minY - NotchMetrics.detailPanelGap - NotchMetrics.detailPanelHeight,
            width: shape.width,
            height: NotchMetrics.detailPanelHeight
        )
    }

    private func removeExpandedMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
        localKeyMonitor = nil
    }
}
