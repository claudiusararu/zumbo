import AppKit
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` so `AppSettings` does not have to
/// import `ServiceManagement` or know its status enum.
///
/// Zumbo is not sandboxed and is not distributed through the Mac App Store
/// (Developer ID, direct download), so `mainApp` registration works from
/// `/Applications` with no helper target and no extra entitlement. Run from
/// somewhere else (e.g. a debug build in DerivedData), macOS may register it
/// as `.requiresApproval` instead of `.enabled` until the user flips it on
/// in System Settings, which `requiresApproval` and `openLoginItemsSettings`
/// exist to surface.
enum LaunchAtLogin {
    /// True when the login item is registered - `.enabled` outright, or
    /// `.requiresApproval` (registered, just not yet flipped on in System
    /// Settings), so a just-completed `set(true)` doesn't read back as off.
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Registers or unregisters the login item. Returns whether the call
    /// itself succeeded; check `requiresApproval` afterward for the
    /// "registered but not approved yet" case, which is not a failure.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    /// Opens System Settings straight to General > Login Items.
    static func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
