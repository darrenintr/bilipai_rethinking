import SwiftUI

struct HomeView: View {
    let repository: BiliPaiRepository

    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = HomeViewModel()

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                searchBar
                categoryStrip
                if model.category == .popular {
                    popularSubCategoryStrip
                }
                if let error = model.errorMessage {
                    ErrorBanner(message: error)
                }
                if model.isLoading && model.videos.isEmpty && model.liveRooms.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if model.category == .live && !model.liveRooms.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.liveRooms) { room in
                            LiveRoomCard(room: room)
                        }
                    }
                } else if model.videos.isEmpty {
                    HomeEmptyState(
                        category: model.category,
                        searchQuery: model.searchQuery,
                        hasError: model.errorMessage != nil
                    )
                } else {
                    if model.category == .recommend {
                        TodayWatchCard(videos: Array(model.videos.prefix(4)))
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                            VideoCard(video: video) {
                                router.openVideo(video)
                            }
                            .onAppear {
                                triggerLoadMoreIfNeeded(currentIndex: index)
                            }
                        }
                    }
                    paginationFooter
                }
            }
            .padding(16)
        }
        .background(BiliPaiTheme.pageBackground)
        .navigationTitle("BiliPai")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
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
        .task {
            await model.load(repository: repository)
        }
        .refreshable {
            await model.load(repository: repository)
        }
        .onChange(of: model.category) { _, _ in
            Task { await model.load(repository: repository) }
        }
        .onChange(of: model.popularSubCategory) { _, _ in
            guard model.category == .popular else { return }
            Task { await model.load(repository: repository) }
        }
        .onChange(of: router.pendingSearchQuery) { _, query in
            Task { await model.applyIntentSearch(query, repository: repository) }
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
                    Task { await model.load(repository: repository) }
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeCategory.androidTabs) { category in
                    Button {
                        model.category = category
                    } label: {
                        Text(category.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(
                                model.category == category ? BiliPaiTheme.biliPink.opacity(0.16) : Color(uiColor: .tertiarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var popularSubCategoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PopularSubCategory.allCases) { subCategory in
                    Button {
                        model.popularSubCategory = subCategory
                    } label: {
                        Text(subCategory.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                model.popularSubCategory == subCategory ? BiliPaiTheme.biliPink.opacity(0.18) : Color(uiColor: .tertiarySystemGroupedBackground),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
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
        } else if !model.hasMore && model.videos.count > 0 && model.category != .live && model.category != .follow {
            Text("— 没有更多了 —")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        Task { await model.loadMore(repository: repository) }
    }
}

private struct HomeEmptyState: View {
    let category: HomeCategory
    let searchQuery: String
    let hasError: Bool

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
    }

    private var title: String {
        if hasError { return "内容加载失败" }
        if category == .follow { return "关注内容需要登录" }
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
        if hasError { return "下拉重试 Bilibili 公共内容源。" }
        if category == .follow {
            return "Android 版这里显示关注动态；iOS 端需要接入账号 Cookie 后才能 1:1 读取。"
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

private struct TodayWatchCard: View {
    let videos: [BiliVideo]
    @EnvironmentObject private var router: AppRouter

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
                                    .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
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
        .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
    }
}
