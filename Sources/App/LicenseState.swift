import AppKit
import Combine
import CryptoKit
import Foundation
import VesperEngine
import os

/// What Settings > License, the menu bar's top line and the notch's locked
/// state all read. Computed from the Keychain trial date plus the cached
/// signed token - see docs/LICENSING.md for the token format this verifies
/// and NOTES.md "Trial and licensing" for the product rules.
enum LicenseStatus: Equatable {
    /// Trial running; `endsAt` is 23:59:59 local time on the third day.
    case trial(endsAt: Date)
    case trialEnded
    case licensed(tier: LicenseTier, machines: Int)
    /// Onboarding step 7 was never reached - no trial date, no license.
    case unlicensed

    var isLicensed: Bool {
        if case .licensed = self { return true }
        return false
    }

    /// The hard gate (NOTES.md: "hard gate, no free tier") applies only
    /// here: trial ran out and nothing has activated since.
    var isLocked: Bool {
        self == .trialEnded
    }
}

/// The single source of truth for whether Zumbo may record. Computed at
/// launch, at midnight, and whenever the app becomes active (so a trial that
/// quietly ended overnight is caught the moment someone comes back). Reads
/// the Keychain, never `AppSettings.trialStartedAt` directly, except once to
/// migrate an existing value that predates this file.
@MainActor
final class LicenseState: ObservableObject {

    @Published private(set) var status: LicenseStatus = .unlicensed
    /// True while `activate(rawKey:)` is awaiting the network call, so the
    /// Settings card can show a spinner on the Activate pill instead of a
    /// second click doing nothing visibly.
    @Published var isActivating = false
    /// Plain-word text under the key field; cleared by the view on every edit.
    @Published var activationError: String?

    /// Fired once, the moment a background re-validate finds the license
    /// revoked or the Worker returns 401 - the notch shows "Your license was
    /// deactivated" from this, not from polling `status`.
    var onLicenseDeactivated: (() -> Void)?

    let machineName = MachineID.displayName
    let endpoints: LicenseEndpoints

    private let client: LicenseClient
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "license")
    private weak var settings: AppSettings?
    private var trialStart: Date?
    private var cancellables = Set<AnyCancellable>()
    private var midnightTask: Task<Void, Never>?
    private var weeklyValidateTask: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?
    private var deactivatedNoticeShown = false

    private static let finalStretchNoticeKey = "com.vesper.license.finalStretchNoticeShownOn"

    /// Overrides the computed status for the owner to see every state on
    /// demand, in Release too (NOTES.md-style debug hooks are launch
    /// arguments, never a hidden UI): `--trial-state ended`, `--trial-state
    /// lastday`, `--trial-state day2`. Harmless in front of real users, who
    /// never pass launch arguments.
    private static func override() -> LicenseStatus? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--trial-state"), index + 1 < arguments.count else { return nil }
        let now = Date()
        switch arguments[index + 1] {
        case "ended": return .trialEnded
        case "lastday": return .trial(endsAt: now.addingTimeInterval(3600))
        case "day2": return .trial(endsAt: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now)
        default: return nil
        }
    }

    init(settings: AppSettings, endpoints: LicenseEndpoints = .production, client: LicenseClient? = nil) {
        self.settings = settings
        self.endpoints = endpoints
        self.client = client ?? LicenseClientFactory.make(endpoints: endpoints)

        migrateLegacyTrialStartIfNeeded()
        settings.$trialStartedAt
            .sink { [weak self] date in
                guard let self, let date, LicenseKeychain.readTrialStart() == nil else { return }
                LicenseKeychain.writeTrialStart(date)
                self.refresh()
            }
            .store(in: &cancellables)

        refresh()
        scheduleMidnightRefresh()
        scheduleWeeklyValidate()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // No deinit: `LicenseState` is a singleton owned by `AppDelegate` for the
    // app's whole lifetime (same as `NotchController`, `ReminderScheduler`),
    // so there is never a live instance to tear down - and Swift 6 strict
    // concurrency refuses to touch a `@MainActor` non-Sendable stored
    // property (`activeObserver`) from a nonisolated deinit anyway.

    // MARK: - Status

    func refresh() {
        if let override = Self.override() {
            status = override
            return
        }
        let now = Date()

        if let token = LicenseKeychain.readToken() {
            if verify(token, now: now) {
                status = .licensed(tier: token.payload.tier, machines: token.payload.tier.maxMachines)
                return
            }
            // A cached token that no longer verifies (bad signature, or past
            // its 30-day grace) is worse than none: drop it so the trial
            // math below runs instead of failing the same check forever.
            LicenseKeychain.deleteToken()
        }

        guard let start = LicenseKeychain.readTrialStart() else {
            trialStart = nil
            status = .unlicensed
            return
        }
        trialStart = start
        status = TrialWindow.hasEnded(now: now, start: start) ? .trialEnded : .trial(endsAt: TrialWindow.endDate(start: start))
    }

    private func verify(_ token: SignedLicenseToken, now: Date) -> Bool {
        guard let publicKey = LicenseState.publicKey() else { return false }
        guard LicenseTokenVerifier.verify(token, publicKey: publicKey) else { return false }
        return LicenseGrace.isWithinGrace(token.payload, now: now)
    }

    /// The mock keypair is trusted only in Debug builds with
    /// `ZUMBO_LICENSE_MOCK=1` / `--license-mock` (`LicenseMockMode`), so a
    /// token signed by `MockLicenseClient` can never verify in a Release
    /// build: there `LicenseMockMode.isEnabled` is a compile-time false.
    private static func publicKey() -> Curve25519.Signing.PublicKey? {
        #if DEBUG
        let base64 = LicenseMockMode.isEnabled ? LicensePublicKey.mockPublicKeyBase64 : LicensePublicKey.productionBase64
        #else
        let base64 = LicensePublicKey.productionBase64
        #endif
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    private func migrateLegacyTrialStartIfNeeded() {
        guard LicenseKeychain.readTrialStart() == nil, let legacy = settings?.trialStartedAt else { return }
        LicenseKeychain.writeTrialStart(legacy)
        log.info("migrated trial start date from UserDefaults to Keychain")
    }

    // MARK: - Activation

    func activate(rawKey: String) async {
        guard LicenseKeyFormatter.isActivatable(rawKey) else { return }
        let key = LicenseKeyFormatter.normalized(rawKey)
        isActivating = true
        activationError = nil
        defer { isActivating = false }
        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            let token = try await client.activate(key: key, machineId: MachineID.current, machineName: machineName, appVersion: version)
            LicenseKeychain.writeToken(token)
            refresh()
        } catch let error as LicenseClientError {
            activationError = error.message
        } catch {
            activationError = LicenseClientError.network.message
        }
    }

    func deactivate() async {
        guard let token = LicenseKeychain.readToken() else { return }
        try? await client.deactivate(key: token.payload.key, machineId: MachineID.current)
        LicenseKeychain.deleteToken()
        refresh()
    }

    // MARK: - Background revalidation

    private func scheduleWeeklyValidate() {
        weeklyValidateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7 * 24 * 60 * 60))
                guard !Task.isCancelled else { return }
                await self?.validateInBackground()
            }
        }
    }

    private func validateInBackground() async {
        guard let token = LicenseKeychain.readToken() else { return }
        do {
            let refreshed = try await client.validate(token: token)
            LicenseKeychain.writeToken(refreshed)
            deactivatedNoticeShown = false
            refresh()
        } catch LicenseClientError.deactivated {
            LicenseKeychain.deleteToken()
            refresh()
            if !deactivatedNoticeShown {
                deactivatedNoticeShown = true
                onLicenseDeactivated?()
            }
        } catch {
            // Offline, or the Worker is down: the cached token's own grace
            // window (`LicenseGrace`) is what keeps things working, and it
            // does so silently - no notice for a routine network miss.
            log.info("weekly license re-validate failed, relying on grace window")
        }
    }

    private func scheduleMidnightRefresh() {
        midnightTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                let calendar = Calendar.current
                let next = calendar.nextDate(
                    after: now, matching: DateComponents(hour: 0, minute: 0, second: 1),
                    matchingPolicy: .nextTimePreservingSmallerComponents
                ) ?? now.addingTimeInterval(86400)
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(now))))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.refresh() }
            }
        }
    }

    // MARK: - Trial-ending notice

    /// Called from the dictation start path, not by a timer: the notice is
    /// "once per day at the first dictation" (NOTES.md), so it only ever
    /// fires from an actual attempt to dictate.
    func finalStretchNoticeIfDue(now: Date = Date()) -> String? {
        // Days left come from the status itself, so the `--trial-state`
        // override drives the notice the same way it drives everything else.
        guard case .trial(let endsAt) = status else { return nil }
        let calendar = Calendar.current
        let daysLeft = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: endsAt)).day ?? 0
        guard daysLeft <= 1 else { return nil }
        if Self.override() == nil {
            let todayKey = calendar.startOfDay(for: now).timeIntervalSince1970
            let defaults = UserDefaults.standard
            guard defaults.double(forKey: Self.finalStretchNoticeKey) != todayKey else { return nil }
            defaults.set(todayKey, forKey: Self.finalStretchNoticeKey)
        }
        return daysLeft == 0 ? "Trial ends today" : "Trial ends tomorrow"
    }

    // MARK: - Display text

    /// One line for the menu bar (disabled, top of the menu) and the
    /// Settings > License status row's label, sharing exactly the same
    /// wording per NOTES.md and the spec: "Trial, 2 days left, ends Sep 22" /
    /// "Trial ended Sep 22" / "Licensed, single Mac" / "Licensed, up to 3
    /// Macs" / "Licensed, team, up to 10 Macs".
    var statusLine: String {
        switch status {
        case .trial(let endsAt):
            let days = trialStart.map { TrialWindow.daysLeft(now: Date(), start: $0) } ?? 0
            let label = days == 1 ? "1 day left" : "\(days) days left"
            return "Trial, \(label), ends \(Self.dateFormatter.string(from: endsAt))"
        case .trialEnded:
            let endsAt = trialStart.map { TrialWindow.endDate(start: $0) } ?? Date()
            return "Trial ended \(Self.dateFormatter.string(from: endsAt))"
        case .licensed(let tier, let machines):
            switch tier {
            case .single:
                return "Licensed, single Mac"
            case .three:
                return "Licensed, up to \(machines) Macs"
            case .team:
                return "Licensed, team, up to \(machines) Macs"
            }
        case .unlicensed:
            return "Not licensed"
        }
    }

    /// Green for trial-running and licensed, red once the trial has ended.
    var statusIsHealthy: Bool { !status.isLocked }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}
