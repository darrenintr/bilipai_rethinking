import SwiftUI

/// 3-page first-launch welcome. The user can skip at any point or
/// reach the final page and tap "开始" to dismiss. The dismiss
/// writes `@AppStorage("bilipai.didOnboard") = true` so the
/// `RootView` cover does not re-present on relaunch.
///
/// Pages are deliberately short: an SF Symbol illustration, a one-line
/// title, and a one-line description. The icon does the heavy lifting
/// and the copy is in Chinese to match the rest of the app.
struct OnboardingView: View {
    @AppStorage("bilipai.didOnboard") private var didOnboard: Bool = false
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
                    OnboardingPageView(page: page, showsLoginCTA: index == Self.pages.count - 1)
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
        .onChange(of: currentPage) { _, newValue in
            if newValue == Self.pages.count - 1 {
                // The user has reached the last page — turn the
                // "Skip" label into "开始" by writing the flag, so
                // tapping it both finishes onboarding and dismisses
                // the cover. We don't dismiss here; the parent
                // observes the @AppStorage change and dismisses.
            }
        }
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
                        cornerRadius: BiliPaiTheme.cornerRadius,
                        style: BiliPaiTheme.cornerStyle
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currentPage == Self.pages.count - 1 ? "开始使用 Paladala" : "跳过引导")
    }
}

private struct OnboardingPage: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let showsLoginCTA: Bool
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 40)
            Image(systemName: page.symbol)
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [page.tint, page.tint.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
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
                .tint(BiliPaiTheme.biliPink)
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
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
