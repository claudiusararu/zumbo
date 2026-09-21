import Foundation

/// Where the app talks to for licensing. The Cloudflare Worker and the Dodo
/// Payments checkout do not exist yet (NOTES.md "Licensing backend"), but the
/// domain is decided: zumbo.app on Cloudflare. See docs/LICENSING.md for the
/// wire format the Worker must implement against these three paths.
struct LicenseEndpoints {
    var baseURL: URL
    var checkoutURL: URL

    static let production = LicenseEndpoints(
        baseURL: URL(string: "https://api.zumbo.app")!,
        checkoutURL: URL(string: "https://zumbo.app/buy")!
    )

    var activateURL: URL { baseURL.appendingPathComponent("activate") }
    var validateURL: URL { baseURL.appendingPathComponent("validate") }
    var deactivateURL: URL { baseURL.appendingPathComponent("deactivate") }
}
