import SwiftUI

// MARK: - Glass Button Style

/// A glass button style inspired by Apple's Liquid Glass `.buttonStyle(.glass)`.
/// In Liquid Glass mode it renders a translucent glass capsule; in Material 3
/// mode it falls back to `.bordered`.
struct BiliPaiGlassButtonStyle: ButtonStyle {
    let materialDesign: MaterialDesign

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                if materialDesign == .liquidGlass {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.18), .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Glass Container

/// Coordinates multiple glass elements for synchronized rendering, similar to
/// Apple's `GlassEffectContainer`. Wraps content in a unified glass region.
/// When the iOS 26 SDK is available, swap the fallback for the real
/// `GlassEffectContainer` + `.glassEffect(.regular, in:)`.
struct BiliPaiGlassContainer<Content: View>: View {
    let materialDesign: MaterialDesign
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        // The iOS 18.5 SDK does not include GlassEffectContainer or
        // .glassEffect — the 4-layer bilipaiGlassSurface composite
        // handles the visual. When the iOS 26 SDK ships, wrap this
        // in GlassEffectContainer and apply .glassEffect to each child.
        content()
    }
}

// MARK: - View Extensions

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

    /// Apply the Liquid Glass navigation bar background. Uses
    /// `.ultraThinMaterial` on iOS 18+ (the real `.toolbarBackground(.glass)`
    /// API is not available in the iOS 18.5 SDK — swap in when the iOS 26
    /// SDK ships).
    @ViewBuilder
    func bilipaiNavBarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
        switch design {
        case .material3:
            self
        case .liquidGlass:
            // The iOS 18.5 SDK does not include .toolbarBackground(.glass).
            // Use .ultraThinMaterial as the fallback. When the iOS 26 SDK
            // ships, replace with .toolbarBackground(.glass, for: .navigationBar).
            self.toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    /// Apply glass material to the toolbar area.
    @ViewBuilder
    func bilipaiToolbarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
        switch design {
        case .material3:
            self
        case .liquidGlass:
            self.toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }

    /// Apply the system glass effect. On iOS 26+ uses `.glassEffect(.regular, in:)`.
    /// Falls back to the custom 4-layer composite on iOS 18.
    @ViewBuilder
    func bilipaiGlassEffect(
        cornerRadius: CGFloat = BiliPaiTheme.cardRadius,
        tint: Color = BiliPaiTheme.biliPink.opacity(0.06)
    ) -> some View {
        // The iOS 18.5 SDK does not include .glassEffect — use the
        // 4-layer composite. When the iOS 26 SDK ships, gate with
        // if #available(iOS 26, *) and call .glassEffect(.regular, in:).
        self.bilipaiGlassSurface(cornerRadius: cornerRadius, tint: tint)
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
