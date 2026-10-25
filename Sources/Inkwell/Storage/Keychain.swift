import Foundation
import Security

enum Keychain {
    static let service = "app.inkwell.mail"

    /// Saves with the default access control: only the app that saved the item (Inkwell, as
    /// identified by its signature) can read it without the user's approval.
    /// The stable signature is what keeps rebuilds from asking again.
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            NSLog("Keychain: saving %@ failed (%d)", key, status)
            return false
        }
        return true
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let value = String(data: d, encoding: .utf8) else { return nil }
        return value
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }

    // Read each password from the Keychain once per launch; IMAP, IDLE and SMTP all need it.
    private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()

    static func password(for account: Account) -> String {
        let key = "acct-\(account.id.uuidString)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let p = cache[key] { return p }
        let p = get(key) ?? ""
        if !p.isEmpty { cache[key] = p }
        return p
    }

    /// Test harnesses only: seed the in-memory cache so no Keychain item is touched.
    static func primeForTesting(_ p: String, for account: Account) {
        cacheLock.lock(); cache["acct-\(account.id.uuidString)"] = p; cacheLock.unlock()
    }

    static func setPassword(_ p: String, for account: Account) {
        let key = "acct-\(account.id.uuidString)"
        set(p, for: key)
        cacheLock.lock(); cache[key] = p; cacheLock.unlock()
    }

    static func forget(_ accountId: UUID) {
        cacheLock.lock(); cache["acct-\(accountId.uuidString)"] = nil; cacheLock.unlock()
    }
}
