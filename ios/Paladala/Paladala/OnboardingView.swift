import Foundation
import SwiftUI

struct OnboardingView: View {
    @AppStorage("paladala.didOnboard") private var didOnboard = false
    @State private var currentPage = 0
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let pages: [OnboardingPage] = [
        OnboardingPage(title: "为 B 站而生", subtitle: "首页 · 推荐 · 动态 · 直播，一个 App 走完", symbol: "play.rectangle.on.rectangle.fill", tint: PaladalaTheme.biliPink),
        OnboardingPage(title: "顺手就走的播放", subtitle: "看到一半切走，视频缩成小窗继续放；想看再点开", symbol: "pip.exit", tint: PaladalaTheme.biliPink),
        OnboardingPage.preferences,
        OnboardingPage(title: "登录后更强", subtitle: "同步历史、收藏、追番和稍后再看", symbol: "person.crop.circle.badge.checkmark", tint: PaladalaTheme.biliPink),
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
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.2),
                value: currentPage
            )

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
            didOnboard = true
        } label: {
            Text(currentPage == Self.pages.count - 1 ? "开始" : "跳过")
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(PaladalaTheme.paper)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
                .background {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(
                            x: PaladalaTheme.hardShadowOffset,
                            y: PaladalaTheme.hardShadowOffset
                        )
                }
        }
        .buttonStyle(PaladalaPressBounceButtonStyle())
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var pageDot: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.pages.count, id: \.self) { i in
                Rectangle()
                    .fill(i == currentPage ? PaladalaTheme.biliPink : Color.primary.opacity(0.2))
                    .frame(width: i == currentPage ? 24 : 8, height: 8)
                    .overlay {
                        Rectangle()
                            .strokeBorder(PaladalaTheme.ink, lineWidth: 1)
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: currentPage)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PaladalaTheme.paper)
        .overlay {
            Rectangle()
                .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
        }
    }
}

// MARK: - Animated background

private struct OnboardingAnimatedBackground: View {
    let page: Int

    var body: some View {
        ZStack {
            PaladalaTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("PALADALA // START")
                    Spacer()
                    Text(String(format: "%02d", page + 1))
                }
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.paper)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .frame(height: 34)
                .background(PaladalaTheme.ink)

                Spacer()

                HStack(spacing: 8) {
                    Rectangle()
                        .fill(PaladalaTheme.biliPink)
                        .frame(maxWidth: .infinity)
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .frame(width: 52)
                }
                .frame(height: 8)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.bottom, PaladalaTheme.Spacing.l)
            }
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appear = false

    var body: some View {
        if isPreferencesPage {
            OnboardingPreferencesPage(currentPage: currentPageBinding)
                .onAppear { appear = true }
        } else {
            marketingBody
                .onAppear {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
                        appear = true
                    }
                }
                .onDisappear { appear = false }
        }
    }

    private var marketingBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 60)

            Image(systemName: page.symbol)
                .font(.system(size: 54, weight: .black))
                .foregroundStyle(PaladalaTheme.ink)
                .frame(width: 124, height: 124)
                .background(PaladalaTheme.biliPink)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
                .background {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(
                            x: PaladalaTheme.hardShadowOffset,
                            y: PaladalaTheme.hardShadowOffset
                        )
                }
                .scaleEffect(appear || reduceMotion ? 1 : 0.86)
                .opacity(appear ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.25).delay(0.1),
                    value: appear
                )

            VStack(alignment: .leading, spacing: 12) {
                Text(page.title)
                    .font(PaladalaTheme.FontRole.displayLarge)
                    .foregroundStyle(PaladalaTheme.ink)
                    .textCase(.uppercase)
                    .multilineTextAlignment(.leading)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 20)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(0.12), value: appear)

                Text(page.subtitle)
                    .font(PaladalaTheme.FontRole.body)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .multilineTextAlignment(.leading)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 16)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(0.18), value: appear)
            }
            .padding(.top, 28)

            if showsLoginCTA {
                Button {
                    Haptics.tap()
                    router.openLogin()
                } label: {
                    Text("立即登录")
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(PaladalaTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(PaladalaTheme.biliPink)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.borderWidth
                                )
                        }
                        .background {
                            Rectangle()
                                .fill(PaladalaTheme.ink)
                                .offset(
                                    x: PaladalaTheme.hardShadowOffset,
                                    y: PaladalaTheme.hardShadowOffset
                                )
                        }
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
                .padding(.top, 24)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 20)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(0.24), value: appear)
            }

            Spacer()
        }
        .padding(.horizontal, PaladalaTheme.Spacing.xxxl)
    }
}

// MARK: - Preferences

private struct OnboardingPreferencesPage: View {
    @Binding var currentPage: Int
    @AppStorage("paladala.themeMode") private var themeMode = ThemeMode.system
    @AppStorage("paladala.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("paladala.backgroundAudio") private var backgroundAudio = false
    @AppStorage("paladala.iCloudSync") private var iCloudSync = false
    @AppStorage("paladala.didOnboard") private var didOnboard = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appear = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 36, weight: .black))
                    .foregroundStyle(PaladalaTheme.ink)
                    .frame(width: 76, height: 76)
                    .background(PaladalaTheme.biliPink)
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                    .scaleEffect(appear || reduceMotion ? 1 : 0.86)
                    .opacity(appear ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(0.1), value: appear)

                Text("定制你的体验")
                    .font(PaladalaTheme.FontRole.displayMedium)
                    .foregroundStyle(PaladalaTheme.ink)
                    .textCase(.uppercase)
                    .opacity(appear ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(0.14), value: appear)

                Text("挑你想用的功能，其余保持默认")
                    .font(PaladalaTheme.FontRole.bodySmall)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .multilineTextAlignment(.leading)
                    .opacity(appear ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(0.18), value: appear)
            }
            .padding(.top, 16)
            .padding(.horizontal, PaladalaTheme.Spacing.xxxl)
            .frame(maxWidth: .infinity, alignment: .leading)

            preferencesCard
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 30)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(0.2), value: appear)

            Spacer()

            ctaStack
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
                .opacity(appear ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(0.24), value: appear)
        }
        .onAppear { appear = true }
        .padding(.horizontal, 0)
    }

    @ViewBuilder
    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("主题", systemImage: themeIcon(themeMode))
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                HStack(spacing: 8) {
                    ForEach(ThemeMode.allCases) { mode in
                        Button {
                            Haptics.selection()
                            themeMode = mode
                        } label: {
                            Text(mode.title)
                                .font(PaladalaTheme.FontRole.labelMono)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                        .paladalaSelectionChip(
                            isSelected: themeMode == mode,
                            design: .liquidGlass
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("界面设计", systemImage: "square.grid.3x3.square")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                HStack {
                    Text("STREET MINIMAL")
                        .font(PaladalaTheme.FontRole.labelMono)
                    Spacer()
                    Text("01")
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(PaladalaTheme.paper)
                        .padding(6)
                        .background(PaladalaTheme.ink)
                }
                .padding(10)
                .background(PaladalaTheme.biliPink)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
            }

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 12) {
                Label("功能开关", systemImage: "switch.2")
                    .font(PaladalaTheme.FontRole.labelMono)
                featureToggle(
                    title: "弹幕",
                    symbol: "text.bubble.fill",
                    isOn: $danmakuEnabled
                )
                featureToggle(
                    title: "后台音频",
                    symbol: "speaker.wave.2.fill",
                    isOn: $backgroundAudio
                )
                featureToggle(
                    title: "iCloud 同步",
                    symbol: "icloud.fill",
                    isOn: $iCloudSync,
                    disabled: !ICloudSync.shared.isAvailable
                )
            }
        }
        .padding(PaladalaTheme.Spacing.content)
        .paladalaStreetPanel(fill: PaladalaTheme.paper)
    }

    private func featureToggle(
        title: String,
        symbol: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        Button {
            guard !disabled else { return }
            Haptics.selection()
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body.weight(.black))
                Text(title)
                    .font(PaladalaTheme.FontRole.labelMono)
                Spacer()
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.body.weight(.black))
            }
            .foregroundStyle(PaladalaTheme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(isOn.wrappedValue ? PaladalaTheme.biliPink : PaladalaTheme.coolGray)
            .overlay {
                Rectangle()
                    .strokeBorder(
                        PaladalaTheme.ink,
                        lineWidth: PaladalaTheme.borderWidth
                    )
            }
        }
        .buttonStyle(PaladalaPressBounceButtonStyle())
        .opacity(disabled ? 0.45 : 1)
        .accessibilityValue(isOn.wrappedValue ? "开启" : "关闭")
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
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    currentPage += 1
                }
            } label: {
                Text("下一步")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(PaladalaTheme.biliPink)
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                    .background {
                        Rectangle()
                            .fill(PaladalaTheme.ink)
                            .offset(
                                x: PaladalaTheme.hardShadowOffset,
                                y: PaladalaTheme.hardShadowOffset
                            )
                    }
            }
            .buttonStyle(PaladalaPressBounceButtonStyle())

            Button {
                Haptics.tap()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    didOnboard = true
                }
            } label: {
                Text("跳过，使用默认")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
            .buttonStyle(.plain)
        }
    }
}
