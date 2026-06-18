import SwiftUI

enum BiliPaiTheme {
    static let biliPink = Color(red: 1.0, green: 0.38, blue: 0.58)
    static let biliPinkDim = Color(red: 0.88, green: 0.24, blue: 0.48)
    static let cyan = Color(red: 0.24, green: 0.78, blue: 0.94)
    static let violet = Color(red: 0.48, green: 0.34, blue: 0.96)
    static let cardRadius: CGFloat = 24
    static let pillRadius: CGFloat = 16
    static let heroRadius: CGFloat = 32
    static let cornerStyle: RoundedCornerStyle = .continuous
    static let pageBackground = Color.clear
    static let cardBackground = Color.primary.opacity(0.055)
    static let contentPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
    static let glassStroke = Color.white.opacity(0.24)
    static let glassShadow = Color.black.opacity(0.08)
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
