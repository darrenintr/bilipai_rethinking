import SwiftUI

struct RootView: View {
    let repository: BiliPaiRepository

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var miniPlayerStore: MiniPlayerStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    @AppStorage("bilipai.didOnboard") private var didOnboard: Bool = false

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
        guard url.scheme == "paladala" || url.scheme == "bilipai" else { return }
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
    @EnvironmentObject private var authStore: AuthStore
    /// Single shared namespace for the hero / zoom transition.
    @Namespace private var heroNamespace
    /// Sidebar visibility. The collapse button flips this to
    /// `.detailOnly`; the system chevron / drag handle brings it
    /// back to `.all`. `NavigationSplitView` owns the actual
    /// show/hide animation — we just hand it a binding.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Local mirror of the top-bar search field. On submit we hand
    /// the query to `router.openSearch`, which already routes to
    /// the home tab and stashes `pendingSearchQuery` for `HomeView`
    /// to consume. We keep the local copy so the field stays
    /// in-sync after a search reset.
    @State private var topBarQuery: String = ""

    /// The currently-highlighted sidebar item, derived from the
    /// router's `selectedTab` plus a one-shot `pendingHomeCategory`
    /// (so a Trends tap lights up the Trends row even before
    /// `HomeView` swaps `model.category`) and `activeProfileSection`
    /// (so Collections / History light up when the corresponding
    /// sub-route is on top of the profile tab's nav stack).
    private var activeSidebarItem: PadSidebarItem? {
        if let pending = router.pendingHomeCategory, pending == .popular {
            return .trends
        }
        switch router.selectedTab {
        case .home: return .home
        case .live: return .live
        case .dynamic: return .trends
        case .profile:
            switch router.activeProfileSection {
            case .favorites: return .collections
            case .history: return .history
            case .watchLater: return .history   // watch-later is closest in chrome to history
            case .none: return .settings
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PadSidebar(
                activeItem: activeSidebarItem,
                columnVisibility: $columnVisibility
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            VStack(spacing: 0) {
                PadTopBar(
                    searchQuery: $topBarQuery,
                    notificationCount: router.notificationCount,
                    onSubmitSearch: { router.openSearch(topBarQuery) },
                    onRefresh: { NotificationCenter.default.post(name: .padHomeRefresh, object: nil) },
                    onNotificationTap: { router.open(.dynamic) },
                    onProfileTap: { router.open(.profile) }
                )
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

/// Sidebar items for the redesigned iPad sidebar.
///
/// We keep this as a file-private enum so we don't have to touch
/// `MainTab` (which the iPhone tab bar still uses verbatim). The
/// mapping from each case to actual navigation is handled in
/// `PadSidebar` (and via `AppRouter.open*` helpers for the
/// non-tab items).
private enum PadSidebarItem: String, Hashable, Identifiable, CaseIterable {
    case home
    case trends
    case live
    case collections
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首頁"
        case .trends: return "動態"
        case .live: return "直播"
        case .collections: return "收藏"
        case .history: return "歷史"
        case .settings: return "設定"
        }
    }

    /// SF Symbol shown in the sidebar. Picked for the new mockup's
    /// outline/lightweight icon style: a filled `house.fill` for
    /// Home, `safari` for Trends (the mockup's compass glyph), a
    /// live broadcast icon for Live, `folder` for Collections,
    /// `clock.arrow.circlepath` for History, and `gearshape` for
    /// Settings. Active state reuses the existing pink pill, so
    /// we don't need filled variants here.
    var symbolName: String {
        switch self {
        case .home: return "house.fill"
        case .trends: return "safari"
        case .live: return "dot.radiowaves.left.and.right"
        case .collections: return "folder"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }

    /// Group the item belongs to. Drives the VStack split in
    /// `PadSidebar` (top group vs. bottom group). Marked private
    /// because `SidebarGroup` is private — Swift requires the
    /// accessor and its return type to share visibility.
    private var group: SidebarGroup {
        switch self {
        case .home, .trends, .live, .collections: return .primary
        case .history, .settings: return .secondary
        }
    }

    private enum SidebarGroup { case primary, secondary }

    /// Static ordering for the rendered list.
    static let topGroup: [PadSidebarItem] = [.home, .trends, .live, .collections]
    static let bottomGroup: [PadSidebarItem] = [.history, .settings]
}

/// iPad sidebar matching the redesigned mockup:
///
///  ┌────────────────────────────┐
///  │ Paladala    [≡]   <- brand + collapse
///  │ Video Discovery           │
///  │                            │
///  │ 🏠  首頁   (pink pill)      │   <- top group
///  │ 🧭  動態                    │
///  │ ((•)) 直播                 │
///  │ 📁  收藏                   │
///  │                            │
///  │ 🕘  歷史                   │   <- bottom group
///  │ ⚙  設定                    │
///  │                            │
///  │ ┌──────┐                  │   <- user card
///  │ │ {un} │ 我的 · Pro        │
///  │ └──────┘                  │
///  └────────────────────────────┘
private struct PadSidebar: View {
    let activeItem: PadSidebarItem?
    @Binding var columnVisibility: NavigationSplitViewVisibility

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            brandHeader
            itemGroup(PadSidebarItem.topGroup)
            Spacer(minLength: 0)
            itemGroup(PadSidebarItem.bottomGroup)
            userCard
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PaladalaBackdrop())
    }

    // MARK: Brand header

    private var brandHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Paladala")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(BiliPaiTheme.biliPink)
                Text("Video Discovery")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            collapseIconButton
        }
    }

    private var collapseIconButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                columnVisibility = .detailOnly
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("收合側邊欄")
    }

    // MARK: Item groups

    private func itemGroup(_ items: [PadSidebarItem]) -> some View {
        VStack(spacing: 4) {
            ForEach(items) { item in
                SidebarRow(
                    symbol: item.symbolName,
                    title: item.title,
                    isActive: activeItem == item
                ) {
                    handleTap(item)
                }
            }
        }
    }

    private func handleTap(_ item: PadSidebarItem) {
        Haptics.tap()
        switch item {
        case .home:
            router.open(.home)
        case .trends:
            router.openHomeTrending()
        case .live:
            router.open(.live)
        case .collections:
            router.openCollections(mid: authStore.activeAccount?.mid ?? 0)
        case .history:
            router.openHistory()
        case .settings:
            router.open(.profile)
        }
    }

    // MARK: User card

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
                    Text(sidebarSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(BiliPaiTheme.biliPink)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius,
                                 style: BiliPaiTheme.cornerStyle)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius,
                                 style: BiliPaiTheme.cornerStyle)
                    .stroke(BiliPaiTheme.biliPink.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var usernameText: String {
        authStore.activeAccount?.name ?? "未登入"
    }

    /// Subtitle adapts to login state: "Pro Account" badge for a
    /// signed-in user, "點擊登入" prompt for the empty state.
    /// Previously hard-coded "我的 · Pro Account" looked out of
    /// place whenever the sidebar was showing the sign-in card.
    private var sidebarSubtitle: String {
        authStore.activeAccount == nil ? "點擊登入" : "我的 · Pro Account"
    }

    @ViewBuilder
    private var sidebarAvatar: some View {
        if let url = authStore.activeAccount?.faceURL {
            ResilientImage(url: url)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(BiliPaiTheme.biliPink.opacity(0.18))
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.body)
                        .foregroundStyle(BiliPaiTheme.biliPink)
                )
        }
    }
}

/// Pinned top bar that sits above the iPad detail pane.
///
/// Pinned (not part of the scroll view) so the search field is a
/// normal first responder without the keyboard-input quirks that
/// show up when a TextField lives inside a `ScrollView`. The bar
/// stays visible across every sidebar destination.
private struct PadTopBar: View {
    @Binding var searchQuery: String
    let notificationCount: Int
    let onSubmitSearch: () -> Void
    let onRefresh: () -> Void
    let onNotificationTap: () -> Void
    let onProfileTap: () -> Void

    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        HStack(spacing: 14) {
            searchPill
            Spacer(minLength: 0)
            refreshButton
            notificationButton
            profilePill
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(PaladalaBackdrop())
    }

    // MARK: Search

    private var searchPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜尋 Paladala 影片", text: $searchQuery)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit(onSubmitSearch)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 420, minHeight: 40)
        .background(
            Color.primary.opacity(0.06),
            in: .rect(cornerRadius: 20, style: .continuous)
        )
    }

    // MARK: Refresh / notification

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(
                    Color.primary.opacity(0.06),
                    in: .rect(cornerRadius: 18, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("重新整理")
    }

    private var notificationButton: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onNotificationTap) {
                Image(systemName: "bell")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(
                        Color.primary.opacity(0.06),
                        in: .rect(cornerRadius: 18, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            if notificationCount > 0 {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5)
                    )
                    .offset(x: 4, y: 4)
            }
        }
        .accessibilityLabel("通知")
    }

    // MARK: Profile pill

    private var profilePill: some View {
        Button(action: onProfileTap) {
            HStack(spacing: 8) {
                profileAvatar
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("個人中心")
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let url = authStore.activeAccount?.faceURL {
            ResilientImage(url: url)
        } else {
            Circle()
                .fill(BiliPaiTheme.biliPink.opacity(0.18))
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.caption)
                        .foregroundStyle(BiliPaiTheme.biliPink)
                )
        }
    }
}

/// One row in the iPad sidebar. Active row gets a rounded pink
/// pill background plus a pink-tinted icon and label; inactive
/// rows use a muted label so the active tab stands out.
private struct SidebarRow: View {
    let symbol: String
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .frame(width: 24)
                    .foregroundStyle(isActive ? BiliPaiTheme.biliPink : .secondary)
                Text(title)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? BiliPaiTheme.biliPink : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isActive {
                        RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius,
                                         style: BiliPaiTheme.cornerStyle)
                            .fill(BiliPaiTheme.biliPink.opacity(0.18))
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius,
                                           style: BiliPaiTheme.cornerStyle))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Notification bridging

extension Notification.Name {
    /// Fired by `PadTopBar.refreshButton` so the iPad home view can
    /// reload its feed without having to hold a direct reference
    /// to `HomeViewModel`. Mirrors the existing
    /// `.homeShowBundledFallback` / `.watchLaterDidChange` pattern.
    static let padHomeRefresh = Notification.Name("bilipai.pad.home.refresh")
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
            content.bilipaiToolbarGlass(.liquidGlass)
        }
    }
}
