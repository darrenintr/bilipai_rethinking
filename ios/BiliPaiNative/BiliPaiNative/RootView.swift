import SwiftUI

struct RootView: View {
    let repository: BiliPaiRepository

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var miniPlayerStore: MiniPlayerStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .material3
    @AppStorage("bilipai.didOnboard") private var didOnboard: Bool = false

    /// Mirror of `networkMonitor.isOnline` so the `RootView.body`
    /// re-evaluates when connectivity changes. We don't observe the
    /// published value directly in the modifier because `.animation`
    /// takes an `Equatable` value, not a binding.
    private var networkMonitorIsOnline: Bool { networkMonitor.isOnline }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                PadRootView(repository: repository)
            } else {
                PhoneRootView(repository: repository)
            }
        }
        .onAppear {
            router.consumePendingIntentRoute()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                diagLog(.lifecycle, "app.foreground")
                router.consumePendingIntentRoute()
            case .background:
                diagLog(.lifecycle, "app.background")
            case .inactive:
                diagLog(.lifecycle, "app.inactive")
            @unknown default:
                break
            }
        }
        .onOpenURL { url in
            handle(url)
        }
        .sheet(isPresented: $router.isLoginSheetPresented) {
            LoginSheet()
        }
        .modifier(LiquidGlassTabBarModifier(materialDesign: materialDesign))
        .fullScreenCover(isPresented: Binding(
            get: { !didOnboard },
            set: { newValue in
                if newValue == false { didOnboard = true }
            }
        )) {
            OnboardingView()
        }
        .overlay(alignment: .top) {
            OfflineBanner()
                .animation(.spring(response: 0.35, dampingFraction: 0.85),
                           value: networkMonitorIsOnline)
        }
        .overlay(alignment: .bottomTrailing) {
            // Pad the mini-player off the tab bar and the safe area.
            // 16pt on the trailing edge, 80pt on the bottom (above
            // the tab bar's glass chrome). On iPad we offset further
            // so the overlay doesn't collide with the sidebar's
            // resize handle.
            MiniPlayerOverlay()
                .padding(.trailing, horizontalSizeClass == .regular ? 32 : 16)
                .padding(.bottom, horizontalSizeClass == .regular ? 32 : 80)
                .animation(.spring(response: 0.35, dampingFraction: 0.85),
                           value: miniPlayerIsShowing)
        }
    }

    /// Mirror of `miniPlayerStore.isShowingMiniPlayer` so the
    /// overlay's animation key is value-based, not environment-based.
    private var miniPlayerIsShowing: Bool {
        miniPlayerStore.isShowingMiniPlayer
    }

    private func handle(_ url: URL) {
        guard url.scheme == "bilipai" else { return }
        switch url.host {
        case "home":
            router.open(.home)
        case "dynamic":
            router.open(.dynamic)
        case "live":
            router.open(.live)
        case "settings":
            router.open(.profile)
        case "search":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "q" })?
                .value ?? ""
            router.openSearch(query)
        case "login":
            router.openLogin()
        default:
            break
        }
    }
}

private struct PhoneRootView: View {
    let repository: BiliPaiRepository
    @EnvironmentObject private var router: AppRouter
    /// Single shared namespace for the hero / zoom transition
    /// between the feed grids and `VideoDetailView`. Declared
    /// at the nav-stack root so the same namespace is visible
    /// to both the source (cards in the feed tabs) and the
    /// destination (`VideoDetailView`).
    @Namespace private var heroNamespace

    var body: some View {
        NavigationStack(path: $router.path) {
            TabView(selection: $router.selectedTab) {
                HomeView(repository: repository, heroNamespace: heroNamespace)
                    .tabItem { Label(MainTab.home.title, systemImage: MainTab.home.symbolName) }
                    .tag(MainTab.home)

                DynamicFeedView(repository: repository, heroNamespace: heroNamespace)
                    .tabItem { Label(MainTab.dynamic.title, systemImage: MainTab.dynamic.symbolName) }
                    .tag(MainTab.dynamic)

                LiveRoomsView(repository: repository)
                    .tabItem { Label(MainTab.live.title, systemImage: MainTab.live.symbolName) }
                    .tag(MainTab.live)

                ProfileSettingsView(repository: repository)
                    .tabItem { Label(MainTab.profile.title, systemImage: MainTab.profile.symbolName) }
                    .tag(MainTab.profile)
            }
            .navigationDestination(for: BiliVideo.self) { video in
                VideoDetailView(video: video, repository: repository, heroNamespace: heroNamespace)
            }
            .navigationDestination(for: ProfileRoute.self) { route in
                profileRouteView(route, repository: repository)
            }
            .navigationDestination(for: ReplyRoute.self) { route in
                ReplyListView(video: route.video, rootComment: route.rootComment, repository: repository)
            }
        }
        // Middle-of-screen / left-edge swipe-back. The enabler
        // is a no-op on the root (where the path is empty) and
        // pops the last item from the navigation path on a
        // successful drag. We wrap the pop in `withAnimation`
        // so the path removal gets the same slide animation
        // the system edge-swipe uses.
        .background(BackGestureEnabler(
            isEnabled: !router.path.isEmpty,
            onPop: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    router.path.removeLast()
                }
            }
        ))
    }
}

private struct PadRootView: View {
    let repository: BiliPaiRepository
    @EnvironmentObject private var router: AppRouter
    /// Single shared namespace for the hero / zoom transition.
    @Namespace private var heroNamespace

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(MainTab.allCases) { tab in
                    Button {
                        router.open(tab)
                    } label: {
                        Label(tab.title, systemImage: tab.symbolName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(router.selectedTab == tab ? BiliPaiTheme.biliPink.opacity(0.14) : Color.clear)
                }
            }
            .navigationTitle("BiliPai")
        } detail: {
            NavigationStack(path: $router.path) {
                selectedView
                    .navigationDestination(for: BiliVideo.self) { video in
                        VideoDetailView(video: video, repository: repository, heroNamespace: heroNamespace)
                    }
                    .navigationDestination(for: ProfileRoute.self) { route in
                        profileRouteView(route, repository: repository)
                    }
                    .navigationDestination(for: ReplyRoute.self) { route in
                        ReplyListView(video: route.video, rootComment: route.rootComment, repository: repository)
                    }
            }
            .background(BackGestureEnabler(
                isEnabled: !router.path.isEmpty,
                onPop: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        router.path.removeLast()
                    }
                }
            ))
        }
    }

    @ViewBuilder
    private var selectedView: some View {
        switch router.selectedTab {
        case .home:
            HomeView(repository: repository, heroNamespace: heroNamespace)
        case .dynamic:
            DynamicFeedView(repository: repository, heroNamespace: heroNamespace)
        case .live:
            LiveRoomsView(repository: repository)
        case .profile:
            ProfileSettingsView(repository: repository)
        }
    }
}

@ViewBuilder
private func profileRouteView(_ route: ProfileRoute, repository: BiliPaiRepository) -> some View {
    switch route {
    case .history:
        HistoryListView(repository: repository)
    case .favorites(let mid):
        FavoriteFoldersView(repository: repository, mid: mid)
    case .watchLater:
        WatchLaterListView(repository: repository)
    }
}

/// Liquid Glass material for the tab bar.
///
/// On iOS 26+ we would use the real `.toolbarBackground(.glass, for:
/// .tabBar)`, which picks up the underlying content and renders a
/// proper Liquid Glass surface. The unsigned-IPA workflow ships with
/// Xcode 16 / iOS 18.5 SDK, which does not include the iOS 26 API, so
/// we fall back to `.ultraThinMaterial` + the same
/// `.toolbarBackground(.visible)` that makes the chrome always show.
/// When the iOS 26 SDK becomes available in the build environment we'll
/// re-introduce the `if #available(iOS 26, *)` branch with the real
/// `.glass` background.
private struct LiquidGlassTabBarModifier: ViewModifier {
    let materialDesign: MaterialDesign

    @ViewBuilder
    func body(content: Content) -> some View {
        switch materialDesign {
        case .material3:
            content
        case .liquidGlass:
            content
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }
}
