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
    /// One-shot gate for the OnboardingView presentation.
    /// Flipped to `true` from `onAppear` so the
    /// `fullScreenCover` binding only evaluates after the
    /// first frame has rendered.  Previously the binding
    /// was `!didOnboard` evaluated on every body call —
    /// that pushed the OnboardingView onto the screen
    /// before any other init could claim the first frame.
    @State private var hasPresentedFirstFrame: Bool = false
    /// One-shot app opening overlay. It is mounted above the
    /// root shell only for the first launch moment, then removed
    /// from the hierarchy so it cannot intercept navigation,
    /// sheets, or video gestures.
    @State private var isOpeningAnimationVisible: Bool = true
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
            // Flip the OnboardingView gate so the fullScreenCover
            // can present after this frame.  Deferred from
            // initial body eval so a fresh launch that hasn't
            // onboarded yet doesn't pay the OnboardingView
            // construction cost on the cold-start critical path.
            if !hasPresentedFirstFrame {
                hasPresentedFirstFrame = true
            }
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
            // Apple's iOS 26 sheet guidance: surface a drag
            // indicator so the user can see the sheet is
            // dismissable without first trying to drag. The
            // explicit "关闭" toolbar button is the primary
            // dismiss affordance; the indicator is the
            // secondary gesture affordance.
            LoginSheet()
                .presentationDragIndicator(.visible)
                .paladalaSheetGlass()
        }
        .modifier(LiquidGlassTabBarModifier(materialDesign: materialDesign))
        .fullScreenCover(isPresented: Binding(
            get: { hasPresentedFirstFrame && !didOnboard },
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
            HStack {
                Spacer(minLength: 16)
                MiniPlayerOverlay()
                    .frame(maxWidth: horizontalSizeClass == .regular ? 360 : 340)
            }
            .padding(.trailing, horizontalSizeClass == .regular ? 32 : 16)
            .padding(.bottom, horizontalSizeClass == .regular ? 32 : 80)
            .animation(.spring(response: 0.35, dampingFraction: 0.85),
                       value: miniPlayerIsShowing)
        }
        .overlay {
            if isOpeningAnimationVisible {
                OpeningScreenAnimation {
                    isOpeningAnimationVisible = false
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
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
        case "up":
            // `paladala://up/<mid>` deep link — resolve the
            // numeric mid from the first path component and
            // push the UP profile. Falls through silently on
            // a non-numeric mid so a malformed URL never
            // crashes the app.
            let mid = Int64(url.pathComponents.first(where: { $0 != "/" }) ?? "")
            if let mid, mid > 0 {
                router.openUP(mid: mid)
            }
        default:
            break
        }
    }
}

private struct OpeningScreenAnimation: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var tileScale: CGFloat = 0.78
    @State private var tileRotation: Double = -8
    @State private var tileOpacity: Double = 0
    @State private var playScale: CGFloat = 0.72
    @State private var playOpacity: Double = 0
    @State private var titleOffset: CGFloat = 14
    @State private var titleOpacity: Double = 0
    @State private var accentProgress: CGFloat = 0
    @State private var shimmerOffset: CGFloat = -150
    @State private var screenOpacity: Double = 1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background

                VStack(spacing: 22) {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: 32,
                            style: PaladalaTheme.cornerStyle
                        )
                        .fill(.ultraThinMaterial)
                        .frame(width: 118, height: 118)
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: 32,
                                style: PaladalaTheme.cornerStyle
                            )
                            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.8)
                        }
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.12),
                            radius: 34,
                            y: 20
                        )

                        RoundedRectangle(
                            cornerRadius: 25,
                            style: PaladalaTheme.cornerStyle
                        )
                        .fill(PaladalaTheme.biliPink)
                        .frame(width: 82, height: 82)
                        .overlay(alignment: .topLeading) {
                            highlightSweep
                                .frame(width: 70, height: 120)
                                .offset(x: shimmerOffset)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 25,
                                        style: PaladalaTheme.cornerStyle
                                    )
                                )
                        }

                        Image(systemName: "play.fill")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 3)
                            .scaleEffect(playScale)
                            .opacity(playOpacity)
                    }
                    .scaleEffect(tileScale)
                    .rotationEffect(.degrees(tileRotation))
                    .opacity(tileOpacity)

                    VStack(spacing: 9) {
                        Text("Paladala")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .foregroundStyle(.primary)
                        premiumAccent
                            .frame(width: 86, height: 3)
                            .scaleEffect(x: accentProgress, anchor: .leading)
                    }
                    .opacity(titleOpacity)
                    .offset(y: titleOffset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, geo.safeAreaInsets.bottom + 24)
            }
            .opacity(screenOpacity)
            .ignoresSafeArea()
        }
        .onAppear { run() }
    }

    private var background: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            VStack(spacing: 0) {
                Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.05)
                    .frame(height: 1)
                Spacer()
                Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.04)
                    .frame(height: 1)
            }
            VStack {
                Spacer()
                premiumAccent
                    .frame(height: 2)
                    .opacity(0.42)
                    .padding(.horizontal, 72)
                    .padding(.bottom, 118)
                    .scaleEffect(x: accentProgress, anchor: .center)
            }
        }
    }

    private var premiumAccent: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        PaladalaTheme.cyan,
                        PaladalaTheme.biliPink,
                        PaladalaTheme.violet
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }

    private var highlightSweep: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        .white.opacity(0),
                        .white.opacity(0.42),
                        .white.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .rotationEffect(.degrees(18))
    }

    private func run() {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                tileOpacity = 1
                playOpacity = 1
                titleOpacity = 1
                titleOffset = 0
                tileScale = 1
                tileRotation = 0
                playScale = 1
                accentProgress = 1
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 650_000_000)
                withAnimation(.easeOut(duration: 0.18)) {
                    screenOpacity = 0
                }
                try? await Task.sleep(nanoseconds: 180_000_000)
                onFinished()
            }
            return
        }

        withAnimation(.spring(response: 0.58, dampingFraction: 0.76)) {
            tileOpacity = 1
            tileScale = 1
            tileRotation = 0
        }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.68).delay(0.12)) {
            playOpacity = 1
            playScale = 1
        }
        withAnimation(.easeOut(duration: 0.32).delay(0.18)) {
            titleOpacity = 1
            titleOffset = 0
        }
        withAnimation(.easeInOut(duration: 0.42).delay(0.24)) {
            accentProgress = 1
        }
        withAnimation(.easeInOut(duration: 0.76).delay(0.28)) {
            shimmerOffset = 110
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            withAnimation(.easeInOut(duration: 0.32)) {
                screenOpacity = 0
                tileScale = 1.04
            }
            try? await Task.sleep(nanoseconds: 340_000_000)
            onFinished()
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
                    .tabItem {
                        // Apple's recommended "select bounce" — the
                        // SF Symbol scales up + back down when the
                        // value flips. Previously the binder was
                        // `selectedTab` itself, which made every
                        // tab icon observe the same value and
                        // bounce on every switch. The bool
                        // per-tab now flips only for the freshly
                        // selected one, matching HIG.
                        Label {
                            Text(MainTab.home.title)
                        } icon: {
                            Image(systemName: MainTab.home.symbolName)
                                .symbolEffect(.bounce, value: router.selectedTab == MainTab.home)
                        }
                    }
                    .tag(MainTab.home)

                DynamicFeedView(repository: repository, heroNamespace: heroNamespace)
                    .tabItem {
                        Label {
                            Text(MainTab.dynamic.title)
                        } icon: {
                            Image(systemName: MainTab.dynamic.symbolName)
                                .symbolEffect(.bounce, value: router.selectedTab == MainTab.dynamic)
                        }
                    }
                    .tag(MainTab.dynamic)

                LiveRoomsView(repository: repository)
                    .tabItem {
                        Label {
                            Text(MainTab.live.title)
                        } icon: {
                            Image(systemName: MainTab.live.symbolName)
                                .symbolEffect(.bounce, value: router.selectedTab == MainTab.live)
                        }
                    }
                    .tag(MainTab.live)

                MusicHomeView(repository: repository)
                    .tabItem {
                        Label {
                            Text(MainTab.music.title)
                        } icon: {
                            Image(systemName: MainTab.music.symbolName)
                                .symbolEffect(.bounce, value: router.selectedTab == MainTab.music)
                        }
                    }
                    .tag(MainTab.music)

                ProfileSettingsView(repository: repository)
                    .tabItem {
                        Label {
                            Text(MainTab.profile.title)
                        } icon: {
                            Image(systemName: MainTab.profile.symbolName)
                                .symbolEffect(.bounce, value: router.selectedTab == MainTab.profile)
                        }
                    }
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
            .navigationDestination(for: UPProfileRoute.self) { route in
                switch route {
                case .up(let mid):
                    UPProfileView(mid: mid, repository: repository)
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
                    .navigationDestination(for: UPProfileRoute.self) { route in
                        switch route {
                        case .up(let mid):
                            UPProfileView(mid: mid, repository: repository)
                        }
                    }
            }
            // System-provided interactive pop gesture handles
            // back navigation; no custom recognizer needed.
        }
    }

    @ViewBuilder
    private var selectedView: some View {
        // Wrap the tab content in a ZStack keyed by `router.selectedTab`
        // so swapping tabs animates the outgoing / incoming view
        // with a crossfade + slide instead of a hard cut.  The
        // `.id(...)` on the inner view forces SwiftUI to discard the
        // previous tab's state (scroll position, async tasks) which
        // also fixes the "iPad sidebar tap doesn't switch" symptom —
        // without the id the navigation stack would sometimes keep
        // showing the prior destination when both tabs route to the
        // same `NavigationStack` shape.
        ZStack {
            switch router.selectedTab {
            case .home:
                HomeView(repository: repository, heroNamespace: heroNamespace)
                    .transition(ScreenSwitchTransition.active)
                    .id(MainTab.home)
            case .dynamic:
                DynamicFeedView(repository: repository, heroNamespace: heroNamespace)
                    .transition(ScreenSwitchTransition.active)
                    .id(MainTab.dynamic)
            case .live:
                LiveRoomsView(repository: repository)
                    .transition(ScreenSwitchTransition.active)
                    .id(MainTab.live)
            case .music:
                MusicHomeView(repository: repository)
                    .transition(ScreenSwitchTransition.active)
                    .id(MainTab.music)
            case .profile:
                ProfileSettingsView(repository: repository)
                    .transition(ScreenSwitchTransition.active)
                    .id(MainTab.profile)
            }
        }
        .animation(ScreenSwitchTransition.animation, value: router.selectedTab)
    }
}

/// Animation contract for tab → tab screen swaps. Centralised
/// here so the iPad sidebar (`PadRootView.selectedView`), the
/// phone tab bar, and any future navigation root all use the
/// same crossfade + slight scale curve.  Tweak the curve in one
/// place and the whole app picks it up.
enum ScreenSwitchTransition {
    /// The transition applied to the outgoing / incoming tab content.
    /// `.opacity` keeps both views readable mid-animation; `.scale`
    /// adds a subtle 2 % depth cue so the change reads as motion,
    /// not a blink.
    static let active: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.985))
            .combined(with: .offset(y: 6)),
        removal: .opacity.combined(with: .scale(scale: 1.01))
    )

    /// Driver animation — slightly bouncy so the swap feels alive
    /// rather than mechanical, but tuned short enough (260 ms) that
    /// the user never waits for the chrome to settle.
    static let animation: Animation = .spring(response: 0.26, dampingFraction: 0.86)
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
    case .favoriteFolder(let folder):
        FavoriteFolderVideosView(repository: repository, folder: folder)
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
