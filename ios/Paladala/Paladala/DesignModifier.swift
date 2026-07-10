import SwiftUI

struct PaladalaGlassButtonStyle: ButtonStyle {
    let materialDesign: MaterialDesign
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PaladalaTheme.FontRole.labelMono)
            .textCase(.uppercase)
            .foregroundStyle(PaladalaTheme.ink)
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.vertical, PaladalaTheme.Spacing.m)
            .background(PaladalaTheme.paper)
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
            }
            .background {
                if !configuration.isPressed {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(
                            x: PaladalaTheme.hardShadowOffset,
                            y: PaladalaTheme.hardShadowOffset
                        )
                }
            }
            .offset(
                x: configuration.isPressed ? PaladalaTheme.pressedOffset : 0,
                y: configuration.isPressed ? PaladalaTheme.pressedOffset : 0
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(
                x: configuration.isPressed ? PaladalaTheme.pressedOffset : 0,
                y: configuration.isPressed ? PaladalaTheme.pressedOffset : 0
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
    }
}

/// Responsive press feedback for the player action bar.
///
/// Each chip in the player control panel uses this style so the
/// press feedback is consistent across subtitle / danmaku /
/// quality / download / coin.  Three layers, all driven by
/// `configuration.isPressed`:
///
/// 1. A scale dip to 0.93 with a snappy spring (response 0.18)
///    so the button feels alive on touch-down.
/// 2. A subtle highlight that lifts the foreground opacity to
///    1.0 (1.0 → 1.0 is a no-op but acts as the explicit
///    "touched" marker when the chip is normally dimmed because
///    it is disabled or pending).
/// 3. A glow halo around the chip that pulses on press — the
///    radial gradient lives behind the label, animates from
///    0 → 0.45 opacity on press, and uses an asymmetric easing
///    so the press builds tension and the release releases it.
///
/// Use `.buttonStyle(PaladalaActionPillStyle())` from any control
/// that lives inside the player's control panel.
struct PaladalaActionPillStyle: ButtonStyle {
    var accent: Color = PaladalaTheme.biliPink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? accent : Color.clear)
            .offset(
                x: configuration.isPressed ? 2 : 0,
                y: configuration.isPressed ? 2 : 0
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
    }
}
/// App-wide hard-edged toggle. Applying this at `RootView` keeps settings,
/// onboarding, SponsorBlock, and diagnostics in one shape language while
/// preserving SwiftUI's Toggle semantics and Dynamic Type label layout.
struct PaladalaStreetToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            guard isEnabled else { return }
            Haptics.selection()
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: PaladalaTheme.Spacing.m) {
                configuration.label
                    .foregroundStyle(PaladalaTheme.ink)
                Spacer(minLength: PaladalaTheme.Spacing.s)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Rectangle()
                        .fill(
                            configuration.isOn
                                ? PaladalaTheme.biliPink
                                : PaladalaTheme.coolGray
                        )
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .frame(width: 18, height: 18)
                        .padding(4)
                }
                .frame(width: 48, height: 28)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.1),
                    value: configuration.isOn
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityValue(configuration.isOn ? "开启" : "关闭")
    }
}

private struct PaladalaInteractiveGlassModifier<S: InsettableShape>: ViewModifier {
    let design: MaterialDesign
    let shape: S
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        fallback(content)
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(tint ?? PaladalaTheme.paper, in: shape)
            .overlay(
                shape.strokeBorder(
                    PaladalaTheme.ink,
                    lineWidth: PaladalaTheme.borderWidth
                )
            )
            .background {
                shape
                    .fill(PaladalaTheme.ink)
                    .offset(
                        x: PaladalaTheme.hardShadowOffset,
                        y: PaladalaTheme.hardShadowOffset
                    )
            }
    }
}

struct PaladalaGlassContainer<Content: View>: View {
    let materialDesign: MaterialDesign
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
    }
}

struct PaladalaBackdrop: View, Equatable {
    @Environment(\.colorScheme) private var envColorScheme
    /// Test-only override. When `nil`, body uses `envColorScheme`
    /// (production path). When non-nil, body uses the override
    /// (unit-test path via `PaladalaBackdrop.scheme(_:)`).
    private var overrideColorScheme: ColorScheme?

    /// Designated init — production callers use `PaladalaBackdrop()`.
    /// `colorScheme` is only used by tests via the `.scheme(_:)`
    /// factory; the production `@Environment` path ignores it.
    init(colorScheme: ColorScheme? = nil) {
        self.overrideColorScheme = colorScheme
    }

    /// Resolved color scheme. `overrideColorScheme` wins so the
    /// `Equatable` test is deterministic under unit-test conditions
    /// (no `@Environment` injection).
    var colorScheme: ColorScheme {
        overrideColorScheme ?? envColorScheme
    }

    /// Equatable — keyed on the resolved color scheme. PR-A audit #10
    /// relies on this so `RootView.body` re-evaluations are skipped
    /// when the backdrop's color scheme is unchanged.
    ///
    /// PR-C Task 5: marked `nonisolated` so the `==` operator
    /// satisfies the `Equatable` protocol's nonisolated
    /// requirement (Swift 6's strict check rejects a
    /// @MainActor-isolated operator where the protocol asks
    /// for a nonisolated one).  The body wraps the
    /// `colorScheme` access in `MainActor.assumeIsolated`
    /// because the call sites are always on the main thread
    /// (XCTest's `XCTAssertEqual` runs on main; SwiftUI's
    /// diffing for `View` re-evaluation also runs on main).
    nonisolated static func == (lhs: PaladalaBackdrop, rhs: PaladalaBackdrop) -> Bool {
        MainActor.assumeIsolated {
            lhs.colorScheme == rhs.colorScheme
        }
    }

    /// Test seam — returns a backdrop with an explicit `colorScheme`
    /// for the `Equatable` test. Not for production use.
    static func scheme(_ scheme: ColorScheme) -> PaladalaBackdrop {
        PaladalaBackdrop(colorScheme: scheme)
    }

    var body: some View {
        PaladalaTheme.canvas
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
        let shape = Rectangle()

        self
            .background(tint ?? PaladalaTheme.cardBackground, in: shape)
            .overlay(
                shape.strokeBorder(
                    stroke ?? PaladalaTheme.ink,
                    lineWidth: stroke == nil ? PaladalaTheme.borderWidth : strokeWidth
                )
            )
            .background {
                shape
                    .fill(PaladalaTheme.ink)
                    .offset(
                        x: PaladalaTheme.hardShadowOffset,
                        y: PaladalaTheme.hardShadowOffset
                    )
            }
    }

    @ViewBuilder
    func paladalaPillSurface(
        _ design: MaterialDesign
    ) -> some View {
        self
            .background(PaladalaTheme.paper)
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
            }
    }

    @ViewBuilder
    func paladalaNavBarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
        self
            .toolbarBackground(PaladalaTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    @ViewBuilder
    func paladalaToolbarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
        self
            .toolbarBackground(PaladalaTheme.paper, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
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
        self
            .font(PaladalaTheme.FontRole.labelMono)
            .textCase(.uppercase)
            .foregroundStyle(isSelected ? PaladalaTheme.paper : PaladalaTheme.ink)
            .background(isSelected ? PaladalaTheme.ink : PaladalaTheme.paper)
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
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
        self.paladalaGlassFallback(cornerRadius: cornerRadius, tint: tint)
    }

    @ViewBuilder
    fileprivate func paladalaGlassFallback(
        cornerRadius: CGFloat,
        tint: Color
    ) -> some View {
        let shape = Rectangle()

        self
            .background(PaladalaTheme.paper, in: shape)
            .overlay {
                shape.strokeBorder(
                    PaladalaTheme.ink,
                    lineWidth: PaladalaTheme.borderWidth
                )
            }
            .background {
                shape
                    .fill(PaladalaTheme.ink)
                    .offset(
                        x: PaladalaTheme.hardShadowOffset,
                        y: PaladalaTheme.hardShadowOffset
                    )
            }
    }

    func paladalaBackdrop() -> some View {
        self.background {
            PaladalaBackdrop()
        }
    }

    /// Opaque paper presentation background for sheets. Apply to the sheet
    /// content so system presentation chrome cannot reintroduce blur.
    @ViewBuilder
    func paladalaSheetGlass() -> some View {
        self
            .presentationBackground(PaladalaTheme.paper)
            .presentationCornerRadius(0)
    }

    /// Street Minimal uses a static skeleton. Besides matching the dry,
    /// print-like direction, this removes one infinite animation and one
    /// GeometryReader/mask stack per visible placeholder cell.
    @ViewBuilder
    func paladalaShimmer(active: Bool = true) -> some View {
        self.opacity(active ? 0.72 : 1)
    }

    /// Opaque Street-Minimal panel for screens that do not need to preserve
    /// the legacy `paladalaCardSurface` signature.
    func paladalaStreetPanel(
        fill: Color = PaladalaTheme.paper,
        elevated: Bool = true
    ) -> some View {
        self
            .background(fill)
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
            }
            .background {
                if elevated {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(
                            x: PaladalaTheme.hardShadowOffset,
                            y: PaladalaTheme.hardShadowOffset
                        )
                }
            }
    }

    func paladalaSectionHeader() -> some View {
        self
            .font(PaladalaTheme.FontRole.sectionHeader)
            .textCase(.uppercase)
            .foregroundStyle(PaladalaTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .foregroundStyle(isSelected ? PaladalaTheme.paper : PaladalaTheme.ink)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 8)
    }
}
