import Foundation
import NearbyCore
import Security
import os

enum IdentityStore {
    private static let service = "com.shkrumelyak.nearby.identity"
    private static let account = "seed"
    private static let logger = Logger(subsystem: "com.shkrumelyak.nearby", category: "identity")

    /// Loads the 32-byte seed from the Keychain or creates and stores a new one.
    static func loadOrCreate() -> Identity {
        if let seed = loadSeed() {
            if let identity = try? Identity(seed: seed) { return identity }
            logger.error("stored seed is unusable, creating a new identity")
        }
        let identity = Identity()
        storeSeed(identity.seed)
        return identity
    }

    private static func loadSeed() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.error("keychain read failed (\(status, privacy: .public))")
            }
            return nil
        }
        return item as? Data
    }

    private static func storeSeed(_ seed: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecValueData as String] = seed
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("keychain write failed (\(status, privacy: .public)), identity is in memory only")
        }
    }
}
