import Foundation
import Splat3D

// MARK: - The app's own API calls
//
// Three routes the website's sign-in needs, which the Splat3D SDK doesn't
// wrap: they are for this app only and aren't in the public API spec.
//
//   POST   /v1/app/token    trade the sign-in code (and PKCE verifier) for a key
//   GET    /v1/app/account  email, plan, credits and what each preset costs
//   DELETE /v1/app/key      revoke this device's key
//
// Everything else goes through SplatClient with that key.

/// What the first-party routes can answer besides success.
enum AppAPIError: Error, LocalizedError {
    /// 401: the key isn't accepted (revoked, or never valid).
    case unauthorized
    /// 400 `invalid_grant`: the code expired, was used, or didn't match.
    case invalidGrant
    /// Any other refusal or a reply this app can't read.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return AppAuth.signedOutNotice
        case .invalidGrant:
            return "This sign-in expired or was already used. Sign in again."
        case .failed(let message):
            return message
        }
    }
}

/// What a sign-in code is worth.
struct AppToken: Equatable, Decodable {
    let apiKey: String
    let keyID: String
    let keyPrefix: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case keyID = "key_id"
        case keyPrefix = "key_prefix"
    }
}

/// What the account holds, for the rules shown before capture.
struct Account: Equatable, Decodable {
    let email: String?
    let plan: String
    let creditBalance: Int
    let presets: [PresetCost]
    /// Scenes processing now, and how many the plan allows at once.
    let running: Int
    let maxRunning: Int

    init(email: String?, plan: String, creditBalance: Int, presets: [PresetCost], running: Int, maxRunning: Int) {
        self.email = email
        self.plan = plan
        self.creditBalance = creditBalance
        self.presets = presets
        self.running = running
        self.maxRunning = maxRunning
    }

    private enum CodingKeys: String, CodingKey {
        case email, plan, credits, presets, scenes
    }

    private enum CreditsKeys: String, CodingKey {
        case balance
    }

    private enum ScenesKeys: String, CodingKey {
        case running
        case maxRunning = "max_running"
    }

    /// One `presets` entry as the API writes it: the name is any string.
    private struct Entry: Decodable {
        let preset: String
        let credits: Int
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        plan = try container.decode(String.self, forKey: .plan)

        let credits = try container.nestedContainer(keyedBy: CreditsKeys.self, forKey: .credits)
        creditBalance = try credits.decode(Int.self, forKey: .balance)

        // A preset this app doesn't know is skipped, not an error: the API
        // may add one before the app does.
        presets = try container.decode([Entry].self, forKey: .presets).compactMap { entry in
            ScenePreset(rawValue: entry.preset).map { PresetCost(preset: $0, credits: entry.credits) }
        }

        let scenes = try container.nestedContainer(keyedBy: ScenesKeys.self, forKey: .scenes)
        running = try scenes.decode(Int.self, forKey: .running)
        maxRunning = try scenes.decode(Int.self, forKey: .maxRunning)
    }
}

/// What a scene made with a preset costs, in credits.
struct PresetCost: Equatable {
    let preset: ScenePreset
    let credits: Int
}

/// Values shared by the sign-in's two halves: the browser hop and the exchange.
enum AppAuth {
    static let clientID = "splatcapture"
    /// RFC 7636.
    static let challengeMethod = "S256"
    /// RFC 6749.
    static let grantType = "authorization_code"
    static let signedOutNotice = "This device was signed out. Sign in again."
}

struct AppAPI {

    let baseURL: URL

    private static let revokeTimeout: TimeInterval = 10
    private static let success = 200..<300
    private static let unauthorized = 401
    private static let badRequest = 400
    private static let invalidGrantCode = "invalid_grant"

    /// No cache and no cookies: the replies carry keys.
    private let session = URLSession(configuration: .ephemeral)

    /// Trade the code for a key. Never retried: a code works once, so any
    /// failure starts the sign-in over.
    func exchange(code: String, verifier: String) async throws -> AppToken {
        let body = [
            "grant_type": AppAuth.grantType,
            "code": code,
            "code_verifier": verifier,
            "client_id": AppAuth.clientID,
        ]
        var request = makeRequest("POST", "v1/app/token", apiKey: nil)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    func account(apiKey: String) async throws -> Account {
        try await send(makeRequest("GET", "v1/app/account", apiKey: apiKey))
    }

    /// Revoke the key the call is made with.
    func revokeKey(apiKey: String) async throws {
        var request = makeRequest("DELETE", "v1/app/key", apiKey: apiKey)
        request.timeoutInterval = Self.revokeTimeout
        _ = try await data(for: request)
    }

    // MARK: Requests

    private func makeRequest(_ method: String, _ path: String, apiKey: String?) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        let data: Payload
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            let code: String?
            let message: String?
        }
        let error: Body
    }

    private func send<Payload: Decodable>(_ request: URLRequest) async throws -> Payload {
        let body = try await data(for: request)
        do {
            return try JSONDecoder().decode(Envelope<Payload>.self, from: body).data
        } catch {
            throw AppAPIError.failed("The server's answer couldn't be read.")
        }
    }

    /// The body of a 2xx answer; anything else is an ``AppAPIError``.
    private func data(for request: URLRequest) async throws -> Data {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppAPIError.failed("The server's answer couldn't be read.")
        }
        if Self.success.contains(http.statusCode) {
            return body
        }
        if http.statusCode == Self.unauthorized {
            throw AppAPIError.unauthorized
        }

        let refusal = try? JSONDecoder().decode(ErrorEnvelope.self, from: body).error
        if http.statusCode == Self.badRequest, refusal?.code == Self.invalidGrantCode {
            throw AppAPIError.invalidGrant
        }
        throw AppAPIError.failed(refusal?.message ?? "The server answered \(http.statusCode).")
    }
}
