import SwiftUI

struct HomeView: View {
    let repository: PaladalaRepository
    /// Optional namespace for the hero / zoom navigation
    /// transition. Threaded down to each `VideoCard` so the
    /// cover image registers as a `matchedTransitionSource`.
    /// `nil` disables the transition (the card still works,
    /// the navigation just falls back to the system
    /// cross-fade).
    let heroNamespace: Namespace.ID?

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var model = HomeViewModel()
    @State private var isShortVideoFeedPresented = false
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    init(repository: PaladalaRepository, heroNamespace: Namespace.ID? = nil) {
        self.repository = repository
        self.heroNamespace = heroNamespace
    }

    /// Resolved on every call so account switches in
    /// `ProfileSettingsView` are reflected in the follow-feed filter
    /// on the next refresh — the view model never caches it.
    private var accountMid: Int64 { authStore.activeAccount?.mid ?? 0 }

    private var columns: [GridItem] {
        // Card-to-card gap tuned for a clear "distinct container"
        // read; minimum column width 146 keeps 2 columns on
        // iPhone SE with the 28 pt inter-column gap.
        let minimumWidth: CGFloat = horizontalSizeClass == .regular ? 220 : 146
        return [
            GridItem(
                .adaptive(minimum: minimumWidth),
                spacing: 28,
                alignment: .top
            )
        ]
    }

    var body: some View {
        ScrollViewReader { proxy in
            feedContent(scrollProxy: proxy)
                .background(Color.clear)
                .navigationTitle("Paladala")
                // Apple large-title guidance for top-level
                // navigation: the title collapses into the
                // chrome on scroll and re-expands when the
                // scroll returns to top. The system handles
                // the animation; we just enable the mode.
                .navigationBarTitleDisplayMode(.large)
                // System-provided search bar. Replaces the
                // hand-rolled pill surface in `feedContent` —
                // gets the magnifying-glass icon, clear
                // button, cancel affordance, and search scopes
                // integration for free.
                .searchable(
                    text: $model.searchQuery,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索 Bilibili 视频和 UP 主"
                )
                .onSubmit(of: .search) {
                    model.category = .search
                    Task { await model.load(repository: repository, accountMid: accountMid) }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        // 离线缓存 quick access. Lives in the top
                        // toolbar so the user can reach their
                        // downloaded videos without going through
                        // the profile tab. `.badge(Int)` gives the
                        // iOS-standard corner pill — adapts to dark
                        // mode + Increase Contrast automatically.
                        Button {
                            Haptics.tap()
                            router.open(.downloads)
                        } label: {
                            Label("离线缓存", systemImage: "arrow.down.circle")
                        }
                        .badge(DownloadStore.shared.records.count)
                        Button {
                            Haptics.tap()
                            isShortVideoFeedPresented = true
                        } label: {
                            Label("短视频", systemImage: "rectangle.portrait.on.rectangle.portrait")
                        }
                        Button {
                            Haptics.tap()
                            Task { await model.load(repository: repository, accountMid: accountMid) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh")
                        Button {
                            router.open(.dynamic)
                        } label: {
                            Image(systemName: "bell")
                        }
                        Button {
                            router.open(.profile)
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
                .modifier(HomeToolbarGlassModifier(materialDesign: materialDesign))
                .task {
                    if model.videos.isEmpty && model.liveRooms.isEmpty {
                        LaunchMetrics.shared.mark(.firstFeedNetworkStart)
                        await model.load(repository: repository, accountMid: accountMid)
                        LaunchMetrics.shared.mark(.firstFeedNetworkComplete)
                    }
                }
                .onChange(of: model.category) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("feedTop", anchor: .top)
                    }
                    Task { await model.load(repository: repository, accountMid: accountMid) }
                }
                .onChange(of: model.popularSubCategory) { _, _ in
                    guard model.category == .popular else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("feedTop", anchor: .top)
                    }
                    Task { await model.load(repository: repository, accountMid: accountMid) }
                }
                .onChange(of: router.pendingSearchQuery) { _, query in
                    Task { await model.applyIntentSearch(query, repository: repository, accountMid: accountMid) }
                }
                .onChange(of: accountMid) { _, _ in
                    guard model.category == .follow else { return }
                    Task { await model.load(repository: repository, accountMid: accountMid) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .homeShowBundledFallback)) { _ in
                    model.showBundledFallback(repository: repository)
                }
                .fullScreenCover(isPresented: $isShortVideoFeedPresented) {
                    ShortVideoFeedView(repository: repository)
                }
        }
    }

    /// The scrollable feed body. The `ScrollViewReader` lives in `body`
    /// so the `proxy` it provides is in scope for the `.refreshable`
    /// modifier, which needs to scroll back to the top of the feed.
    @ViewBuilder
    private func feedContent(scrollProxy proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                Color.clear
                    .frame(height: 0)
                    .id("feedTop")

                categoryStrip
                // [TESTING] visible label so an on-device tester
                // can tell at a glance this is the cover-overlap
                // fix build.
                HStack(spacing: 6) {
                    Image(systemName: "ladybug.fill")
                    Text("TESTING BUILD · 直播 HLS 代理 + 多 CDN 故障转移")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color.orange)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.category == .popular {
                    popularSubCategoryStrip
                }
                if let error = model.errorMessage {
                    VStack(spacing: 10) {
                        ErrorBanner(message: error)
                        Button {
                            model.showBundledFallback(repository: repository)
                        } label: {
                            Label("查看离线样例", systemImage: "wifi.slash")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                if model.isShowingBundledFallback {
                    HomeOfflineBanner {
                        Task {
                            await model.load(repository: repository, accountMid: accountMid)
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("feedTop", anchor: .top)
                            }
                        }
                    }
                }
                if model.isLoading && model.videos.isEmpty && model.liveRooms.isEmpty && model.dynamicItems.isEmpty {
                    // Skeleton grid only on the *first* load — once
                    // any data is in `videos` / `liveRooms` /
                    // `dynamicItems` we let the user see what we have
                    // and use the inline "加载更多" spinner at the
                    // bottom for paginated loads.
                    SkeletonGrid()
                        .padding(.top, 4)
                } else if model.category == .live && !model.liveRooms.isEmpty {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(model.liveRooms) { room in
                            LiveRoomCard(room: room)
                        }
                    }
                    // Extra outer horizontal margin so the card grid
                    // breathes more than the rest of the feed
                    // (search bar / category strip / banners). 8pt
                    // per side on top of the feed's 16pt container
                    // padding — enough to read at a glance without
                    // collapsing the column count on iPhone.
                    .padding(.horizontal, 8)
                } else if model.category == .follow {
                    DynamicFeedList(model: model, repository: repository)
                } else if model.videos.isEmpty && !(model.category == .search && !model.searchUsers.isEmpty) {
                    HomeEmptyState(
                        category: model.category,
                        searchQuery: model.searchQuery,
                        hasError: model.errorMessage != nil,
                        onRetry: {
                            Task { await model.load(repository: repository, accountMid: accountMid) }
                        }
                    )
                } else {
                    if model.category == .recommend {
                        TodayWatchCard(videos: Array(model.videos.prefix(4)))
                            .padding(.bottom, 4)
                    }
                    if model.category == .search && !model.searchUsers.isEmpty {
                        SearchUserResultsStrip(users: model.searchUsers)
                            .padding(.bottom, 2)
                    }
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                            VideoCard(
                                video: video,
                                repository: repository,
                                heroNamespace: heroNamespace,
                                action: { router.openVideo(video) }
                            )
                            .frame(maxWidth: .infinity)
                            .id(video.id)
                            // One-shot stagger fan-in on the
                            // initial session load. Each card fades
                            // in with a small delay so the grid
                            // feels alive instead of popping in.
                            // Capped at index 12 (≈420 ms total)
                            // so the 13th card and beyond mount at
                            // their natural pace — otherwise the
                            // bottom of the grid would still be
                            // fading in 700 ms after the top, which
                            // reads as laggy on a fast scroll-back.
                            .opacity(model.firstPageAnimated ? 1 : 0)
                            .offset(y: model.firstPageAnimated ? 0 : 12)
                            .animation(
                                .easeOut(duration: 0.32)
                                    .delay(Double(min(index, 12)) * 0.035),
                                value: model.firstPageAnimated
                            )
                            .onAppear {
                                triggerLoadMoreIfNeeded(currentIndex: index)
                            }
                        }
                    }
                    // Extra outer horizontal margin so the video
                    // cards sit further from the screen edges than
                    // the rest of the feed chrome. Mirrors the
                    // live-room grid above for a consistent feel.
                    .padding(.horizontal, 8)
                    paginationFooter
                }
            }
            .padding(PaladalaTheme.contentPadding)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            Haptics.medium()
            await model.load(repository: repository, accountMid: accountMid)
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("feedTop", anchor: .top)
            }
        }
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            PaladalaGlassContainer(materialDesign: materialDesign, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(HomeCategory.androidTabs) { category in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                model.category = category
                            }
                            Haptics.selection()
                        } label: {
                            Text(category.title)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 9)
                                .paladalaSelectionChip(
                                    isSelected: model.category == category,
                                    design: materialDesign
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var popularSubCategoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            PaladalaGlassContainer(materialDesign: materialDesign, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(PopularSubCategory.allCases) { subCategory in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                model.popularSubCategory = subCategory
                            }
                            Haptics.selection()
                        } label: {
                            Text(subCategory.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .paladalaSelectionChip(
                                    isSelected: model.popularSubCategory == subCategory,
                                    design: materialDesign
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if model.isLoadingMore {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("加载更多…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        } else if model.videos.count > 0 && model.category != .live {
            // Replace the "— 没有更多了 —" caption with a real action. The
            // user can either pull-to-refresh, tap the "换一批" button to
            // re-request the next page (works when the upstream endpoint
            // sometimes returned a short page), or tap "重新加载" when the
            // current list is the bundled offline sample set.
            VStack(spacing: 10) {
                if model.isShowingBundledFallback {
                    Text("当前展示离线样例数据")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await model.load(repository: repository, accountMid: accountMid) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        Task { await model.loadNextBatch(repository: repository, accountMid: accountMid) }
                    } label: {
                        Label("换一批", systemImage: "infinity")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        } else if model.category == .follow && model.dynamicHasMore && !model.dynamicItems.isEmpty {
            Button {
                Task { await model.loadMore(repository: repository, accountMid: accountMid) }
            } label: {
                Label("查看更多关注动态", systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        }
    }

    private func triggerLoadMoreIfNeeded(currentIndex: Int) {
        // Pre-fetch when the user gets within the last four visible cells of
        // the loaded page. Anything tighter makes the bottom of the grid feel
        // empty for a moment; anything looser wastes requests.
        let threshold = max(0, model.videos.count - 4)
        guard currentIndex >= threshold else { return }
        Task { await model.loadMore(repository: repository, accountMid: accountMid) }
    }
}

private struct HomeOfflineBanner: View {
    let onRetry: () -> Void
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.title3)
                .foregroundStyle(PaladalaTheme.biliPink)
            VStack(alignment: .leading, spacing: 2) {
                Text("网络异常 · 当前为离线样例")
                    .font(.subheadline.weight(.semibold))
                Text("下拉或点“重新加载”即可拉取 Bilibili 公共内容源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新加载", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .paladalaCardSurface(materialDesign)
    }
}

private struct SearchUserResultsStrip: View {
    let users: [BiliUserSearchResult]
    @EnvironmentObject private var router: AppRouter
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("相关 UP 主", systemImage: "person.2")
                .font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(users) { user in
                        Button {
                            Haptics.selection()
                            router.openUP(mid: user.mid)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    CoverImage(url: user.faceURL)
                                        .frame(width: 42, height: 42)
                                        .clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(user.name)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Text("\(user.fans.compactCount) 粉丝 · \(user.videos.compactCount) 视频")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                if !user.sign.isEmpty {
                                    Text(user.sign)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(width: 210, alignment: .leading)
                            .padding(12)
                            .paladalaCardSurface(materialDesign)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private final class ShortVideoFeedViewModel: ObservableObject {
    @Published var videos: [BiliVideo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var freshIndex = 0

    func load(repository: PaladalaRepository, replacing: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let next = try await repository.shortVideoFeed(freshIndex: freshIndex)
            freshIndex += 1
            if replacing {
                videos = next
            } else {
                let existing = Set(videos.map(\.id))
                videos.append(contentsOf: next.filter { !existing.contains($0.id) })
            }
        } catch {
            errorMessage = "短视频加载失败：\(error.localizedDescription)"
        }
        isLoading = false
    }
}

private struct ShortVideoFeedView: View {
    let repository: PaladalaRepository

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = ShortVideoFeedViewModel()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                            ShortVideoPage(video: video, size: geo.size) {
                                dismiss()
                                router.openVideo(video)
                            }
                            .onAppear {
                                if index >= max(0, model.videos.count - 3) {
                                    Task { await model.load(repository: repository, replacing: false) }
                                }
                            }
                        }
                        if model.isLoading && model.videos.isEmpty {
                            ProgressView()
                                .tint(.white)
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .ignoresSafeArea()
            }

            if let error = model.errorMessage, model.videos.isEmpty {
                ErrorBanner(message: error)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 18)
            .padding(.trailing, 16)
        }
        .task {
            if model.videos.isEmpty {
                await model.load(repository: repository)
            }
        }
    }
}

private struct ShortVideoPage: View {
    let video: BiliVideo
    let size: CGSize
    let open: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverImage(url: video.coverURL)
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.3), .black.opacity(0.86)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            VStack(alignment: .leading, spacing: 12) {
                Text(video.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                Text(video.ownerName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label("播放", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(PaladalaTheme.biliPink, in: Capsule())
                    Text(video.duration.mmss)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 44)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

private struct HomeEmptyState: View {
    let category: HomeCategory
    let searchQuery: String
    let hasError: Bool
    var isLoggedIn = false
    var onRetry: (() -> Void)? = nil
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            HStack(spacing: 10) {
                if let onRetry {
                    Button {
                        Haptics.tap()
                        onRetry()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    Haptics.tap()
                    // The bundled-fallback call is bound at the
                    // call-site (HomeView) — the empty state view
                    // itself does not know the repository. Surface
                    // the action via the environment instead.
                    NotificationCenter.default.post(name: .homeShowBundledFallback, object: nil)
                } label: {
                    Label("查看离线样例", systemImage: "wifi.slash")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var title: String {
        if hasError { return "内容加载失败" }
        if category == .follow { return isLoggedIn ? "暂无关注动态" : "关注内容需要登录" }
        if category == .live { return "暂无直播间" }
        if category == .search && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "搜索 Bilibili"
        }
        return "暂无视频"
    }

    private var systemImage: String {
        if category == .follow { return "person.2" }
        if category == .live { return "play.tv" }
        if category == .search { return "magnifyingglass" }
        return "play.rectangle"
    }

    private var description: String {
        if hasError { return "下拉重试或查看离线样例。" }
        if category == .follow {
            return isLoggedIn
                ? "当前账号暂时没有可展示的关注动态，下拉刷新或稍后再试。"
                : "登录账号后查看关注 UP 主的视频、专栏、番剧和直播开播动态。"
        }
        if category == .live {
            return "下拉刷新 Bilibili 公共直播列表。"
        }
        if category == .search && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "输入关键词后加载 Bilibili 公共搜索结果。"
        }
        return "换个关键词，或切换到热门、排行榜、分区内容。"
    }
}

extension Notification.Name {
    /// Posted by `HomeEmptyState` when the user taps the "查看离线
    /// 样例" button. The home view subscribes and calls
    /// `model.showBundledFallback(repository:)`. We use a
    /// notification so the empty-state view stays decoupled from
    /// the repository.
    static let homeShowBundledFallback = Notification.Name("paladala.home.showBundledFallback")
}

/// Applies Liquid Glass background to the navigation bar toolbar
/// on the home screen.
private struct HomeToolbarGlassModifier: ViewModifier {
    let materialDesign: MaterialDesign

    func body(content: Content) -> some View {
        if materialDesign == .liquidGlass {
            content.paladalaNavBarGlass(.liquidGlass)
        } else {
            content
        }
    }
}

/// Follow-tab renderer. Each card reuses the chrome shape from
/// `DynamicFeedView` (avatar row + text + optional attached video)
/// so the visual language matches the standalone 动态 tab. The list
/// also pre-fetches the next offset page when the user approaches
/// the bottom — same trigger window as `DynamicFeedView`.
private struct DynamicFeedList: View {
    let model: HomeViewModel
    let repository: PaladalaRepository
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        if model.dynamicNeedsLogin {
            HomeEmptyState(
                category: .follow,
                searchQuery: "",
                hasError: false,
                isLoggedIn: authStore.isLoggedIn
            )
        } else if model.dynamicItems.isEmpty && !model.isLoading {
            HomeEmptyState(
                category: .follow,
                searchQuery: "",
                hasError: false,
                isLoggedIn: authStore.isLoggedIn
            )
        } else {
            LazyVStack(spacing: 14) {
                ForEach(Array(model.dynamicItems.enumerated()), id: \.element.id) { index, post in
                    DynamicPostCard(post: post)
                        .onAppear {
                            if index >= max(0, model.dynamicItems.count - 5) {
                                Task { await model.loadMore(repository: repository, accountMid: authStore.activeAccount?.mid ?? 0) }
                            }
                        }
                }
                if model.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
        }
    }
}

/// Card chrome for a single dynamic post. Mirrors the rows in
/// `DynamicFeedView` so the follow tab and the standalone 动态 tab
/// render the same shapes — same avatar, same text, same attached
/// `VideoCard`. Kept private to this file because the public
/// `DynamicFeedView` body inlines its own copy; refactoring both to
/// share this type is the next cleanup pass once we know which shapes
/// the follow tab needs.
private struct DynamicPostCard: View {
    let post: DynamicPost
    @EnvironmentObject private var router: AppRouter
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.author)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(post.timeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if post.kind == .liveStarted {
                            Text("· 开播")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PaladalaTheme.biliPink)
                        } else if post.kind == .article {
                            Text("· 专栏")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else if post.kind == .forward {
                            Text("· 转发")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            if !post.text.isEmpty {
                Text(post.text)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let video = post.attachedVideo {
                VideoCard(video: video, action: { router.openVideo(video) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .paladalaCardSurface(materialDesign)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = post.authorAvatarURL {
            CoverImage(url: url)
                .frame(width: 42, height: 42)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(PaladalaTheme.biliPink.opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay(Text(String(post.author.prefix(1))).font(.headline))
        }
    }
}

private struct TodayWatchCard: View {
    let videos: [BiliVideo]
    @EnvironmentObject private var router: AppRouter
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("今日看什么", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text("今晚轻松看")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PaladalaTheme.biliPink)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(videos) { video in
                        Button {
                            router.openVideo(video)
                        } label: {
                            HStack(spacing: 10) {
                                CoverImage(url: video.coverURL)
                                    .frame(width: 110, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(video.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(2)
                                    Text("基于最近播放的本地推荐位")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(width: 270, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .paladalaCardSurface(materialDesign)
    }
}
