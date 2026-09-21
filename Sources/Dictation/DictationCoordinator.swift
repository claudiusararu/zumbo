import AppKit
import Carbon.HIToolbox
import Combine
import VesperEngine
import os

/// Glues the engine to the notch panel, history and permissions. The only
/// place that knows the order of a dictation: permissions -> settings ->
/// start -> levels -> stop -> paste -> history -> done.
@MainActor
final class DictationCoordinator {

    private let engine: DictationDriver
    private let notch: NotchController
    private let history: HistoryStore
    private let settings: AppSettings
    private let reminders: ReminderScheduler
    private let sounds = Sounds()
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "dictation")

    private var levelTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private(set) var isDictating = false
    /// Shown at most once per launch: the first recording that starts
    /// without Input Monitoring tells the owner Escape will not work
    /// everywhere, instead of silently failing later.
    private var inputMonitoringNoticeShown = false

    /// The live hotkey monitor, handed over by `AppDelegate` once installed.
    /// `AppSettings.hotkeyTrigger` is reassignable at runtime (see
    /// `HotkeyMonitor.trigger`'s doc comment), so the Settings shortcut
    /// recorder's save takes effect immediately, not only at next launch.
    var hotkeyMonitor: HotkeyMonitor? {
        didSet { hotkeyMonitor?.trigger = settings.hotkeyTrigger }
    }
    private var hotkeyCancellable: AnyCancellable?

    /// The app that was frontmost when the session started. Zumbo never
    /// activates, so that is the app the text will be pasted into. `isSelf`
    /// is true on the rare path where the frontmost app genuinely reports as
    /// Zumbo (see `frontmostTarget()`); the more reliable signal for "the
    /// user is dictating into our own panel" is `noteTargetID` below, set
    /// from the panel's own state rather than from `NSWorkspace`.
    private var target: (bundleID: String?, name: String?, isSelf: Bool)?

    /// Last transcript, for the Debug menu and for logging.
    private(set) var lastTranscript: String?

    /// Set right before a session starts if the History detail panel is open
    /// on a note: the recording appends to that note instead of pasting,
    /// exactly as if "New note" had targeted it. Cleared once consumed.
    private var noteTargetID: UUID?
    /// True for the one session started by "New note" or the note hotkey:
    /// forces `.note` context even with no detail panel open, so `finish`
    /// creates a fresh note instead of pasting.
    private var pendingNewNote = false
    /// The running meeting's entry id, set by `toggleMeetingMode()`. Nil when
    /// meeting mode is off.
    private var activeMeetingID: UUID?
    /// The live meeting orchestrator (chunked transcription, optional
    /// speaker labels). Non-nil for the whole life of a meeting, recording
    /// or paused - its presence is what `toggle()`/`start()`/`cancel()` check
    /// to route the hotkey/Escape to pause/resume instead of a dictation.
    private var meetingSession: MeetingSession?
    private var meetingUpdatesTask: Task<Void, Never>?
    private var meetingLevelTask: Task<Void, Never>?

    var isModelReady: Bool { engine.isModelReady }

    init(
        engine: DictationDriver, notch: NotchController, history: HistoryStore, settings: AppSettings,
        reminders: ReminderScheduler
    ) {
        self.engine = engine
        self.notch = notch
        self.history = history
        self.settings = settings
        self.reminders = reminders
        observeState()
        hotkeyCancellable = settings.$hotkeyTrigger
            .dropFirst()
            .sink { [weak self] trigger in self?.hotkeyMonitor?.trigger = trigger }
    }

    // MARK: - Model

    /// Loads the speech model in the background and logs real download
    /// progress. Onboarding will show this later; for now it goes to the log.
    func loadModel() {
        // Settings (enabled packs, rules, developer mode) must reach the engine
        // before the boosting context is built, or the first dictation boosts
        // against every pack.
        engine.apply(settings: settings)
        Task { [weak self] in
            guard let self else { return }
            let progress = Task { [weak self] in
                guard let self else { return }
                for await fraction in self.engine.modelLoadProgress {
                    self.log.info("model load \(Int(fraction * 100), privacy: .public)%")
                }
            }
            await self.engine.loadModel()
            progress.cancel()
            self.notch.model.modelReady = self.engine.isModelReady
            self.notch.model.dictionaryCount = self.engine.dictionaryTermCount
        }
    }

    // MARK: - Session

    /// The main hotkey/quick action. While a meeting is running this
    /// pauses/resumes it instead - meeting mode never pastes, so the normal
    /// dictate action does not apply.
    func toggle() {
        guard meetingSession == nil else {
            toggleMeetingPause()
            return
        }
        isDictating ? stop() : start()
    }

    /// "New note" quick action, menu item and the note hotkey: starts a
    /// recording that is always saved as a fresh note, never pasted,
    /// regardless of what the detail panel is showing. Refused while a
    /// meeting is recording - one microphone session at a time.
    func startNote() {
        guard !isDictating, meetingSession == nil else { return }
        pendingNewNote = true
        start()
    }

    // MARK: - Meeting mode

    var isMeetingModeOn: Bool { notch.model.meetingModeOn }

    /// The single entry point (quick-action toggle switch, menu item): on
    /// starts recording immediately and keeps recording continuously - there
    /// is no separate "press the hotkey" step. Off asks the row to confirm
    /// first (`NotchRootView`'s "End meeting?"); this method itself is only
    /// ever the *on* path or the confirmed *off* path
    /// (`endMeetingConfirmed()`), never a toggle mid-meeting.
    func toggleMeetingMode() {
        if notch.model.meetingModeOn {
            // The row's own Stop button owns the confirm step; the menu
            // item and a second quick-action tap both end immediately
            // without asking again, since they are already a deliberate,
            // separate action from an accidental row click.
            endMeetingConfirmed()
        } else {
            startMeeting()
        }
    }

    /// Starts recording immediately (guarded the same way a plain dictation
    /// is: model ready, microphone authorized). Refuses while a plain
    /// dictation or note is already recording, and vice versa - one
    /// microphone session at a time.
    private func startMeeting() {
        guard !isDictating, meetingSession == nil else { return }

        guard engine.isModelReady else {
            notch.showNotice(NotchNotice(message: "Loading speech model", actionTitle: nil))
            return
        }

        guard MicrophonePermission.isAuthorized() else {
            MicrophonePermission.request { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.startMeeting()
                    } else {
                        self.notch.showNotice(
                            NotchNotice(message: "Grant Microphone in System Settings", actionTitle: "Open"),
                            action: { PermissionPanes.open(.microphone) })
                    }
                }
            }
            return
        }

        let id = history.createMeeting(title: Self.meetingTitle(for: Date()))
        activeMeetingID = id

        // Shown every time meeting mode goes on: it is the one place that
        // says how the mode works (arm, then Record) and what the mic hears.
        var disclosure =
            "Meeting mode is on. Press Right Option or the Record button to start; "
            + "press again to pause. Text is saved to a meeting note, never pasted. "
            + "On a call, use speakers instead of headphones so the other side is heard. "
            + "Nothing leaves this Mac."
        let addOnReady = engine.speakerModelIsReady
        if !(settings.labelSpeakers && addOnReady) {
            disclosure += " Speaker labels are off. Turn them on in Settings > Models."
        }
        let session = engine.makeMeetingSession()
        meetingSession = session
        notch.startMeetingUI()

        // The disclosure notice used to show immediately, in the same
        // run-loop turn as `startMeetingUI()`'s own transition - two window
        // resizes stacked back to back, which could still surface as a
        // reentrant AppKit layout crash even with the frame queue's
        // coalescing (NotchController.scheduleFrame). Waiting for the
        // meeting transition to settle first, and only showing the notice if
        // meeting mode is still on, keeps the notice's own content-sized
        // width and hold time with no risk of colliding with the transition.
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: NotchController.settleDelay + .milliseconds(50))
            guard !Task.isCancelled, self.notch.model.meetingModeOn else { return }
            self.notch.showNotice(
                NotchNotice(message: disclosure, actionTitle: "OK"), holdFor: 8, returnTo: .meeting)
        }

        meetingUpdatesTask = Task { [weak self] in
            guard let self else { return }
            for await update in session.paragraphUpdates {
                self.handleMeetingParagraph(update)
            }
        }
        meetingLevelTask = Task { [weak self] in
            guard let self else { return }
            for await level in session.levels {
                self.notch.model.apply(level: level)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                // Missing or off: this meeting runs the whole way through
                // without labels (spec). Nothing downloads on its own here -
                // only Settings > Models' switch ever starts a download.
                try await session.start(labelSpeakers: self.settings.labelSpeakers)
                if self.settings.playSounds { self.sounds.play(.start) }
            } catch {
                self.log.error("meeting start failed: \(error.localizedDescription, privacy: .public)")
                self.notch.showNotice(NotchNotice(message: "Could not start the microphone", actionTitle: nil))
                self.abandonMeeting()
            }
        }
    }

    /// Hotkey, or the row's Record/Pause button: starts or pauses the
    /// meeting recording instead of dictating while meeting mode is on.
    /// Never pastes. A paused fragment is transcribed right away so its
    /// text lands in the note before the next one starts.
    func toggleMeetingPause() {
        guard let meetingSession else { return }
        if meetingSession.isPaused {
            do {
                try meetingSession.resume()
                notch.setMeetingPausedUI(false)
                if settings.playSounds { sounds.play(.start) }
            } catch {
                log.error("meeting resume failed: \(error.localizedDescription, privacy: .public)")
                notch.showNotice(NotchNotice(message: "Could not start the microphone", actionTitle: nil))
            }
        } else {
            notch.setMeetingPausedUI(true)
            Task { await meetingSession.pause() }
        }
    }

    /// The row's Stop button, after its own "End meeting?" confirm - or the
    /// menu item / quick-action toggle turning meeting mode back off.
    /// Finalizes diarization, appends the last chunk, flashes "Meeting
    /// saved, N words, m:ss" in the row, then retracts.
    func endMeetingConfirmed() {
        guard let meetingSession, let activeMeetingID else { return }
        self.meetingSession = nil
        self.activeMeetingID = nil
        meetingUpdatesTask?.cancel()
        meetingUpdatesTask = nil
        meetingLevelTask?.cancel()
        meetingLevelTask = nil

        Task { [weak self] in
            guard let self else { return }
            let (_, duration) = await meetingSession.stop()
            if self.settings.playSounds { self.sounds.play(.finish) }
            if meetingSession.labelAvailability == .unavailable {
                self.history.appendMeetingFooter(
                    id: activeMeetingID, note: "Speaker labels were off for this meeting")
            }
            self.history.endMeeting(id: activeMeetingID)
            let totalWords = self.history.entry(id: activeMeetingID)?.wordCount ?? 0
            self.notch.showMeetingSaved("Meeting saved, \(totalWords) words, \(Self.durationStamp(duration))")
            try? await Task.sleep(for: .milliseconds(1600))
            self.notch.endMeetingUI()
        }
    }

    /// The microphone failed to start after the entry and session were
    /// already created: closes the (empty) meeting entry and tears down.
    private func abandonMeeting() {
        meetingUpdatesTask?.cancel()
        meetingUpdatesTask = nil
        meetingLevelTask?.cancel()
        meetingLevelTask = nil
        if let activeMeetingID {
            history.endMeeting(id: activeMeetingID)
        }
        activeMeetingID = nil
        meetingSession = nil
        notch.endMeetingUI()
    }

    private func handleMeetingParagraph(_ update: MeetingParagraphUpdate) {
        guard let activeMeetingID else { return }
        let totalWords = history.appendMeetingChunk(
            id: activeMeetingID, text: update.text, speakerLabel: update.speakerLabel,
            at: Date(), newParagraph: update.isNewParagraph)
        guard let totalWords else { return }
        notch.showMeetingSaved("Saved, \(totalWords) words")
    }

    private static func meetingTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        let day = formatter.string(from: date)
        let time = DateFormatter()
        time.dateFormat = "H:mm"
        return "Meeting, \(day) \(time.string(from: date))"
    }

    private static func durationStamp(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// The single entry point for every trigger (hotkey, menu, quick action).
    /// Refuses, with a message in the notch, when the model is still loading
    /// or the microphone is not granted.
    func start() {
        // Onboarding's "Try it" step (step 6) owns the hotkey while it is
        // showing (`AppDelegate.installHotkey()` routes to
        // `OnboardingCoordinator` on every other step); this only runs when
        // the panel itself is mid-try.
        guard notch.model.state != .onboarding else {
            startOnboardingTry()
            return
        }
        // The main hotkey calls `start()`/`stop()` directly (press/release),
        // not `toggle()` - so meeting-mode redirection has to live here too.
        // The monitor alternates onPressed/onReleased on taps, so `stop()`
        // routes to pause/resume as well; nothing pastes.
        guard meetingSession == nil else {
            toggleMeetingPause()
            return
        }
        guard !isDictating else { return }

        guard engine.isModelReady else {
            log.info("dictate refused: model still loading")
            notch.showNotice(NotchNotice(message: "Loading speech model", actionTitle: nil))
            return
        }

        // Microphone permission is asked for on the first dictation attempt,
        // not at launch: the prompt makes sense only when it is about to be used.
        guard MicrophonePermission.isAuthorized() else {
            MicrophonePermission.request { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.start()
                    } else {
                        self.notch.showNotice(
                            NotchNotice(message: "Grant Microphone in System Settings", actionTitle: "Open"),
                            action: { PermissionPanes.open(.microphone) })
                    }
                }
            }
            return
        }

        isDictating = true
        target = Self.frontmostTarget()

        // Decide what this recording is for, in priority order: an explicit
        // "New note" / note-hotkey press, then the History detail panel
        // being open on a note (our own panel is key while expanded, so a
        // dictation started then is aimed at that note, not at whatever app
        // used to be frontmost), then meeting mode, then a plain dictation.
        if pendingNewNote {
            notch.model.recordingContext = .note
            noteTargetID = nil
            pendingNewNote = false
        } else if notch.model.state == .expanded, let detailID = notch.model.detailEntryID,
                  history.entry(id: detailID)?.kind == .note {
            notch.model.recordingContext = .note
            noteTargetID = detailID
        } else {
            notch.model.recordingContext = .dictation
            noteTargetID = nil
        }

        engine.apply(settings: settings)
        if settings.playSounds { sounds.play(.start) }
        notch.transition(to: .recording)
        installEscapeMonitor()
        noticeInputMonitoringIfNeeded()

        levelTask = Task { [weak self] in
            guard let self else { return }
            var seen = 0
            for await level in self.engine.levels {
                if Task.isCancelled { break }
                self.notch.model.apply(level: level)
                #if DEBUG
                // First second of levels on stderr: the only way to see the
                // real range of the stream without a human at the microphone.
                seen += 1
                if seen <= 30 {
                    FileHandle.standardError.write(
                        Data("level \(seen): raw \(level) smoothed \(self.notch.model.level)\n".utf8))
                }
                #endif
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.start()
            } catch {
                self.log.error("engine start failed: \(error.localizedDescription, privacy: .public)")
                self.isDictating = false
                self.cancelStreams()
                self.notch.showNotice(
                    NotchNotice(message: "Could not start the microphone", actionTitle: nil))
            }
        }
    }

    /// Escape while recording: the microphone stops, nothing is transcribed,
    /// nothing is pasted, the notch retracts. The Escape key itself still
    /// reaches the frontmost app (a listen-only monitor cannot swallow it).
    func cancel() {
        guard isDictating else { return }
        isDictating = false
        engine.cancel()
        cancelStreams()
        target = nil
        noteTargetID = nil
        pendingNewNote = false
        notch.transition(to: .idle)
        log.info("dictation cancelled by the user")
    }

    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?

    /// Global monitor for Escape while another app is frontmost (macOS
    /// delivers global key events only to apps trusted for Accessibility
    /// and never while any app has Secure Keyboard Entry on), plus a local
    /// monitor for the case where our own panel holds the keys.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        if !AXIsProcessTrusted() {
            log.error("escape monitor installed without Accessibility trust: global key events will not arrive")
        }
        if IsSecureEventInputEnabled() {
            log.error("secure keyboard entry is on in some app: global key events will not arrive")
        }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.isDictating, event.keyCode == 53 else { return }
                self.cancel()
            }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, self.isDictating, event.keyCode == 53 else { return false }
                self.cancel()
                return true
            }
            return handled ? nil : event
        }
    }

    /// Once per launch, the first recording started without Input
    /// Monitoring tells the owner Escape cannot reach other apps yet.
    /// Mirrors the meeting disclosure's pattern: wait for the recording
    /// transition to settle, then show the notice and return to
    /// `.recording` on timeout - or straight to Settings > General if the
    /// owner taps the pill.
    private func noticeInputMonitoringIfNeeded() {
        guard !inputMonitoringNoticeShown, !CGPreflightListenEventAccess() else { return }
        inputMonitoringNoticeShown = true
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: NotchController.settleDelay + .milliseconds(50))
            guard !Task.isCancelled, self.isDictating else { return }
            self.notch.showNotice(
                NotchNotice(message: "Escape cannot cancel yet. Allow Input Monitoring in Settings > General.",
                            actionTitle: "Open Settings"),
                holdFor: 5, action: { [weak self] in self?.openGeneralSettings() }, returnTo: .recording)
        }
    }

    /// Opens the expanded panel straight to Settings > General. Scheduled a
    /// beat later than the tap itself, since `showNotice`'s own action
    /// always transitions back to its `returnTo` state right after this
    /// closure returns - that beat lets this navigation win instead.
    private func openGeneralSettings() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.notch.model.initialSettingsCategory = "General"
            self.notch.setExpandedPage(.settings)
            self.notch.transition(to: .expanded)
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        localEscapeMonitor = nil
    }

    func stop() {
        // Mirrors `start()`'s onboarding redirect.
        guard notch.model.recordingContext != .onboarding else {
            stopOnboardingTry()
            return
        }
        // The hotkey monitor alternates press/release callbacks on taps, so
        // the second tap of a meeting lands here: route it to pause/resume
        // as well, otherwise a paused meeting could never resume by hotkey.
        // A hold inverts the state while held (mute while held when
        // recording, talk while held when paused) and restores it on release.
        guard meetingSession == nil else {
            toggleMeetingPause()
            return
        }
        guard isDictating else { return }
        isDictating = false

        Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.engine.stop()
                self.finish(transcript: transcript)
            } catch {
                self.log.error("engine stop failed: \(error.localizedDescription, privacy: .public)")
                self.cancelStreams()
                self.notch.showNotice(NotchNotice(message: "Transcription failed", actionTitle: nil))
            }
            self.cancelStreams()
        }
    }

    /// Paste, record, then show done. Shared by the microphone path and the
    /// hidden `--transcribe-file` path. A note or a meeting recording never
    /// reaches the paste step at all: it is saved (or appended) and the
    /// notch just shows done.
    private func finish(transcript: String) {
        // A press that caught no speech: nothing to paste, nothing to record.
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.info("empty transcript, nothing inserted")
            engine.reset()
            target = nil
            noteTargetID = nil
            notch.showNotice(NotchNotice(message: "Nothing heard", actionTitle: nil), holdFor: 2)
            return
        }

        lastTranscript = transcript
        let result = engine.lastResult

        switch notch.model.recordingContext {
        case .note:
            let noteID: UUID
            if let noteTargetID {
                history.appendToNote(id: noteTargetID, text: transcript)
                noteID = noteTargetID
            } else {
                noteID = history.createNote(text: transcript)
            }
            noteTargetID = nil
            engine.reset()
            target = nil
            if settings.playSounds { sounds.play(.finish) }
            if !proposeReminderIfNeeded(noteID: noteID, text: transcript) {
                notch.finish()
            }
            return
        case .onboarding:
            // Never actually reached: `stop()` redirects to
            // `stopOnboardingTry()`/`finishOnboardingTry(transcript:)`
            // before this method is ever called. Exhaustive only.
            return
        case .dictation:
            break
        }
        let pasteStart = Date()
        let delivery = engine.insert(transcript)
        let pasteMs = Int(Date().timeIntervalSince(pasteStart) * 1000)
        log.info("delivery: \(String(describing: delivery), privacy: .public), paste \(pasteMs, privacy: .public) ms")
        if let result {
            log.info(
                """
                stages: asr \(Int(result.asrMs), privacy: .public) ms, \
                spotter \(Int(result.spotterMs), privacy: .public) ms, \
                rescore \(Int(result.rescoreMs), privacy: .public) ms, \
                rules \(Int(result.rulesMs), privacy: .public) ms, \
                boost setup \(Int(result.boostingSetupMs), privacy: .public) ms, \
                paste \(pasteMs, privacy: .public) ms
                """)
        }

        record(transcript: transcript, result: result)
        engine.reset()

        switch delivery {
        case .inserted:
            if settings.playSounds { sounds.play(.finish) }
            notch.finish()
        case .copiedOnly:
            // Text is on the clipboard, but the Cmd-V could not be simulated.
            notch.showNotice(
                NotchNotice(message: "Grant Accessibility in System Settings", actionTitle: "Open"),
                action: { PermissionPanes.open(.accessibility) })
        case .failed(let message):
            log.error("insert failed: \(message, privacy: .public)")
            notch.showNotice(NotchNotice(message: "Could not paste the text", actionTitle: nil))
        }
    }

    // MARK: - Onboarding "Try it" (step 6)

    /// A real dictation, same engine, but it never touches the paste path,
    /// history, or the notch's own `.recording` state - the panel stays on
    /// `.onboarding` the whole time and the step's own read-only field is
    /// what shows the result. Silently does nothing if the model is not
    /// ready or the microphone was somehow not granted yet (step 2 already
    /// gated on it, but the hotkey can still fire before that finishes).
    private func startOnboardingTry() {
        guard !isDictating, meetingSession == nil,
              engine.isModelReady, MicrophonePermission.isAuthorized() else { return }
        isDictating = true
        notch.model.recordingContext = .onboarding
        notch.model.onboardingTryListening = true
        engine.apply(settings: settings)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.start()
            } catch {
                self.log.error("onboarding try start failed: \(error.localizedDescription, privacy: .public)")
                self.isDictating = false
                self.notch.model.onboardingTryListening = false
                return
            }
        }
        // Same level subscription `start()` sets up for the normal recording
        // row - step 6's WaveformBarsView reads `NotchModel.level`, which
        // only ever moves if something is feeding it.
        levelTask = Task { [weak self] in
            guard let self else { return }
            for await level in self.engine.levels {
                if Task.isCancelled { break }
                self.notch.model.apply(level: level)
            }
        }
    }

    private func stopOnboardingTry() {
        guard isDictating else { return }
        isDictating = false
        levelTask?.cancel()
        levelTask = nil
        notch.model.level = 0
        Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.engine.stop()
                self.finishOnboardingTry(transcript: transcript)
            } catch {
                self.log.error("onboarding try stop failed: \(error.localizedDescription, privacy: .public)")
            }
            self.notch.model.onboardingTryListening = false
        }
    }

    /// Underlines words that came from a pack or My words - the same
    /// approximation the Teach popover's own corrections use
    /// (`CorrectionLayoutManager`), matched against the live dictionary
    /// rather than a per-word "was this boosted" flag from the engine, which
    /// does not exist yet.
    private func finishOnboardingTry(transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.reset()
        guard !trimmed.isEmpty else { return }
        notch.model.onboardingTryText = transcript
        let dictionaryWords = Set(dictionaryTerms().map { $0.text.lowercased() })
        let spoken = transcript.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        notch.model.onboardingTryHighlights = spoken
            .map(String.init)
            .filter { dictionaryWords.contains($0.lowercased()) }
        notch.model.onboardingTryState = .granted
    }

    // MARK: - Reminders (entry point A: by voice)

    /// A note that was just created or appended to gets checked for a time
    /// phrase (`ReminderParser`). A clean match shows a two-pill proposal
    /// ("Note saved. Remind you Thu 7:00 PM?" - Set reminder / No); an
    /// ambiguous bare hour asks which reading instead. Never overwrites a
    /// note that already has a pending reminder. Returns true when a
    /// reminder notice took the place of the normal "done" checkmark, so the
    /// caller skips `notch.finish()`.
    @discardableResult
    private func proposeReminderIfNeeded(noteID: UUID, text: String) -> Bool {
        guard history.entry(id: noteID)?.reminderState != .pending else { return false }
        switch ReminderParser.parse(text) {
        case .date(let date):
            notch.showReminderNotice(
                message: "Note saved. Remind you \(Self.dayTimeStamp(date))?",
                primaryTitle: "Set reminder", secondaryTitle: "No", holdFor: 6,
                primaryAction: { [weak self] in self?.confirmReminder(noteID: noteID, at: date) },
                secondaryAction: {})
            return true
        case .ambiguous(let first, let second):
            // The notice renders its secondary (muted) pill before its
            // primary (white) one, so `second`/`first` are swapped here: the
            // two pills then read left to right in the same order the
            // message names them ("...7:00 AM or 7:00 PM?").
            notch.showReminderNotice(
                message: "Remind you at \(Self.clockStamp(first)) or \(Self.clockStamp(second))?",
                primaryTitle: Self.clockStamp(second), secondaryTitle: Self.clockStamp(first), holdFor: 6,
                primaryAction: { [weak self] in self?.confirmReminder(noteID: noteID, at: second) },
                secondaryAction: { [weak self] in self?.confirmReminder(noteID: noteID, at: first) })
            return true
        case .none:
            return false
        }
    }

    private func confirmReminder(noteID: UUID, at date: Date) {
        reminders.setReminder(id: noteID, at: date)
        notch.showNotice(NotchNotice(message: "Reminder set for \(Self.dayTimeStamp(date))", actionTitle: nil), holdFor: 2.5)
    }

    /// "Thu 7:00 PM" - the day name only matters once the date is not today,
    /// but including it always keeps the notice unambiguous either way.
    static func dayTimeStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE h:mm a")
        return formatter.string(from: date)
    }

    /// "7:00 PM" alone, for the ambiguous ask's two pills and the message
    /// that names both readings.
    static func clockStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("h:mm a")
        return formatter.string(from: date)
    }

    private func record(transcript: String, result: DictationResult?) {
        let entry = DictationHistoryEntry(
            finalText: transcript,
            rawText: result?.rawText ?? transcript,
            bundleID: target?.bundleID,
            appName: target?.name,
            duration: result?.duration ?? 0)
        history.add(entry)
        target = nil
    }

    private func cancelStreams() {
        removeEscapeMonitor()
        levelTask?.cancel()
        levelTask = nil
        notch.model.level = 0
    }

    /// Follows the engine's own state so the notch shows transcribing as a
    /// distinct step instead of a frozen recording row.
    private func observeState() {
        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.engine.states {
                switch state {
                case .recording:
                    self.notch.model.liveText = "Listening..."
                case .transcribing:
                    self.notch.model.liveText = "Transcribing..."
                    self.notch.model.level = 0
                case .done, .idle:
                    break
                case .failed(let message):
                    self.log.error("engine state failed: \(message, privacy: .public)")
                }
            }
        }
    }

    // MARK: - File path (hidden launch argument)

    /// Runs the whole post-capture pipeline on a WAV and pastes the result,
    /// so the end-to-end path can be checked without a human at the mic.
    func transcribeFile(at url: URL) async {
        guard !isDictating else { return }
        await engine.loadModel()
        notch.model.modelReady = engine.isModelReady
        guard engine.isModelReady else {
            notch.showNotice(NotchNotice(message: "Speech model not available", actionTitle: nil))
            return
        }
        target = Self.frontmostTarget()
        engine.apply(settings: settings)
        notch.transition(to: .recording)
        do {
            let transcript = try await engine.transcribeFile(at: url)
            log.info("file transcript: \(transcript, privacy: .public)")
            finish(transcript: transcript)
            // This path is the unattended check, so the stage timings go to
            // stderr as well as the log.
            if let result = engine.lastResult {
                let line = """
                    stages: asr \(Int(result.asrMs)) ms, spotter \(Int(result.spotterMs)) ms, \
                    rescore \(Int(result.rescoreMs)) ms, rules \(Int(result.rulesMs)) ms, \
                    boost setup \(Int(result.boostingSetupMs)) ms, total transcribe \
                    \(Int(result.transcriptionMs)) ms
                    """
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        } catch {
            log.error("file transcription failed: \(error.localizedDescription, privacy: .public)")
            notch.showNotice(NotchNotice(message: "Transcription failed", actionTitle: nil))
        }
    }

    private static func frontmostTarget() -> (bundleID: String?, name: String?, isSelf: Bool) {
        let app = NSWorkspace.shared.frontmostApplication
        let mine = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if mine { return (nil, nil, true) }
        guard let app else { return (nil, nil, false) }
        // Normalized at capture time: a system process or an empty name never
        // makes it into history.json as anything but "Unknown app".
        let identity = AppIdentity.normalize(bundleID: app.bundleIdentifier, name: app.localizedName)
        return (identity.bundleID, identity.name, false)
    }

    /// Pastes arbitrary text into whatever app is currently frontmost, via the
    /// same engine insert path a dictation uses. Used by the history detail
    /// panel's "Insert again" button. Zumbo never activates and the panel is
    /// a nonactivating one, so the app that was frontmost when the panel
    /// opened stays frontmost and is still the paste target.
    func insertIntoFrontmost(_ text: String) -> TextDeliveryResult {
        engine.insert(text)
    }

    /// Settings > Models' "Speaker labels" toggle turning on - the only
    /// place a download ever starts.
    func startSpeakerModelDownload() {
        engine.startSpeakerModelDownloadIfNeeded()
    }

    /// Settings > Models' "Cancel" button while downloading.
    func cancelSpeakerModelDownload() {
        engine.cancelSpeakerModelDownload()
    }

    /// Settings > Models' "Remove" button, after its confirm step.
    func removeSpeakerModel() {
        do {
            try engine.removeSpeakerModel()
        } catch {
            log.error("speaker labels add-on remove failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Dictionary

    /// The user's own taught words, for the Dictionary settings screen.
    func dictionaryTerms() -> [DictionaryTerm] {
        engine.userDictionaryTerms
    }

    func addDictionaryTerm(_ term: DictionaryTerm) throws {
        try engine.addDictionaryTerm(term)
    }

    func removeDictionaryTerm(text: String) throws {
        try engine.removeDictionaryTerm(text: text)
    }
}

/// The System Settings panes Zumbo needs to be able to send the user to.
enum PermissionPanes {
    case accessibility
    case inputMonitoring
    case microphone
    case notifications

    private var urlString: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .notifications:
            return "x-apple.systempreferences:com.apple.preference.notifications"
        }
    }

    static func open(_ pane: PermissionPanes) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
