import SwiftUI

struct HomeView: View {
    let repository: BiliPaiRepository
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
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    init(repository: BiliPaiRepository, heroNamespace: Namespace.ID? = nil) {
        self.repository = repository
        self.heroNamespace = heroNamespace
    }

    /// Resolved on every call so account switches in
    /// `ProfileSettingsView` are reflected in the follow-feed filter
    /// on the next refresh — the view model never caches it.
    private var accountMid: Int64 { authStore.activeAccount?.mid ?? 0 }

    private var columns: [GridItem] {
        let minimumWidth: CGFloat = horizontalSizeClass == .regular ? 220 : 156
        return [
            GridItem(
                .adaptive(minimum: minimumWidth),
                spacing: 12,
                alignment: .top
            )
        ]
    }

    var body: some View {
        // iPad gets the redesigned layout (top bar lives in
        // `PadRootView`, so this view is just the body content).
        // iPhone keeps the original `ScrollViewReader`-driven
        // layout untouched.
        if horizontalSizeClass == .regular {
            iPadHomeContent(
                model: model,
                repository: repository,
                heroNamespace: heroNamespace
            )
        } else {
            phoneBody
        }
    }

    /// The original iPhone layout. Extracted into a private computed
    /// view so the `horizontalSizeClass` branch in `body` reads
    /// cleanly without disturbing the existing
    /// `ScrollViewReader` / `feedContent` wiring.
    private var phoneBody: some View {
        ScrollViewReader { proxy in
            feedContent(scrollProxy: proxy)
                .background(Color.clear)
                .navigationTitle("Paladala")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
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
                        await model.load(repository: repository, accountMid: accountMid)
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

                searchBar
                categoryStrip
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
                    LazyVGrid(columns: columns, spacing: 16) {
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
                } else if model.videos.isEmpty {
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
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                            VideoCard(
                                video: video,
                                repository: repository,
                                heroNamespace: heroNamespace,
                                action: { router.openVideo(video) }
                            )
                            .frame(maxWidth: .infinity)
                            .id(video.id)
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
            .padding(BiliPaiTheme.contentPadding)
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

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索 Bilibili 视频", text: $model.searchQuery)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit {
                    model.category = .search
                    Task { await model.load(repository: repository, accountMid: accountMid) }
                }
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .bilipaiPillSurface(materialDesign)
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            BiliPaiGlassContainer(materialDesign: materialDesign, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(HomeCategory.androidTabs) { category in
                        Button {
                            model.category = category
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
            BiliPaiGlassContainer(materialDesign: materialDesign, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(PopularSubCategory.allCases) { subCategory in
                        Button {
                            model.popularSubCategory = subCategory
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
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.title3)
                .foregroundStyle(BiliPaiTheme.biliPink)
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
        .bilipaiCardSurface(materialDesign)
    }
}

private struct HomeEmptyState: View {
    let category: HomeCategory
    let searchQuery: String
    let hasError: Bool
    var isLoggedIn = false
    var onRetry: (() -> Void)? = nil
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(BiliPaiTheme.biliPink.opacity(0.8))
                .padding(.bottom, 2)
            VStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
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
        .padding()
        .bilipaiCardSurface(materialDesign)
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
    static let homeShowBundledFallback = Notification.Name("bilipai.home.showBundledFallback")
}

/// Applies Liquid Glass background to the navigation bar toolbar
/// on the home screen.
private struct HomeToolbarGlassModifier: ViewModifier {
    let materialDesign: MaterialDesign

    func body(content: Content) -> some View {
        if materialDesign == .liquidGlass {
            content.bilipaiNavBarGlass(.liquidGlass)
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
    let repository: BiliPaiRepository
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
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

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
                                .foregroundStyle(BiliPaiTheme.biliPink)
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
        .bilipaiCardSurface(materialDesign)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = post.authorAvatarURL {
            CoverImage(url: url)
                .frame(width: 42, height: 42)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(BiliPaiTheme.biliPink.opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay(Text(String(post.author.prefix(1))).font(.headline))
        }
    }
}

private struct TodayWatchCard: View {
    let videos: [BiliVideo]
    @EnvironmentObject private var router: AppRouter
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("今日看什么", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text("今晚轻松看")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BiliPaiTheme.biliPink)
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
                                    .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
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
        .bilipaiCardSurface(materialDesign)
    }
}

// MARK: - iPad layout
//
// The redesigned iPad home lives entirely below the
// `PadTopBar` pinned at the `PadRootView` level. It reuses the
// shared `HomeViewModel` and the existing `BiliVideo` model —
// no new fields are added to the model. The "Today" section
// reuses the first 3 items of the loaded feed; once a real
// recommendations endpoint lands, swap the prefix for that
// fetch without touching the view layer.
//
// `iPadVideoCard` is intentionally a sibling of the iPhone
// `VideoCard` (in `SharedViews.swift`), not a variant of it —
// the iPad card needs an avatar row + meta line that the iPhone
// card does not, and a single shared component would force the
// phone to pay the avatar-rendering cost for every cell.

/// iPad-only home content. Branches off `HomeView.body` when
/// `horizontalSizeClass == .regular`. All state is local except
/// the externally-owned `HomeViewModel`.
private struct iPadHomeContent: View {
    @ObservedObject var model: HomeViewModel
    let repository: BiliPaiRepository
    let heroNamespace: Namespace.ID?

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    @State private var sortOption: UploadSort = .latest
    @State private var didApplyPendingCategory = false

    /// 3-column grid matches the design mockup; spacing is wider
    /// than the iPhone grid (12pt) because the iPad cards are
    /// bigger and need more visual room.
    private static let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18),
    ]

    private var modelAccountMid: Int64 {
        authStore.activeAccount?.mid ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                iPadCategoryChips(model: model)
                iPadTodaySection(videos: Array(model.videos.prefix(3)))
                iPadRecentUploadsSection(
                    videos: sortedVideos,
                    repository: repository,
                    heroNamespace: heroNamespace,
                    sortOption: $sortOption,
                    columns: Self.columns
                )
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            Haptics.medium()
            await model.load(repository: repository, accountMid: modelAccountMid)
        }
        .task {
            // Apply the one-shot `pendingHomeCategory` set by the
            // sidebar's Trends tap. We do this exactly once per
            // task invocation to avoid loops if `model.category`
            // doesn't actually change.
            if !didApplyPendingCategory, let pending = router.pendingHomeCategory {
                didApplyPendingCategory = true
                router.pendingHomeCategory = nil
                if model.category != pending {
                    model.category = pending
                }
            }
            if model.videos.isEmpty && model.liveRooms.isEmpty {
                await model.load(repository: repository, accountMid: modelAccountMid)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .padHomeRefresh)) { _ in
            Haptics.medium()
            Task { await model.load(repository: repository, accountMid: modelAccountMid) }
        }
        .onChange(of: model.category) { _, _ in
            Task { await model.load(repository: repository, accountMid: modelAccountMid) }
        }
    }

    /// Sort the current feed locally. Note: the upstream
    /// `recommend` endpoint doesn't return a `pubDate`, so
    /// `.oldest` is currently a reverse of `.latest` rather than
    /// a true chronological order. Once `BiliVideo` gains a
    /// `pubDate` field, swap the `.reversed()` for a real sort.
    private var sortedVideos: [BiliVideo] {
        switch sortOption {
        case .latest:
            return model.videos
        case .popular:
            return model.videos.sorted { $0.viewCount > $1.viewCount }
        case .oldest:
            return model.videos.reversed()
        }
    }
}

/// Horizontal category chip strip rendered at the top of the
/// iPad home content. Uses dark-pill active state (the
/// mockup's "All" treatment) rather than the iPhone's pink
/// `paladalaSelectionChip`, so the two form factors stay
/// visually distinct.
private struct iPadCategoryChips: View {
    @ObservedObject var model: HomeViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(HomeCategory.androidTabs) { category in
                    iPadCategoryChip(
                        title: chipTitle(for: category),
                        isSelected: model.category == category
                    ) {
                        if model.category != category {
                            model.category = category
                        }
                    }
                }
            }
        }
    }

    /// The mockup's chip names don't map 1:1 to `HomeCategory`
    /// (we don't have `music / vlogs / lifestyle / cooking`
    /// cases). We use the existing `category.title` for now and
    /// mark this as a known mapping gap in the doc comment.
    private func chipTitle(for category: HomeCategory) -> String {
        switch category {
        case .recommend: return "All"
        case .follow:    return "Follow"
        case .popular:   return "Trending"
        case .live:      return "Live"
        case .anime:     return "Anime"
        case .game:      return "Gaming"
        case .knowledge: return "Knowledge"
        case .tech:      return "Tech"
        case .search:    return "Search"
        }
    }
}

/// Single chip in the iPad category strip. Filled-black active
/// state matches the mockup; inactive chips use a soft neutral
/// capsule so the active chip stands out.
private struct iPadCategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    isSelected ? Color.primary : Color.primary.opacity(0.06),
                    in: .rect(cornerRadius: BiliPaiTheme.pillRadius,
                              style: BiliPaiTheme.cornerStyle)
                )
                .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : .primary)
        }
        .buttonStyle(.plain)
    }
}

/// "What to watch today" section. Header carries a sparkles
/// icon and a "See all recommendations" link; the three
/// recommendation cards sit below in a horizontal HStack. Each
/// card is a 16:10 cover + 2-line title + a soft-grey
/// recommendation reason (hard-coded for now — the upstream
/// API doesn't return per-video reasoning).
private struct iPadTodaySection: View {
    let videos: [BiliVideo]
    let onSeeAll: () -> Void = {}

    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("今天看什麼", systemImage: "sparkles")
                    .font(.title3.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                Spacer()
                Button("See all recommendations", action: onSeeAll)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BiliPaiTheme.biliPink)
            }
            if videos.isEmpty {
                // Empty placeholder: keep the section visible
                // (instead of hiding it) so the user understands
                // the layout even before the first feed load
                // returns. Mirrors the iPhone `HomeEmptyState`
                // pattern at a smaller scale.
                Text("今日推薦準備中…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .bilipaiCardSurface(materialDesign)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(videos) { video in
                        iPadRecommendCard(video: video)
                    }
                }
            }
        }
    }
}

/// One card in the "What to watch today" row. Tap to open the
/// video via the existing router.
private struct iPadRecommendCard: View {
    let video: BiliVideo
    @EnvironmentObject private var router: AppRouter
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        Button {
            router.openVideo(video)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    CoverImage(url: video.coverURL)
                        .aspectRatio(16 / 10, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipShape(.rect(cornerRadius: BiliPaiTheme.cardRadius,
                                         style: BiliPaiTheme.cornerStyle))
                    // The "LIVE" badge is rendered only when the
                    // future `video.isLive` lands; for now there
                    // is no signal to attach it to, so the slot
                    // stays empty.
                }
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Based on what you've been watching · 根據你的觀看")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .bilipaiCardSurface(materialDesign)
            .clipShape(.rect(cornerRadius: BiliPaiTheme.cardRadius,
                             style: BiliPaiTheme.cornerStyle))
        }
        .buttonStyle(.plain)
    }
}

/// "Recent Uploads" section. Title + "Sort by: …" dropdown on
/// the right, then a 3-column grid of `iPadVideoCard` cells.
private struct iPadRecentUploadsSection: View {
    let videos: [BiliVideo]
    let repository: BiliPaiRepository
    let heroNamespace: Namespace.ID?
    @Binding var sortOption: UploadSort
    let columns: [GridItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("最新上傳")
                    .font(.title3.weight(.semibold))
                Spacer()
                iPadSortMenu(selection: $sortOption)
            }
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(videos) { video in
                    iPadVideoCard(
                        video: video,
                        repository: repository,
                        heroNamespace: heroNamespace
                    ) {
                        router.openVideo(video)
                    }
                }
            }
        }
    }

    @EnvironmentObject private var router: AppRouter
}

/// Sort dropdown for the Recent Uploads section. Uses the
/// canonical `Menu { Picker } label: { ... }` pattern so the
/// label looks like a button and the picker items render
/// inside the menu when tapped.
private struct iPadSortMenu: View {
    @Binding var selection: UploadSort

    var body: some View {
        Menu {
            Picker("排序", selection: $selection) {
                ForEach(UploadSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("排序：\(selection.title)")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Color.primary.opacity(0.06),
                in: .rect(cornerRadius: BiliPaiTheme.pillRadius,
                          style: BiliPaiTheme.cornerStyle)
            )
        }
    }
}

private enum UploadSort: String, CaseIterable, Identifiable {
    case latest
    case popular
    case oldest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest:  return "最新"
        case .popular: return "最多觀看"
        case .oldest:  return "最早"
        }
    }
}

/// iPad video card. Cover with duration badge, 2-line title,
/// then a channel row (initial-letter avatar + channel name +
/// meta line + kebab menu).
private struct iPadVideoCard: View {
    let video: BiliVideo
    let repository: BiliPaiRepository?
    let heroNamespace: Namespace.ID?
    let action: () -> Void

    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    /// Reserved height for the title block. The cover has a
    /// fixed 16:10 aspect ratio (so it dictates its own
    /// height); pinning the title block keeps all cards in a
    /// row at the same total height even when one title wraps
    /// to 2 lines and another stays at 1.
    private static let titleBlockHeight: CGFloat = 44

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    CoverImage(url: video.coverURL)
                        .aspectRatio(16 / 10, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipShape(.rect(cornerRadius: BiliPaiTheme.cardRadius,
                                         style: BiliPaiTheme.cornerStyle))
                    Text(video.duration.mmss)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Color.black.opacity(0.62),
                            in: .rect(cornerRadius: BiliPaiTheme.pillRadius,
                                      style: BiliPaiTheme.cornerStyle)
                        )
                        .padding(8)
                }
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(minHeight: Self.titleBlockHeight, alignment: .topLeading)
                channelRow
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .bilipaiCardSurface(materialDesign)
            .clipShape(.rect(cornerRadius: BiliPaiTheme.cardRadius,
                             style: BiliPaiTheme.cornerStyle))
            .contentShape(.rect(cornerRadius: BiliPaiTheme.cardRadius,
                                style: BiliPaiTheme.cornerStyle))
        }
        .buttonStyle(.plain)
        .modifier(VideoContextMenuIfAvailable(video: video, repository: repository))
    }

    private var channelRow: some View {
        HStack(spacing: 8) {
            channelAvatar
            VStack(alignment: .leading, spacing: 2) {
                Text(video.ownerName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(metaLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            kebabMenu
        }
    }

    /// Placeholder channel avatar. `BiliVideo` does not have an
    /// `ownerAvatarURL` field; we render a colored circle with
    /// the first character of the channel name. When the field
    /// lands, swap this for a `ResilientImage(url:)` call.
    private var channelAvatar: some View {
        let initial = video.ownerName.first.map(String.init) ?? "·"
        return Circle()
            .fill(BiliPaiTheme.biliPink.opacity(0.18))
            .frame(width: 28, height: 28)
            .overlay(
                Text(initial)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BiliPaiTheme.biliPink)
            )
    }

    /// "1.2M views · 刚刚" — `pubDate` doesn't exist on the
    /// model yet, so the time slot is hard-coded to "剛剛".
    private var metaLine: String {
        let views = video.viewCount > 0 ? "\(video.viewCount.compactCount) views" : "— views"
        return "\(views) · 剛剛"
    }

    /// Kebab menu. We expose a small subset of actions here —
    /// the long-press `VideoContextMenuIfAvailable` covers the
    /// full set (watch-later / favourite / etc.), but the
    /// visible kebab is what the mockup calls for.
    private var kebabMenu: some View {
        Menu {
            if let url = bilibiliShareURL(for: video) {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                UIPasteboard.general.string = bilibiliShareURL(for: video)?.absoluteString
            } label: {
                Label("Copy link", systemImage: "doc.on.doc")
            }
            Button {
                if let url = bilibiliShareURL(for: video) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open in browser", systemImage: "safari")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }

    private func bilibiliShareURL(for video: BiliVideo) -> URL? {
        guard !video.bvid.isEmpty else { return nil }
        return URL(string: "https://www.bilibili.com/video/\(video.bvid)")
    }
}
