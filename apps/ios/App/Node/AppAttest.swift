import CryptoKit
import DeviceCheck
import Foundation
import Security
import os

/// Proves relay requests come from this app on this device (PRD R17). The key id lives in the
/// Keychain; the key itself never leaves the Secure Enclave.
/// https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity
enum AppAttest {
    private static let service = "com.arsenstorm.nearby.appattest"
    private static let account = "keyid"
    private static let logger = Logger(subsystem: "com.arsenstorm.nearby", category: "appattest")

    /// False in the Simulator and on devices without a Secure Enclave, so callers must degrade.
    static var isSupported: Bool { DCAppAttestService.shared.isSupported }

    /// The key id, creating and storing one if needed, and whether the server has yet to accept an
    /// attestation for it (→ the caller must send one).
    static func keyID() async throws -> (id: String, isNew: Bool) {
        if let id = load() { return (id, !UserDefaults.standard.bool(forKey: flag(id))) }
        // generateKey already returns the id base64-encoded, which is the wire form the Worker wants.
        let id = try await DCAppAttestService.shared.generateKey()
        store(id)
        return (id, true)
    }

    /// Step 1 of the Apple flow: certify a fresh key against the server's challenge. Once per key.
    static func attestation(keyID: String, nonce: Data) async throws -> Data {
        try await guarded { try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: hash(nonce)) }
    }

    /// Step 2, on every request: sign the entitlement bound to this room's nonce (see the Worker's
    /// `clientData()`), so a captured assertion cannot be paired with another subscription or socket.
    static func assertion(keyID: String, jws: String, nonce: Data) async throws -> Data {
        let clientData = Data(jws.utf8) + nonce
        return try await guarded {
            try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: hash(clientData))
        }
    }

    static func markAttested(_ keyID: String) {
        UserDefaults.standard.set(true, forKey: flag(keyID))
    }

    /// Forget the key so the next request makes and attests a fresh one.
    static func reset() {
        if let id = load() { UserDefaults.standard.removeObject(forKey: flag(id)) }
        SecItemDelete(query as CFDictionary)
    }

    private static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private static func flag(_ keyID: String) -> String { "appattest.attested.\(keyID)" }

    /// A key the Secure Enclave no longer holds (device restore, key rotation) is dead weight.
    private static func guarded(_ body: () async throws -> Data) async throws -> Data {
        do {
            return try await body()
        } catch let error as DCError where error.code == .invalidKey {
            logger.error("app attest key rejected, forgetting it")
            reset()
            throw error
        }
    }

    // MARK: - Keychain

    // Computed: a `[String: Any]` constant is not Sendable, and this is cheap to rebuild.
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load() -> String? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound { logger.error("keychain read failed (\(status, privacy: .public))") }
            return nil
        }
        return (item as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func store(_ keyID: String) {
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecValueData as String] = Data(keyID.utf8)
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("keychain write failed (\(status, privacy: .public)), key id is in memory only")
        }
    }
}
