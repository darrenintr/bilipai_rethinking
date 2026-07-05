import SwiftUI

struct OnboardingView: View {
    @AppStorage("paladala.didOnboard") private var didOnboard = false
    @State private var currentPage = 0
    @EnvironmentObject private var router: AppRouter

    private static let pages: [OnboardingPage] = [
        OnboardingPage(title: "为 B 站而生", subtitle: "首页 · 推荐 · 动态 · 直播，一个 App 走完", symbol: "play.rectangle.on.rectangle.fill", tint: .pink),
        OnboardingPage(title: "顺手就走的播放", subtitle: "看到一半切走，视频缩成小窗继续放；想看再点开", symbol: "pip.exit", tint: .blue),
        OnboardingPage.preferences,
        OnboardingPage(title: "登录后更强", subtitle: "同步历史、收藏、追番和稍后再看", symbol: "person.crop.circle.badge.checkmark", tint: .green),
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            OnboardingAnimatedBackground(page: currentPage)

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
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: currentPage)

            VStack {
                skipButton
                    .padding(.trailing, 20)
                    .padding(.top, 12)
                Spacer()
                pageDot
                    .padding(.bottom, 32)
            }
        }
    }

    private var skipButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                didOnboard = true
            }
        } label: {
            Text(currentPage == Self.pages.count - 1 ? "开始" : "跳过")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    .ultraThinMaterial,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var pageDot: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.pages.count, id: \.self) { i in
                Circle()
                    .fill(i == currentPage ? PaladalaTheme.biliPink : Color.primary.opacity(0.2))
                    .frame(width: i == currentPage ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentPage)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Animated background

private struct OnboardingAnimatedBackground: View {
    let page: Int
    @State private var animate = false

    private var colors: [Color] {
        switch page {
        case 0: return [.pink.opacity(0.3), .purple.opacity(0.15)]
        case 1: return [.blue.opacity(0.25), .cyan.opacity(0.15)]
        case 2: return [PaladalaTheme.biliPink.opacity(0.2), .orange.opacity(0.1)]
        case 3: return [.green.opacity(0.2), .mint.opacity(0.15)]
        default: return [.pink.opacity(0.2), .purple.opacity(0.1)]
        }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            Circle()
                .fill(colors[0].gradient)
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: animate ? 100 : -100, y: animate ? -80 : 80)

            Circle()
                .fill(colors.count > 1 ? colors[1].gradient : colors[0].gradient)
                .frame(width: 250, height: 250)
                .blur(radius: 70)
                .offset(x: animate ? -80 : 80, y: animate ? 100 : -60)
        }
        .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: animate)
        .onAppear { animate = true }
        .animation(.easeInOut(duration: 1.5), value: page)
    }
}

// MARK: - Page model

private struct OnboardingPage: Identifiable {
    enum Kind { case marketing, preferences }
    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    init(kind: Kind = .marketing, title: String, subtitle: String, symbol: String, tint: Color) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.tint = tint
    }

    static let preferences = OnboardingPage(kind: .preferences, title: "定制你的体验", subtitle: "挑你想用的功能，其余保持默认", symbol: "slider.horizontal.3", tint: PaladalaTheme.biliPink)
}

// MARK: - Page view

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let showsLoginCTA: Bool
    let isPreferencesPage: Bool
    let currentPageBinding: Binding<Int>
    @EnvironmentObject private var router: AppRouter

    @State private var appear = false

    var body: some View {
        if isPreferencesPage {
            OnboardingPreferencesPage(currentPage: currentPageBinding)
                .onAppear { appear = true }
        } else {
            marketingBody
                .onAppear {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { appear = true }
                }
                .onDisappear { appear = false }
        }
    }

    private var marketingBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)

            Image(systemName: page.symbol)
                .font(.system(size: 88, weight: .ultraLight))
                .foregroundStyle(page.tint.gradient)
                .symbolRenderingMode(.hierarchical)
                .scaleEffect(appear ? 1 : 0.3)
                .opacity(appear ? 1 : 0)
                .rotationEffect(.degrees(appear ? 0 : -15))
                .animation(.spring(response: 0.7, dampingFraction: 0.6).delay(0.1), value: appear)

            VStack(spacing: 10) {
                Text(page.title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 20)
                    .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.25), value: appear)

                Text(page.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 16)
                    .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.35), value: appear)
            }
            .padding(.top, 28)

            if showsLoginCTA {
                Button {
                    Haptics.tap()
                    router.openLogin()
                } label: {
                    Text("立即登录")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            PaladalaTheme.biliPink.gradient,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 20)
                .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.5), value: appear)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Preferences

private struct OnboardingPreferencesPage: View {
    @Binding var currentPage: Int
    @AppStorage("paladala.themeMode") private var themeMode = ThemeMode.system
    @AppStorage("paladala.materialDesign") private var materialDesign = MaterialDesign.liquidGlass
    @AppStorage("paladala.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("paladala.backgroundAudio") private var backgroundAudio = false
    @AppStorage("paladala.iCloudSync") private var iCloudSync = false
    @AppStorage("paladala.todayWatch") private var todayWatch = true
    @AppStorage("paladala.didOnboard") private var didOnboard = false

    @State private var appear = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            VStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundStyle(PaladalaTheme.biliPink.gradient)
                    .symbolRenderingMode(.hierarchical)
                    .scaleEffect(appear ? 1 : 0.5)
                    .opacity(appear ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.65).delay(0.1), value: appear)

                Text("定制你的体验")
                    .font(.title2.weight(.bold))
                    .opacity(appear ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(0.2), value: appear)

                Text("挑你想用的功能，其余保持默认")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .opacity(appear ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(0.3), value: appear)
            }
            .padding(.top, 16)

            preferencesCard
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 30)
                .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.4), value: appear)

            Spacer()

            ctaStack
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
                .opacity(appear ? 1 : 0)
                .animation(.easeOut(duration: 0.4).delay(0.6), value: appear)
        }
        .onAppear { appear = true }
        .padding(.horizontal, 0)
    }

    @ViewBuilder
    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("主题", systemImage: themeIcon(themeMode))
                    .font(.subheadline.weight(.semibold))
                Picker("主题", selection: $themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("界面设计", systemImage: materialDesign == .liquidGlass ? "sparkles" : "rectangle.3.group")
                    .font(.subheadline.weight(.semibold))
                Picker("界面设计", selection: $materialDesign) {
                    ForEach(MaterialDesign.allCases) { design in
                        Text(design.title).tag(design)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 12) {
                Label("功能开关", systemImage: "switch.2")
                    .font(.subheadline.weight(.semibold))
                Toggle(isOn: $danmakuEnabled) { Label("弹幕", systemImage: "text.bubble.fill") }
                Toggle(isOn: $backgroundAudio) { Label("后台音频", systemImage: "speaker.wave.2.fill") }
                Toggle(isOn: $iCloudSync) { Label("iCloud 同步", systemImage: "icloud.fill") }
                    .disabled(!ICloudSync.shared.isAvailable)
                Toggle(isOn: $todayWatch) { Label("今日看什么", systemImage: "list.star") }
            }
        }
        .padding(PaladalaTheme.Spacing.content)
        .background(
            PaladalaTheme.SemanticColor.card,
            in: RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle)
        )
    }

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
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    currentPage += 1
                }
            } label: {
                Text("下一步")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        PaladalaTheme.biliPink.gradient,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button {
                Haptics.tap()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    didOnboard = true
                }
            } label: {
                Text("跳过，使用默认")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
