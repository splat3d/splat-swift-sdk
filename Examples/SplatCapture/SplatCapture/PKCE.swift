import CryptoKit
import Foundation
import Security

// MARK: - PKCE (RFC 7636)
//
// The app proves it is the one that started a sign-in without holding a
// secret: it sends the SHA-256 of a random verifier up front and the
// verifier itself only when it redeems the code.
//
//   verifier  = base64url(32 random bytes)                  43 characters
//   challenge = base64url(SHA256(ASCII(verifier)))          sent to the web
//   state     = base64url(16 random bytes)                  checked on return

enum PKCE {

    private static let verifierBytes = 32
    private static let stateBytes = 16

    static func verifier() -> String {
        base64url(randomBytes(verifierBytes))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func state() -> String {
        base64url(randomBytes(stateBytes))
    }

    /// Base64url without padding (RFC 4648 §5): also how device IDs are written.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "The system has no random bytes")
        return Data(bytes)
    }

    #if DEBUG
    /// RFC 7636 Appendix B: a wrong hash or encoding would sign nobody in.
    static func checkAgainstRFC() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        assert(Self.challenge(for: verifier) == challenge, "PKCE challenge does not match RFC 7636 Appendix B")
    }
    #endif
}
