import Foundation
import Security

/// Transport/session boundary; production persistence is always Keychain-backed.
protocol SessionTokenStorage: Sendable {
    var accessToken: String? { get }
    var refreshToken: String? { get }
    var hasSession: Bool { get }
    var generation: UUID { get }
    func save(_ session: Session)
    func clear()
    func replace(_ session: Session, ifGeneration: UUID, refreshToken: String) -> Bool
    func clear(ifGeneration: UUID) -> Bool
}

/// Paired JWTs persist in Keychain; the generation protects them from stale
/// network responses within this process. All pair mutations share one lock.
final class TokenStore: SessionTokenStorage, @unchecked Sendable {
    static let shared = TokenStore()
    private let service: String
    private let accessKey = "accessToken"
    private let refreshKey = "refreshToken"
    private let lock = NSLock()
    private var credentialGeneration = UUID()

    init(service: String = "com.carezaar.app.session") {
        self.service = service
        // Keychain survives uninstall; the installation marker intentionally does not.
        let installedKey = service == "com.carezaar.app.session" ? "carezaar.installMarker" : "\(service).installMarker"
        if !UserDefaults.standard.bool(forKey: installedKey) {
            clear()
            UserDefaults.standard.set(true, forKey: installedKey)
        }
    }

    var accessToken: String? { lock.lock(); defer { lock.unlock() }; return read(accessKey) }
    var refreshToken: String? { lock.lock(); defer { lock.unlock() }; return read(refreshKey) }
    var generation: UUID { lock.lock(); defer { lock.unlock() }; return credentialGeneration }
    var hasSession: Bool {
        lock.lock(); defer { lock.unlock() }
        return !(read(accessKey)?.isEmpty ?? true) && !(read(refreshKey)?.isEmpty ?? true)
    }

    func save(_ session: Session) {
        lock.lock(); defer { lock.unlock() }
        credentialGeneration = UUID()
        write(accessKey, session.accessToken)
        write(refreshKey, session.refreshToken)
    }

    /// Refresh may replace only the credentials it verified. Logout/new login wins
    /// over a delayed response, with the comparison and paired write under one lock.
    func replace(_ session: Session, ifGeneration expected: UUID, refreshToken: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard credentialGeneration == expected, read(refreshKey) == refreshToken,
              !session.accessToken.isEmpty, !session.refreshToken.isEmpty else { return false }
        write(accessKey, session.accessToken)
        write(refreshKey, session.refreshToken)
        return true
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        clearLocked()
    }

    func clear(ifGeneration expected: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard credentialGeneration == expected else { return false }
        clearLocked()
        return true
    }

    private func clearLocked() {
        credentialGeneration = UUID()
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
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ key: String, _ value: String) {
        let q = query(key)
        SecItemDelete(q as CFDictionary)
        var insert = q
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    private func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
