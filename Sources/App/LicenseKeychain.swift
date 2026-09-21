import Foundation
import Security
import VesperEngine

/// Thin wrapper over the Keychain (service "com.claudiusararu.zumbo") for
/// the two things licensing must survive a reinstall: the trial start date
/// (account "trial") and the cached signed license token (account
/// "license"). `UserDefaults` lives in a plist any process running as the
/// user can read and edit; the Keychain at least requires going through
/// Security.framework, which is the point of moving the trial date here at
/// all (NOTES.md "Trial and licensing": "3-day trial from first launch,
/// start date in Keychain").
enum LicenseKeychain {
    private static let service = "com.claudiusararu.zumbo"
    private static let trialAccount = "trial"
    private static let licenseAccount = "license"

    // MARK: - Generic read/write/delete

    private static func readData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private static func writeData(_ data: Data, account: String) -> Bool {
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = matchQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return updateStatus == errSecSuccess
    }

    @discardableResult
    private static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Trial start date

    static func readTrialStart() -> Date? {
        guard let data = readData(account: trialAccount),
              let interval = try? JSONDecoder().decode(Double.self, from: data) else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    /// Writes the trial start once. Called by `LicenseState` the first time
    /// it sees a start date - whether that came from onboarding just now or
    /// from migrating an older `AppSettings.trialStartedAt`.
    static func writeTrialStart(_ date: Date) {
        guard let data = try? JSONEncoder().encode(date.timeIntervalSince1970) else { return }
        writeData(data, account: trialAccount)
    }

    // MARK: - License token

    static func readToken() -> SignedLicenseToken? {
        guard let data = readData(account: licenseAccount) else { return nil }
        return try? JSONDecoder().decode(SignedLicenseToken.self, from: data)
    }

    static func writeToken(_ token: SignedLicenseToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        writeData(data, account: licenseAccount)
    }

    static func deleteToken() {
        delete(account: licenseAccount)
    }
}
