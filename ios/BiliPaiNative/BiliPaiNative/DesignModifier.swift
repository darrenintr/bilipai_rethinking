import SwiftUI

struct BiliPaiGlassButtonStyle: ButtonStyle {
    let materialDesign: MaterialDesign

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(PaladalaInteractiveGlassModifier(
                design: materialDesign,
                shape: RoundedRectangle(
                    cornerRadius: BiliPaiTheme.cornerRadius,
                    style: BiliPaiTheme.cornerStyle
                ),
                tint: nil
            ))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PaladalaInteractiveGlassModifier<S: InsettableShape>: ViewModifier {
    let design: MaterialDesign
    let shape: S
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        switch design {
        case .material3:
            fallback(content)
        case .liquidGlass:
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                if let tint {
                    content.glassEffect(.regular.tint(tint).interactive(), in: shape)
                } else {
                    content.glassEffect(.regular.interactive(), in: shape)
                }
            } else {
                fallback(content)
            }
            #else
            fallback(content)
            #endif
        }
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.thinMaterial, in: shape)
            .overlay(shape.strokeBorder(BiliPaiTheme.glassStroke, lineWidth: 0.75))
    }
}

struct BiliPaiGlassContainer<Content: View>: View {
    let materialDesign: MaterialDesign
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct PaladalaBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.black, BiliPaiTheme.violet.opacity(0.22), Color.black]
                    : [Color.white, BiliPaiTheme.cyan.opacity(0.18), BiliPaiTheme.biliPink.opacity(0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [BiliPaiTheme.biliPink.opacity(colorScheme == .dark ? 0.22 : 0.18), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 320
            )

            RadialGradient(
                colors: [BiliPaiTheme.cyan.opacity(colorScheme == .dark ? 0.16 : 0.14), .clear],
                center: .bottomLeading,
                startRadius: 30,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder
    func bilipaiCardSurface(
        _ design: MaterialDesign,
        cornerRadius: CGFloat = BiliPaiTheme.cardRadius
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: BiliPaiTheme.cornerStyle)

        switch design {
        case .material3:
            self.background(BiliPaiTheme.cardBackground, in: shape)
        case .liquidGlass:
            // Keep feed cards in the content layer. Apple recommends
            // reserving Liquid Glass for floating navigation and controls.
            self
                .background(Color.primary.opacity(0.06), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

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
            self.modifier(PaladalaInteractiveGlassModifier(
                design: design,
                shape: RoundedRectangle(
                    cornerRadius: BiliPaiTheme.pillRadius,
                    style: BiliPaiTheme.cornerStyle
                ),
                tint: nil
            ))
        }
    }

    @ViewBuilder
    func bilipaiNavBarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
        switch design {
        case .material3:
            self
        case .liquidGlass:
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                self
            } else {
                self.toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
            #else
            self.toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
    }

    @ViewBuilder
    func bilipaiToolbarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
        switch design {
        case .material3:
            self
        case .liquidGlass:
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                self
            } else {
                self.toolbarBackground(.ultraThinMaterial, for: .tabBar)
                    .toolbarBackground(.visible, for: .tabBar)
            }
            #else
            self.toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            #endif
        }
    }

    @ViewBuilder
    func paladalaTabBarBehavior() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func paladalaSelectionChip(
        isSelected: Bool,
        design: MaterialDesign
    ) -> some View {
        if isSelected {
            self.modifier(PaladalaInteractiveGlassModifier(
                design: design,
                shape: RoundedRectangle(
                    cornerRadius: BiliPaiTheme.cornerRadius,
                    style: BiliPaiTheme.cornerStyle
                ),
                tint: BiliPaiTheme.biliPink.opacity(0.22)
            ))
        } else {
            self.background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(
                    cornerRadius: BiliPaiTheme.cornerRadius,
                    style: BiliPaiTheme.cornerStyle
                )
            )
        }
    }

    @ViewBuilder
    func bilipaiGlassEffect(
        cornerRadius: CGFloat = BiliPaiTheme.cardRadius,
        tint: Color = BiliPaiTheme.biliPink.opacity(0.06)
    ) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(
                .regular.tint(tint),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self.bilipaiGlassFallback(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        self.bilipaiGlassFallback(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    @ViewBuilder
    fileprivate func bilipaiGlassFallback(
        cornerRadius: CGFloat,
        tint: Color
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: BiliPaiTheme.cornerStyle)

        self
            .background(.thinMaterial, in: shape)
            .background(tint, in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), BiliPaiTheme.glassStroke.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
            }
            .shadow(color: BiliPaiTheme.glassShadow, radius: 12, y: 5)
    }

    func paladalaBackdrop() -> some View {
        self.background {
            PaladalaBackdrop()
        }
    }
}
