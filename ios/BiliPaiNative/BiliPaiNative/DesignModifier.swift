import SwiftUI

extension View {
    /// Render a card-like surface using the user's chosen material design.
    ///
    /// Material 3 keeps the standard `secondarySystemGroupedBackground`
    /// surface. Liquid Glass uses `.ultraThinMaterial` plus a faint
    /// pink-tint highlight on top to mimic the iOS 26 `glassEffect`
    /// look on iOS 18 — when the project migrates to the iOS 26 SDK
    /// the `.liquidGlass` branch can swap in `.glassEffect(.regular, in:)` directly.
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
            self.bilipaiGlassSurface(cornerRadius: cornerRadius, tint: BiliPaiTheme.biliPink.opacity(0.06))
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
            self.bilipaiGlassSurface(cornerRadius: BiliPaiTheme.pillRadius, tint: BiliPaiTheme.biliPink.opacity(0.04))
        }
    }

    /// Liquid Glass surface — a real glass-like material on iOS 18.
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
