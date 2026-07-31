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
    /// `true` while `refreshActiveAccountVip()` is in flight. Read
    /// by `ProfileSettingsView` to show a spinner on the manual
    /// "刷新大会员状态" button — without this, a slow network round
    /// trip looks like the tap was ignored. Set on the main actor
    /// because the button's `isLoading` mirror is read from
    /// SwiftUI view body in the same runloop.
    @Published private(set) var isRefreshingVip = false

    /// True when at least one account is stored and we have an active
    /// selection. Profile / follow views use this to gate UI.
    var isLoggedIn: Bool { activeAccount != nil }

    private let store: AccountSessionStore
    /// Owned auth API client for background VIP refresh. Kept on
    /// the auth store (rather than reaching into a global singleton)
    /// so unit tests can inject a mock by overriding the
    /// `BilibiliAuthAPI` initializer.
    private let authAPI: BilibiliAuthAPI

    /// `init` no longer reads the Keychain — that work
    /// moved to `bootstrap()` so the cold-start path
    /// (`PaladalaApp.init → AuthStore()`) doesn't block on
    /// Keychain I/O on the main actor.  `bootstrap()` is
    /// idempotent and safe to call from `PaladalaApp.body.
    /// onAppear` (which already calls `authStore.refresh()`
    /// as a defensive re-hydration guard).
    init(
        store: AccountSessionStore = AccountSessionStore(),
        authAPI: BilibiliAuthAPI = BilibiliAuthAPI()
    ) {
        self.store = store
        self.authAPI = authAPI
    }

    /// Read the persisted account list and active-mid from
    /// the Keychain / `UserDefaults` fallback.  Equivalent
    /// to the previous `init`'s synchronous Keychain read,
    /// but called off the cold-start critical path.
    func bootstrap() {
        refresh()
    }

    /// Re-read the persisted state. Call after the user signs in or
    /// out from the login sheet.
    func refresh() {
        let list = store.getAccounts()
        let activeMid = store.getActiveAccountMid()
        accounts = list.sorted(by: { $0.lastUsedAt > $1.lastUsedAt })
        activeAccount = list.first(where: { $0.mid == activeMid })
            ?? list.sorted(by: { $0.lastUsedAt > $1.lastUsedAt }).first
        // Diagnostic so the user can confirm via the in-app log
        // export that persisted state is actually being read on a
        // fresh launch (the symptom of the regression was "the latest
        // build lost the ability to keep the login status").
        bpLog("AuthStore.refresh: accounts=\(accounts.count) activeMid=\(activeAccount?.mid ?? 0)")
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

    // MARK: - VIP refresh

    /// Re-fetch the active account's 大会员 status from
    /// `/x/web-interface/nav` and write the updated `vipBadge`
    /// back to the Keychain. Safe to call from any main-actor
    /// context (the network hop happens on `BilibiliAuthAPI`'s
    /// own URLSession).
    ///
    /// Why a dedicated method instead of reusing `refresh()`:
    /// `refresh()` is the local Keychain re-read — it only sees
    /// what was already persisted. The whole point of this helper
    /// is to make a *network* call so the user's just-renewed
    /// membership (or a freshly-upgraded annual plan) actually
    /// lands on the badge without forcing a full re-login.
    ///
    /// Concurrency: a single in-flight call is gated by
    /// `isRefreshingVip` so two button taps in quick succession
    /// don't double-fire the network round-trip. The call site
    /// is `@MainActor` and the method body awaits inside a
    /// `defer { isRefreshingVip = false }` so the flag is
    /// always cleared on the success / failure / cancellation
    /// path.
    @discardableResult
    func refreshActiveAccountVip() async -> BiliVIPBadge? {
        guard let account = activeAccount, account.mid > 0 else {
            return nil
        }
        if isRefreshingVip {
            // Bail quietly — the user will see the existing
            // spinner tick over without an extra fetch firing
            // in the background. Returning the cached badge
            // keeps the call-site `await` flow linear.
            return account.vipBadge
        }
        isRefreshingVip = true
        defer { isRefreshingVip = false }

        let cookieHeader = account.cookieHeader
        do {
            let info = try await authAPI.navInfo(cookieHeader: cookieHeader)
            // Defensive: `navInfo` returns the new badge even
            // for the rare mid-id drift case (the upstream
            // sometimes rotates mid on account merge). The
            // `mid` mismatch is logged so a regression is
            // diagnosable from the in-app log export.
            if info.mid != account.mid {
                bpLog("refreshActiveAccountVip: mid drift stored=\(account.mid) upstream=\(info.mid)")
            }
            // Project to the same nil-vs-badge rule the
            // login flow uses: an inactive projection is
            // persisted as nil so the next `bootstrap()` does
            // not show a stale "已开通" chip for a lapsed
            // user.
            let newBadge: BiliVIPBadge? = info.vipBadge.isActive ? info.vipBadge : nil
            applyVIPBadge(newBadge, to: account.mid)
            return newBadge
        } catch {
            // Swallow the network failure — the persisted
            // badge stays as-is. A noisy banner on every
            // cold-start hiccup would be worse than the
            // existing "the badge is one refresh behind"
            // status quo, and the user can force a retry
            // from the profile manual button.
            bpLog("refreshActiveAccountVip failed: \(error.localizedDescription)")
            return account.vipBadge
        }
    }

    /// Persist an updated VIP badge onto the account list
    /// (in-memory + Keychain) and republish `activeAccount`
    /// so SwiftUI views re-render the chip.
    private func applyVIPBadge(_ badge: BiliVIPBadge?, to mid: Int64) {
        guard let index = accounts.firstIndex(where: { $0.mid == mid }) else { return }
        var updated = accounts[index]
        guard updated.vipBadge != badge else { return }
        updated.vipBadge = badge
        accounts[index] = updated
        store.upsertCurrentAccount(updated)
        if activeAccount?.mid == mid {
            activeAccount = updated
        }
        bpLog("refreshActiveAccountVip: mid=\(mid) badge=\(badge?.kind.rawValue ?? -1)")
    }
}
