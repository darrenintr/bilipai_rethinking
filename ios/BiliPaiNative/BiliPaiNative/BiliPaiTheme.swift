import SwiftUI

enum BiliPaiTheme {
    static let biliPink = Color(red: 250 / 255, green: 114 / 255, blue: 152 / 255)
    static let biliPinkDim = Color(red: 230 / 255, green: 104 / 255, blue: 140 / 255)
    static let cardRadius: CGFloat = 8
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
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
