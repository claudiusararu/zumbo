import CryptoKit
import Foundation

// Pure licensing logic (trial-window math, token verification, grace-period
// and key-formatting rules) with no Keychain/UserDefaults/network access, so
// `swift test` covers it with no app target and no device. See
// docs/LICENSING.md for the wire format this mirrors and NOTES.md "Trial and
// licensing" / "Licensing backend" for the product decisions behind it.

// MARK: - Trial window

/// 3 calendar days from the start day, ending 23:59:59 local time on the
/// third day: start Sep 20 -> ends end of Sep 22.
public enum TrialWindow {
    public static let lengthInDays = 3

    /// The instant the trial ends: 23:59:59 local time on the
    /// `lengthInDays`th calendar day counted from `start`'s calendar day.
    public static func endDate(start: Date, calendar: Calendar = .current) -> Date {
        let startDay = calendar.startOfDay(for: start)
        let lastDay = calendar.date(byAdding: .day, value: lengthInDays - 1, to: startDay) ?? startDay
        var components = calendar.dateComponents([.year, .month, .day], from: lastDay)
        components.hour = 23
        components.minute = 59
        components.second = 59
        return calendar.date(from: components) ?? lastDay
    }

    /// Whole calendar days between today and the end day (not counting
    /// today), used for "N days left" copy. Start Sep 20, asked on Sep 20 ->
    /// 2 (matches "Trial, 2 days left, ends Sep 22"); asked on Sep 22 -> 0
    /// ("Trial ends today").
    public static func daysLeft(now: Date, start: Date, calendar: Calendar = .current) -> Int {
        let end = endDate(start: start, calendar: calendar)
        guard now <= end else { return 0 }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfEndDay = calendar.startOfDay(for: end)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfEndDay).day ?? 0
        return max(0, days)
    }

    public static func hasEnded(now: Date, start: Date, calendar: Calendar = .current) -> Bool {
        now > endDate(start: start, calendar: calendar)
    }

    /// True on the day before the end and on the last day itself - the two
    /// days the "Trial ends tomorrow" / "Trial ends today" notice fires,
    /// once per day, at the first dictation.
    public static func isInFinalStretch(now: Date, start: Date, calendar: Calendar = .current) -> Bool {
        guard !hasEnded(now: now, start: start, calendar: calendar) else { return false }
        return daysLeft(now: now, start: start, calendar: calendar) <= 1
    }
}

// MARK: - License token

/// One license tier: a single-Mac activation, a three-Mac one, or a
/// ten-Mac team one. Matches the Worker's `tier` field exactly (see
/// docs/LICENSING.md).
public enum LicenseTier: String, Codable, Equatable, Sendable {
    case single
    case three
    case team

    /// The machine-activation limit for this tier - `single` gets 1,
    /// `three` gets 3, `team` gets 10.
    public var maxMachines: Int {
        switch self {
        case .single: return 1
        case .three: return 3
        case .team: return 10
        }
    }
}

/// What the Worker signs and the app verifies. Dates are encoded as seconds
/// since 1970 so canonical JSON is stable across platforms and locales.
public struct LicenseTokenPayload: Codable, Equatable, Sendable {
    public var key: String
    public var machineId: String
    public var tier: LicenseTier
    public var issuedAt: Date
    public var expiresAt: Date

    public init(key: String, machineId: String, tier: LicenseTier, issuedAt: Date, expiresAt: Date) {
        self.key = key
        self.machineId = machineId
        self.tier = tier
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

/// The payload plus an Ed25519 signature over its canonical JSON encoding,
/// base64-encoded. This whole struct is what `/activate` and `/validate`
/// return as `token` and what gets cached in the Keychain.
public struct SignedLicenseToken: Codable, Equatable, Sendable {
    public var payload: LicenseTokenPayload
    public var signature: String

    public init(payload: LicenseTokenPayload, signature: String) {
        self.payload = payload
        self.signature = signature
    }
}

public enum LicenseTokenVerifier {

    /// Sorted keys + fixed date strategy: the same payload always encodes to
    /// the same bytes, on the Worker (any language) and here, so the
    /// signature checks out.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    public static func canonicalData(for payload: LicenseTokenPayload) throws -> Data {
        try encoder.encode(payload)
    }

    /// `true` only if the signature matches the payload bytes exactly under
    /// `publicKey` - a proxied "valid: true" with a mismatched or missing
    /// signature always fails here, offline or online.
    public static func verify(_ token: SignedLicenseToken, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        guard let signatureData = Data(base64Encoded: token.signature) else { return false }
        guard let payloadData = try? canonicalData(for: token.payload) else { return false }
        return publicKey.isValidSignature(signatureData, for: payloadData)
    }

    /// Test-only signer (used by `MockLicenseClient` and
    /// scripts/sign-test-token.swift) - production tokens are signed by the
    /// Worker, which holds the matching private key, never this app.
    public static func sign(_ payload: LicenseTokenPayload, privateKey: Curve25519.Signing.PrivateKey) throws -> SignedLicenseToken {
        let data = try canonicalData(for: payload)
        let signature = try privateKey.signature(for: data)
        return SignedLicenseToken(payload: payload, signature: signature.base64EncodedString())
    }
}

// MARK: - Grace period

/// A verified token keeps working offline for 30 days past its own
/// `expiresAt`, so a re-validation outage never locks someone out
/// mid-trip. The weekly background re-validate is what normally refreshes
/// `expiresAt` long before the grace window matters.
public enum LicenseGrace {
    public static let days = 30

    public static func graceEnd(for payload: LicenseTokenPayload, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: payload.expiresAt) ?? payload.expiresAt
    }

    public static func isWithinGrace(_ payload: LicenseTokenPayload, now: Date, calendar: Calendar = .current) -> Bool {
        now <= graceEnd(for: payload, calendar: calendar)
    }
}

// MARK: - Key formatting

/// The one place the manual-key prefix lives - change this and the manual
/// format regex, the mock key, and `LicenseClient.acceptedKey` all follow.
public enum LicenseKeyFormat {
    public static let prefix = "ZUMB"
}

/// Two key shapes are valid:
///
/// 1. A Dodo-issued license key: a bare UUID, 32 hex digits grouped
///    8-4-4-4-12 (`db44b22c-fe9b-4a68-bf0d-b0e0d6c6c8c0`), case-insensitive.
///    Dodo generates these; the format is not configurable. Normalized to
///    lowercase.
/// 2. Our own manually issued key: `ZUMB-XXXX-XXXX-XXXX-XXXX`, four groups
///    of four alphanumerics after the prefix, case-insensitive. Normalized
///    to uppercase.
///
/// Typed/pasted text is never rewritten as you go - no forced uppercasing,
/// no hyphen insertion - so pasting a lowercase Dodo UUID keeps it exactly
/// as copied. Only `normalized(_:)`, called once on submit, rewrites case.
public enum LicenseKeyFormatter {
    public static let placeholder = "Paste your license key"

    private static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        options: [.caseInsensitive]
    )
    private static let manualRegex = try! NSRegularExpression(
        pattern: "^\(LicenseKeyFormat.prefix)-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$",
        options: [.caseInsensitive]
    )

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }

    /// True when `trimmed` is a Dodo UUID key (format 1 above). Expects
    /// already-trimmed input.
    public static func isUUIDFormat(_ trimmed: String) -> Bool {
        matches(uuidRegex, trimmed)
    }

    /// True when `trimmed` is our manual `ZUMB-...` key (format 2 above).
    /// Expects already-trimmed input.
    public static func isManualFormat(_ trimmed: String) -> Bool {
        matches(manualRegex, trimmed)
    }

    /// True when `raw`, trimmed, is valid in either format - drives the
    /// Activate button's enabled state. Never mutates or reformats `raw`.
    public static func isActivatable(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return isUUIDFormat(trimmed) || isManualFormat(trimmed)
    }

    /// Normalizes a key to its canonical stored/compared form: trimmed,
    /// UUID keys lowercase, `ZUMB-` keys uppercase - matching how the
    /// Worker normalizes keys server-side (src/license-key.ts there).
    /// Call this once, on submit; never on every keystroke. If `raw`
    /// matches neither format it is returned merely trimmed - callers
    /// should gate on `isActivatable` first.
    public static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUUIDFormat(trimmed) { return trimmed.lowercased() }
        if isManualFormat(trimmed) { return trimmed.uppercased() }
        return trimmed
    }
}
