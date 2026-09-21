import AppKit
import VesperEngine
@preconcurrency import UserNotifications
import os

/// Drives the eight-step first-launch walkthrough (docs/ARCHITECTURE.md
/// "Onboarding"): step transitions, the mic/accessibility permission polls,
/// the compact-row trigger while another app has focus, the hotkey redirect
/// for steps 4 and 6, and the trial/license finish. `AppDelegate` owns one
/// instance for the app's whole life; `OnboardingView.swift` only reads
/// `NotchModel`'s onboarding fields and calls the request closures this
/// wires.
@MainActor
final class OnboardingCoordinator {

    /// Same checkout URL the licensing flow uses (`LicenseEndpoints`).
    static let buyURL = LicenseEndpoints.production.checkoutURL

    private let notch: NotchController
    private let settings: AppSettings
    private let dictation: DictationCoordinator
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "onboarding")

    private var pollTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?
    private var permissionAlertWindowTask: Task<Void, Never>?
    /// Guards the three system permission requests (the mic prompt,
    /// `AXIsProcessTrustedWithOptions`'s prompt, `CGRequestListenEventAccess`)
    /// so each fires at most once per onboarding run - reset only in
    /// `resetState()` (a fresh `present()`/`resumeOrPresent()`). Doubles as
    /// the "was this asked yet" flag `refreshPermissionMarks()` uses to
    /// decide a red mark. The "Open System Settings" pills never touch
    /// these - they only open a pane, never re-fire a request.
    private var micRequested = false
    private var accessibilityRequested = false
    private var inputMonitoringRequested = false

    init(notch: NotchController, settings: AppSettings, dictation: DictationCoordinator) {
        self.notch = notch
        self.settings = settings
        self.dictation = dictation
    }

    /// Called once at launch: wires every request closure `OnboardingView`
    /// calls and installs the compact-row trigger. Does not itself show
    /// onboarding - call `present()` for that.
    func start() {
        wireRequests()
        installWorkspaceObserver()
    }

    /// Fresh run from step 1, whatever was showing before (first launch, or
    /// Settings' "Run setup" closing the panel out from under Settings).
    func present() {
        resetState()
        notch.transition(to: .onboarding)
        managePolling()
    }

    /// Launch-time entry point: resumes at `AppSettings.onboardingStep` if
    /// the app quit mid-walkthrough (a "Quit & Reopen" from a permission's
    /// system dialog does not relaunch a menu-bar app with no Dock icon),
    /// otherwise a plain `present()` from step 1. Permission steps re-check
    /// their state on appear, so a permission granted before the quit shows
    /// green immediately and auto-advances.
    func resumeOrPresent() {
        let saved = settings.onboardingStep
        guard saved > 1 else {
            present()
            return
        }
        resetState()
        notch.transition(to: .onboarding)
        enterStep(saved)
    }

    /// Settings > About's "Run setup". Leaves whatever page was open (the
    /// state transition below replaces it) and starts over.
    func restart() {
        present()
    }

    // MARK: - Hotkey (steps 4 and 6 only; `AppDelegate.installHotkey()`
    // routes here instead of the coordinator while onboarding is showing)

    func hotkeyPressed() {
        switch notch.model.onboardingStep {
        case 5:
            notch.model.onboardingHotkeyState = .granted
            notch.model.onboardingHotkeyHeld = true
        case 7:
            dictation.start()
        default:
            break
        }
    }

    func hotkeyReleased() {
        switch notch.model.onboardingStep {
        case 5:
            notch.model.onboardingHotkeyHeld = false
        case 7:
            dictation.stop()
        default:
            break
        }
    }

    // MARK: - Step machine

    private func wireRequests() {
        let m = notch.model
        m.onboardingBackRequest = { [weak self] in self?.back() }
        m.onboardingContinueRequest = { [weak self] in self?.continueStep() }
        m.onboardingSkipRequest = { [weak self] in self?.skip() }
        m.onboardingAllowMicRequest = { [weak self] in self?.openMicrophoneSettings() }
        m.onboardingOpenAccessibilityRequest = { [weak self] in self?.openAccessibility() }
        m.onboardingOpenInputMonitoringRequest = { [weak self] in self?.openInputMonitoring() }
        m.onboardingPickAreaRequest = { [weak self] area in self?.togglePick(area) }
        m.onboardingStartTrialRequest = { [weak self] in self?.startTrial() }
        m.onboardingBuyRequest = { [weak self] in self?.buy() }
        m.onboardingActivateRequest = { [weak self] key in self?.activate(key: key) }
        m.onboardingRestoreFromCompactRequest = { [weak self] in self?.restoreFromCompact() }
    }

    private func resetState() {
        let m = notch.model
        m.onboardingStep = 1
        settings.onboardingStep = 1
        m.onboardingCompact = false
        m.onboardingMicState = MicrophonePermission.isAuthorized() ? .granted : .notAsked
        m.onboardingAccessibilityState = TextInserter.isAccessibilityTrusted() ? .granted : .notAsked
        m.onboardingInputMonitoringState = CGPreflightListenEventAccess() ? .granted : .notAsked
        m.onboardingHotkeyState = .notAsked
        m.onboardingTryState = .notAsked
        m.onboardingHotkeyHeld = false
        m.onboardingTryListening = false
        m.onboardingPickedAreas = []
        m.onboardingTryText = ""
        m.onboardingTryHighlights = []
        m.onboardingLicenseKey = ""
        micRequested = false
        accessibilityRequested = false
        inputMonitoringRequested = false
        permissionAlertWindowTask?.cancel()
    }

    private func goToStep(_ step: Int) {
        enterStep(step)
    }

    /// The one place `onboardingStep` changes: updates the model, persists
    /// it (`AppSettings.onboardingStep`, cleared again in `finish()`) so a
    /// quit mid-walkthrough resumes here, fires that step's system
    /// permission request exactly once for this run, compacts to the small
    /// row while an alert might be up, and re-checks every permission mark
    /// for the step being entered.
    private func enterStep(_ step: Int) {
        notch.model.onboardingStep = step
        settings.onboardingStep = step
        switch step {
        case 2: requestMicIfNeeded()
        case 3: requestAccessibilityIfNeeded()
        case 4: requestInputMonitoringIfNeeded()
        default: permissionAlertWindowTask?.cancel()
        }
        refreshPermissionMarks()
        if isPendingPermissionStep(step) {
            beginPermissionAlertWindow()
        }
        managePolling()
    }

    /// Whether `step` is a permission step whose grant is not in yet - the
    /// signal for "a system alert might still be showing", read after
    /// `refreshPermissionMarks()` so an already-granted permission (a
    /// resumed run, or Continue pressed back to a step already cleared)
    /// never force-compacts for nothing.
    private func isPendingPermissionStep(_ step: Int) -> Bool {
        switch step {
        case 2: return notch.model.onboardingMicState != .granted
        case 3: return notch.model.onboardingAccessibilityState != .granted
        case 4: return notch.model.onboardingInputMonitoringState != .granted
        default: return false
        }
    }

    /// A system permission alert (the mic prompt, Accessibility's, Input
    /// Monitoring's) may be showing from the moment its request fires until
    /// the poll turns green or 20 s pass: compacts to the small row so the
    /// alert - which does not register as an "activated app" for
    /// `NSWorkspace` and so never trips `installWorkspaceObserver()` below -
    /// is never left sitting behind the panel's own high window level (see
    /// `NotchPanel.swift`). Restored by the poll turning green
    /// (`restoreFromCompactIfGranted()`, called from `refreshPermissionMarks()`),
    /// by the compact row's own "Back to setup" pill, or by this 20 s
    /// timeout if neither happened.
    private func beginPermissionAlertWindow() {
        permissionAlertWindowTask?.cancel()
        notch.setOnboardingCompact(true)
        let step = notch.model.onboardingStep
        permissionAlertWindowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            guard self.notch.model.state == .onboarding, self.notch.model.onboardingStep == step,
                  self.notch.model.onboardingCompact else { return }
            self.restoreFromCompact()
        }
    }

    private func back() {
        let step = notch.model.onboardingStep
        guard step > 1 else { return }
        goToStep(step - 1)
    }

    /// Whether the current step's Continue button is enabled - both
    /// permission steps require the grant, step 6 requires one result. Every
    /// other step is always free to continue. Read by `OnboardingView` for
    /// the button's own disabled state, so the two never disagree.
    func canContinue() -> Bool {
        switch notch.model.onboardingStep {
        case 2: return notch.model.onboardingMicState == .granted
        case 3: return notch.model.onboardingAccessibilityState == .granted
        case 4: return notch.model.onboardingInputMonitoringState == .granted
        case 7: return notch.model.onboardingTryState == .granted
        default: return true
        }
    }

    private func continueStep() {
        guard canContinue() else { return }
        let step = notch.model.onboardingStep
        if step == 6 {
            applyPickedPacks()
        }
        guard step < 8 else { return }
        goToStep(step + 1)
    }

    /// Step 6's "Skip, use the developer set" (leaves `enabledPacks`
    /// untouched) and step 7's "Skip" (leaves the try-it field empty).
    private func skip() {
        switch notch.model.onboardingStep {
        case 6: goToStep(7)
        case 7: goToStep(8)
        default: break
        }
    }

    private func togglePick(_ area: OnboardingArea) {
        if notch.model.onboardingPickedAreas.contains(area) {
            notch.model.onboardingPickedAreas.remove(area)
        } else {
            notch.model.onboardingPickedAreas.insert(area)
        }
    }

    /// Union of every picked area's packs. An empty pick (Continue pressed
    /// with nothing selected, same as Skip) leaves the developer-set default
    /// untouched.
    private func applyPickedPacks() {
        let picked = notch.model.onboardingPickedAreas
        guard !picked.isEmpty else { return }
        settings.enabledPacks = Set(picked.flatMap(\.packs))
    }

    // MARK: - Microphone (step 2)

    /// The one call site for the real system mic prompt - fired once from
    /// `enterStep(2)`, never from the pill.
    private func requestMicIfNeeded() {
        guard !micRequested else { return }
        micRequested = true
        MicrophonePermission.request { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.notch.model.onboardingMicState = granted ? .granted : .denied
                self.restoreFromCompactIfGranted()
            }
        }
    }

    /// The pill: opens the Microphone pane only, never re-asks.
    private func openMicrophoneSettings() {
        PermissionPanes.open(.microphone)
    }

    // MARK: - Accessibility (step 3)

    /// The one call site for `AXIsProcessTrustedWithOptions`'s prompt during
    /// onboarding - fired once from `enterStep(3)`, never from the pill.
    /// `AppDelegate.installHotkey()` only asks again post-onboarding (a
    /// permission revoked after setup), so the two never race.
    private func requestAccessibilityIfNeeded() {
        guard !accessibilityRequested else { return }
        accessibilityRequested = true
        TextInserter.requestAccessibilityPermission()
    }

    /// The pill: opens the Accessibility pane only, never re-asks.
    private func openAccessibility() {
        PermissionPanes.open(.accessibility)
    }

    // MARK: - Input Monitoring (step 4)

    /// The one call site for `CGRequestListenEventAccess()` during
    /// onboarding - fired once from `enterStep(4)`, never from the pill.
    private func requestInputMonitoringIfNeeded() {
        guard !inputMonitoringRequested else { return }
        inputMonitoringRequested = true
        CGRequestListenEventAccess()
    }

    /// The pill: opens the Input Monitoring pane only, never re-asks.
    private func openInputMonitoring() {
        PermissionPanes.open(.inputMonitoring)
    }

    // MARK: - Permission polling and the compact row

    /// Every second while a permission step (2, 3 or 4) is showing, plus once
    /// whenever `NSApplication.didBecomeActiveNotification` fires (belt and
    /// suspenders: Zumbo is a nonactivating panel and never activates
    /// itself, so this rarely fires for us, but the owner asked for it
    /// explicitly alongside the 1 s poll) and once when the compact row's
    /// "Back to setup" pill restores the full panel.
    private func managePolling() {
        pollTask?.cancel()
        let step = notch.model.onboardingStep
        guard step == 2 || step == 3 || step == 4 else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.refreshPermissionMarks()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshPermissionMarks() {
        switch notch.model.onboardingStep {
        case 2:
            if MicrophonePermission.isAuthorized() {
                notch.model.onboardingMicState = .granted
            } else if micRequested {
                notch.model.onboardingMicState = .denied
            }
        case 3:
            if TextInserter.isAccessibilityTrusted() {
                notch.model.onboardingAccessibilityState = .granted
            } else if accessibilityRequested {
                notch.model.onboardingAccessibilityState = .denied
            }
        case 4:
            if CGPreflightListenEventAccess() {
                notch.model.onboardingInputMonitoringState = .granted
            } else if inputMonitoringRequested {
                notch.model.onboardingInputMonitoringState = .denied
            }
        default:
            return
        }
        restoreFromCompactIfGranted()
    }

    private func restoreFromCompactIfGranted() {
        guard notch.model.onboardingCompact else { return }
        let granted: Bool
        switch notch.model.onboardingStep {
        case 2: granted = notch.model.onboardingMicState == .granted
        case 3: granted = notch.model.onboardingAccessibilityState == .granted
        default: granted = notch.model.onboardingInputMonitoringState == .granted
        }
        if granted { restoreFromCompact() }
    }

    private func restoreFromCompact() {
        permissionAlertWindowTask?.cancel()
        notch.setOnboardingCompact(false)
        refreshPermissionMarks()
    }

    /// Another app (System Settings, showing a permission pane) took focus
    /// while a permission step is open: compact to the small row instead of
    /// covering it. Zumbo never activates itself, so "another app became
    /// active" is an unambiguous signal here.
    private func installWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // `Notification` is not `Sendable`; pull the one plain, Sendable
            // value out of it before crossing into the main-actor closure
            // below, instead of capturing `note` itself.
            let activatedPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated {
                guard let self, self.notch.model.state == .onboarding else { return }
                let step = self.notch.model.onboardingStep
                guard step == 2 || step == 3 || step == 4 else { return }
                guard let activatedPID, activatedPID != ProcessInfo.processInfo.processIdentifier else { return }
                self.notch.setOnboardingCompact(true)
            }
        }
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissionMarks() }
        }
    }

    // MARK: - Step 7

    private func startTrial() {
        settings.trialStartedAt = Date()
        finish()
    }

    private func buy() {
        NSWorkspace.shared.open(Self.buyURL)
    }

    /// Mirrors Settings > License's own "Activate" - a stub until the
    /// Cloudflare Worker + Dodo Payments licensing backend exists (NOTES.md
    /// "Licensing backend"). Wired here so the real call has exactly one
    /// place to land later.
    private func activate(key: String) {
        log.info("onboarding license activation is not wired yet")
    }

    private func finish() {
        settings.onboardingCompleted = true
        settings.onboardingStep = 0
        notch.transition(to: .idle)
        requestFinishNotification()
    }

    /// Notification permission is asked for exactly once, here, not at
    /// launch and not anywhere else - silently does nothing if denied.
    private func requestFinishNotification() {
        let center = UNUserNotificationCenter.current()
        let keyLabel = settings.hotkeyTrigger.displayLabel
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Zumbo"
            content.body = "Zumbo is ready. Press \(keyLabel) anywhere."
            center.add(UNNotificationRequest(
                identifier: "com.zumbo.onboarding.finished", content: content, trigger: nil))
        }
    }
}
