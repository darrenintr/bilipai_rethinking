import SwiftUI

struct RootView: View {
    let repository: PaladalaRepository

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var miniPlayerStore: MiniPlayerStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    @AppStorage("paladala.didOnboard") private var didOnboard: Bool = false
    /// Timestamp of the most recent transition out of `.active`
    /// (i.e. when the user locked the screen or switched apps).
    /// Used by the `scenePhase` change handler to decide whether
    /// the upcoming `.active` is a "long" background — if it
    /// is, we tear down `LocalHLSProxyServer` so the next
    /// `serve(playback:)` starts on a fresh port.  Without
    /// this the user gets a stuck spinner and `NSURLError
    /// -1004 "Could not connect to the server."` for every
    /// video they try to play after the screen has been
    /// locked for more than a few seconds.
    @State private var lastBackgroundAt: Date?
    /// The threshold above which a background → foreground
    /// transition is treated as "long" and triggers a proxy
    /// teardown.  Picked at 5 s: shorter than that and we
    /// would race the user's own quick app-switches; longer
    /// than that and iOS has had time to suspend the
    /// `NWListener` and the upstream `URLSession` leg.
    private static let longBackgroundThreshold: TimeInterval = 5

    /// Mirror of `networkMonitor.isOnline` so the `RootView.body`
    /// re-evaluates when connectivity changes. We don't observe the
    /// published value directly in the modifier because `.animation`
    /// takes an `Equatable` value, not a binding.
    private var networkMonitorIsOnline: Bool { networkMonitor.isOnline }

    var body: some View {
        ZStack {
            PaladalaBackdrop()

            Group {
                if horizontalSizeClass == .regular {
                    PadRootView(repository: repository)
                } else {
                    PhoneRootView(repository: repository)
                }
            }
        }
        .onAppear {
            // First frame has been rendered.  This is the
            // canonical "time to first frame" anchor — anything
            // visible on screen from here onward is post-load
            // and gets attributed to interactive time, not
            // cold-start time.
            LaunchMetrics.shared.mark(.firstRootViewAppeared)
            router.consumePendingIntentRoute()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Recreate the local HLS proxy on the long
                // background → foreground path.  iOS suspends
                // the `NWListener` and the upstream
                // `URLSession` legs while we are backgrounded;
                // the listener's `state` callback never fires
                // `.cancelled`, so the proxy stays alive-but-
                // dead and every video opened after a long
                // lock screen fails with `NSURLError -1004`.
                // Tearing the proxy down here forces the
                // next `serve(playback:)` to allocate a new
                // port and a fresh upstream session.
                let backgroundDuration: TimeInterval? =
                    lastBackgroundAt.map {
                        Date().timeIntervalSince($0)
                    }
                let wasLong = (backgroundDuration ?? 0)
                    >= Self.longBackgroundThreshold
                diagLog(.lifecycle, "app.foreground", details: [
                    "backgroundSeconds":
                        backgroundDuration.map { String(format: "%.2f", $0) }
                            ?? "unknown",
                    "longBackground": wasLong
                ])
                if wasLong {
                    LocalHLSProxyServer.shared.recreateForResume()
                }
                lastBackgroundAt = nil
                Analytics.log("app_foreground")
                router.consumePendingIntentRoute()
            case .background:
                lastBackgroundAt = Date()
                diagLog(.lifecycle, "app.background")
                Analytics.log("app_background")
            case .inactive:
                diagLog(.lifecycle, "app.inactive")
                Analytics.log("app_inactive")
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
        guard url.scheme == "paladala" || url.scheme == "paladala" else { return }
        switch url.host {
        case "home":
            router.open(.home)
        case "dynamic":
            router.open(.dynamic)
        case "live":
            router.open(.live)
        case "music":
            router.open(.music)
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
    let repository: PaladalaRepository
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

                MusicHomeView(repository: repository)
                    .tabItem { Label(MainTab.music.title, systemImage: MainTab.music.symbolName) }
                    .tag(MainTab.music)

                ProfileSettingsView(repository: repository)
                    .tabItem { Label(MainTab.profile.title, systemImage: MainTab.profile.symbolName) }
                    .tag(MainTab.profile)
            }
            .paladalaTabBarBehavior()
            .navigationDestination(for: BiliVideo.self) { video in
                VideoDetailView(video: video, repository: repository, heroNamespace: heroNamespace)
            }
            .navigationDestination(for: ProfileRoute.self) { route in
                profileRouteView(route, repository: repository)
            }
            .navigationDestination(for: ReplyRoute.self) { route in
                ReplyListView(video: route.video, rootComment: route.rootComment, repository: repository)
            }
            .navigationDestination(for: LocalVideoRoute.self) { route in
                switch route {
                case .local(let record):
                    VideoDetailView(
                        video: record.video,
                        repository: repository,
                        heroNamespace: heroNamespace,
                        localRecord: record
                    )
                }
            }
            .navigationDestination(for: MusicRoute.self) { route in
                switch route {
                case .player(let video):
                    MusicPlayerView(video: video, repository: repository)
                }
            }
        }
        // System-provided interactive pop gesture handles back
        // navigation; `NavigationStack` (iOS 16+) ships with
        // swipe-from-edge built in. No custom gesture needed.
    }
}

private struct PadRootView: View {
    let repository: PaladalaRepository
    @EnvironmentObject private var router: AppRouter
    /// Single shared namespace for the hero / zoom transition.
    @Namespace private var heroNamespace
    /// Sidebar visibility. The collapse button flips this to
    /// `.detailOnly`; the system chevron / drag handle brings it
    /// back to `.all`. `NavigationSplitView` owns the actual
    /// show/hide animation — we just hand it a binding.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Tabs rendered in the sidebar's main list. Excludes `.profile`
    /// because the new design surfaces 我的 as a user card at the
    /// bottom of the sidebar instead of a regular row. The five-case
    /// `MainTab` enum stays unchanged so the phone tab bar keeps
    /// working.
    private static let sidebarTabs: [MainTab] = [.home, .dynamic, .live, .music]

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PadSidebar(
                tabs: Self.sidebarTabs,
                columnVisibility: $columnVisibility
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
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
                    .navigationDestination(for: MusicRoute.self) { route in
                        switch route {
                        case .player(let video):
                            MusicPlayerView(video: video, repository: repository)
                        }
                    }
            }
            // System-provided interactive pop gesture handles
            // back navigation; no custom recognizer needed.
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
        case .music:
            MusicHomeView(repository: repository)
        case .profile:
            ProfileSettingsView(repository: repository)
        }
    }
}

/// New iPad sidebar matching the redesigned mockup:
///
///  ┌────────────────────────────┐
///  │ 🏠  首頁   (pink pill)      │   <- active row gets a
///  │ 🧭  動態                    │      rounded pink capsule
///  │ ((•))  直播                 │
///  │                            │
///  │  ┌──────┐                  │   <- user card: avatar +
///  │  │ {un} │ 我的              │      username + 我的 label
///  │  └──────┘                  │
///  │                            │
///  │ ≡<  收合                    │   <- collapse button
///  └────────────────────────────┘
///
/// All copy is Traditional Chinese; the pink highlight uses
/// `PaladalaTheme.biliPink` to stay consistent with the rest of
/// the app.
private struct PadSidebar: View {
    let tabs: [MainTab]
    @Binding var columnVisibility: NavigationSplitViewVisibility

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        VStack(spacing: 18) {
            tabList
            Spacer(minLength: 0)
            userCard
            collapseButton
        }
        .padding(.horizontal, 18)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PaladalaBackdrop())
    }

    private var tabList: some View {
        VStack(spacing: 6) {
            ForEach(tabs) { tab in
                SidebarRow(
                    tab: tab,
                    isActive: router.selectedTab == tab
                ) {
                    router.open(tab)
                }
            }
        }
    }

    @ViewBuilder
    private var userCard: some View {
        Button {
            router.open(.profile)
        } label: {
            HStack(spacing: 12) {
                sidebarAvatar
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(usernameText)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("我的")
                        .font(.subheadline)
                        .foregroundStyle(PaladalaTheme.biliPink)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius,
                                 style: PaladalaTheme.cornerStyle)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius,
                                 style: PaladalaTheme.cornerStyle)
                    .stroke(PaladalaTheme.biliPink.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                columnVisibility = .detailOnly
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text("收合")
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var usernameText: String {
        authStore.activeAccount?.name ?? "未登入"
    }

    @ViewBuilder
    private var sidebarAvatar: some View {
        if let url = authStore.activeAccount?.faceURL {
            ResilientImage(url: url)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(PaladalaTheme.biliPink.opacity(0.18))
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.body)
                        .foregroundStyle(PaladalaTheme.biliPink)
                )
        }
    }
}

/// One row in the iPad sidebar. Active row gets a rounded pink
/// pill background plus a pink-tinted icon and label; inactive
/// rows use a muted label so the active tab stands out.
private struct SidebarRow: View {
    let tab: MainTab
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: tab.sidebarSymbolName)
                    .font(.body.weight(.semibold))
                    .frame(width: 24)
                    .foregroundStyle(isActive ? PaladalaTheme.biliPink : .secondary)
                Text(tab.title)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? PaladalaTheme.biliPink : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isActive {
                        RoundedRectangle(cornerRadius: PaladalaTheme.pillRadius,
                                         style: PaladalaTheme.cornerStyle)
                            .fill(PaladalaTheme.biliPink.opacity(0.18))
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: PaladalaTheme.pillRadius,
                                           style: PaladalaTheme.cornerStyle))
        }
        .buttonStyle(.plain)
    }
}

@ViewBuilder
private func profileRouteView(_ route: ProfileRoute, repository: PaladalaRepository) -> some View {
    switch route {
    case .history:
        HistoryListView(repository: repository)
    case .favorites(let mid):
        FavoriteFoldersView(repository: repository, mid: mid)
    case .watchLater:
        WatchLaterListView(repository: repository)
    case .downloads:
        DownloadedVideosView(repository: repository)
    }
}

/// Liquid Glass material for the tab bar.
///
/// Uses `.ultraThinMaterial` as the fallback for the iOS 18.5 SDK.
/// When the iOS 26 SDK ships, replace with `.toolbarBackground(.glass,
/// for: .tabBar)` which picks up the underlying content and renders a
/// proper Liquid Glass surface.
private struct LiquidGlassTabBarModifier: ViewModifier {
    let materialDesign: MaterialDesign

    @ViewBuilder
    func body(content: Content) -> some View {
        switch materialDesign {
        case .material3:
            content
        case .liquidGlass:
            content.paladalaToolbarGlass(.liquidGlass)
        }
    }
}
