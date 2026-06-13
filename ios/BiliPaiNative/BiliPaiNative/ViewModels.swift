import AVFoundation
import AVKit
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var category: HomeCategory = .recommend
    @Published var popularSubCategory: PopularSubCategory = .comprehensive
    @Published var searchQuery = ""
    @Published var videos: [BiliVideo] = []
    @Published var liveRooms: [BiliLiveRoom] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMore = true
    @Published var errorMessage: String?

    private var page = 1
    /// The maximum number of items the upstream endpoint will return in one
    /// request. Once we get fewer than this many results we know we are at
    /// the end of the feed.
    private let pageSize = 20

    func load(repository: BiliPaiRepository) async {
        page = 1
        isLoading = true
        isLoadingMore = false
        hasMore = true
        errorMessage = nil
        await loadPage(repository: repository, replacing: true)
        isLoading = false
    }

    func loadMore(repository: BiliPaiRepository) async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        guard category != .follow, category != .live else { return }
        // Some feed flavours always return the full list in a single response
        // (e.g. weekly/precious). Skip pagination for them so we do not
        // request the same page twice in a row.
        guard categorySupportsPagination else { return }
        isLoadingMore = true
        page += 1
        await loadPage(repository: repository, replacing: false)
        isLoadingMore = false
    }

    private var categorySupportsPagination: Bool {
        switch category {
        case .recommend, .search:
            return true
        case .popular:
            return popularSubCategory == .comprehensive
        case .anime, .game, .knowledge, .tech:
            return true
        case .follow, .live:
            return false
        }
    }

    func applyIntentSearch(_ query: String, repository: BiliPaiRepository) async {
        guard !query.isEmpty else { return }
        category = .search
        searchQuery = query
        await load(repository: repository)
    }

    private func loadPage(repository: BiliPaiRepository, replacing: Bool) async {
        do {
            if category == .follow {
                videos = []
                liveRooms = []
                errorMessage = "登录后查看关注动态、关注直播和个人推荐。"
                hasMore = false
            } else if category == .live {
                liveRooms = try await repository.liveRooms()
                videos = []
                hasMore = false
            } else {
                let next = try await repository.feed(
                    category: category,
                    searchQuery: searchQuery,
                    popularSubCategory: popularSubCategory,
                    page: page
                )
                if replacing {
                    videos = next
                } else {
                    videos.append(contentsOf: next)
                }
                liveRooms = []
                // Bilibili endpoints do not return an explicit cursor; we infer
                // that the list is exhausted when the server returns fewer
                // items than a full page, or when the category does not
                // support pagination at all.
                hasMore = categorySupportsPagination && next.count >= pageSize
            }
        } catch {
            if replacing {
                errorMessage = "内容加载失败，下拉重试。"
            } else {
                // Roll back the page bump so the next pull-to-refresh does not
                // skip the page we failed to load.
                page = max(1, page - 1)
                errorMessage = "加载更多失败：\(error.localizedDescription)"
            }
        }
    }
}

@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published var detail: BiliVideo
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var comments: [BiliComment] = []
    @Published var commentsLoading = false
    @Published var commentsErrorMessage: String?
    @Published var danmakuEnabled = true
    @Published var audioModeEnabled = false
    @Published var playbackSpeed: Float = 1

    private var failureObserver: NSObjectProtocol?
    private var rateObserver: NSObjectProtocol?

    init(video: BiliVideo) {
        self.detail = video
    }

    deinit {
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        if let rateObserver {
            NotificationCenter.default.removeObserver(rateObserver)
        }
    }

    func load(repository: BiliPaiRepository) async {
        isLoading = true
        errorMessage = nil
        do {
            detail = try await repository.detail(for: detail)
            let playback = try await repository.playback(for: detail)
            let asset = AVURLAsset(
                url: playback.url,
                options: [
                    "AVURLAssetHTTPHeaderFieldsKey": [
                        "Referer": playback.referer.absoluteString,
                        "User-Agent": "Mozilla/5.0 BiliPai-iOS/0.1"
                    ]
                ]
            )
            let item = AVPlayerItem(asset: asset)
            // Keep a small forward buffer so the player starts quickly without
            // stalling on a slow CDN. The default behaviour is to wait until
            // enough data is buffered, which makes the first few seconds feel
            // frozen on cellular.
            item.preferredForwardBufferDuration = 4
            let player = AVPlayer(playerItem: item)
            // `automaticallyWaitsToMinimizeStalling` is true by default; it
            // can leave a sluggish feed stuck on the buffering spinner. Allow
            // the player to start as soon as it has any data and let the
            // network catch up. The AVPlayer will still pause if the item
            // becomes unplayable.
            player.automaticallyWaitsToMinimizeStalling = false
            player.allowsExternalPlayback = true
            player.appliesMediaSelectionCriteriaAutomatically = true
            player.rate = playbackSpeed

            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor in
                    self.errorMessage = "播放失败：\(error?.localizedDescription ?? "未知错误")"
                }
            }
            rateObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // AVPlayer will normally resume from a stall on its own; this
                // just keeps the spinner from getting stuck if it does not.
                self.player?.play()
            }

            self.player = player
            await loadComments(repository: repository)
        } catch {
            errorMessage = "Playback is unavailable for this item without a valid public play URL."
            await loadComments(repository: repository)
        }
        isLoading = false
    }

    func teardown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        if let rateObserver {
            NotificationCenter.default.removeObserver(rateObserver)
            self.rateObserver = nil
        }
    }

    private func loadComments(repository: BiliPaiRepository) async {
        commentsLoading = true
        commentsErrorMessage = nil
        do {
            comments = try await repository.comments(for: detail)
        } catch BilibiliAPIError.missingIdentity {
            commentsErrorMessage = "评论不可用"
            comments = []
        } catch {
            commentsErrorMessage = "Could not load public comments."
        }
        commentsLoading = false
    }
}

@MainActor
final class LiveViewModel: ObservableObject {
    @Published var rooms: [BiliLiveRoom] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load(repository: BiliPaiRepository) async {
        isLoading = true
        errorMessage = nil
        do {
            rooms = try await repository.liveRooms()
        } catch {
            errorMessage = "Could not load live rooms."
        }
        isLoading = false
    }
}
