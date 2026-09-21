import AppKit
import Combine
import Foundation
import Sparkle
import os

/// Sparkle 2, wired to the notch instead of Sparkle's own windows.
///
/// Zumbo is an LSUIElement app: it has no Dock icon, no main window and its
/// only panel is a nonactivating `NSPanel` that must never take focus. Every
/// stock Sparkle window (the "update available" sheet, the release notes
/// browser, the progress window) would need an activating window and would
/// yank focus out of whatever the user was typing in. So this class is the
/// whole user interface: it implements `SPUUserDriver` and turns each step of
/// an update into the notch's existing one-line notice.
///
/// The flow the owner sees:
///   "Zumbo 1.0.2 is available"   [Update] [Later] [x]
///   "Downloading, 4 MB of 10 MB" with a thin progress line
///   "Installing..."               then Sparkle relaunches the app
///
/// Release notes are deliberately never shown: the marketing site carries
/// them, and a browser window here would be the exact focus-stealing thing
/// the notch exists to avoid. Those two delegate methods are no-ops.
///
/// "Later" writes a timestamp 24 hours out (`AppSettings.updateSnoozeUntil`);
/// background checks inside that window answer `.dismiss` without ever
/// drawing a notice. A manual check from Settings > About ignores the snooze,
/// because the owner asked for it explicitly.
@MainActor
final class UpdateController: NSObject, SPUUserDriver {

    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "updates")
    private unowned let notch: NotchController
    private let settings: AppSettings
    private var updater: SPUUpdater?
    private var cancellables = Set<AnyCancellable>()

    /// True from the moment Settings > About's "Check" pill is pressed until
    /// that session ends. A background check that finds nothing stays silent;
    /// a manual one answers "You are up to date".
    private var userInitiated = false
    /// Set once the download starts, so an error can say "Could not download
    /// the update" instead of "Could not check for updates".
    private var downloading = false

    /// The `showUpdateFoundWithAppcastItem` answer, held while the notice is
    /// on screen. Resolved exactly once: by "Update", by "Later", or by the
    /// notice leaving the screen any other way (the "x", Escape, the hold
    /// expiring). Leaving it unresolved would wedge Sparkle's session.
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?

    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    /// Progress is redrawn at most ~6 times a second: every byte chunk would
    /// re-measure and resize the panel window, which is visible jitter.
    private var lastProgressDraw = Date.distantPast

    /// How long a "Later" silences the updater.
    private static let snoozeInterval: TimeInterval = 24 * 60 * 60
    /// Effectively "until something resolves it": the update notice is not a
    /// transient toast, it waits for an answer. Every path out of it resolves
    /// `pendingChoice`, so nothing leaks if this does fire.
    private static let noticeHold: Double = 3600

    init(notch: NotchController, settings: AppSettings) {
        self.notch = notch
        self.settings = settings
        super.init()
    }

    /// Builds the updater and arms the scheduled check. `SUEnableAutomaticChecks`
    /// and `SUScheduledCheckInterval` (86400) come from the Info.plist, so this
    /// does not have to set them in code; `startUpdater` is what actually puts
    /// the daily cycle on the run loop.
    func start() {
        let updater = SPUUpdater(
            hostBundle: Bundle.main, applicationBundle: Bundle.main, userDriver: self, delegate: nil)
        do {
            try updater.start()
            self.updater = updater
            log.info("updater started, feed \(updater.feedURL?.absoluteString ?? "none", privacy: .public)")
        } catch {
            // A broken updater must never take the app down: dictation still
            // works, the owner just does not get automatic updates.
            log.error("updater failed to start: \(error.localizedDescription, privacy: .public)")
        }

        // Any exit from the notice that is not one of the two pills - the "x",
        // Escape, a click elsewhere - still owes Sparkle an answer.
        notch.model.$state
            .sink { [weak self] state in
                guard let self, state != .notice, self.pendingChoice != nil else { return }
                self.resolve(.dismiss, snooze: true)
            }
            .store(in: &cancellables)
    }

    /// Settings > About's "Check" pill.
    func checkForUpdates() {
        guard let updater else {
            showNotice("Updates are not available in this build", actionTitle: nil)
            return
        }
        userInitiated = true
        updater.checkForUpdates()
    }

    // MARK: - Notice plumbing

    private func showNotice(
        _ message: String, actionTitle: String?, secondaryTitle: String? = nil,
        dismissible: Bool = false, progress: Double? = nil, hold: Double = 4.5,
        action: (() -> Void)? = nil, secondaryAction: (() -> Void)? = nil
    ) {
        notch.showNotice(
            NotchNotice(
                message: message, actionTitle: actionTitle, secondaryActionTitle: secondaryTitle,
                dismissible: dismissible, progress: progress),
            holdFor: hold, action: action, secondaryAction: secondaryAction)
    }

    private func resolve(_ choice: SPUUserUpdateChoice, snooze: Bool) {
        guard let reply = pendingChoice else { return }
        pendingChoice = nil
        if snooze { settings.updateSnoozeUntil = Date().addingTimeInterval(Self.snoozeInterval) }
        reply(choice)
    }

    private var snoozed: Bool {
        guard let until = settings.updateSnoozeUntil else { return false }
        return until > Date()
    }

    /// "4 MB" - whole megabytes, because a byte-exact count on a two-line
    /// notice is noise, not information.
    private static func megabytes(_ bytes: UInt64) -> String {
        "\(max(1, Int((Double(bytes) / 1_048_576).rounded()))) MB"
    }

    // MARK: - SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Never asked in practice (SUEnableAutomaticChecks is already true in
        // the Info.plist). If it ever is: checks yes, downloads no, and no
        // system profile is ever sent anywhere.
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true, automaticUpdateDownloading: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // A background check inside the snooze window never draws anything.
        guard userInitiated || !snoozed else {
            reply(.dismiss)
            return
        }
        pendingChoice = reply
        downloading = false
        let version = appcastItem.displayVersionString
        showNotice(
            "Zumbo \(version) is available", actionTitle: "Update", secondaryTitle: "Later",
            dismissible: true, hold: Self.noticeHold,
            action: { [weak self] in self?.resolve(.install, snooze: false) },
            secondaryAction: { [weak self] in self?.resolve(.dismiss, snooze: true) })
    }

    /// No release notes window, by design (see the type's doc comment). The
    /// download arriving is simply ignored so the session proceeds.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if userInitiated {
            let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            showNotice("You are up to date, \(short)", actionTitle: nil)
        }
        userInitiated = false
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.error("updater error: \(error.localizedDescription, privacy: .public)")
        let message = downloading
            ? "Could not download the update. Try again later."
            : "Could not check for updates. Try again later."
        // Plain words, no error codes: nothing here is actionable by the
        // owner beyond trying again.
        showNotice(message, actionTitle: nil, hold: 6)
        pendingChoice = nil
        downloading = false
        userInitiated = false
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloading = true
        expectedBytes = 0
        receivedBytes = 0
        lastProgressDraw = .distantPast
        showNotice("Downloading the update", actionTitle: nil, progress: 0, hold: Self.noticeHold)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        guard Date().timeIntervalSince(lastProgressDraw) > 0.16 else { return }
        lastProgressDraw = Date()
        guard expectedBytes > 0 else { return }
        let fraction = min(1, Double(receivedBytes) / Double(expectedBytes))
        notch.updateNoticeInPlace(NotchNotice(
            message: "Downloading, \(Self.megabytes(receivedBytes)) of \(Self.megabytes(expectedBytes))",
            actionTitle: nil, progress: fraction))
    }

    func showDownloadDidStartExtractingUpdate() {
        showNotice("Installing...", actionTitle: nil, progress: 0, hold: Self.noticeHold)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        guard Date().timeIntervalSince(lastProgressDraw) > 0.16 else { return }
        lastProgressDraw = Date()
        notch.updateNoticeInPlace(
            NotchNotice(message: "Installing...", actionTitle: nil, progress: progress))
    }

    /// The owner already said "Update"; there is no second confirmation step.
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        notch.updateNoticeInPlace(
            NotchNotice(message: "Installing...", actionTitle: nil, progress: nil))
        // Sparkle's Autoupdate helper quits and relaunches the app itself.
        // That works for an LSUIElement app with no Dock icon (the helper
        // launches the bundle, it does not rely on an app-switcher entry), so
        // there is nothing extra to do here and no extra entitlement needed.
        if !applicationTerminated { retryTerminatingApplication() }
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool, acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        pendingChoice = nil
        downloading = false
        userInitiated = false
        if notch.model.state == .notice, notch.model.notice?.progress != nil {
            notch.transition(to: .idle)
        }
    }
}
