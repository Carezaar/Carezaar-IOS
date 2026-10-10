import Foundation
import Security

/// Persists the JWT pair in the Keychain. The Android client keeps the session across
/// launches and the Splash screen decides routing from token presence, so iOS must
/// survive relaunch the same way.
final class TokenStore: @unchecked Sendable {
    static let shared = TokenStore()

    private let service = "com.carezaar.app.session"
    private let accessKey = "accessToken"
    private let refreshKey = "refreshToken"
    private let lock = NSLock()

    private init() {
        // Keychain items survive uninstall, so a reinstalled app would silently resume
        // the previous install's session (possibly someone else's, on a shared or resold
        // device). UserDefaults does not survive, so it marks a fresh install.
        let installedKey = "carezaar.installMarker"
        if !UserDefaults.standard.bool(forKey: installedKey) {
            clear()
            UserDefaults.standard.set(true, forKey: installedKey)
        }
    }

    var accessToken: String? { read(accessKey) }
    var refreshToken: String? { read(refreshKey) }
    var hasSession: Bool { accessToken != nil }

    func save(_ session: Session) {
        write(accessKey, session.accessToken)
        write(refreshKey, session.refreshToken)
    }

    func clear() {
        delete(accessKey)
        delete(refreshKey)
    }

    // MARK: - Keychain

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    private func read(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        let q = query(key)
        SecItemDelete(q as CFDictionary)
        var insert = q
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    private func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(query(key) as CFDictionary)
    }
}
