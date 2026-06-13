import SwiftUI

extension View {
    /// Render a card-like surface using the user's chosen material design.
    ///
    /// `.material3` keeps the existing `BiliPaiTheme.cardBackground`
    /// (a `secondarySystemGroupedBackground` rounded rectangle). The
    /// `.liquidGlass` case replaces it with the iOS 26+
    /// `.glassEffect(.regular, in: .rect(cornerRadius:))` modifier so the
    /// surface picks up the new frosted / refractive material.
    @ViewBuilder
    func bilipaiCardSurface(
        _ design: MaterialDesign,
        cornerRadius: CGFloat = BiliPaiTheme.cardRadius
    ) -> some View {
        switch design {
        case .material3:
            self.background(
                BiliPaiTheme.cardBackground,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
        case .liquidGlass:
            if #available(iOS 26.0, *) {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            } else {
                // iOS 17 / 18 fallback: a thin material with the same
                // corner radius is the closest visual approximation that
                // compiles against the current SDK. Users on iOS 26+
                // still get the real Liquid Glass material.
                self.background(
                    .thinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
            }
        }
    }

    /// Same as `bilipaiCardSurface(_:)` but for the search bar and other
    /// pill-shaped controls. The default corner radius is the full pill
    /// (`Capsule`).
    @ViewBuilder
    func bilipaiPillSurface(
        _ design: MaterialDesign
    ) -> some View {
        switch design {
        case .material3:
            self.background(.thinMaterial, in: Capsule())
        case .liquidGlass:
            if #available(iOS 26.0, *) {
                self.glassEffect(.regular, in: .capsule)
            } else {
                self.background(.thinMaterial, in: Capsule())
            }
        }
    }
}
