import AuthenticationServices
import Foundation
import Observation
import StoreKit
import SwiftUI
import Splat3D

// MARK: - Signing in
//
// The app never sees a password and holds no key of its own. The website
// signs the user in, and the app trades a one-time code for an API key made
// for this device (RFC 8252: system browser, authorization code, PKCE):
//
//   SplatCapture                          splat-3d.com                 api
//    verifier, challenge = S256(verifier), state, device_id
//    ── /connect/app?client_id&code_challenge&state&device_id ──▶  sign in, Allow
//    ◀── https://splat-3d.com/connect/app/callback?code&state ──
//    check state
//    ── POST /v1/app/token {code, code_verifier} ─────────────────────────▶ key
//    Keychain ← key;  GET /v1/app/account, SDK getUsage()  (the rules)
//    sign out = DELETE /v1/app/key
//
// The callback is an https link the system checks against the website's
// webcredentials association, so no other app can catch the code.

/// Who is signed in on this device, and what the account allows.
@MainActor
@Observable
final class AccountSession {

    struct APICredentials: Sendable, Equatable {
        let apiKey: String
        let apiURL: URL
    }

    enum State: Equatable {
        /// `notice` says why, when the user didn't just choose to be here.
        case signedOut(notice: String?)
        case signingIn
        case signedIn(APICredentials)
    }

    private(set) var state: State
    private(set) var account: Account?
    private(set) var usage: Usage?
    /// Links to buy credits show only where the App Store allows them: the
    /// US storefront. See the README.
    private(set) var showsPurchaseLinks = false

    private let api = AppAPI(baseURL: AppEnvironment.apiURL)
    private let apiURL = AppEnvironment.apiURL
    private let store: CaptureStore
    #if DEBUG
    private var isPreview = false
    #endif

    private static let callbackPath = "/connect/app/callback"
    private static let connectPath = "/connect/app"
    private static let usStorefront = "USA"
    private static let accessDenied = "access_denied"

    private static let signInFailed = "Sign-in didn't finish. Try again."
    private static let revokeFailed = "Signed out on this device. If this phone is lost, revoke its key in Dashboard → Developer."

    init() {
        Keychain.forgetKeysOfEarlierInstall()
        store = .live
        if let key = Keychain.apiKey(for: AppEnvironment.apiURL) {
            state = .signedIn(APICredentials(apiKey: key, apiURL: AppEnvironment.apiURL))
        } else {
            state = .signedOut(notice: nil)
        }
        #if DEBUG
        PKCE.checkAgainstRFC()
        #endif
    }

    #if DEBUG
    /// A session in a fixed state that never reaches the API or the
    /// Keychain, for PreviewHarness.
    init(previewing state: State, account: Account? = nil, usage: Usage? = nil, showsPurchaseLinks: Bool = false) {
        self.state = state
        self.account = account
        self.usage = usage
        self.showsPurchaseLinks = showsPurchaseLinks
        store = CaptureStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PreviewCapture"))
        isPreview = true
    }
    #endif

    // MARK: Sign in

    /// Open the website's sign-in in the system browser, and finish with the
    /// code it hands back. Backing out is not a failure: it says nothing.
    func signIn(using webAuth: WebAuthenticationSession) async {
        #if DEBUG
        guard !isPreview else {
            return
        }
        #endif
        guard case .signedOut = state else {
            return
        }
        state = .signingIn

        let verifier = PKCE.verifier()
        let expectedState = PKCE.state()
        let callback: URL
        do {
            callback = try await webAuth.authenticate(
                using: connectURL(verifier: verifier, state: expectedState),
                callback: .https(host: AppEnvironment.webURL.host()!, path: Self.callbackPath),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
        } catch {
            let backedOut = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            state = .signedOut(notice: backedOut ? nil : Self.signInFailed)
            return
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if value("error") == Self.accessDenied {
            state = .signedOut(notice: nil)
            return
        }
        guard value("state") == expectedState, let code = value("code") else {
            state = .signedOut(notice: Self.signInFailed)
            return
        }

        do {
            let token = try await api.exchange(code: code, verifier: verifier)
            guard Keychain.saveAPIKey(token.apiKey, for: apiURL) else {
                // The key exists server-side; don't leave it active.
                try? await api.revokeKey(apiKey: token.apiKey)
                state = .signedOut(notice: Self.signInFailed)
                return
            }
            state = .signedIn(APICredentials(apiKey: token.apiKey, apiURL: apiURL))
        } catch {
            state = .signedOut(notice: error.localizedDescription)
            return
        }
        await refresh()
    }

    /// Why the last sign-in ended, while signed out.
    var notice: String? {
        if case .signedOut(let notice) = state {
            return notice
        }
        return nil
    }

    private func connectURL(verifier: String, state: String) -> URL {
        var components = URLComponents(url: AppEnvironment.webURL, resolvingAgainstBaseURL: false)!
        components.path = Self.connectPath
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppAuth.clientID),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: AppAuth.challengeMethod),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "device_id", value: Keychain.deviceID()),
        ]
        return components.url!
    }

    // MARK: Sign out

    /// Revoke this device's key, then forget it and the saved captures,
    /// whatever the revoke answered.
    func signOut() async {
        guard case .signedIn(let credentials) = state else {
            return
        }

        var notice: String?
        #if DEBUG
        let revokes = !isPreview
        #else
        let revokes = true
        #endif
        if revokes {
            do {
                try await api.revokeKey(apiKey: credentials.apiKey)
            } catch AppAPIError.unauthorized {
                // Already revoked: nothing is left to do.
            } catch {
                notice = Self.revokeFailed
            }
            Keychain.deleteAPIKey(for: apiURL)
        }
        store.clear()
        forget(notice: notice)
    }

    /// The API refused this key (401): sign in again. A key that is no longer
    /// the signed-in one changes nothing, so a stale caller can't sign out a
    /// fresh session.
    func keyRejected(_ rejected: APICredentials) {
        guard state == .signedIn(rejected) else {
            return
        }
        Keychain.deleteAPIKey(for: apiURL)
        forget(notice: AppAuth.signedOutNotice)
    }

    private func forget(notice: String?) {
        account = nil
        usage = nil
        state = .signedOut(notice: notice)
    }

    // MARK: Rules

    /// Load the account and the month's usage together. A failure keeps what
    /// was shown before: the server enforces the rules, so the app never
    /// blocks on a read.
    func refresh() async {
        #if DEBUG
        guard !isPreview else {
            return
        }
        #endif
        guard case .signedIn(let credentials) = state else {
            return
        }

        async let loadedAccount = Self.load(account: api, credentials)
        async let loadedUsage = Self.load(usage: credentials)
        let (accountResult, usageResult) = await (loadedAccount, loadedUsage)

        // Signed out, or in again as someone else, while the reads ran.
        guard state == .signedIn(credentials) else {
            return
        }

        if accountResult.isUnauthorized || usageResult.isUnauthorized {
            keyRejected(credentials)
            return
        }
        if case .success(let account) = accountResult {
            self.account = account
        }
        if case .success(let usage) = usageResult {
            self.usage = usage
        }
    }

    nonisolated private static func load(account api: AppAPI, _ credentials: APICredentials) async -> Result<Account, Error> {
        do {
            return .success(try await api.account(apiKey: credentials.apiKey))
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func load(usage credentials: APICredentials) async -> Result<Usage, Error> {
        let client = SplatClient(apiKey: credentials.apiKey, baseURL: credentials.apiURL)
        do {
            return .success(try await client.getUsage())
        } catch {
            return .failure(error)
        }
    }

    // MARK: Storefront

    /// Follow the App Store storefront for as long as the app runs.
    func watchStorefront() async {
        showsPurchaseLinks = Self.sellsHere(await Storefront.current)
        for await storefront in Storefront.updates {
            showsPurchaseLinks = Self.sellsHere(storefront)
        }
    }

    private static func sellsHere(_ storefront: Storefront?) -> Bool {
        storefront?.countryCode == usStorefront
    }
}

private extension Result where Failure == Error {
    /// Whether the API said the key is no good.
    var isUnauthorized: Bool {
        guard case .failure(let error) = self else {
            return false
        }
        if case AppAPIError.unauthorized = error {
            return true
        }
        if case SplatError.unauthorized = error {
            return true
        }
        return false
    }
}
