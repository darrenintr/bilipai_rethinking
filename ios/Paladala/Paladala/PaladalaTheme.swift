import SwiftUI

enum PaladalaTheme {
    // MARK: - Street Minimal palette
    //
    // The redesign deliberately keeps the palette tiny. `ink` and
    // `paper` invert in dark mode so the same hard-edged hierarchy remains
    // legible without falling back to blur, translucency, or a separate
    // visual language. Pink is a signal color only: active controls, live
    // state, and primary calls to action.
    static let biliPink = Color(red: 1.0, green: 0.38, blue: 0.58) // #FF6194
    static let biliPinkDim = Color(red: 0.70, green: 0.14, blue: 0.35)
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : .black
    })
    static let paper = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.045, blue: 0.045, alpha: 1)
            : UIColor(red: 0.976, green: 0.976, blue: 0.976, alpha: 1)
    })
    static let coolGray = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1)
            : UIColor(red: 0.957, green: 0.957, blue: 0.957, alpha: 1)
    })
    static let mutedInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1)
            : UIColor(red: 0.30, green: 0.27, blue: 0.27, alpha: 1)
    })

    // Compatibility accents kept for API consumers. They intentionally map
    // back into the constrained Street palette instead of introducing extra
    // hues into the interface.
    static let cyan = ink
    static let violet = biliPink

    // MARK: - Geometry
    static let cornerRadius: CGFloat = 0
    static let cardRadius = cornerRadius
    static let pillRadius = cornerRadius
    static let heroRadius = cornerRadius
    static let cornerStyle: RoundedCornerStyle = .continuous
    static let borderWidth: CGFloat = 1.5
    static let hairlineWidth: CGFloat = 1
    static let hardShadowOffset: CGFloat = 4
    static let pressedOffset: CGFloat = 4
    static let pageBackground = canvas
    static let cardBackground = paper
    // Deprecated semantic aliases retained while existing call sites migrate.
    static let glassStroke = ink
    static let glassShadow = ink

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
        static let display: CGFloat = 48

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
        static let card = paper
        /// Subdued surface — list rows, secondary cards.
        static let surface = coolGray
        /// Hairline border, chip stroke, divider.
        static let stroke = ink
        /// Primary foreground (text, icon) — adaptive to colorScheme.
        static let onSurface = ink
        /// Muted foreground (subtitles, captions) — adaptive to colorScheme.
        static let onSurfaceMuted = mutedInk
        /// Accent — brand pink, used for active states and CTAs.
        static let accent = biliPink
        /// Success (download complete, etc.).
        static let success = ink
        /// Warning (rate-limit, slow network).
        static let warning = biliPink
        /// Error (network failure, parse failure).
        static let error = biliPink
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
        static let displayLarge: Font = .system(size: 36, weight: .black, design: .rounded)
        static let displayMedium: Font = .system(size: 28, weight: .black, design: .rounded)
        static let headline: Font = .system(size: 24, weight: .bold, design: .default)
        static let body: Font = .system(size: 16, weight: .regular, design: .default)
        static let bodySmall: Font = .system(size: 14, weight: .regular, design: .default)
        static let labelMono: Font = .system(size: 12, weight: .medium, design: .monospaced)
        /// Card / row title — same weight as a section title but smaller.
        static let cardTitle: Font = .system(size: 16, weight: .bold, design: .rounded)
        /// Section header in a scroll view — slightly larger.
        static let sectionHeader: Font = .system(size: 20, weight: .black, design: .rounded)
        /// Large icon for an empty / placeholder state.
        static let emptyStateIcon: Font = .system(size: 56, weight: .light)
        /// Very large hero icon (onboarding).
        static let heroIcon: Font = .system(size: 96, weight: .light)
        /// Live / LIVE badge inside a card.
        static let badge: Font = .system(size: 11, weight: .bold, design: .monospaced)
        /// Compact monospaced caption (log viewer timestamps).
        static let monospacedCaption: Font = labelMono
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

enum MaterialDesign: String, CaseIterable, Identifiable {
    case material3
    case liquidGlass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .material3: "街头极简"
        case .liquidGlass: "街头硬影"
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
