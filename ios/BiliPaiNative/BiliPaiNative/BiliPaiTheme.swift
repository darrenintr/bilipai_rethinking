import SwiftUI

enum BiliPaiTheme {
    // MARK: - Brand colors
    static let biliPink = Color(red: 1.0, green: 0.38, blue: 0.58)
    static let biliPinkDim = Color(red: 0.88, green: 0.24, blue: 0.48)
    static let cyan = Color(red: 0.24, green: 0.78, blue: 0.94)
    static let violet = Color(red: 0.48, green: 0.34, blue: 0.96)
    static let cornerRadius: CGFloat = 24
    static let cardRadius = cornerRadius
    static let pillRadius = cornerRadius
    static let heroRadius = cornerRadius
    static let cornerStyle: RoundedCornerStyle = .continuous
    static let pageBackground = Color.clear
    static let cardBackground = Color.primary.opacity(0.055)
    static let glassStroke = Color.white.opacity(0.24)
    static let glassShadow = Color.black.opacity(0.08)

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
        static let card = Color(uiColor: .secondarySystemGroupedBackground)
        /// Subdued surface — list rows, secondary cards.
        static let surface = Color(uiColor: .tertiarySystemGroupedBackground)
        /// Hairline border, chip stroke, divider.
        static let stroke = Color.primary.opacity(0.08)
        /// Primary foreground (text, icon) — adaptive to colorScheme.
        static let onSurface = Color.primary
        /// Muted foreground (subtitles, captions) — adaptive to colorScheme.
        static let onSurfaceMuted = Color.secondary
        /// Accent — brand pink, used for active states and CTAs.
        static let accent = biliPink
        /// Success (download complete, etc.).
        static let success = Color.green
        /// Warning (rate-limit, slow network).
        static let warning = Color.orange
        /// Error (network failure, parse failure).
        static let error = Color.red
    }

    // MARK: - Typography roles
    //
    // Centralised font treatments for repeated roles. Use these
    // instead of `.font(.system(size: …))` for the same conceptual
    // element across multiple screens.
    enum FontRole {
        /// Card / row title — same weight as a section title but smaller.
        static let cardTitle: Font = .headline
        /// Section header in a scroll view — slightly larger.
        static let sectionHeader: Font = .title3.weight(.semibold)
        /// Large icon for an empty / placeholder state.
        static let emptyStateIcon: Font = .system(size: 56, weight: .light)
        /// Very large hero icon (onboarding).
        static let heroIcon: Font = .system(size: 96, weight: .light)
        /// Live / LIVE badge inside a card.
        static let badge: Font = .caption2.weight(.bold)
        /// Compact monospaced caption (log viewer timestamps).
        static let monospacedCaption: Font = .system(.caption2, design: .monospaced)
    }

    // MARK: - Deprecated aliases
    //
    // Kept for source compatibility during the migration. New
    // code should use `BiliPaiTheme.Spacing.content` / `.section`.
    @available(*, deprecated, message: "Use BiliPaiTheme.Spacing.content")
    static let contentPadding: CGFloat = 16
    @available(*, deprecated, message: "Use BiliPaiTheme.Spacing.section")
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

enum MaterialDesign: String, CaseIterable, Identifiable {
    case material3
    case liquidGlass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .material3: "高性能简洁"
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
