import SwiftUI

extension View {
    /// Render a card-like surface using the user's chosen material design.
    ///
    /// Material 3 keeps the standard `secondarySystemGroupedBackground`
    /// surface. Liquid Glass uses the real iOS 26 `glassEffect` when
    /// available, falling back to a layered `.ultraThinMaterial`
    /// composite on iOS 18 (the unsigned-IPA workflow ships with
    /// Xcode 16 / iOS 18.5 SDK).  The `MaterialDesign` enum is keyed
    /// off `@AppStorage("bilipai.materialDesign")` so the user's
    /// preference survives relaunch.
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
            if #available(iOS 26, *) {
                self.bilipaiCardGlassSurface(cornerRadius: cornerRadius)
            } else {
                self.bilipaiGlassSurface(cornerRadius: cornerRadius, tint: BiliPaiTheme.biliPink.opacity(0.06))
            }
        }
    }

    /// Same as `bilipaiCardSurface(_:)` but for the search bar and other
    /// pill-shaped controls. Uses the new `pillRadius` (12) cap so the
    /// pill reads as rounder than the card surfaces. The
    /// `.regular.interactive()` glass variant picks up the system
    /// highlight on iOS 26+ — useful for the search bar so the user
    /// gets visual feedback when the field is tapped.
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
            if #available(iOS 26, *) {
                self.glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle)
                )
            } else {
                self.bilipaiGlassSurface(cornerRadius: BiliPaiTheme.pillRadius, tint: BiliPaiTheme.biliPink.opacity(0.04))
            }
        }
    }

    /// Apply the Liquid Glass navigation bar background on iOS 26+.
    /// The iOS 18 toolchain does not have `.toolbarBackground(.glass, ...)`,
    /// so on older OS the modifier is a no-op and the system default
    /// nav bar is left in place.
    @ViewBuilder
    func bilipaiNavBarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
        if design == .liquidGlass, #available(iOS 26, *) {
            self.toolbarBackground(.glass, for: .navigationBar)
        } else {
            self
        }
    }

    /// iOS 26+ real glass effect for card surfaces. The
    /// `RoundedRectangle` shape is the same one the iOS 18 fallback
    /// uses, so the two code paths produce visually comparable
    /// outlines.
    @available(iOS 26, *)
    fileprivate func bilipaiCardGlassSurface(cornerRadius: CGFloat) -> some View {
        self.glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: BiliPaiTheme.cornerStyle)
        )
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
