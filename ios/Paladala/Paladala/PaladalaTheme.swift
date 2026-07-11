import SwiftUI

/// Top-level design variant. Drives the visual language of the
/// whole app via `PaladalaTheme`'s computed tokens. The two
/// values intentionally model the "old vs new" toggle:
/// - `.streetRedesign` — the hard-edged Street Minimal language
///   introduced in the e03bbbb3 redesign. Default.
/// - `.classic` — the pre-redesign Liquid-Glass-on-system
///   language (corner radius 24, soft glass shadows, system
///   `Color.primary` / `.secondary` foreground, etc.).
///
/// Persisted to `UserDefaults` under `paladala.designVariant` so
/// the user's choice survives relaunch. The `RootView` listens
/// for the change and reapplies it via `PaladalaTheme.apply(_:)`
/// so views re-render against the new token values.
enum DesignVariant: String, CaseIterable, Identifiable, Sendable {
    case classic
    case streetRedesign

    var id: String { rawValue }

    /// User-facing label shown in the Settings toggle.
    var title: String {
        switch self {
        case .classic: "经典 Liquid Glass"
        case .streetRedesign: "街头硬影"
        }
    }

    /// Short blurb shown under the toggle so the user knows what
    /// they're getting.
    var blurb: String {
        switch self {
        case .classic:
            "还原到改版前的视觉:圆角 24、玻璃材质、系统色。"
        case .streetRedesign:
            "当前的硬边极简风格:无圆角、1.5pt 黑边、4pt 实心硬影。"
        }
    }
}

enum PaladalaTheme {
    // MARK: - Active variant
    //
    // `nonisolated(unsafe)` because every read is a value-typed
    // load (Color / CGFloat / Font — atomic on word-sized
    // copies) and the only writer is the settings toggle on
    // the main actor. Swift 6 strict concurrency refuses plain
    // `static var` outside an actor; this is the documented
    // escape hatch for "I know what I'm doing" globals.
    nonisolated(unsafe) static var activeVariant: DesignVariant = .streetRedesign

    /// Apply a new variant. Called from the Settings toggle and
    /// from `PaladalaApp.init` on launch.
    static func apply(_ variant: DesignVariant) {
        activeVariant = variant
    }

    // MARK: - Brand colors (variant-agnostic)
    static let biliPink = Color(red: 1.0, green: 0.38, blue: 0.58) // #FF6194
    static let biliPinkDim = Color(red: 0.70, green: 0.14, blue: 0.35)

    // MARK: - Adaptive ink + paper (variant-aware)
    //
    // The redesign deliberately keeps the palette tiny. `ink` and
    // `paper` invert in dark mode so the same hard-edged hierarchy
    // remains legible without falling back to blur, translucency,
    // or a separate visual language. Pink is a signal color only.
    static var ink: Color {
        switch activeVariant {
        case .streetRedesign:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? .white : .black
            })
        case .classic:
            return .primary
        }
    }
    static var paper: Color {
        switch activeVariant {
        case .streetRedesign:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? .black : .white
            })
        case .classic:
            return Color(uiColor: .systemBackground)
        }
    }
    static var canvas: Color {
        switch activeVariant {
        case .streetRedesign:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.045, green: 0.045, blue: 0.045, alpha: 1)
                    : UIColor(red: 0.976, green: 0.976, blue: 0.976, alpha: 1)
            })
        case .classic:
            return Color.clear
        }
    }
    static var coolGray: Color {
        switch activeVariant {
        case .streetRedesign:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1)
                    : UIColor(red: 0.957, green: 0.957, blue: 0.957, alpha: 1)
            })
        case .classic:
            return Color.primary.opacity(0.055)
        }
    }
    static var mutedInk: Color {
        switch activeVariant {
        case .streetRedesign:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1)
                    : UIColor(red: 0.30, green: 0.27, blue: 0.27, alpha: 1)
            })
        case .classic:
            return .secondary
        }
    }
    static var cyan: Color {
        switch activeVariant {
        case .streetRedesign: return ink
        case .classic: return Color(red: 0.24, green: 0.78, blue: 0.94)
        }
    }
    static var violet: Color {
        switch activeVariant {
        case .streetRedesign: return biliPink
        case .classic: return Color(red: 0.48, green: 0.34, blue: 0.96)
        }
    }

    // MARK: - Geometry (variant-aware)
    static var cornerRadius: CGFloat {
        switch activeVariant {
        case .streetRedesign: return 0
        case .classic: return 24
        }
    }
    static var cardRadius: CGFloat { cornerRadius }
    static var pillRadius: CGFloat { cornerRadius }
    static var heroRadius: CGFloat { cornerRadius }
    static let cornerStyle: RoundedCornerStyle = .continuous
    static var borderWidth: CGFloat {
        switch activeVariant {
        case .streetRedesign: return 1.5
        case .classic: return 0
        }
    }
    static var hairlineWidth: CGFloat {
        switch activeVariant {
        case .streetRedesign: return 1
        case .classic: return 0.5
        }
    }
    static var hardShadowOffset: CGFloat {
        switch activeVariant {
        case .streetRedesign: return 4
        case .classic: return 0
        }
    }
    static var pressedOffset: CGFloat {
        switch activeVariant {
        case .streetRedesign: return 4
        case .classic: return 0
        }
    }
    static var pageBackground: Color {
        switch activeVariant {
        case .streetRedesign: return canvas
        case .classic: return Color.clear
        }
    }
    static var cardBackground: Color {
        switch activeVariant {
        case .streetRedesign: return paper
        case .classic: return Color.primary.opacity(0.055)
        }
    }
    static var glassStroke: Color {
        switch activeVariant {
        case .streetRedesign: return ink
        case .classic: return Color.white.opacity(0.24)
        }
    }
    static var glassShadow: Color {
        switch activeVariant {
        case .streetRedesign: return ink
        case .classic: return Color.black.opacity(0.08)
        }
    }

    // MARK: - Spacing scale (xs … xxxl)
    //
    // Use these in place of `.padding(N)` literals so the design
    // language can be tweaked in one place. Picked from the
    // existing distribution (4, 8, 12, 16, 20, 24, 32) so the
    // eventual migration is a 1-to-1 swap.
    enum Spacing {
        /// 4pt — micro gaps (e.g. dot separator from text)
        static let xs: CGFloat = 4
        /// 8pt — small inline gaps (icon ↔ label)
        static let s: CGFloat = 8
        /// 12pt — section-internal gaps (chip to chip)
        static let m: CGFloat = 12
        /// 16pt — content-to-edge padding (the most common)
        static let l: CGFloat = 16
        /// 20pt — generous horizontal padding (login, onboarding hero)
        static let xl: CGFloat = 20
        /// 24pt — between major sections
        static let xxl: CGFloat = 24
        /// 32pt — screen-edge breathing room
        static let xxxl: CGFloat = 32
        /// 48pt — zine-scale separation between editorial blocks.
        /// Falls back to `xxxl` (32) in the classic variant where
        /// the editorial spacing layer doesn't exist.
        static var display: CGFloat {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return 48
            case .classic: return xxxl
            }
        }

        /// Default content padding (alias of `.l`).
        static let content = l
        /// Default section spacing (alias of `.l`).
        static let section = l
    }

    // MARK: - Semantic color tokens
    //
    // Map common iOS system colors to named roles so the design
    // can be retargeted (e.g. for a "true black" dark mode) in
    // one place. Use these instead of `Color(uiColor: …)` in
    // view files.
    enum SemanticColor {
        /// Filled card / surface — main opaque layer.
        static var card: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return paper
            case .classic: return Color(uiColor: .secondarySystemGroupedBackground)
            }
        }
        /// Subdued surface — list rows, secondary cards.
        static var surface: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return coolGray
            case .classic: return Color(uiColor: .tertiarySystemGroupedBackground)
            }
        }
        /// Hairline border, chip stroke, divider.
        static var stroke: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return ink
            case .classic: return Color.primary.opacity(0.08)
            }
        }
        /// Primary foreground (text, icon) — adaptive to colorScheme.
        static var onSurface: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return ink
            case .classic: return .primary
            }
        }
        /// Muted foreground (subtitles, captions) — adaptive to colorScheme.
        static var onSurfaceMuted: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return mutedInk
            case .classic: return .secondary
            }
        }
        /// Accent — brand pink, used for active states and CTAs.
        static let accent = biliPink
        /// Success (download complete, etc.).
        static var success: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return ink
            case .classic: return .green
            }
        }
        /// Warning (rate-limit, slow network).
        static var warning: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return biliPink
            case .classic: return .orange
            }
        }
        /// Error (network failure, parse failure).
        static var error: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return biliPink
            case .classic: return .red
            }
        }
    }

    // MARK: - Typography roles
    //
    // Centralised font treatments for repeated roles. Use these
    // instead of `.font(.system(size: …))` for the same conceptual
    // element across multiple screens.
    enum FontRole {
        /// Brand/editorial display face. The system rounded face gives Latin
        /// text a geometric silhouette while preserving complete CJK and
        /// Dynamic Type fallback without shipping multi-megabyte web fonts.
        /// In the classic variant, falls back to `.largeTitle` so callers
        /// that adopt the new role don't crash.
        static var displayLarge: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 36, weight: .black, design: .rounded)
            case .classic: return .largeTitle
            }
        }
        static var displayMedium: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 28, weight: .black, design: .rounded)
            case .classic: return .title
            }
        }
        static var headline: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 24, weight: .bold, design: .default)
            case .classic: return .headline
            }
        }
        static var body: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 16, weight: .regular, design: .default)
            case .classic: return .body
            }
        }
        static var bodySmall: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 14, weight: .regular, design: .default)
            case .classic: return .callout
            }
        }
        static var labelMono: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 12, weight: .medium, design: .monospaced)
            case .classic: return .caption2
            }
        }
        /// Card / row title — same weight as a section title but smaller.
        static var cardTitle: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 16, weight: .bold, design: .rounded)
            case .classic: return .headline
            }
        }
        /// Section header in a scroll view — slightly larger.
        static var sectionHeader: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 20, weight: .black, design: .rounded)
            case .classic: return .title3.weight(.semibold)
            }
        }
        /// Large icon for an empty / placeholder state.
        static let emptyStateIcon: Font = .system(size: 56, weight: .light)
        /// Very large hero icon (onboarding).
        static let heroIcon: Font = .system(size: 96, weight: .light)
        /// Live / LIVE badge inside a card.
        static var badge: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 11, weight: .bold, design: .monospaced)
            case .classic: return .caption2.weight(.bold)
            }
        }
        /// Compact monospaced caption (log viewer timestamps).
        static var monospacedCaption: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return labelMono
            case .classic: return .system(.caption2, design: .monospaced)
            }
        }
    }

    // MARK: - Deprecated aliases
    //
    // Kept for source compatibility during the migration. New
    // code should use `PaladalaTheme.Spacing.content` / `.section`.
    @available(*, deprecated, message: "Use PaladalaTheme.Spacing.content")
    static let contentPadding: CGFloat = 16
    @available(*, deprecated, message: "Use PaladalaTheme.Spacing.section")
    static let sectionSpacing: CGFloat = 16
}

/// User-facing light/dark preference. Stored as a raw string in
/// `@AppStorage` so the value survives app upgrades even if we add new
/// cases. Mapped to SwiftUI's `ColorScheme?` at the root.
enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    /// The SwiftUI `ColorScheme?` value for `.preferredColorScheme(...)`.
    /// `nil` means "follow the system" (matches the `.system` case).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Glass material used by the per-view glass modifiers
/// (`.paladalaCardSurface`, nav bars, toolbars). Unrelated to
/// the top-level `DesignVariant` — this is a SwiftUI material
/// choice, not a design language.
enum MaterialDesign: String, CaseIterable, Identifiable {
    case material3
    case liquidGlass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .material3: "Material 3"
        case .liquidGlass: "Liquid Glass"
        }
    }
}

extension Int {
    var compactCount: String {
        if self >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000)
        }
        if self >= 1_000 {
            return String(format: "%.1fK", Double(self) / 1_000)
        }
        return "\(self)"
    }
}

extension Int {
    var mmss: String {
        let minutes = self / 60
        let seconds = self % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension Date {
    /// Compact Chinese relative-time label used on the home
    /// `VideoCard` date row.
    ///
    ///  - "刚刚"  under 1 minute
    ///  - "N 分钟前"  under 1 hour
    ///  - "N 小时前"  under 24 hours
    ///  - "N 天前"    under 30 days
    ///  - "N 周前"    under 12 months
    ///  - "N 个月前"  under 12 months
    ///  - "N 年前"    older
    ///  - "yyyy-MM-dd"  when the date is more than 1 year in
    ///    the past, or any future date (server clock skew)
    ///
    /// `Locale.current` is used so the Chinese labels stay
    /// natural on the iOS 26 zh-Hans / zh-Hant systems the
    /// build targets; English / Japanese / Korean regions get
    /// the same labels in their script as long as the
    /// surrounding chrome is also localised.
    var relativeDateLabel: String {
        let now = Date()
        let delta = now.timeIntervalSince(self)
        // Future date — server clock skew or a scheduled premiere.
        // Fall back to a calendar string so we don't render
        // "刚刚" for a 2099 timestamp.
        if delta < 0 {
            return absoluteDateLabel
        }
        let minute: TimeInterval = 60
        let hour: TimeInterval = 60 * minute
        let day: TimeInterval = 24 * hour
        let week: TimeInterval = 7 * day
        let month: TimeInterval = 30 * day
        let year: TimeInterval = 365 * day
        if delta < minute {
            return "刚刚"
        }
        if delta < hour {
            return "\(Int(delta / minute)) 分钟前"
        }
        if delta < day {
            return "\(Int(delta / hour)) 小时前"
        }
        if delta < week {
            return "\(Int(delta / day)) 天前"
        }
        if delta < month {
            return "\(Int(delta / week)) 周前"
        }
        if delta < year {
            return "\(Int(delta / month)) 个月前"
        }
        return "\(Int(delta / year)) 年前"
    }

    /// `yyyy-MM-dd` short calendar form.  Used for older videos
    /// (over a year ago) and for any future date that the
    /// relative form would mis-render.
    var absoluteDateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }
}
