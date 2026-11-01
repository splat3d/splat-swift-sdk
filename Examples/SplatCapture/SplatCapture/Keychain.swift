import Foundation
import Security

// MARK: - Keychain
//
// What the app keeps across launches, as generic-password items:
//
//   api-key.<api host>   this device's API key, one per environment
//   device-id            tells the website which device a key is for
//
// Both are readable after the first unlock and never leave this device (no
// backup restore, no iCloud). The Keychain outlives a deleted app, so a
// marker file in Application Support, which doesn't, tells a reinstall from
// a launch: a reinstall starts signed out, with its old keys removed.

enum Keychain {

    private static let service = "com.splat3d.SplatCapture"
    private static let apiKeyPrefix = "api-key."
    private static let deviceIDAccount = "device-id"
    private static let installedMarker = "installed"

    // MARK: API key

    static func apiKey(for apiURL: URL) -> String? {
        read(account: apiKeyAccount(apiURL))
    }

    @discardableResult
    static func saveAPIKey(_ key: String, for apiURL: URL) -> Bool {
        write(key, account: apiKeyAccount(apiURL))
    }

    static func deleteAPIKey(for apiURL: URL) {
        delete(account: apiKeyAccount(apiURL))
    }

    // MARK: Device ID

    /// The device's ID: 16 random bytes, made once.
    static func deviceID() -> String {
        if let existing = read(account: deviceIDAccount) {
            return existing
        }
        let made = PKCE.base64url(PKCE.randomBytes(16))
        write(made, account: deviceIDAccount)
        return made
    }

    // MARK: Fresh install

    /// On the first launch of an install, remove every API key an earlier
    /// install left behind. The device ID stays: it names the phone.
    static func forgetKeysOfEarlierInstall() {
        let marker = URL.applicationSupportDirectory.appendingPathComponent(installedMarker)
        guard !FileManager.default.fileExists(atPath: marker.path) else {
            return
        }

        for account in accounts(withPrefix: apiKeyPrefix) {
            delete(account: account)
        }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    // MARK: Items

    private static func apiKeyAccount(_ apiURL: URL) -> String {
        apiKeyPrefix + (apiURL.host() ?? apiURL.absoluteString)
    }

    private static func query(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    private static func read(account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func write(_ value: String, account: String) -> Bool {
        delete(account: account)
        var item = query(account: account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }

    private static func accounts(withPrefix prefix: String) -> [String] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
    }
}
