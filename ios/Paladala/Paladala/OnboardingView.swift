import SwiftUI

/// 4-page first-run welcome.
///
/// Pages 0-1 introduce the app's value prop (everything-in-one
/// B 站 client, mini-player friendly). Page 2 is a "Pick Your
/// Defaults" preferences card that lets the user opt in to the
/// 6 feature flags before the app ever lands them on the home
/// screen — defaults that previously had to be discovered in
/// the profile settings. Page 3 is the dedicated login card.
///
/// `didOnboard` is written when the user taps `跳过` (defaults
/// apply) on the preferences page, or `开始` on the final page.
/// The `.fullScreenCover` in `RootView` reads
/// `@AppStorage("paladala.didOnboard")` and dismisses when the
/// flag flips to `true`.
struct OnboardingView: View {
    @AppStorage("paladala.didOnboard") private var didOnboard: Bool = false
    @State private var currentPage: Int = 0
    @EnvironmentObject private var router: AppRouter

    private static let pages: [OnboardingPage] = [
        OnboardingPage(
            title: "为 B 站而生",
            subtitle: "首页 · 推荐 · 动态 · 直播，一个 App 走完",
            symbol: "play.rectangle.on.rectangle.fill",
            tint: .pink
        ),
        OnboardingPage(
            title: "顺手就走的播放",
            subtitle: "看到一半切走，视频缩成小窗继续放；想看再点开",
            symbol: "pip.exit",
            tint: .blue
        ),
        OnboardingPage.preferences,
        OnboardingPage(
            title: "登录后更强",
            subtitle: "同步历史、收藏、追番和稍后再看",
            symbol: "person.crop.circle.badge.checkmark",
            tint: .green
        )
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $currentPage) {
                ForEach(Array(Self.pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(
                        page: page,
                        showsLoginCTA: index == Self.pages.count - 1,
                        isPreferencesPage: page.kind == .preferences,
                        currentPageBinding: Binding(
                            get: { currentPage },
                            set: { currentPage = $0 }
                        )
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            skipButton
                .padding(.trailing, 20)
                .padding(.top, 12)
        }
        .background(OnboardingBackground())
    }

    private var skipButton: some View {
        Button {
            didOnboard = true
        } label: {
            Text(currentPage == Self.pages.count - 1 ? "开始" : "跳过")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(
                        cornerRadius: PaladalaTheme.cornerRadius,
                        style: PaladalaTheme.cornerStyle
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currentPage == Self.pages.count - 1 ? "开始使用 Paladala" : "跳过引导")
    }
}

private struct OnboardingPage: Identifiable {
    enum Kind {
        case marketing
        case preferences
    }
    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    init(
        kind: Kind = .marketing,
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
    }

    /// The "Pick Your Defaults" preferences card. The struct's
    /// `title` / `subtitle` / `symbol` fields are unused by the
    /// preferences view (it has its own header), so we fill them
    /// with the same strings the original marketing layout used
    /// to keep the data shape uniform.
    static let preferences = OnboardingPage(
        kind: .preferences,
        title: "定制你的体验",
        subtitle: "挑你想用的功能，其余保持默认",
        symbol: "slider.horizontal.3",
        tint: .pink
    )
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let showsLoginCTA: Bool
    let isPreferencesPage: Bool
    /// Routed through from `OnboardingView` — the parent's `@State`
    /// is the single source of truth, and the child view mutates it
    /// via the binding.  Marketing pages never read this.
    let currentPageBinding: Binding<Int>
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        if isPreferencesPage {
            OnboardingPreferencesPage(currentPage: currentPageBinding)
        } else {
            marketingBody
        }
    }

    private var marketingBody: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 40)
            Image(systemName: page.symbol)
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(page.tint.gradient)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
                .padding(.bottom, 8)
            VStack(spacing: 12) {
                Text(page.title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(page.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if showsLoginCTA {
                Button {
                    Haptics.tap()
                    router.openLogin()
                } label: {
                    Text("立即登录")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(PaladalaTheme.biliPink)
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

/// "Pick Your Defaults" preferences card. The user can opt in or
/// out of 6 feature flags before the app ever shows the home
/// screen. All values are written straight through to the same
/// `@AppStorage` keys the settings screen reads, so the choice
/// survives a relaunch and is mirrored to iCloud on the user's
/// other devices (when `ICloudSync` is enabled).
///
/// Uses native SwiftUI controls (`Picker(.segmented)` +
/// `Toggle`) so the choices match iOS Settings.app conventions
/// — automatic Dynamic Type, dark-mode and accessibility
/// behaviour, no custom tap targets to maintain.
private struct OnboardingPreferencesPage: View {
    @Binding var currentPage: Int
    @AppStorage("paladala.themeMode") private var themeMode: ThemeMode = .system
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    @AppStorage("paladala.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("paladala.backgroundAudio") private var backgroundAudio = false
    @AppStorage("paladala.iCloudSync") private var iCloudSync = false
    @AppStorage("paladala.todayWatch") private var todayWatch = true
    @AppStorage("paladala.didOnboard") private var didOnboard: Bool = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(PaladalaTheme.biliPink.gradient)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text("定制你的体验")
                    .font(.title2.weight(.bold))
                Text("挑你想用的功能，其余保持默认")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 32)

            preferencesCard
                .padding(.horizontal, 20)

            Spacer()

            ctaStack
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Theme — segmented picker (3 options).
            VStack(alignment: .leading, spacing: 8) {
                Label("主题", systemImage: themeIcon(themeMode))
                    .font(.subheadline.weight(.semibold))
                Picker("主题", selection: $themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("主题")
            }

            // Material design — segmented picker (2 options).
            VStack(alignment: .leading, spacing: 8) {
                Label("界面设计", systemImage: materialDesign == .liquidGlass
                      ? "sparkles" : "rectangle.3.group")
                    .font(.subheadline.weight(.semibold))
                Picker("界面设计", selection: $materialDesign) {
                    ForEach(MaterialDesign.allCases) { design in
                        Text(design.title).tag(design)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("界面设计")
            }

            Divider().padding(.vertical, 4)

            // Feature toggles — native `Toggle` rows.
            VStack(alignment: .leading, spacing: 12) {
                Label("功能开关", systemImage: "switch.2")
                    .font(.subheadline.weight(.semibold))
                Toggle(isOn: $danmakuEnabled) {
                    Label("弹幕", systemImage: "text.bubble.fill")
                }
                Toggle(isOn: $backgroundAudio) {
                    Label("后台音频", systemImage: "speaker.wave.2.fill")
                }
                Toggle(isOn: $iCloudSync) {
                    Label("iCloud 同步", systemImage: "icloud.fill")
                }
                .disabled(!ICloudSync.shared.isAvailable)
                Toggle(isOn: $todayWatch) {
                    Label("今日看什么", systemImage: "list.star")
                }
            }
        }
        .padding(PaladalaTheme.Spacing.content)
        .paladalaCardSurface(materialDesign)
    }

    /// SF Symbol for the currently-selected `ThemeMode`. Drives
    /// the leading icon in the segmented-picker section header.
    private func themeIcon(_ mode: ThemeMode) -> String {
        switch mode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    @ViewBuilder
    private var ctaStack: some View {
        VStack(spacing: 10) {
            Button {
                Haptics.tap()
                currentPage += 1
            } label: {
                Text("下一步")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(PaladalaTheme.biliPink)

            Button {
                Haptics.tap()
                didOnboard = true
            } label: {
                Text("跳过，使用默认")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct OnboardingBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(uiColor: .systemBackground),
                Color(uiColor: .secondarySystemBackground)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
