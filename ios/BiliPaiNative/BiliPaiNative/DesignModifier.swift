import SwiftUI

extension View {
    /// Render a card-like surface using the user's chosen material design.
    ///
    /// Material 3 keeps the standard `secondarySystemGroupedBackground`
    /// surface. Liquid Glass uses a layered `.ultraThinMaterial`
    /// composite — the unsigned-IPA workflow ships with Xcode 16 /
    /// iOS 18.5 SDK, which does not include the iOS 26 `glassEffect`
    /// API. When the build environment catches up to the iOS 26 SDK
    /// we'll swap the fallback in for the real `glassEffect` here
    /// and in `bilipaiPillSurface`. The `MaterialDesign` enum is
    /// keyed off `@AppStorage("bilipai.materialDesign")` so the
    /// user's preference survives relaunch.
    @ViewBuilder
    func bilipaiCardSurface(
        _ design: MaterialDesign,
        cornerRadius: CGFloat = BiliPaiTheme.cardRadius
    ) -> some View {
        switch design {
        case .material3:
            self.background(
                BiliPaiTheme.cardBackground,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: BiliPaiTheme.cornerStyle)
            )
        case .liquidGlass:
            self.bilipaiGlassSurface(
                cornerRadius: cornerRadius,
                tint: BiliPaiTheme.biliPink.opacity(0.06)
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
        case .material3:
            self.background(
                .thinMaterial,
                in: RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle)
            )
        case .liquidGlass:
            self.bilipaiGlassSurface(
                cornerRadius: BiliPaiTheme.pillRadius,
                tint: BiliPaiTheme.biliPink.opacity(0.04)
            )
        }
    }

    /// Apply the Liquid Glass navigation bar background. On the
    /// unsigned-IPA workflow the iOS 26 `.toolbarBackground(.glass)`
    /// API is not available, so this is a no-op — the system default
    /// nav bar is left in place. When the iOS 26 SDK is wired up
    /// we'll gate the real API behind `if #available(iOS 26, *)`
    /// inside this method.
    @ViewBuilder
    func bilipaiNavBarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
        // iOS 18 toolchain does not have `.toolbarBackground(.glass, ...)`;
        // intentionally a no-op until the build environment ships with
        // the iOS 26 SDK.
        self
    }

    /// Liquid Glass surface — a layered composite that reads as
    /// glass-like on iOS 18 (and degrades gracefully on older OS).
    /// Layered:
    /// 1. `.ultraThinMaterial` (real system blur that reads the wallpaper / content behind)
    /// 2. A faint top-edge highlight (mimics the iOS 26 glass refraction line)
    /// 3. A soft tint overlay (mimics the iOS 26 glass color tint)
    /// 4. A hairline border (mimics the iOS 26 glass edge stroke)
    @ViewBuilder
    fileprivate func bilipaiGlassSurface(
        cornerRadius: CGFloat,
        tint: Color
    ) -> some View {
        self.background {
            ZStack {
                // Base glass blur — picks up whatever is behind.
                RoundedRectangle(cornerRadius: cornerRadius, style: BiliPaiTheme.cornerStyle)
                    .fill(.ultraThinMaterial)
                // Top edge highlight: a vertical gradient that is
                // brightest at the top edge and fades downward,
                // suggesting refraction along the glass surface.
                RoundedRectangle(cornerRadius: cornerRadius, style: BiliPaiTheme.cornerStyle)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .blendMode(.plusLighter)
                // Faint pink tint so the BiliPai identity comes through
                // the glass without making the surface look opaque.
                RoundedRectangle(cornerRadius: cornerRadius, style: BiliPaiTheme.cornerStyle)
                    .fill(tint)
                // Hairline border — the iOS 26 glass edge stroke.
                RoundedRectangle(cornerRadius: cornerRadius, style: BiliPaiTheme.cornerStyle)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.6),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
        }
    }
}
