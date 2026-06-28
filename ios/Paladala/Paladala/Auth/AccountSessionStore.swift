import Foundation

/// Persists the multi-account list and the active-account `mid` in the
/// iOS Keychain. Mirrors the Android `AccountSessionStore` API surface:
/// callers see `getAccounts()`, `getActiveAccountMid()`,
/// `upsertCurrentAccount()`, `activateAccount(mid:)`,
/// `removeAccount(mid:)`. All mutations are atomic; if the JSON encode
/// throws we fail closed (the prior list stays).
final class AccountSessionStore {
    private static let accountsAccount = "paladala.accounts"
    private static let activeMidAccount = "paladala.activeMid"
    private static let accountsDefaultsKey = "paladala.accounts.defaults"
    private static let activeMidDefaultsKey = "paladala.activeMid.defaults"

    private let keychain: KeychainStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let defaults: UserDefaults

    init(
        keychain: KeychainStore = KeychainStore(),
        defaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.defaults = defaults
    }

    func getAccounts() -> [StoredAccount] {
        guard let data = keychain.readData(account: Self.accountsAccount)
            ?? defaults.data(forKey: Self.accountsDefaultsKey) else {
            return []
        }
        do {
            return try decoder.decode([StoredAccount].self, from: data)
        } catch {
            bpLog("account list decode failed: \(error)")
            return []
        }
    }

    func getActiveAccountMid() -> Int64? {
        guard let data = keychain.readData(account: Self.activeMidAccount)
                ?? defaults.data(forKey: Self.activeMidDefaultsKey),
              let raw = String(data: data, encoding: .utf8),
              let mid = Int64(raw) else {
            return nil
        }
        return mid
    }

    /// Insert / update the given account, then mark it as the active one.
    /// Returns the persisted list.
    @discardableResult
    func upsertCurrentAccount(_ account: StoredAccount) -> [StoredAccount] {
        var list = getAccounts()
        if let index = list.firstIndex(where: { $0.mid == account.mid }) {
            list[index] = account
        } else {
            list.append(account)
        }
        persist(list: list, activeMid: account.mid)
        return list
    }

    func activateAccount(mid: Int64) {
        let list = getAccounts()
        guard list.contains(where: { $0.mid == mid }) else { return }
        var updated = list
        if let index = updated.firstIndex(where: { $0.mid == mid }) {
            updated[index].lastUsedAt = Date()
        }
        persist(list: updated, activeMid: mid)
    }

    func removeAccount(mid: Int64) {
        let list = getAccounts().filter { $0.mid != mid }
        let nextActive: Int64? = {
            if getActiveAccountMid() == mid {
                return list.sorted(by: { $0.lastUsedAt > $1.lastUsedAt }).first?.mid
            }
            return getActiveAccountMid()
        }()
        persist(list: list, activeMid: nextActive)
    }

    func clearActiveAccount() {
        keychain.delete(account: Self.activeMidAccount)
        defaults.removeObject(forKey: Self.activeMidDefaultsKey)
    }

    private func persist(list: [StoredAccount], activeMid: Int64?) {
        do {
            let data = try encoder.encode(list)
            try keychain.writeData(data, account: Self.accountsAccount)
            defaults.set(data, forKey: Self.accountsDefaultsKey)
        } catch {
            bpLog("account list persist failed: \(error)")
        }
        if let activeMid, let raw = "\(activeMid)".data(using: .utf8) {
            try? keychain.writeData(raw, account: Self.activeMidAccount)
            defaults.set(raw, forKey: Self.activeMidDefaultsKey)
        } else {
            keychain.delete(account: Self.activeMidAccount)
            defaults.removeObject(forKey: Self.activeMidDefaultsKey)
        }
    }
}
