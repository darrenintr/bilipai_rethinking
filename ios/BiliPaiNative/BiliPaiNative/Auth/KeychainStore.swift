import Foundation
import Security

/// Thin wrapper around `Security.framework` for storing small
/// `Data` blobs (typically the JSON-encoded `[StoredAccount]` list)
/// keyed by a service + account pair. Used by `AccountSessionStore`.
///
/// Each entry is a `kSecClassGenericPassword` with
/// `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// so the credentials survive reboot but never leave the device.
struct KeychainStore {
    enum KeychainError: Error {
        case unhandled(OSStatus)
    }

    let service: String

    init(service: String = "com.bilipai.nativeios.auth") {
        self.service = service
    }

    func readData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return nil }
            NSLog("BiliPai: Keychain read failed for \(account): \(status)")
            return nil
        }
        return item as? Data
    }

    func writeData(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
        default:
            throw KeychainError.unhandled(status)
        }
    }

    func delete(account: String) {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("BiliPai: Keychain delete failed for \(account): \(status)")
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}
