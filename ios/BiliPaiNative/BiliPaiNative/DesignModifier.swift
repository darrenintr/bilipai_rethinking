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
        cornerRadius: CGFloat = BiliPaiTheme.cardRadius,
        tint: Color? = nil,
        stroke: Color? = nil,
        strokeWidth: CGFloat = 0.5
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: BiliPaiTheme.cornerStyle)

        switch design {
        case .material3:
            self
                .background(tint ?? BiliPaiTheme.cardBackground, in: shape)
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
    /// the on/off feature flags (danmaku, background audio, iCloud,
    /// 今日看什么). `disabled` dims + ignores taps — the iCloud chip
    /// is disabled when the user has no iCloud account signed in.
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
        .foregroundStyle(isSelected ? BiliPaiTheme.biliPink : .primary)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 8)
    }
}
