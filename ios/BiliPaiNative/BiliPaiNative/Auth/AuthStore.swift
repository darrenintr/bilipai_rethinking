import Foundation
import Combine

/// Global, observable auth state. Injected as an `@EnvironmentObject`
/// in `RootView` so every screen can read the active account without
/// plumbing it through the navigation stack. Mirrors the Android
/// `AuthStore` / `AccountManager` split.
@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var accounts: [StoredAccount] = []
    @Published private(set) var activeAccount: StoredAccount?

    /// True when at least one account is stored and we have an active
    /// selection. Profile / follow views use this to gate UI.
    var isLoggedIn: Bool { activeAccount != nil }

    private let store: AccountSessionStore

    init(store: AccountSessionStore = AccountSessionStore()) {
        self.store = store
        refresh()
    }

    /// Re-read the persisted state. Call after the user signs in or
    /// out from the login sheet.
    func refresh() {
        let list = store.getAccounts()
        let activeMid = store.getActiveAccountMid()
        // Sanity check the persisted state. Bilibili user IDs fit in
        // unsigned 32-bit (max ~4.3×10⁹); anything larger is parser
        // corruption or a stale keychain value from an older build.
        // Log a warning per offender and skip it when picking the
        // active account so the user lands on a usable one (or the
        // sign-in sheet if nothing valid survives).
        let invalid = list.filter { $0.mid <= 0 || $0.mid > UInt32.max }
        for bad in invalid {
            bpLog("AuthStore.refresh: skipping invalid account \(bad.name) mid=\(bad.mid)")
        }
        let usable = list.filter { $0.mid > 0 && $0.mid <= UInt32.max }
        accounts = usable.sorted(by: { $0.lastUsedAt > $1.lastUsedAt })
        activeAccount = usable.first(where: { $0.mid == activeMid })
            ?? usable.sorted(by: { $0.lastUsedAt > $1.lastUsedAt }).first
        // Diagnostic so the user can confirm via the in-app log
        // export that persisted state is actually being read on a
        // fresh launch (the symptom of the regression was "the latest
        // build lost the ability to keep the login status").
        bpLog("AuthStore.refresh: accounts=\(accounts.count) (skipped \(invalid.count)) activeMid=\(activeAccount?.mid ?? 0)")
    }

    /// Mark a freshly-completed login as the active one and persist it.
    func completeLogin(_ account: StoredAccount) {
        store.upsertCurrentAccount(account)
        refresh()
    }

    func switchTo(mid: Int64) {
        store.activateAccount(mid: mid)
        refresh()
    }

    func signOut() {
        if let mid = activeAccount?.mid {
            store.removeAccount(mid: mid)
        }
        store.clearActiveAccount()
        refresh()
    }

    func remove(mid: Int64) {
        store.removeAccount(mid: mid)
        refresh()
    }
}
