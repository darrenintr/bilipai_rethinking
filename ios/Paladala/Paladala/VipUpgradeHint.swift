//
//  VipUpgradeHint.swift
//  Paladala
//
//  Upgrade-sheet copy + actions for the 大会员-gated rows in
//  the player toolbar (video quality menu, audio quality menu).
//
//  Why a dedicated file: the gated-row copy is small but it
//  renders in two places (`qualityMenu` and `audioQualityMenu`)
//  and needs three branches — the user is signed out, the user
//  is signed in but not VIP, the user *was* VIP and lapsed —
//  plus a primary "去开通/续费" action that opens B站's account
//  page and a secondary "去登录" action for the signed-out
//  branch. Centralising the copy + alert body here keeps the
//  toolbar menus thin and the strings in one spot so the
//  hint's tone stays consistent.
//
//  Three reasons drive the copy:
//
//    • `.loggedOut` — no cookie; the playurl still 4xx-gated
//      the request because B站 returns `-62002` even for
//      anonymous callers asking for a 大会员 qn. The user can
//      either sign in (in case their account is VIP) or open
//      the upgrade page to learn more.
//
//    • `.notVIP` — the active account is signed in but the
//      cookie's `data.vip` is `.none`. Single action: open
//      the upgrade page.
//
//    • `.expired` — the account had VIP at one point but the
//      due date has lapsed (mirrored by the playurl `-40103`).
//      Single action: open the renewal page. Reusing the same
//      upgrade URL because B站's account hub serves both
//      purchase and renewal on the same surface.
//
//  The `openUpgradePage` helper routes through
//  `UIApplication.shared.open` with a fixed B站 account URL.
//  SwiftUI's `Environment(\.openURL)` is not used here because
//  the URL host is not in the Info.plist `LSApplicationQueriesSchemes`
//  and we want a single point that can be swapped for an
//  in-app WebView later (the public version of B站 routes the
//  user into the native B站 app via a custom scheme when
//  installed; Paladala's unsigned builds keep the http fallback
//  so it works on stock iOS).
//
//  All copy lives in `L10n.vip.*` so the strings can be
//  localised; the helper itself is locale-agnostic.
//

import SwiftUI
import UIKit

/// Why the upgrade sheet was shown. Drawn from either the
/// upstream playurl business code or the local `BiliVIPBadge`
/// status — the helper itself is stateless, callers decide.
enum VipUpgradeReason: Equatable, Sendable {
    /// No active account. Tapping a gated row while signed out
    /// shows the "去登录 / 去开通" two-button sheet so the user
    /// can pick whichever matches their situation.
    case loggedOut
    /// Signed-in but `BiliVIPBadge.kind == .none`. Single
    /// "去开通" action.
    case notVIP
    /// Was VIP, now lapsed (`BiliVIPBadge.isExpired` or playurl
    /// returned `-40103`). Single "去开通/续费" action.
    case expired
}

extension VipUpgradeReason {
    /// Alert title for the sheet. Kept short so the iOS native
    /// alert chrome does not wrap on a single line.
    var alertTitle: String {
        switch self {
        case .loggedOut, .notVIP: return L10n.vip.requiredTitle
        case .expired: return L10n.vip.expiredTitle
        }
    }

    /// Alert body copy. The `gatedLabel` parameter names the
    /// specific row the user just tapped (e.g. "4K · 大会员"
    /// for the video menu, "320K Hi-Res · 大会员" for the
    /// audio menu) so they know *what* the upgrade unlocks.
    /// Callers pass the rendered row label so the helper
    /// stays menu-agnostic.
    ///
    /// The body intentionally does not name every VIP benefit
    /// — B站's account page does a better job selling the
    /// membership than a one-line alert ever could.
    func alertMessage(gatedLabel: String? = nil) -> String {
        switch self {
        case .loggedOut:
            // The body is the generic "登录大会员账号后可解锁"
            // because we don't know whether the user's
            // (non-existent) account would be VIP. The
            // secondary "去登录" button handles the sign-in
            // branch; the primary "去开通" still makes sense
            // because some signed-out users are browsing on a
            // fresh install with no plan to sign in.
            return L10n.vip.upgradeHint
        case .notVIP:
            if let gatedLabel {
                return L10n.vip.requiredHint + "（" + gatedLabel + "）"
            }
            return L10n.vip.requiredHint
        case .expired:
            if let gatedLabel {
                return L10n.vip.expiredHint + "（" + gatedLabel + "）"
            }
            return L10n.vip.expiredHint
        }
    }

    /// Whether the sheet should expose the secondary "去登录"
    /// button. Only the signed-out branch shows it — the other
    /// two branches would route a signed-in user to a sign-in
    /// sheet, which is at best noise.
    var showsLoginAction: Bool { self == .loggedOut }
}

/// URL the primary "去开通/续费" button opens. Kept as a
/// static so a debug / settings toggle could override it
/// later (e.g. for a custom in-app WebView) without touching
/// the call sites.
enum VipUpgradeURL {
    /// B站 account hub — both purchase and renewal live here
    /// in the official web flow. Pinned to https so ATS
    /// always allows it; the path `/account/bigVip.html` is
    /// the VIP-specific landing page on `account.bilibili.com`.
    nonisolated static let upgrade = URL(string: "https://account.bilibili.com/account/bigVip.html")!
}

/// View modifier that attaches the upgrade alert to any
/// view that binds a `VipUpgradeReason?`. The toolbar menus
/// flip the binding to `.some(.loggedOut)` / `.some(.notVIP)`
/// / `.some(.expired)` and the modifier renders the alert on
/// the next runloop turn.
///
/// Two closures, not three, because the upgrade URL is a
/// constant — the only "action" we need from the caller is
/// the "open URL" / "open login sheet" decision tree. The
/// `onLogin` closure only fires for the `.loggedOut` branch
/// (the modifier's `showsLoginAction` is the gate); the
/// `onUpgrade` closure fires for *every* branch where the
/// primary button is tapped (logged-out, not-VIP, expired).
struct VipUpgradeAlertModifier: ViewModifier {
    @Binding var reason: VipUpgradeReason?
    /// Optional context — the *rendered* label of the row the
    /// user just tapped (e.g. "4K · 大会员" for the video
    /// menu, "320K Hi-Res · 大会员" for the audio menu). The
    /// caller is responsible for picking the right label
    /// (gated.video vs. gated.audio) so the modifier can be
    /// shared between the two menus without a generic
    /// constraint. `nil` falls back to the generic body.
    let gatedLabel: String?
    let onLogin: () -> Void
    let onUpgrade: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            reason?.alertTitle ?? "",
            isPresented: Binding(
                get: { reason != nil },
                set: { if !$0 { reason = nil } }
            ),
            presenting: reason
        ) { current in
            // Primary: 去开通/续费 — every branch shows this.
            // Uses the default role so it renders as the
            // bold blue button on iOS 15+.
            Button(L10n.vip.actionUpgrade) {
                onUpgrade()
                reason = nil
            }
            // Secondary: 去登录 — only for the signed-out
            // branch. We deliberately *don't* show it for
            // `.notVIP` / `.expired` because the user is
            // already signed in; another sign-in sheet would
            // be confusing.
            if current.showsLoginAction {
                Button(L10n.vip.actionLogin) {
                    onLogin()
                    reason = nil
                }
            }
            // Cancel — always present so the user can dismiss
            // without taking an action. iOS will style the
            // cancel button as the bold option on iOS 15+ when
            // no other role is set, but the primary "去开通"
            // is what we want bolded, so this stays as the
            // trailing role:cancel.
            Button(L10n.common.cancel, role: .cancel) {
                reason = nil
            }
        } message: { current in
            Text(current.alertMessage(gatedLabel: gatedLabel))
        }
    }
}

extension View {
    /// Attach the 大会员 upgrade alert to a view. Call from
    /// any view that needs to surface a "this row needs VIP"
    /// prompt — quality menu, audio quality menu, future
    /// "play 4K" hero CTA, etc.
    ///
    /// Usage:
    /// ```swift
    /// @State private var upgradeReason: VipUpgradeReason?
    /// @State private var gatedLabel: String?
    /// ...
    /// .vipUpgradeAlert(
    ///     reason: $upgradeReason,
    ///     gatedLabel: gatedLabel,
    ///     onLogin: { router.presentLoginSheet() },
    ///     onUpgrade: { openURL(VipUpgradeURL.upgrade) }
    /// )
    /// ```
    func vipUpgradeAlert(
        reason: Binding<VipUpgradeReason?>,
        gatedLabel: String? = nil,
        onLogin: @escaping () -> Void = {},
        onUpgrade: @escaping () -> Void = {}
    ) -> some View {
        modifier(VipUpgradeAlertModifier(
            reason: reason,
            gatedLabel: gatedLabel,
            onLogin: onLogin,
            onUpgrade: onUpgrade
        ))
    }
}
