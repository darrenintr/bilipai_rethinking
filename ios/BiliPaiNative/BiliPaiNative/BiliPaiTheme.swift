import SwiftUI

enum BiliPaiTheme {
    static let biliPink = Color(red: 250 / 255, green: 114 / 255, blue: 152 / 255)
    static let biliPinkDim = Color(red: 230 / 255, green: 104 / 255, blue: 140 / 255)
    /// Default card / sheet / banner corner radius. Increased from 8
    /// → 18 so the iOS UI reads as rounder and matches the "more
    /// rounded" user-facing direction.
    static let cardRadius: CGFloat = 18
    /// Tight pill radius for inline chips, badges, search bar caps.
    static let pillRadius: CGFloat = 12
    /// Soft hero radius for big surfaces (login QR card, full-screen
    /// modals). Continuous corners are applied at the call sites.
    static let heroRadius: CGFloat = 28
    /// Default shape style for rounded rectangles. Use this at every
    /// `RoundedRectangle(cornerRadius:style:)` site for consistency.
    static let cornerStyle: RoundedCornerStyle = .continuous
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
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

/// User-facing design language. `.material3` keeps the current
/// `.secondarySystemGroupedBackground` surfaces and the `.thinMaterial`
/// search bar. `.liquidGlass` swaps the same surfaces for the iOS 26+
/// `.glassEffect(...)` material so users on iOS 26+ can preview the new
/// look without a separate app build.
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

