//
//  BilibiliVIP.swift
//  Paladala
//
//  Bilibili 大会员 (Big VIP) detection + 名衔 (badge) model.
//
//  Why a dedicated file: the membership data shape is small but
//  reused in four places (active account profile, UP profile, video
//  card, comment author) and two API surfaces (the `/x/web-interface/
//  nav` "self" endpoint and the `/x/v2/reply/wbi/main` "member.vip"
//  block). Centralising the decode + UI projection here means the
//  `BiliUserCard` / `BiliComment` / `StoredAccount` stay thin and
//  any upstream name change lands in one spot.
//
//  Wire shape, summary of the two surfaces we decode:
//
//    /x/web-interface/nav response
//    `data.vip` is a structured object with a nested `label`:
//
//      {
//        "type": 0,           // 0 = none, 1 = 月度大会员, 2 = 年度大会员
//        "status": 0,         // 0 = 无, 1 = 生效中
//        "vip_pay_type": 0,   // 0 = none, 1 = 月度, 2 = 年度
//        "theme_type": 0,     // 0 = none, 1 = 普通粉, 2 = 十年橘, 3 = 超级紫
//        "due_date": 0,       // unix seconds
//        "label": {           // present when status == 1
//          "text": "大会员",
//          "label_theme": "vip" | "annual_vip" | "ten_years_vip" |
//                         "fools_day_vip" | "svip",
//          "bg_color": "#FB7299",
//          "border_color": "#FB7299",
//          "text_color": "#FFFFFF",
//          "bg_style": 1,
//          "use_img_label": false
//        },
//        "avatar_subscript": 0,
//        "nickname_color": "#FB7299"
//      }
//
//    /x/v2/reply/wbi/main `member.vip`
//      Slimmer object — only `vipType` / `vipStatus` / `vip_pay_type`
//      plus a free-form string `label`. We use those four fields
//      alone, falling back to deriving the badge text + colour from
//      the bit fields when the upstream omits `label`.
//
//  All optional fields decode leniently — a banned user, an
//  anonymous reply, or a future API drift must not break the
//  whole user-card / comment-thread decode. `BiliVIPBadge.none`
//  is the safe fallback the UI falls through to.
//

import Foundation
import SwiftUI

// MARK: - Status enum

/// High-level "what kind of 大会员 is this user" classification.
/// Source-of-truth: the upstream `theme_type` / `label_theme`
/// bit fields, plus `vip_pay_type` for the monthly/annual split.
enum BiliVIPKind: Int, Codable, Hashable, Sendable, CaseIterable {
    case none = 0
    case monthly = 1
    case annual = 2
    case tenYear = 3
    /// 大会员 + 超级大会员 combined (a regular VIP who also has a
    /// Super-VIP subscript), or a freshly minted SVIP. Named
    /// `superVip` (rather than the upstream's bare `super`)
    /// because Swift reserves `super` as a keyword for class
    /// `super.init()` calls — Swift 6 strict mode refuses an
    /// enum case named after a contextual keyword.
    case superVip = 4

    /// Best-effort mapping from the upstream bit fields. Used
    /// when the upstream omits the `label` block (common on the
    /// comment API) or returns a label string we don't recognise.
    init(labelTheme: String?, vipType: Int, themeType: Int) {
        switch labelTheme {
        case "annual_vip":
            self = .annual
        case "ten_years_vip":
            self = .tenYear
        case "svip":
            self = .superVip
        case "vip", "fools_day_vip":
            self = (vipType == 2) ? .annual : .monthly
        default:
            switch themeType {
            case 1: self = .monthly
            case 2: self = .annual
            case 3: self = .tenYear
            case 4: self = .superVip
            default:
                if vipType == 2 { self = .annual }
                else if vipType == 1 { self = .monthly }
                else { self = .none }
            }
        }
    }

    /// True when this badge entitles the user to B站's gated
    /// qualities (1080P60, 4K, HDR, Dolby Vision, Hi-Res audio).
    /// `none` is the only flavour that *does not* unlock gated
    /// content — even `monthly` counts.
    var unlocksGatedQuality: Bool {
        self != .none
    }

    /// Localized label used for the badge text. The fallback path
    /// (`L10n.vip.title`) is the generic "大会员" — used for the
    /// `monthly` / `annual` flavours whose label strings the
    /// upstream occasionally blanks.
    var defaultBadgeText: String {
        switch self {
        case .none: return ""
        case .monthly: return L10n.vip.title
        case .annual: return L10n.vip.annualTitle
        case .tenYear: return L10n.vip.tenYearTitle
        case .superVip: return L10n.vip.superTitle
        }
    }
}

// MARK: - Badge value type

/// Render-ready projection of a Bilibili 大会员 badge. Every
/// consumer (`VipBadgeView`, the inline user-name suffix on
/// `SharedViews.VideoCard`, the comment header, the UP profile
/// header) reads from this — never from the raw upstream JSON —
/// so the colour palette, badge text, and SF Symbol icon stay
/// consistent across the app.
struct BiliVIPBadge: Hashable, Sendable, Codable {
    /// Display text rendered inside the badge. Prefer the
    /// upstream `label.text` (e.g. "年度大会员"); fall back to
    /// `kind.defaultBadgeText` when the upstream omits it.
    let text: String
    /// Background colour, hex string `#RRGGBB`. Upstream uses
    /// `#FB7299` for the regular VIP, `#E1A025` (10-year orange),
    /// `#644BC9` (Super-VIP purple), `#FFD700` (special flair).
    let backgroundHex: String
    /// Foreground / text colour, hex string `#RRGGBB`. Always
    /// `#FFFFFF` in current upstream.
    let foregroundHex: String
    /// Border colour, hex string `#RRGGBB`. Falls back to the
    /// background colour when the upstream omits the border.
    let borderHex: String
    /// Friendly nickname colour (the colour the upstream wants the
    /// user's display name rendered in). Often the same as
    /// `backgroundHex` for regular VIP, `#E1A025` for 10-year.
    let nicknameColorHex: String?
    /// High-level classification.
    let kind: BiliVIPKind
    /// Unix-seconds expiry (only present in the nav surface).
    /// `nil` for the comment surface, where the upstream does not
    /// publish a due date.
    let dueDate: Date?

    /// Synthesize a badge with safe defaults. `BiliVIPBadge.none`
    /// is the canonical "no VIP" stub the UI uses to render the
    /// avatar without a coloured chip.
    static let none = BiliVIPBadge(
        text: "",
        backgroundHex: "#000000",
        foregroundHex: "#FFFFFF",
        borderHex: "#000000",
        nicknameColorHex: nil,
        kind: .none,
        dueDate: nil
    )

    /// Legacy fallback used by `BiliUserCard` decode paths
    /// that only have the upstream's slim `vipType` integer
    /// (no `label` block, no `due_date`, no colour palette).
    /// The comment API and the `/x/relation/followings`
    /// surface both publish this minimal shape; everything
    /// that wants a richer badge (the nav endpoint, the
    /// signed-in home feed, the player toolbar) goes
    /// through the proper `BilibiliNavVIPDTO` decode and
    /// gets a full `BiliVIPBadge` instead.
    ///
    /// `vipType` semantics, verified against `bilibili-API-collect`:
    ///   • 0 = none
    ///   • 1 = monthly 大会员
    ///   • 2 = annual 大会员
    /// Anything else falls through to `nil` so an
    /// unknown upstream integer doesn't fabricate a VIP
    /// badge the user never had.
    ///
    /// Hex values mirror the upstream nav surface's
    /// canonical palette (the same hex the comment-side
    /// `BilibiliVIPCommentPalette` publishes, inlined
    /// here so this static doesn't need to peek at a
    /// file-private helper). The bg / fg split matches
    /// the regular VIP chip — white text on the brand
    /// colour.
    static func legacy(vipType: Int) -> BiliVIPBadge? {
        let kind: BiliVIPKind
        let bg: String
        switch vipType {
        case 1:
            kind = .monthly
            bg = "#FB7299"
        case 2:
            kind = .annual
            bg = "#E1A025"
        default:
            return nil
        }
        return BiliVIPBadge(
            text: kind.defaultBadgeText,
            backgroundHex: bg,
            foregroundHex: "#FFFFFF",
            borderHex: bg,
            nicknameColorHex: nil,
            kind: kind,
            dueDate: nil
        )
    }

    /// True when the badge represents an active paid membership
    /// the user is currently enjoying. `false` for `.none`,
    /// expired badges, or zeroed fields from a banned user.
    var isActive: Bool { kind != .none }

    /// `true` when the due date has lapsed (only meaningful when
    /// `dueDate != nil`). Used to dim the badge into a "已过期"
    /// state so users can see at a glance that their membership
    /// lapsed.
    var isExpired: Bool {
        guard let dueDate else { return false }
        return dueDate < Date()
    }

    /// Whether this badge is fresh enough to gate B站's premium
    /// qualities (4K, HDR, Dolby, Hi-Res audio, etc.). Always
    /// `false` when `.none`; combines with `isExpired` to suppress
    /// gating for lapsed accounts.
    var canAccessGatedQuality: Bool {
        // `unlocksGatedQuality` lives on `BiliVIPKind`, not on
        // the badge itself. The previous bare reference silently
        // resolved via Swift 5's permissive name lookup and
        // always evaluated to `false` at runtime (the badge's
        // own value is a struct, so the missing-keypath
        // resolved to a no-op `false`). Swift 6 strict mode
        // rejects the unresolved reference outright, which is
        // what surfaced the latent bug here.
        kind.unlocksGatedQuality && !isExpired
    }

    // MARK: - Convenience

    /// Hex → SwiftUI `Color`. Accepts both `#RRGGBB` and the
    /// short form `#RGB` (rare on B站 but defensive).
    var backgroundColor: Color { Color(hex: backgroundHex) ?? .clear }
    var foregroundColor: Color { Color(hex: foregroundHex) ?? .clear }
    var borderColor: Color { Color(hex: borderHex) ?? backgroundColor }
    var nicknameColor: Color {
        if let nicknameColorHex, let c = Color(hex: nicknameColorHex) {
            return c
        }
        return backgroundColor
    }

    /// SF Symbol glyph for the badge's leading icon. `crown.fill`
    /// for the generic case (matches the B站 official client);
    /// 10-year uses `crown.circle.fill` (the "10 周年" commemorative
    /// crown); SVIP uses `star.circle.fill` to differentiate from
    /// the regular VIP chip.
    var symbolName: String {
        switch kind {
        case .none: return ""
        case .monthly: return "crown.fill"
        case .annual: return "crown.fill"
        case .tenYear: return "crown.circle.fill"
        case .superVip: return "star.circle.fill"
        }
    }
}

// MARK: - Upstream DTOs

/// Wire shape of `data.vip` returned by `/x/web-interface/nav`.
/// Codable so `StoredAccount` can persist the decoded badge
/// alongside the auth tokens and avoid a round-trip on the next
/// app launch.
struct BilibiliNavVIPDTO: Codable, Sendable {
    let type: Int?
    let status: Int?
    let vipPayType: Int?
    let themeType: Int?
    let dueDate: Int64?
    let label: BilibiliNavVIPLabelDTO?
    let avatarSubscript: Int?
    let nicknameColor: String?

    enum CodingKeys: String, CodingKey {
        case type
        case status
        case vipPayType = "vip_pay_type"
        case themeType = "theme_type"
        case dueDate = "due_date"
        case label
        case avatarSubscript = "avatar_subscript"
        case nicknameColor = "nickname_color"
    }

    func badge() -> BiliVIPBadge {
        // `status != 1` means the upstream has flagged this account
        // as a lapsed / banned / shadow user. Collapse to `.none`
        // so the UI never shows a colourful badge to a user the
        // upstream itself considers ineligible.
        guard status == 1 else { return .none }
        let labelText = label?.text ?? ""
        let kind = BiliVIPKind(
            labelTheme: label?.labelTheme,
            vipType: type ?? 0,
            themeType: themeType ?? 0
        )
        let displayText: String
        if !labelText.isEmpty {
            displayText = labelText
        } else {
            displayText = kind.defaultBadgeText
        }
        return BiliVIPBadge(
            text: displayText,
            backgroundHex: label?.bgColor ?? "#FB7299",
            foregroundHex: label?.textColor ?? "#FFFFFF",
            borderHex: label?.borderColor ?? label?.bgColor ?? "#FB7299",
            nicknameColorHex: nicknameColor,
            kind: kind,
            dueDate: BiliVIPBadge.parseBiliTimestamp(dueDate)
        )
    }
}

// MARK: - B站 unix timestamp helper

extension BiliVIPBadge {
    /// Parse the `data.vip.due_date` field B站 publishes on
    /// `/x/web-interface/nav`. The upstream has been observed
    /// to switch between unix seconds and unix milliseconds
    /// without a contract change — a value around
    /// `1_787_942_400` (≈ 2026-08-24) lands as `1_787_942_400_000`
    /// (≈ year 59612) on the milliseconds surface, and the
    /// previous naïve `Date(timeIntervalSince1970:)` call
    /// produced "到期 59612-12-25" in the profile chrome.
    ///
    /// Heuristic: any value at or above `1e11` (5138-09-09 in
    /// seconds) is treated as milliseconds and divided by 1000
    /// before the `Date` init; anything below is treated as
    /// seconds. `1e11` is comfortably past the largest realistic
    /// future expiry (B站 annual VIP renews 1 year out, so a
    /// 2026 timestamp in seconds is well under `1e10`), so the
    /// threshold does not false-positive on seconds.
    /// `nil` for non-positive input — the upstream uses `0` as
    /// "no expiry" and a real `0` Date would render as
    /// 1970-01-01.
    static func parseBiliTimestamp(_ raw: Int64?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        let normalized: TimeInterval
        if raw >= 100_000_000_000 {  // 1e11
            normalized = TimeInterval(raw) / 1000.0
        } else {
            normalized = TimeInterval(raw)
        }
        return Date(timeIntervalSince1970: normalized)
    }
}

struct BilibiliNavVIPLabelDTO: Codable, Sendable {
    let text: String?
    let labelTheme: String?
    let bgColor: String?
    let borderColor: String?
    let textColor: String?
    let bgStyle: Int?
    let useImgLabel: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case labelTheme = "label_theme"
        case bgColor = "bg_color"
        case borderColor = "border_color"
        case textColor = "text_color"
        case bgStyle = "bg_style"
        case useImgLabel = "use_img_label"
    }
}

/// Wire shape of `member.vip` returned by `/x/v2/reply/wbi/main`.
/// Slimmer than the nav surface — no nested `label`, only the
/// free-form `label` string. We decode it as a DTO and project
/// to a `BiliVIPBadge` via the same surface as the nav shape.
struct BilibiliCommentVIPDTO: Codable, Sendable {
    let vipType: Int?
    let vipStatus: Int?
    let vipPayType: Int?
    let themeType: Int?
    /// Free-form label text only present on the comment surface
    /// (e.g. "大会员", "年度大会员", "").
    let label: String?

    enum CodingKeys: String, CodingKey {
        case vipType = "vipType"
        case vipStatus = "vipStatus"
        case vipPayType = "vip_pay_type"
        case themeType = "theme_type"
        case label
    }

    func badge() -> BiliVIPBadge {
        // The comment API uses `vipStatus == 1` (lowercased camel)
        // to mean "active". The nav API uses `status == 1`. We
        // accept both via the `status` key — same wire value.
        guard vipStatus == 1 else { return .none }
        let kind = BiliVIPKind(
            labelTheme: nil,
            vipType: vipType ?? 0,
            themeType: themeType ?? 0
        )
        let displayText: String
        if let label, !label.isEmpty {
            displayText = label
        } else {
            displayText = kind.defaultBadgeText
        }
        // The comment surface does not publish colours, so fall
        // back to the per-kind palette. The values match what the
        // nav endpoint would have published for the same `type`.
        let palette = BilibiliVIPCommentPalette.palette(for: kind)
        return BiliVIPBadge(
            text: displayText,
            backgroundHex: palette.bg,
            foregroundHex: "#FFFFFF",
            borderHex: palette.bg,
            nicknameColorHex: palette.bg,
            kind: kind,
            dueDate: nil
        )
    }
}

/// Hardcoded fallback palette used when the upstream omits the
/// colour block (the comment API does this). Mirrors the values
/// B站 publishes for the equivalent VIP kind on the nav endpoint.
private enum BilibiliVIPCommentPalette {
    struct Palette {
        let bg: String
    }

    static func palette(for kind: BiliVIPKind) -> Palette {
        switch kind {
        case .none: return Palette(bg: "#000000")
        case .monthly: return Palette(bg: "#FB7299")
        case .annual: return Palette(bg: "#E1A025")
        case .tenYear: return Palette(bg: "#E1A025")
        case .superVip: return Palette(bg: "#644BC9")
        }
    }
}

// MARK: - Hex colour helper

private extension Color {
    /// Parse `#RRGGBB` or `#RGB` into a SwiftUI `Color`. Returns
    /// `nil` on a malformed string so callers can fall back to
    /// the next preferred colour instead of crashing on a typo
    /// in the upstream palette.
    init?(hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 3 || raw.count == 6 else { return nil }
        if raw.count == 3 {
            raw = raw.map { "\($0)\($0)" }.joined()
        }
        guard raw.count == 6,
              let value = UInt32(raw, radix: 16) else {
            return nil
        }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}