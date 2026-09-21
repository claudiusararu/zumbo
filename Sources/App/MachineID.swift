import CryptoKit
import Foundation
import IOKit

/// A stable per-Mac identifier for activation limits, derived from
/// `IOPlatformUUID` (survives reinstalls and reboots, changes only if the
/// logic board is replaced) and SHA-256 hashed before it ever leaves the
/// Mac, so the Worker never sees the raw hardware UUID.
enum MachineID {
    static let current: String = {
        let uuid = platformUUID() ?? UUID().uuidString
        let digest = SHA256.hash(data: Data(uuid.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }()

    /// The name shown next to "Activated on this Mac" in Settings > License.
    static var displayName: String {
        Host.current().localizedName ?? "This Mac"
    }

    private static func platformUUID() -> String? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let property = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return property.takeRetainedValue() as? String
    }
}
