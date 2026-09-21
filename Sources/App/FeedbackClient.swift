import Foundation

/// Plain-word errors `FeedbackSettingsView` shows under the Send button.
/// Never a raw `URLError` or HTTP status on screen.
enum FeedbackClientError: Error, Equatable {
    case network
    case rateLimited
    case invalid

    var message: String {
        switch self {
        case .network: return "Could not send. Check your connection and try again."
        case .rateLimited: return "Please wait a bit before sending more."
        case .invalid: return "Could not send. Check your connection and try again."
        }
    }
}

/// What the app sends to `POST /feedback` on the licensing Worker
/// (zumbo-api/src/routes/feedback.ts): kind, the message, an optional
/// email and quote permission, plus app version, macOS version and license
/// state - no other data.
struct FeedbackSubmission: Encodable {
    let kind: String
    let text: String
    let email: String?
    let mayQuote: Bool
    let appVersion: String
    let macOSVersion: String
    let licenseState: String
}

/// Talks to `LicenseEndpoints.baseURL/feedback`. Same request/response shape
/// as `HTTPLicenseClient`: every non-2xx response is mapped to a
/// `FeedbackClientError` here, at the one place that knows the wire format.
final class FeedbackClient: Sendable {
    private let endpoints: LicenseEndpoints
    private let session: URLSession

    init(endpoints: LicenseEndpoints = .production, session: URLSession = .shared) {
        self.endpoints = endpoints
        self.session = session
    }

    func send(_ submission: FeedbackSubmission) async throws {
        var request = URLRequest(url: endpoints.baseURL.appendingPathComponent("feedback"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(submission)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let urlResponse = response as? HTTPURLResponse else { throw FeedbackClientError.network }
            data = responseData
            http = urlResponse
        } catch {
            throw FeedbackClientError.network
        }

        switch http.statusCode {
        case 200..<300:
            struct Response: Decodable { let ok: Bool }
            guard let decoded = try? JSONDecoder().decode(Response.self, from: data), decoded.ok else {
                throw FeedbackClientError.network
            }
        case 429:
            throw FeedbackClientError.rateLimited
        case 422:
            throw FeedbackClientError.invalid
        default:
            throw FeedbackClientError.network
        }
    }
}
