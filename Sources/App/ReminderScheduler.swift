import Foundation
import UserNotifications
import VesperEngine
import os

/// Owns every reminder's two clocks: the system notification
/// (`UNUserNotificationCenter`, fires even while Zumbo is not running) and
/// an in-process timer that shows the matching notch notice at the same
/// moment, while the app is running. `HistoryStore` is the source of truth
/// for what is pending; this class only arms/disarms the timers and talks to
/// the notification center around it.
@MainActor
final class ReminderScheduler: NSObject {

    private let history: HistoryStore
    private let notch: NotchController
    private let settings: AppSettings
    private let sounds = Sounds()
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "reminders")

    /// One in-process timer per pending reminder id, so the notch shows its
    /// own notice the instant a reminder fires while the app is running.
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var permissionRequested = false

    init(history: HistoryStore, notch: NotchController, settings: AppSettings) {
        self.history = history
        self.notch = notch
        self.settings = settings
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Called once at launch, after `checkMissedReminders()`: arms a live
    /// timer for every reminder still pending.
    func start() {
        for entry in history.pendingReminders {
            arm(entry)
        }
        // Reflects a denial from a previous run immediately, without waiting
        // for the next `setReminder(id:at:)` to ask again.
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                guard status != .notDetermined else { return }
                self?.permissionRequested = true
                self?.authorizationStatus = status == .authorized ? .authorized : .denied
            }
        }
    }

    // MARK: - Missed reminders

    /// Checked once at launch, before `start()`: anything already past due
    /// fired while nothing was watching (the Mac was asleep, or the app was
    /// not running at all) - mark it missed and show the firing notice once
    /// more, so it is never silently lost.
    func checkMissedReminders() {
        for entry in history.overdueReminders {
            history.markReminderMissed(id: entry.id)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [entry.id.uuidString])
            showFiringNotice(for: entry, missed: true)
        }
    }

    // MARK: - Setting a reminder

    /// The proposal notice's "Set reminder" pill, the ambiguous notice's
    /// chosen time, or the hand picker's "Set". Requests notification
    /// permission the first time a reminder is ever set, not before.
    func setReminder(id: UUID, at date: Date) {
        requestPermissionIfNeeded()
        history.setReminder(id: id, at: date)
        guard let entry = history.entry(id: id) else { return }
        arm(entry)
        scheduleSystemNotification(for: entry)
    }

    /// The detail panel chip's "x", or the proposal notice's "No".
    func cancelReminder(id: UUID) {
        history.cancelReminder(id: id)
        disarm(id: id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    /// The firing notice's "Done", or acknowledging a missed one.
    func complete(id: UUID) {
        history.completeReminder(id: id)
        disarm(id: id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    /// The firing notice's "Snooze 10 min".
    func snooze(id: UUID, by seconds: TimeInterval = 600) {
        history.snoozeReminder(id: id, by: seconds)
        guard let entry = history.entry(id: id) else { return }
        arm(entry)
        scheduleSystemNotification(for: entry)
    }

    // MARK: - Permission

    /// Whether notification permission was ever granted - the reminder
    /// picker reads this to explain a denial, with a pill to the right pane.
    /// Nil while undecided (never asked yet).
    var authorizationStatus: UNAuthorizationStatus? {
        didSet { onAuthorizationChange?(authorizationStatus == .denied) }
    }
    /// Wired by `AppDelegate` to `NotchModel.notificationsDenied`.
    var onAuthorizationChange: ((Bool) -> Void)?

    private func requestPermissionIfNeeded() {
        guard !permissionRequested else { return }
        permissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.log.error("notification permission request failed: \(error.localizedDescription, privacy: .public)")
                }
                self?.authorizationStatus = granted ? .authorized : .denied
            }
        }
    }

    // MARK: - In-process timer

    private func arm(_ entry: DictationHistoryEntry) {
        disarm(id: entry.id)
        guard let at = entry.reminderAt else { return }
        let id = entry.id
        timers[id] = Task { [weak self] in
            let interval = at.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(for: .seconds(interval))
            }
            guard !Task.isCancelled, let self else { return }
            guard let live = self.history.entry(id: id), live.reminderState == .pending else { return }
            self.showFiringNotice(for: live, missed: false)
        }
    }

    private func disarm(id: UUID) {
        timers[id]?.cancel()
        timers[id] = nil
    }

    // MARK: - Notch notice

    private func showFiringNotice(for entry: DictationHistoryEntry, missed: Bool) {
        let body = String(ReminderParser.taskText(from: entry.finalText).prefix(60))
        // The bell already says "reminder"; only a missed one gets a prefix.
        let message = missed ? "Missed: \(body)" : body
        if settings.playSounds { sounds.play(.reminder) }
        notch.showReminderNotice(
            message: message, primaryTitle: "Done", secondaryTitle: "Snooze 10 min", holdFor: 30,
            primaryAction: { [weak self] in self?.complete(id: entry.id) },
            secondaryAction: { [weak self] in self?.snooze(id: entry.id) })
    }

    // MARK: - System notification

    private func scheduleSystemNotification(for entry: DictationHistoryEntry) {
        guard let at = entry.reminderAt else { return }
        let content = UNMutableNotificationContent()
        content.title = (entry.title?.isEmpty == false) ? entry.title! : "Reminder"
        content.body = String(ReminderParser.taskText(from: entry.finalText).prefix(120))
        content.sound = .default
        let interval = max(1, at.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.log.error("notification schedule failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

extension ReminderScheduler: UNUserNotificationCenterDelegate {
    /// Shows the system banner even while Zumbo is technically "frontmost"
    /// (never true in practice - LSUIElement, nonactivating panel - but
    /// harmless to declare either way).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
