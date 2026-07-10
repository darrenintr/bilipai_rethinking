import SwiftUI

@MainActor
final class DynamicFeedViewModel: ObservableObject {
    @Published var posts: [DynamicPost] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMore = true
    @Published var errorMessage: String?

    private var nextOffset = ""

    func load(repository: PaladalaRepository) async {
        isLoading = true
        errorMessage = nil
        nextOffset = ""
        do {
            let page = try await repository.dynamicFeed(offset: "")
            posts = page.items
            nextOffset = page.nextOffset
            hasMore = page.hasMore && !page.nextOffset.isEmpty
        } catch {
            posts = []
            hasMore = false
            errorMessage = "动态加载失败"
        }
        isLoading = false
    }

    func loadMore(repository: PaladalaRepository) async {
        guard !isLoading, !isLoadingMore, hasMore, !nextOffset.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await repository.dynamicFeed(offset: nextOffset)
            let seen = Set(posts.map(\.id))
            posts.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            nextOffset = page.nextOffset
            hasMore = page.hasMore && !page.nextOffset.isEmpty
        } catch {
            errorMessage = "动态加载更多失败"
        }
    }
}

@MainActor
final class HistoryListViewModel: ObservableObject {
    @Published var items: [HistoryEntry] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var hasMore = true

    private var nextCursor: HistoryCursorState?

    func load(repository: PaladalaRepository) async {
        isLoading = true
        errorMessage = nil
        do {
            let page = try await repository.history()
            items = page.items
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch {
            items = []
            nextCursor = nil
            hasMore = false
            errorMessage = "历史记录加载失败"
        }
        isLoading = false
    }

    func loadMore(repository: PaladalaRepository) async {
        guard !isLoading, !isLoadingMore, hasMore, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await repository.history(cursor: cursor)
            let seen = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch {
            errorMessage = "历史记录加载更多失败"
        }
    }
}

@MainActor
final class FavoriteFoldersViewModel: ObservableObject {
    @Published var folders: [FavoriteFolderSummary] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load(repository: PaladalaRepository, mid: Int64) async {
        isLoading = true
        errorMessage = nil
        do {
            folders = try await repository.favoriteFolders(mid: mid)
        } catch {
            folders = []
            errorMessage = "收藏夹加载失败"
        }
        isLoading = false
    }
}

@MainActor
final class FavoriteFolderVideosViewModel: ObservableObject {
    @Published var title = "收藏夹"
    @Published var videos: [BiliVideo] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var hasMore = true

    private var page = 1

    func load(repository: PaladalaRepository, mediaID: Int64) async {
        isLoading = true
        errorMessage = nil
        page = 1
        do {
            let result = try await repository.favoriteVideos(mediaID: mediaID, page: page)
            title = result.title
            videos = result.videos
            hasMore = result.hasMore
        } catch {
            videos = []
            hasMore = false
            errorMessage = "收藏内容加载失败"
        }
        isLoading = false
    }

    func loadMore(repository: PaladalaRepository, mediaID: Int64) async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        page += 1
        do {
            let result = try await repository.favoriteVideos(mediaID: mediaID, page: page)
            let seen = Set(videos.map(\.id))
            videos.append(contentsOf: result.videos.filter { !seen.contains($0.id) })
            hasMore = result.hasMore
        } catch {
            page = max(1, page - 1)
            errorMessage = "收藏内容加载更多失败"
        }
    }
}

@MainActor
final class WatchLaterViewModel: ObservableObject {
    @Published var videos: [BiliVideo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load(repository: PaladalaRepository) async {
        isLoading = true
        errorMessage = nil
        do {
            videos = try await repository.watchLaterVideos()
        } catch {
            videos = []
            errorMessage = "稍后再看加载失败"
        }
        isLoading = false
    }
}

struct HistoryListView: View {
    let repository: PaladalaRepository
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore
    @StateObject private var model = HistoryListViewModel()

    var body: some View {
        List {
            if let error = model.errorMessage {
                ErrorBanner(
                    message: error,
                    retry: { Task { await model.load(repository: repository) } },
                    primary: authStore.activeAccount == nil
                        ? .init(label: "登录", action: { router.openLogin() })
                        : nil
                )
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, entry in
                Button {
                    Haptics.tap()
                    var video = entry.video
                    video.resumeTime = Double(entry.progress)
                    router.openVideo(video)
                } label: {
                    VideoListRow(video: entry.video, subtitle: historySubtitle(entry))
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .videoContextMenu(for: entry.video, repository: repository, isHistoryRow: true)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        NotificationCenter.default.post(
                            name: .historyDidRemove,
                            object: entry.video
                        )
                        model.items.removeAll { $0.video.id == entry.video.id }
                        Haptics.tap()
                    } label: {
                        Label("从历史记录中移除", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        Task {
                            do {
                                try await repository.addToWatchLater(video: entry.video)
                                Haptics.success()
                            } catch {
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label("稍后再看", systemImage: "clock.badge.checkmark")
                    }
                    .tint(PaladalaTheme.biliPink)
                }
                .onAppear {
                    if index >= max(0, model.items.count - 5) {
                        Task { await model.loadMore(repository: repository) }
                    }
                }
            }
            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .background(PaladalaTheme.canvas)
        .navigationTitle("历史记录")
        .task { await model.load(repository: repository) }
        .refreshable { await model.load(repository: repository) }
        .onReceive(NotificationCenter.default.publisher(for: .historyDidRemove)) { note in
            // The context menu posts the offending `BiliVideo`. Drop
            // any matching entry from the local cache so the row
            // disappears immediately; the next refresh will reconcile
            // with the server.
            if let video = note.object as? BiliVideo {
                model.items.removeAll { $0.video.id == video.id }
                Haptics.tap()
            }
        }
    }

    private func historySubtitle(_ entry: HistoryEntry) -> String {
        if entry.progress > 0 {
            return "看到 \(entry.progress.mmss) · \(entry.video.ownerName)"
        }
        return entry.video.ownerName
    }
}

struct WatchLaterListView: View {
    let repository: PaladalaRepository
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore
    @StateObject private var model = WatchLaterViewModel()

    var body: some View {
        List {
            if let error = model.errorMessage {
                ErrorBanner(
                    message: error,
                    retry: { Task { await model.load(repository: repository) } },
                    primary: authStore.activeAccount == nil
                        ? .init(label: "登录", action: { router.openLogin() })
                        : nil
                )
                    .listRowSeparator(.hidden)
            }
            ForEach(model.videos) { video in
                Button {
                    Haptics.tap()
                    router.openVideo(video)
                } label: {
                    VideoListRow(video: video, subtitle: video.ownerName)
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .videoContextMenu(for: video, repository: repository, isWatchLaterRow: true)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task {
                            do {
                                try await repository.removeFromWatchLater(video: video)
                                model.videos.removeAll { $0.id == video.id }
                                Haptics.success()
                            } catch {
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label("从稍后再看中移除", systemImage: "clock.badge.xmark")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .background(PaladalaTheme.canvas)
        .navigationTitle("稍后再看")
        .task { await model.load(repository: repository) }
        .refreshable { await model.load(repository: repository) }
        .onReceive(NotificationCenter.default.publisher(for: .watchLaterDidChange)) { _ in
            Task { await model.load(repository: repository) }
        }
    }
}

struct FavoriteFoldersView: View {
    let repository: PaladalaRepository
    let mid: Int64
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore
    @StateObject private var model = FavoriteFoldersViewModel()

    var body: some View {
        List {
            if let error = model.errorMessage {
                ErrorBanner(
                    message: error,
                    retry: { Task { await model.load(repository: repository, mid: mid) } },
                    primary: authStore.activeAccount == nil
                        ? .init(label: "登录", action: { router.openLogin() })
                        : nil
                )
                    .listRowSeparator(.hidden)
            }
            ForEach(model.folders) { folder in
                NavigationLink {
                    FavoriteFolderVideosView(repository: repository, folder: folder)
                } label: {
                    FavoriteFolderRow(folder: folder)
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .background(PaladalaTheme.canvas)
        .navigationTitle("我的收藏")
        .task { await model.load(repository: repository, mid: mid) }
    }
}

struct FavoriteFolderVideosView: View {
    let repository: PaladalaRepository
    let folder: FavoriteFolderSummary
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore
    @StateObject private var model = FavoriteFolderVideosViewModel()

    var body: some View {
        List {
            if let error = model.errorMessage {
                ErrorBanner(
                    message: error,
                    retry: { Task { await model.load(repository: repository, mediaID: folder.id) } },
                    primary: authStore.activeAccount == nil
                        ? .init(label: "登录", action: { router.openLogin() })
                        : nil
                )
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                Button {
                    Haptics.tap()
                    router.openVideo(video)
                } label: {
                    VideoListRow(video: video, subtitle: video.ownerName)
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .onAppear {
                    if index >= max(0, model.videos.count - 5) {
                        Task { await model.loadMore(repository: repository, mediaID: folder.id) }
                    }
                }
            }
            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .background(PaladalaTheme.canvas)
        .navigationTitle(model.title)
        .task { await model.load(repository: repository, mediaID: folder.id) }
        .refreshable { await model.load(repository: repository, mediaID: folder.id) }
    }
}

private struct FavoriteFolderRow: View {
    let folder: FavoriteFolderSummary

    var body: some View {
        HStack(spacing: 12) {
            ResilientImage(url: folder.coverURL, maximumPixelSize: 360)
                .frame(width: 88, height: 56)
                .clipShape(Rectangle())
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.title)
                    .font(PaladalaTheme.FontRole.cardTitle)
                    .foregroundStyle(PaladalaTheme.ink)
                    .textCase(.uppercase)
                    .lineLimit(2)
                Text("\(folder.mediaCount) 个内容")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !folder.ownerName.isEmpty {
                    Text(folder.ownerName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(PaladalaTheme.Spacing.m)
        .paladalaStreetPanel(fill: PaladalaTheme.paper)
    }
}

private struct VideoListRow: View {
    let video: BiliVideo
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ResilientImage(url: video.coverURL, maximumPixelSize: 480)
                .frame(width: 112, height: 70)
                .clipShape(Rectangle())
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(video.title)
                    .font(PaladalaTheme.FontRole.cardTitle)
                    .foregroundStyle(PaladalaTheme.ink)
                    .textCase(.uppercase)
                    .lineLimit(2)
                Text(subtitle)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label(video.viewCount.compactCount, systemImage: "play.fill")
                    Label(video.danmakuCount.compactCount, systemImage: "text.bubble")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(PaladalaTheme.Spacing.m)
        .paladalaStreetPanel(fill: PaladalaTheme.paper)
    }
}
