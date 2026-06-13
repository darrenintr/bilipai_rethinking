import SwiftUI

extension View {
    /// Render a card-like surface using the user's chosen material design.
    ///
    /// Both `.material3` and `.liquidGlass` map to the same `cardBackground`
    /// surface today because the iOS 26 `.glassEffect(...)` API is not in
    /// the iOS 18.5 SDK that ships with the current Xcode release used by
    /// the unsigned-IPA workflow. When the project migrates to the iOS 26
    /// SDK the `.liquidGlass` branch can swap `.cardBackground` for
    /// `.glassEffect(.regular, in: .rect(cornerRadius:))` directly — the
    /// picker / @AppStorage plumbing does not have to change.
    @ViewBuilder
    func bilipaiCardSurface(
        _ design: MaterialDesign,
        cornerRadius: CGFloat = BiliPaiTheme.cardRadius
    ) -> some View {
        // The `design` parameter is intentionally accepted but currently
        // ignored — the Liquid Glass preset resolves to the same surface
        // until the iOS 26 SDK is in the toolchain. Keeping the parameter
        // means callers do not have to change when the real branch lands.
        switch design {
        case .material3, .liquidGlass:
            self.background(
                BiliPaiTheme.cardBackground,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: BiliPaiTheme.cornerStyle)
            )
        }
    }

    /// Same as `bilipaiCardSurface(_:)` but for the search bar and other
    /// pill-shaped controls. Uses the new `pillRadius` (12) cap so the
    /// pill reads as rounder than the card surfaces.
    @ViewBuilder
    func bilipaiPillSurface(
        _ design: MaterialDesign
    ) -> some View {
        switch design {
        case .material3, .liquidGlass:
            self.background(
                .thinMaterial,
                in: RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle)
            )
        }
    }
}
