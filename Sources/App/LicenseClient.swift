import CryptoKit
import Foundation
import VesperEngine

/// Plain-word errors `LicenseSettingsView` shows under the key field. Never
/// a raw `URLError` or HTTP status on screen.
enum LicenseClientError: Error, Equatable {
    case notRecognized
    case machineLimitReached
    case network
    case deactivated

    var message: String {
        switch self {
        case .notRecognized: return "That key was not recognised."
        case .machineLimitReached: return "This key is already used on 3 Macs. Deactivate one first."
        case .network: return "Could not reach the license server. Check your connection."
        case .deactivated: return "Your license was deactivated."
        }
    }
}

/// What the app needs from the licensing backend. One real implementation
/// (`HTTPLicenseClient`, talking to the Worker in docs/LICENSING.md) and one
/// fixture (`MockLicenseClient`) so activation is testable with no Worker
/// deployed yet.
protocol LicenseClient: Sendable {
    func activate(key: String, machineId: String, machineName: String, appVersion: String) async throws -> SignedLicenseToken
    func validate(token: SignedLicenseToken) async throws -> SignedLicenseToken
    func deactivate(key: String, machineId: String) async throws
}

/// `ZUMBO_LICENSE_MOCK=1` or `--license-mock` picks the fixture client
/// everywhere the app needs one, so no call site has to know which mode it
/// is running in. A free function, not a protocol static method: Swift
/// refuses to call a protocol extension's static factory through the
/// protocol's own existential metatype (`(any LicenseClient).Type`).
enum LicenseClientFactory {
    static func make(endpoints: LicenseEndpoints = .production) -> LicenseClient {
        // The mock client exists in Debug builds only. A Release build never
        // reads the flag, so a shipped app cannot be switched to the mock
        // by launching it with an argument or an environment variable.
        #if DEBUG
        if LicenseMockMode.isEnabled { return MockLicenseClient() }
        #endif
        return HTTPLicenseClient(endpoints: endpoints)
    }
}

/// One place that answers "is the mock license mode on". Compiled out of
/// Release builds entirely: there the answer is always false.
enum LicenseMockMode {
    static var isEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ZUMBO_LICENSE_MOCK"] == "1"
            || ProcessInfo.processInfo.arguments.contains("--license-mock")
        #else
        return false
        #endif
    }
}

/// Talks to the Cloudflare Worker described in docs/LICENSING.md. Every
/// non-2xx response is mapped to a `LicenseClientError` here, at the one
/// place that knows the wire format, so `LicenseState` never has to parse a
/// status code.
final class HTTPLicenseClient: LicenseClient, Sendable {
    let endpoints: LicenseEndpoints
    private let session: URLSession

    init(endpoints: LicenseEndpoints = .production, session: URLSession = .shared) {
        self.endpoints = endpoints
        self.session = session
    }

    func activate(key: String, machineId: String, machineName: String, appVersion: String) async throws -> SignedLicenseToken {
        struct Body: Encodable { let key, machineId, machineName, appVersion: String }
        struct Response: Decodable { let token: SignedLicenseToken }
        let body = Body(key: key, machineId: machineId, machineName: machineName, appVersion: appVersion)
        let response: Response = try await post(endpoints.activateURL, body: body)
        return response.token
    }

    func validate(token: SignedLicenseToken) async throws -> SignedLicenseToken {
        struct Body: Encodable { let token: SignedLicenseToken }
        struct Response: Decodable { let token: SignedLicenseToken }
        let response: Response = try await post(endpoints.validateURL, body: Body(token: token))
        return response.token
    }

    func deactivate(key: String, machineId: String) async throws {
        struct Body: Encodable { let key, machineId: String }
        struct Empty: Decodable {}
        let _: Empty? = try? await post(endpoints.deactivateURL, body: Body(key: key, machineId: machineId))
    }

    private func post<Body: Encodable, Response: Decodable>(_ url: URL, body: Body) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same date wire format as LicenseCore's canonical encoding: seconds
        // since 1970. The default strategy counts from 2001 and would put
        // every timestamp 31 years off, failing the token's sanity check.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        request.httpBody = try? encoder.encode(body)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let urlResponse = response as? HTTPURLResponse else { throw LicenseClientError.network }
            data = responseData
            http = urlResponse
        } catch {
            throw LicenseClientError.network
        }

        switch http.statusCode {
        case 200..<300:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            guard let decoded = try? decoder.decode(Response.self, from: data) else { throw LicenseClientError.network }
            return decoded
        case 401:
            throw LicenseClientError.deactivated
        case 409:
            throw LicenseClientError.machineLimitReached
        case 404, 422:
            throw LicenseClientError.notRecognized
        default:
            throw LicenseClientError.network
        }
    }
}

/// Used when `ZUMBO_LICENSE_MOCK=1` or `--license-mock` is present, so
/// activation, validation and deactivation can all be exercised with no
/// Worker deployed. Accepts exactly one key ("ZUMB-TEST-TEST-TEST-TEST",
/// tier `.single`) and signs its token with a throwaway keypair
/// (`LicensePublicKey.mockPrivateKeyBase64`) that is never trusted outside
/// this mode - see `LicenseState.publicKey(mock:)`.
#if DEBUG
final class MockLicenseClient: LicenseClient, Sendable {
    static let acceptedKey = "\(LicenseKeyFormat.prefix)-TEST-TEST-TEST-TEST"

    private let privateKey: Curve25519.Signing.PrivateKey

    init() {
        let data = Data(base64Encoded: LicensePublicKey.mockPrivateKeyBase64) ?? Data()
        self.privateKey = (try? Curve25519.Signing.PrivateKey(rawRepresentation: data)) ?? Curve25519.Signing.PrivateKey()
    }

    func activate(key: String, machineId: String, machineName: String, appVersion: String) async throws -> SignedLicenseToken {
        guard key == Self.acceptedKey else { throw LicenseClientError.notRecognized }
        let now = Date()
        let payload = LicenseTokenPayload(
            key: key, machineId: machineId, tier: .single,
            issuedAt: now, expiresAt: Calendar.current.date(byAdding: .year, value: 1, to: now) ?? now
        )
        return try LicenseTokenVerifier.sign(payload, privateKey: privateKey)
    }

    func validate(token: SignedLicenseToken) async throws -> SignedLicenseToken { token }
    func deactivate(key: String, machineId: String) async throws {}
}
#endif
