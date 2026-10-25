import Foundation
import Security

/// One-time move from the app's previous name, Amailana: its data folder, preferences and
/// Keychain items. Runs only in the real app bundle, never with INKWELL_HOME (test copies).
enum LegacyMigration {
    static let oldBundleId = "app.amailana.mail"
    private static let doneKey = "migratedFromAmailana"

    private static var isRealApp: Bool {
        Bundle.main.bundleIdentifier == Keychain.service && ProcessInfo.processInfo.environment["INKWELL_HOME"] == nil
    }

    /// Moves ~/Library/Application Support/Amailana into the Inkwell folder. Must run before
    /// anything opens the database. Item by item, so a folder created early (e.g. by the MCP
    /// helper) doesn't block it; nothing that already exists in the new folder is overwritten.
    static func moveDataFolder() {
        guard isRealApp else { return }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("Amailana", isDirectory: true)
        let new = support.appendingPathComponent("Inkwell", isDirectory: true)
        guard fm.fileExists(atPath: old.appendingPathComponent("mail.sqlite").path),
              !fm.fileExists(atPath: new.appendingPathComponent("mail.sqlite").path),
              let items = try? fm.contentsOfDirectory(atPath: old.path) else { return }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        for name in items {
            let dest = new.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            do { try fm.moveItem(at: old.appendingPathComponent(name), to: dest) }
            catch { NSLog("Migration: moving %@ failed: %@", name, error.localizedDescription) }
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true { try? fm.removeItem(at: old) }
    }

    /// Copies preferences (IMAP capability cache, theme flags…) and moves each password and AI
    /// key into Inkwell's Keychain service. Reading an old item asks the user once per item,
    /// since it belongs to the old app; items the user declines stay behind untouched.
    static func moveDefaultsAndKeychain() {
        guard isRealApp else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: doneKey) {
            for (k, v) in defaults.persistentDomain(forName: oldBundleId) ?? [:]
            where defaults.object(forKey: k) == nil && !k.hasPrefix("NS") && k != "keychainRestrictedACL" {
                defaults.set(v, forKey: k)
            }
            defaults.set(true, forKey: doneKey)
        }
        let list: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: oldBundleId,
                                   kSecReturnAttributes as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(list as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return }
        for item in items {
            guard let key = item[kSecAttrAccount as String] as? String else { continue }
            let one: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: oldBundleId,
                                      kSecAttrAccount as String: key]
            if Keychain.get(key) == nil {
                var read = one
                read[kSecReturnData as String] = true
                read[kSecMatchLimit as String] = kSecMatchLimitOne
                var data: CFTypeRef?
                guard SecItemCopyMatching(read as CFDictionary, &data) == errSecSuccess, let d = data as? Data,
                      let value = String(data: d, encoding: .utf8), Keychain.set(value, for: key) else { continue }
            }
            SecItemDelete(one as CFDictionary)
        }
    }
}
