import Foundation
import Security

/// Minimal secrets store. Originally Keychain-backed, but ad-hoc-signed builds
/// re-prompt for keychain access on every rebuild because each binary's
/// signature is a fresh identity. We now persist to a 0600 plist in
/// `~/Library/Application Support/ClaudeDeck/secrets.plist` so daily dev
/// rebuilds don't bounce a password dialog at the user.
///
/// On first read after upgrading, we attempt one Keychain fallback to migrate
/// any prior value — that triggers a single final prompt. After that the file
/// is authoritative and macOS never asks again.
enum Keychain {
    private static let service = "co.ailogy.claudedeck"

    static func set(_ value: String?, account: String) {
        var bag = readBag()
        if let value = value, !value.isEmpty {
            bag[account] = value
        } else {
            bag.removeValue(forKey: account)
        }
        writeBag(bag)
        // Clear any lingering Keychain entry so future reads don't drift back
        // to the old store (and so the next user doesn't get a stale value).
        deleteFromKeychain(account: account)
    }

    static func get(account: String) -> String? {
        if let v = readBag()[account], !v.isEmpty { return v }
        // One-time migration from the legacy Keychain store.
        if let legacy = readFromKeychain(account: account), !legacy.isEmpty {
            var bag = readBag()
            bag[account] = legacy
            writeBag(bag)
            deleteFromKeychain(account: account)
            return legacy
        }
        return nil
    }

    // MARK: - File store

    private static var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let dir = support.appending(path: "ClaudeDeck", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        return dir.appending(path: "secrets.plist")
    }

    private static func readBag() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = raw as? [String: String] else {
            return [:]
        }
        return dict
    }

    private static func writeBag(_ bag: [String: String]) {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: bag, format: .binary, options: 0)
            let url = storeURL
            try data.write(to: url, options: [.atomic])
            // Tighten to owner read/write only — this file holds API keys.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Swallow — UI surfaces the missing-key case via Summarizer.hasApiKey.
        }
    }

    // MARK: - Legacy Keychain migration

    private static func readFromKeychain(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    private static func deleteFromKeychain(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}
