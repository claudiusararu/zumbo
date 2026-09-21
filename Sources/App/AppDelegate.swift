import AppKit
import Carbon.HIToolbox
import Combine
import VesperEngine
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let settings = AppSettings()
    private var settingsCancellables = Set<AnyCancellable>()
    // Demo runs (--demo, used only for screenshot checks) get their own
    // history file, never the real one at the default URL: seeding fake
    // entries there must not touch the dictations a real session recorded.
    private let history = ProcessInfo.processInfo.arguments.contains("--demo")
        ? HistoryStore(url: AppDelegate.demoHistoryURL())
        : HistoryStore()
    private lazy var licenseState = LicenseState(settings: settings)
    private lazy var notch = NotchController(history: history, settings: settings, licenseState: licenseState)
    private lazy var reminders = ReminderScheduler(history: history, notch: notch, settings: settings)
    private var coordinator: DictationCoordinator!
    private var onboarding: OnboardingCoordinator!
    private var hotkey: HotkeyMonitor?
    /// The second, optional hotkey that always starts a note. Nil whenever
    /// `AppSettings.noteHotkeyTrigger` is nil (off).
    private var noteHotkey: HotkeyMonitor?
    private var statusItem: NSStatusItem?
    private var dictateItem: NSMenuItem?
    private var meetingModeItem: NSMenuItem?
    private var licenseStatusItem: NSMenuItem?
    private var meetingBadgeView: NSView?
    /// Sparkle 2 plus the custom `SPUUserDriver` that draws every update step
    /// as a notch notice. Built after `notch.start()`, so the panel exists
    /// before the first scheduled check can fire.
    private var updates: UpdateController?
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement starts every launch hidden; this only switches to
        // .regular when the user has turned "Hide Dock icon" off. Never
        // calls NSApp.activate - the notch panel must stay a nonactivating
        // panel and this must never steal focus from the frontmost app.
        applyDockIconPolicy(hide: settings.hideDockIcon)
        settings.$hideDockIcon
            .dropFirst()
            .sink { [weak self] hide in self?.applyDockIconPolicy(hide: hide) }
            .store(in: &settingsCancellables)

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--diag") {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Zumbo")
            let text = "accessibilityTrusted=\(AXIsProcessTrusted()) inputMonitoring=\(CGPreflightListenEventAccess()) secureInput=\(IsSecureEventInputEnabled()) bundle=\(Bundle.main.bundleIdentifier ?? "?")\n"
            try? text.write(to: dir.appendingPathComponent("diag.txt"), atomically: true, encoding: .utf8)
        }
        // The mock engine stays available for the --demo screenshot paths, so
        // the panel can be driven with no microphone and no model.
        let engine: DictationDriver = arguments.contains("--demo") ? MockEngine() : EngineAdapter()
        coordinator = DictationCoordinator(
            engine: engine, notch: notch, history: history, settings: settings, reminders: reminders)
        notch.model.ruleCount = settings.enabledRuleCount
        notch.model.modelReady = engine.isModelReady

        settings.dictionaryActions = AppSettings.DictionaryActions(
            terms: { [weak self] in self?.coordinator.dictionaryTerms() ?? [] },
            add: { [weak self] term in try self?.coordinator.addDictionaryTerm(term) },
            remove: { [weak self] text in try self?.coordinator.removeDictionaryTerm(text: text) })

        notch.onQuickAction = { [weak self] action in
            guard let self, self.notch.model.state != .onboarding else { return }
            switch action {
            case .dictate: guard self.canRecord() else { return }; self.coordinator.toggle()
            case .note: guard self.canRecord() else { return }; self.coordinator.startNote()
            case .meeting: guard self.canRecord() else { return }; self.coordinator.toggleMeetingMode()
            case .history: self.notch.toggleExpanded()
            case .settings: self.showSettings()
            }
        }

        notch.model.lockedBuyRequest = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.licenseState.endpoints.checkoutURL)
        }
        notch.model.lockedEnterKeyRequest = { [weak self] in
            guard let self else { return }
            self.notch.model.initialSettingsCategory = "License"
            self.notch.model.pendingActivationKey = ""
            self.notch.setExpandedPage(.settings)
            self.notch.transition(to: .expanded)
        }
        licenseState.onLicenseDeactivated = { [weak self] in
            self?.notch.showNotice(NotchNotice(message: "Your license was deactivated", actionTitle: nil))
        }

        notch.onStopRecording = { [weak self] in
            self?.coordinator.stop()
        }
        notch.onToggleMeetingPause = { [weak self] in
            self?.coordinator.toggleMeetingPause()
        }
        notch.onEndMeeting = { [weak self] in
            self?.coordinator.endMeetingConfirmed()
        }

        notch.model.insertAgainRequest = { [weak self] text in
            _ = self?.coordinator.insertIntoFrontmost(text)
        }
        reminders.onAuthorizationChange = { [weak self] denied in self?.notch.model.notificationsDenied = denied }
        notch.model.setReminderRequest = { [weak self] id, date in
            self?.reminders.setReminder(id: id, at: date)
        }
        notch.model.cancelReminderRequest = { [weak self] id in
            self?.reminders.cancelReminder(id: id)
        }

        notch.start()

        // After `notch.start()`: it wires its own default
        // `onboardingRestoreFromCompactRequest`, which this overwrites with
        // the richer one that also refreshes the permission marks.
        onboarding = OnboardingCoordinator(notch: notch, settings: settings, dictation: coordinator)
        onboarding.start()
        settings.runSetupAgainRequest = { [weak self] in self?.onboarding.restart() }

        // Not in --demo runs: a screenshot pass must never reach out to the
        // network or draw an update notice over the state being captured.
        if !arguments.contains("--demo") {
            let updates = UpdateController(notch: notch, settings: settings)
            updates.start()
            self.updates = updates
            settings.checkForUpdatesRequest = { [weak updates] in updates?.checkForUpdates() }
        }

        buildStatusItem()
        observeMeetingModeBadge()
        installTrialNoticeObserver()

        settings.downloadSpeakerModelRequest = { [weak self] in self?.coordinator.startSpeakerModelDownload() }
        settings.cancelSpeakerModelDownloadRequest = { [weak self] in self?.coordinator.cancelSpeakerModelDownload() }
        settings.removeSpeakerModelRequest = { [weak self] in self?.coordinator.removeSpeakerModel() }
        settings.speakerModelStatus = engine.speakerModelStatus
        Task { [weak self] in
            guard let self else { return }
            for await status in engine.speakerModelStatusUpdates {
                self.settings.speakerModelStatus = status
            }
        }

        // Parakeet loads in the background; until it is ready every dictate
        // path says so instead of starting a session that cannot run.
        coordinator.loadModel()
        installHotkey()
        installNoteHotkey()

        // Newest-first list, capped and rewritten on every mutation; the
        // retention window is read from AppSettings live, so a Settings
        // change takes effect on the next purge with no relaunch needed.
        history.retentionDaysProvider = { [weak settings] in settings?.retentionDays ?? 30 }
        history.purgeExpired()
        history.startRetentionTimer()

        // Missed reminders (the Mac was asleep, or the app was not running)
        // are surfaced once before the live timers arm, so nothing already
        // due fires twice.
        reminders.checkMissedReminders()
        reminders.start()

        handleLaunchArguments()
        presentOnboardingIfNeeded()
    }

    /// First launch (`onboardingCompleted` defaults to false), or the DEBUG
    /// `--onboarding` argument. Never fires alongside `--demo` or
    /// `--transcribe-file`, which drive the panel into a specific state of
    /// their own for a screenshot or the unattended pipeline check.
    private func presentOnboardingIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard !args.contains("--demo"), !args.contains("--transcribe-file") else { return }
        var shouldPresent = !settings.onboardingCompleted
        #if DEBUG
        if args.contains("--onboarding") { shouldPresent = true }
        #endif
        guard shouldPresent else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.onboarding.resumeOrPresent()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.stop()
        noteHotkey?.stop()
    }

    // MARK: - Dock icon

    /// Takes the value from the publisher: `@Published` emits before the
    /// property changes, so reading `settings.hideDockIcon` in the sink
    /// applied the old value and inverted the switch.
    private func applyDockIconPolicy(hide: Bool) {
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
    }

    /// The Dock icon is only visible when "Hide Dock icon" is off; clicking
    /// it opens the notch panel straight to History, the closest thing this
    /// app has to a main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard notch.model.state != .onboarding else { return true }
        notch.setExpandedPage(.history)
        notch.transition(to: .expanded)
        return true
    }

    // MARK: - Hotkey

    /// Installs the engine's hybrid tap/hold monitor on the persisted trigger
    /// (Right Option by default). Press starts a session, release or the next
    /// tap stops it.
    ///
    /// A modifier trigger works through NSEvent's flags monitors alone and
    /// needs no permission, so the monitor is always installed. Only a combo
    /// trigger needs the CGEvent tap, which needs Input Monitoring; when that
    /// is missing, `HotkeyMonitor.start()` still leaves the flags monitors
    /// running (so switching back to a modifier trigger works with no
    /// restart) and the notch shows a message with a button to the right
    /// System Settings pane instead of crashing.
    private func installHotkey() {
        let monitor = HotkeyMonitor(trigger: settings.hotkeyTrigger)
        monitor.onPressed = {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Steps 4 and 6 consume the hotkey themselves (mark the
                // trial, or run a real "Try it" dictation); every other
                // onboarding step ignores it entirely.
                if self.notch.model.state == .onboarding {
                    self.onboarding.hotkeyPressed()
                } else if self.canRecord() {
                    self.coordinator.start()
                }
            }
        }
        monitor.onReleased = {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.notch.model.state == .onboarding {
                    self.onboarding.hotkeyReleased()
                } else {
                    self.coordinator.stop()
                }
            }
        }
        monitor.start()
        hotkey = monitor
        coordinator.hotkeyMonitor = monitor
        log.info("hotkey installed: \(String(describing: self.settings.hotkeyTrigger), privacy: .public)")

        if monitor.tapCreationFailed, case .combo = settings.hotkeyTrigger {
            log.error("input monitoring not granted, combo hotkey inactive")
            notch.showNotice(
                NotchNotice(message: "Grant Input Monitoring in System Settings", actionTitle: "Open"),
                holdFor: 8,
                action: { InputMonitoringPermission.request() })
        }

        // Accessibility is what lets the finished text be pasted. Asking now
        // (post-onboarding only - `OnboardingCoordinator.requestAccessibilityIfNeeded()`
        // owns the first-run ask on its own step, so the two never both fire
        // the system prompt for the same launch) means a permission revoked
        // after setup gets re-prompted at the next launch instead of staying
        // silently broken.
        if !settings.onboardingCompleted {
            log.info("accessibility not granted yet; onboarding's own step will prompt")
        } else if !TextInserter.isAccessibilityTrusted() {
            log.info("accessibility not granted yet; prompting")
            TextInserter.requestAccessibilityPermission()
        }
    }

    /// The optional second hotkey that always starts a note. Rebuilt whenever
    /// `AppSettings.noteHotkeyTrigger` changes: nil tears the monitor down,
    /// a trigger (re)installs it with that trigger. Mirrors `installHotkey`'s
    /// permission handling: a combo trigger needs Input Monitoring, and when
    /// that tap fails the notch says so with a button to the right pane.
    private func installNoteHotkey() {
        rebuildNoteHotkey(trigger: settings.noteHotkeyTrigger)
        settings.$noteHotkeyTrigger
            .dropFirst()
            .sink { [weak self] trigger in self?.rebuildNoteHotkey(trigger: trigger) }
            .store(in: &settingsCancellables)
    }

    private func rebuildNoteHotkey(trigger: HotkeyTrigger?) {
        noteHotkey?.stop()
        noteHotkey = nil
        guard let trigger else { return }

        let monitor = HotkeyMonitor(trigger: trigger)
        monitor.onPressed = {
            Task { @MainActor [weak self] in
                guard let self, self.canRecord() else { return }
                self.coordinator.startNote()
            }
        }
        monitor.onReleased = {
            Task { @MainActor [weak self] in self?.coordinator.stop() }
        }
        monitor.start()
        noteHotkey = monitor
        log.info("note hotkey installed: \(String(describing: trigger), privacy: .public)")

        if monitor.tapCreationFailed, case .combo = trigger {
            log.error("input monitoring not granted, note hotkey combo inactive")
            notch.showNotice(
                NotchNotice(message: "Grant Input Monitoring in System Settings", actionTitle: "Open"),
                holdFor: 8,
                action: { InputMonitoringPermission.request() })
        }
    }

    /// Small red dot on the menu bar waveform icon while meeting mode is on,
    /// a plain `NSView` overlay rather than a composited image: the icon
    /// itself stays a template (monochrome, tinted by the system), and the
    /// dot needs its own color to read as a live indicator.
    private func observeMeetingModeBadge() {
        notch.model.$meetingModeOn
            .sink { [weak self] on in self?.setMeetingBadge(visible: on) }
            .store(in: &settingsCancellables)
    }

    private func setMeetingBadge(visible: Bool) {
        guard let button = statusItem?.button else { return }
        if visible {
            guard meetingBadgeView == nil else { return }
            let size: CGFloat = 6
            let dot = NSView(frame: NSRect(x: button.bounds.width - size, y: button.bounds.height - size,
                                            width: size, height: size))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.layer?.cornerRadius = size / 2
            dot.autoresizingMask = [.minXMargin, .minYMargin]
            button.addSubview(dot)
            meetingBadgeView = dot
        } else {
            meetingBadgeView?.removeFromSuperview()
            meetingBadgeView = nil
        }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // The system waveform symbol: crisp at menu bar size, where our
            // own bitmap glyph blurred into a blob. Symbols are fine in a menu
            // bar; the app icon stays our own drawing.
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Zumbo")
            image?.isTemplate = true
            button.image = image
            button.image?.size = NSSize(width: 16, height: 16)
        }

        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: licenseState.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        licenseStatusItem = status

        let dictate = NSMenuItem(title: "Start Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        dictate.target = self
        menu.addItem(dictate)
        dictateItem = dictate

        let newNote = NSMenuItem(title: "New Note", action: #selector(newNote), keyEquivalent: "")
        newNote.target = self
        menu.addItem(newNote)

        let meetingMode = NSMenuItem(title: "Start Meeting", action: #selector(toggleMeetingMode), keyEquivalent: "")
        meetingMode.target = self
        menu.addItem(meetingMode)
        meetingModeItem = meetingMode

        let history = NSMenuItem(title: "History", action: #selector(showHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        let settings = NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let feedback = NSMenuItem(title: "Send feedback...", action: #selector(showFeedback), keyEquivalent: "")
        feedback.target = self
        menu.addItem(feedback)

        #if DEBUG
        menu.addItem(.separator())
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = buildDebugMenu()
        menu.addItem(debugItem)
        #endif

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Zumbo", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        item.isVisible = self.settings.showMenuBarIcon
        statusItem = item

        // Settings > General > "Show menu bar icon" toggle. `self.` is load
        // bearing: the local `settings` NSMenuItem built above shadows the
        // `AppSettings` property of the same name.
        self.settings.$showMenuBarIcon
            .sink { [weak self] visible in self?.statusItem?.isVisible = visible }
            .store(in: &settingsCancellables)
    }

    #if DEBUG
    private func buildDebugMenu() -> NSMenu {
        let menu = NSMenu(title: "Debug")
        let items: [(String, Selector)] = [
            ("Simulate hover", #selector(debugHover)),
            ("Simulate recording 3 s", #selector(debugRecording)),
            ("Simulate done", #selector(debugDone)),
            ("Show expanded", #selector(debugExpanded))
        ]
        for (title, selector) in items {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }
    #endif

    func menuNeedsUpdate(_ menu: NSMenu) {
        licenseState.refresh()
        licenseStatusItem?.title = licenseState.statusLine
        meetingModeItem?.state = coordinator.isMeetingModeOn ? .on : .off
        meetingModeItem?.title = coordinator.isMeetingModeOn ? "End Meeting" : "Start Meeting"

        guard let item = dictateItem else { return }
        if !coordinator.isModelReady {
            item.title = "Loading speech model..."
            item.isEnabled = false
            return
        }
        item.isEnabled = true
        item.title = coordinator.isDictating ? "Stop Dictation" : "Start Dictation"
    }

    // MARK: - Actions

    @objc private func toggleDictation() {
        guard notch.model.state != .onboarding, canRecord() else { return }
        guard coordinator.isModelReady else {
            notch.showNotice(NotchNotice(message: "Loading speech model", actionTitle: nil))
            return
        }
        coordinator.toggle()
    }

    @objc private func newNote() {
        guard notch.model.state != .onboarding, canRecord() else { return }
        guard coordinator.isModelReady else {
            notch.showNotice(NotchNotice(message: "Loading speech model", actionTitle: nil))
            return
        }
        coordinator.startNote()
    }

    @objc private func toggleMeetingMode() {
        guard notch.model.state != .onboarding, canRecord() else { return }
        coordinator.toggleMeetingMode()
    }

    // MARK: - Licensing gate

    /// The one choke point every recording path (hotkey, menu item, quick
    /// action) goes through. `false` means the trial has ended and nothing
    /// has activated: shows the locked notch state instead and refuses.
    /// Also the first place a "Trial ends tomorrow/today" notice can fire,
    /// since NOTES.md ties it to "the first dictation", not a timer.
    @discardableResult
    private func canRecord() -> Bool {
        if licenseState.status.isLocked {
            notch.showLocked()
            return false
        }
        if let message = licenseState.finalStretchNoticeIfDue() {
            // Not now: the recording row would replace the notice in the same
            // instant. It shows once the notch is back to idle after this
            // dictation (see `installTrialNoticeObserver`).
            pendingTrialNotice = message
        }
        return true
    }

    private var pendingTrialNotice: String?

    /// Shows a held trial notice the next time the notch settles to idle,
    /// a beat after the done check, so it lands after the dictation and not
    /// under it.
    private func installTrialNoticeObserver() {
        notch.model.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self, state == .idle, let message = self.pendingTrialNotice else { return }
                self.pendingTrialNotice = nil
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard let self, self.notch.model.state == .idle else { return }
                    self.notch.showNotice(
                        NotchNotice(message: message, actionTitle: "Buy a license", dismissible: true), holdFor: 6,
                        action: { [weak self] in
                            guard let self else { return }
                            NSWorkspace.shared.open(self.licenseState.endpoints.checkoutURL)
                        })
                }
            }
            .store(in: &settingsCancellables)
    }

    /// `zumbo://activate?key=...`: opens Settings > License pre-filled and
    /// activates right away.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "zumbo", url.host == "activate" else { return }
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "key" })?.value ?? ""
        notch.model.initialSettingsCategory = "License"
        notch.model.pendingActivationKey = key
        notch.setExpandedPage(.settings)
        notch.transition(to: .expanded)
    }

    /// History lives inside the expanded notch panel, so this is the real
    /// surface, with placeholder rows for now.
    @objc private func showHistory() {
        guard notch.model.state != .onboarding else { return }
        notch.transition(to: .expanded)
    }

    /// No settings window: this opens the expanded panel straight to its
    /// Settings page. Pressed again while already there, it collapses, same
    /// as the History quick action toggles the panel.
    @objc private func showSettings() {
        guard notch.model.state != .onboarding else { return }
        if notch.model.state == .expanded, notch.model.expandedPage == .settings {
            notch.transition(to: .idle)
            return
        }
        // Page first, then one expand straight to the Settings height; the
        // other order grew twice with the text already on screen.
        notch.setExpandedPage(.settings)
        notch.transition(to: .expanded)
    }

    /// Menu bar "Send feedback...": opens the expanded panel straight to
    /// Settings > Feedback, same pattern as the `zumbo://activate` deep
    /// link opening Settings > License.
    @objc private func showFeedback() {
        guard notch.model.state != .onboarding else { return }
        notch.model.initialSettingsCategory = "Feedback"
        notch.setExpandedPage(.settings)
        notch.transition(to: .expanded)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Debug helpers

    #if DEBUG
    @objc private func debugHover() {
        notch.transition(to: .hover)
    }

    @objc private func debugRecording() {
        simulateRecording(seconds: 3)
    }

    @objc private func debugDone() {
        notch.finish()
    }

    @objc private func debugExpanded() {
        notch.transition(to: .expanded)
    }
    #endif

    #if DEBUG
    /// Moves the real pointer to the top center of a chosen display.
    private func warpPointer(to keyword: String) {
        let screens = NSScreen.screens
        let target: NSScreen?
        switch keyword {
        case "builtin": target = screens.first(where: { $0.hasHardwareNotch }) ?? screens.first
        case "external": target = screens.first(where: { !$0.hasHardwareNotch })
        default: target = NSScreen.main
        }
        guard let screen = target,
              let zero = screens.first(where: { $0.frame.origin == .zero }) else { return }

        // Cocoa is bottom-left origin, CGWarpMouseCursorPosition is top-left.
        let point = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 120)
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: zero.frame.maxY - point.y))
        log.info("pointer warped to \(keyword, privacy: .public)")
    }
    #endif

    private func simulateRecording(seconds: Double) {
        coordinator.start()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.coordinator.stop()
        }
    }

    // MARK: - Demo history

    /// Isolated from the real `history.json`: a `--demo` run seeds fake
    /// entries to have something to screenshot, and that must never land in
    /// the file the user's real dictations are stored in.
    private static func demoHistoryURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Zumbo/demo-history.json")
    }

    /// Five entries across four different apps (one an "Unknown app" case, an
    /// empty bundle id and a system process name, to exercise the capture-time
    /// mapping), so the app filter row, the Favorites pill and the grid/row
    /// layouts all have something real to render. Only used by the
    /// `--demo expanded`, `--demo expanded-grid`, `--demo expanded-settings`
    /// and `--demo expanded-detail` screenshot paths, and only when the demo
    /// history is still empty.
    private func seedDemoHistoryIfNeeded() {
        guard history.entries.isEmpty else { return }
        let seeds: [(text: String, bundleID: String?, appName: String?, duration: Double, favorite: Bool)] = [
            ("Use kubectl to list the pods on the Kubernetes cluster.", "com.apple.dt.Xcode", "Xcode", 6, true),
            ("Let's ship the release notes by Friday afternoon and tag the reviewers before end of day.",
             "com.apple.Notes", "Notes", 9, false),
            ("Open a pull request against the main branch and tag review.", "com.apple.Safari", "Safari", 4, false),
            ("Remember to renew the domain before it expires next month.", nil, "loginwindow", 3, false),
            ("Add oat milk, coffee filters and the good olive oil to the list.", "com.apple.Notes", "Notes", 5, true),
        ]
        for seed in seeds {
            let identity = AppIdentity.normalize(bundleID: seed.bundleID, name: seed.appName)
            history.add(DictationHistoryEntry(
                finalText: seed.text, rawText: seed.text,
                bundleID: identity.bundleID, appName: identity.name,
                duration: seed.duration, isFavorite: seed.favorite))
        }

        // A note with a pending reminder (the "Notes" filter and its bell
        // chip need one to show anything) and a finished meeting, so
        // `--demo expanded-notes` has a real card to filter to.
        let noteText = "Call the accountant about the Q3 estimate before Friday."
        let note = DictationHistoryEntry(
            finalText: noteText, rawText: noteText, bundleID: nil, appName: nil,
            duration: 0, kind: .note, title: "Accountant call")
        history.add(note)
        history.setReminder(id: note.id, at: Date().addingTimeInterval(3600))

        let meetingText = "[00:00] Kickoff on the Q3 roadmap.\n[00:42] Ship the release notes by Friday."
        history.add(DictationHistoryEntry(
            finalText: meetingText, rawText: meetingText, bundleID: nil, appName: nil,
            duration: 620, kind: .meeting, title: "Roadmap sync", endedAt: Date()))
    }

    // MARK: - Launch arguments

    /// `Zumbo --demo recording|hover|done|expanded|expanded-grid|expanded-settings|expanded-detail`
    /// drives the panel straight into one state. Used for screenshot checks
    /// without a microphone. `recording` holds for 12 s so there is time to
    /// capture it. `expanded-grid` opens expanded and switches the History
    /// tab to the grid layout. `expanded-settings` opens expanded straight to
    /// the Settings page. `expanded-detail` opens expanded and the first
    /// card's detail panel. All four history-backed demos seed fake entries
    /// first if the demo history is still empty. `expanded-settings` also
    /// reads `--settings-category general|dictation|dictionary|models|
    /// license|about` to land on a specific category instead of the default
    /// General, for the per-category screenshot checks.
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments

        #if DEBUG
        // `--demo-screen builtin|external` parks the pointer on that display
        // first, because the panel follows the pointer. Screenshot checks need
        // to pick the display.
        if let index = args.firstIndex(of: "--demo-screen"), index + 1 < args.count {
            warpPointer(to: args[index + 1])
        }
        #endif

        // Hidden, for the meeting-mode crash fix: no GUI is needed to drive
        // the toggle repeatedly (the DEBUG menu isn't in Release builds), so
        // this exercises `toggleMeetingMode()` - the same path the quick
        // action and the menu item use - directly. 2 s after launch, N
        // on/off cycles 700 ms apart, with a `showNotice` thrown in every
        // third toggle to also race the notice path against the meeting
        // transition, then quits with exit code 0. Not gated behind DEBUG:
        // harmless (and needed) in Release, since that's the build shipped.
        if let index = args.firstIndex(of: "--stress-meeting-toggle"), index + 1 < args.count,
           let count = Int(args[index + 1]) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { exit(0) }
                for i in 0..<count {
                    self.coordinator.toggleMeetingMode()
                    if (i + 1) % 3 == 0 {
                        self.notch.showNotice(
                            NotchNotice(message: "Stress test notice \(i)", actionTitle: "OK"),
                            holdFor: 0.3, returnTo: self.notch.model.meetingModeOn ? .meeting : .idle)
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                }
                exit(0)
            }
            return
        }

        // Hidden, for the unattended end-to-end check: run the whole pipeline
        // on a WAV (no capture, the file's samples) and paste the result into
        // whatever app is frontmost.
        if let index = args.firstIndex(of: "--transcribe-file"), index + 1 < args.count {
            let path = args[index + 1]
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                await self.coordinator.transcribeFile(at: URL(fileURLWithPath: path))
            }
            return
        }

        guard let index = args.firstIndex(of: "--demo"), index + 1 < args.count else { return }
        let demo = args[index + 1]

        Task { [weak self] in
            // Let the status item and panel settle first.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            switch demo {
            case "hover": self.notch.transition(to: .hover)
            case "recording": self.simulateRecording(seconds: 12)
            case "done": self.notch.finish()
            case "expanded":
                self.seedDemoHistoryIfNeeded()
                self.notch.transition(to: .expanded)
            case "expanded-grid":
                self.notch.transition(to: .expanded)
                self.notch.setHistoryLayout(.grid)
            case "expanded-settings":
                self.seedDemoHistoryIfNeeded()
                // `--settings-category general|dictation|dictionary|models|license|about`
                // (screenshot checks only) opens straight to that category
                // instead of the default General.
                if let categoryIndex = args.firstIndex(of: "--settings-category"), categoryIndex + 1 < args.count {
                    self.notch.model.initialSettingsCategory = args[categoryIndex + 1].capitalized
                }
                self.notch.transition(to: .expanded)
                self.notch.setExpandedPage(.settings)
            case "expanded-detail":
                self.seedDemoHistoryIfNeeded()
                self.notch.transition(to: .expanded)
                // The seeded note (not the meeting or a plain dictation): it
                // is the one with a reminder chip in the chip row.
                if let note = self.history.entries.first(where: { $0.kind == .note }) {
                    self.notch.setDetailEntry(note.id)
                }
            case "expanded-teach":
                self.seedDemoHistoryIfNeeded()
                self.notch.model.demoOpenTeach = true
                self.notch.transition(to: .expanded)
                // A plain dictation, not the meeting (its first word is a
                // "[00:00]" timestamp, not a real word to teach).
                if let first = self.history.entries.first(where: { $0.kind == .dictation }) {
                    self.notch.setDetailEntry(first.id)
                }
            case "expanded-notes":
                self.seedDemoHistoryIfNeeded()
                self.notch.model.initialKindFilter = .note
                self.notch.transition(to: .expanded)
            case "idle":
                self.notch.transition(to: .idle)
            case "notice":
                self.notch.showNotice(
                    NotchNotice(message: "Note saved. Remind you at 5 PM?", actionTitle: "Set reminder", secondaryActionTitle: "No"),
                    holdFor: 20)
            case "reminder":
                self.seedDemoHistoryIfNeeded()
                self.notch.showReminderNotice(
                    message: "Reminder: Call the accountant about the Q3 estimate.",
                    primaryTitle: "Done", secondaryTitle: "Snooze 10 min", holdFor: 20,
                    primaryAction: {}, secondaryAction: {})
            case "update":
                self.notch.showNotice(
                    NotchNotice(message: "Zumbo 1.2.0 is available", actionTitle: "Update", secondaryActionTitle: "Later"),
                    holdFor: 20)
            case "meeting":
                self.notch.startMeetingUI()
                self.notch.setMeetingPausedUI(false)
            case "meeting-paused":
                self.notch.startMeetingUI()
            case "locked":
                self.notch.showLocked()
            default:
                if demo.hasPrefix("settings-") {
                    let category = String(demo.dropFirst("settings-".count))
                    self.seedDemoHistoryIfNeeded()
                    self.notch.model.initialSettingsCategory = category.capitalized
                    self.notch.transition(to: .expanded)
                    self.notch.setExpandedPage(.settings)
                } else if demo.hasPrefix("onboarding-"), let step = Int(demo.dropFirst("onboarding-".count)) {
                    self.notch.model.onboardingStep = step
                    self.notch.transition(to: .onboarding)
                } else {
                    self.log.error("unknown --demo value: \(demo, privacy: .public)")
                }
            }
        }
    }
}
