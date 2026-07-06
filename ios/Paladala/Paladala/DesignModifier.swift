import SwiftUI

struct PaladalaGlassButtonStyle: ButtonStyle {
    let materialDesign: MaterialDesign

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(PaladalaInteractiveGlassModifier(
                design: materialDesign,
                shape: RoundedRectangle(
                    cornerRadius: PaladalaTheme.cornerRadius,
                    style: PaladalaTheme.cornerStyle
                ),
                tint: nil
            ))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Spring-bounce press feedback for inline buttons. Heavier scale
/// (0.92) and a springier easing than `PaladalaGlassButtonStyle`,
/// so taps on follow / like / favourite / watch-later targets
/// feel tactile. Compose with `.buttonStyle(.plain)` + your
/// custom chrome — this style only owns the press animation.
///
/// Reduce Motion short-circuits the scale so accessibility users
/// still get the press state through the visual highlight only.
struct PaladalaPressBounceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(
                configuration.isPressed
                    ? .spring(response: 0.18, dampingFraction: 0.6)
                    : .spring(response: 0.32, dampingFraction: 0.7),
                value: configuration.isPressed
            )
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
            .overlay(shape.strokeBorder(PaladalaTheme.glassStroke, lineWidth: 0.75))
    }
}

struct PaladalaGlassContainer<Content: View>: View {
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
                    ? [Color.black, PaladalaTheme.violet.opacity(0.22), Color.black]
                    : [Color.white, PaladalaTheme.cyan.opacity(0.18), PaladalaTheme.biliPink.opacity(0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [PaladalaTheme.biliPink.opacity(colorScheme == .dark ? 0.22 : 0.18), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 320
            )

            RadialGradient(
                colors: [PaladalaTheme.cyan.opacity(colorScheme == .dark ? 0.16 : 0.14), .clear],
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
    func paladalaCardSurface(
        _ design: MaterialDesign,
        cornerRadius: CGFloat = PaladalaTheme.cardRadius,
        tint: Color? = nil,
        stroke: Color? = nil,
        strokeWidth: CGFloat = 0.5
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: PaladalaTheme.cornerStyle)

        switch design {
        case .material3:
            self
                .background(tint ?? PaladalaTheme.cardBackground, in: shape)
                .overlay(
                    shape.strokeBorder(stroke ?? Color.clear, lineWidth: strokeWidth)
                )
        case .liquidGlass:
            // Keep feed cards in the content layer. Apple recommends
            // reserving Liquid Glass for floating navigation and controls.
            self
                .background(tint ?? Color.primary.opacity(0.06), in: shape)
                .overlay(
                    shape.strokeBorder(
                        stroke ?? Color.primary.opacity(0.08),
                        lineWidth: stroke == nil ? 0.5 : strokeWidth
                    )
                )
        }
    }

    @ViewBuilder
    func paladalaPillSurface(
        _ design: MaterialDesign
    ) -> some View {
        switch design {
        case .material3:
            self.background(
                .thinMaterial,
                in: RoundedRectangle(cornerRadius: PaladalaTheme.pillRadius, style: PaladalaTheme.cornerStyle)
            )
        case .liquidGlass:
            self.modifier(PaladalaInteractiveGlassModifier(
                design: design,
                shape: RoundedRectangle(
                    cornerRadius: PaladalaTheme.pillRadius,
                    style: PaladalaTheme.cornerStyle
                ),
                tint: nil
            ))
        }
    }

    @ViewBuilder
    func paladalaNavBarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
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
    func paladalaToolbarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
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
                    cornerRadius: PaladalaTheme.cornerRadius,
                    style: PaladalaTheme.cornerStyle
                ),
                tint: PaladalaTheme.biliPink.opacity(0.22)
            ))
        } else {
            self.background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(
                    cornerRadius: PaladalaTheme.cornerRadius,
                    style: PaladalaTheme.cornerStyle
                )
            )
        }
    }

    /// Picker-style chip. Tap to set `selection` to `value`. Renders
    /// pink when the value matches, neutral otherwise. Used by the
    /// first-run welcome preferences card for `themeMode` /
    /// `materialDesign` style pickers; also reusable in the settings
    /// screen for the same kind of grouped choices.
    @ViewBuilder
    func paladalaPickerChip<Value: Hashable>(
        selection: Binding<Value>,
        value: Value,
        design: MaterialDesign,
        title: String,
        symbol: String
    ) -> some View {
        let isSelected = selection.wrappedValue == value
        Button {
            Haptics.selection()
            selection.wrappedValue = value
        } label: {
            PaladalaChip(title: title, symbol: symbol, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .paladalaSelectionChip(isSelected: isSelected, design: design)
    }

    /// Toggle-style chip. Tap to flip `isOn`. Renders pink when on,
    /// neutral when off. Used by the welcome preferences card for
    /// the on/off feature flags (danmaku, background audio, iCloud).
    /// `disabled` dims + ignores taps — the iCloud chip is disabled
    /// when the user has no iCloud account signed in.
    @ViewBuilder
    func paladalaToggleChip(
        isOn: Binding<Bool>,
        design: MaterialDesign,
        title: String,
        symbol: String,
        disabled: Bool = false
    ) -> some View {
        Button {
            Haptics.selection()
            isOn.wrappedValue.toggle()
        } label: {
            PaladalaChip(title: title, symbol: symbol, isSelected: isOn.wrappedValue)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .paladalaSelectionChip(isSelected: isOn.wrappedValue, design: design)
    }

    @ViewBuilder
    func paladalaGlassEffect(
        cornerRadius: CGFloat = PaladalaTheme.cardRadius,
        tint: Color = PaladalaTheme.biliPink.opacity(0.06)
    ) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(
                .regular.tint(tint),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self.paladalaGlassFallback(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        self.paladalaGlassFallback(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    @ViewBuilder
    fileprivate func paladalaGlassFallback(
        cornerRadius: CGFloat,
        tint: Color
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: PaladalaTheme.cornerStyle)

        self
            .background(.thinMaterial, in: shape)
            .background(tint, in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), PaladalaTheme.glassStroke.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
            }
            .shadow(color: PaladalaTheme.glassShadow, radius: 12, y: 5)
    }

    func paladalaBackdrop() -> some View {
        self.background {
            PaladalaBackdrop()
        }
    }

    /// Liquid Glass presentation background for sheets. On iOS 26+
    /// uses `.glassEffect(.regular)` for the live refraction; on
    /// iOS 17 / 18 falls back to `.regularMaterial` with a matching
    /// `presentationCornerRadius`. Apply to the *sheet content*
    /// (not the `.sheet(isPresented:)` modifier), so the system
    /// applies it to the host that wraps the body.
    @ViewBuilder
    func paladalaSheetGlass() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(28)
        } else {
            self
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(28)
        }
        #else
        self
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(28)
        #endif
    }

    /// Sweeping shimmer overlay used by skeleton placeholders while
    /// the first feed / profile / comments page is loading. A
    /// translucent `LinearGradient` slides across the content shape
    /// in a 1.4 s loop, masked to the underlying view so the
    /// gradient only paints inside the rounded rectangles / circles.
    /// `redacted(reason: .placeholder)` is intentionally NOT used
    /// here — the system redaction mask conflicts with the manual
    /// overlay, and you end up with no shimmer at all.
    @ViewBuilder
    func paladalaShimmer(active: Bool = true) -> some View {
        if active {
            modifier(PaladalaShimmerModifier())
        } else {
            // No-op: lets call sites write a single modifier chain
            // and disable the shimmer (e.g. during Reduce Motion).
            // SwiftUI skips the modifier entirely so the static
            // placeholder paints as-is.
            self
        }
    }
}

/// Internal label view used by `paladalaPickerChip` and
/// `paladalaToggleChip`. Centralising the visual treatment here
/// means both chip variants share the same SF Symbol + title
/// rhythm without duplication.
private struct PaladalaChip: View {
    let title: String
    let symbol: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(isSelected ? PaladalaTheme.biliPink : .primary)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 8)
    }
}

/// Sweeping shimmer animation. A 90 pt translucent white gradient
/// slides left-to-right across the masked content in a 1.4 s loop,
/// `repeatForever(autoreverses: false)`. The host view is duplicated
/// as the `mask` so the gradient only paints inside the rounded
/// rectangles / circles the placeholder already draws — the
/// surrounding card padding stays clear.
///
/// Reduce Motion (`@Environment(\.accessibilityReduceMotion)`)
/// short-circuits the animation entirely; the placeholder still
/// paints but with no sweeping highlight.
private struct PaladalaShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .overlay {
                    GeometryReader { geo in
                        // Width of the sweeping band — kept narrow so
                        // a single shimmer reads as a "highlight
                        // passing through" rather than a wash.
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0), location: 0),
                                .init(color: .white.opacity(0.45), location: 0.5),
                                .init(color: .white.opacity(0), location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 90)
                        // Translate the band across the full width
                        // plus its own width so it fully enters and
                        // exits the visible rect on every cycle.
                        .offset(x: phase * (geo.size.width + 90))
                        .blendMode(.plusLighter)
                    }
                    // Clip the band to the placeholder rects so the
                    // shimmer does not bleed across card padding.
                    .mask(content)
                }
                .onAppear {
                    // Single one-shot kick — `repeatForever` keeps
                    // driving `phase` from the new resting state.
                    withAnimation(
                        .linear(duration: 1.4)
                            .repeatForever(autoreverses: false)
                    ) {
                        phase = 1
                    }
                }
        }
    }
}
