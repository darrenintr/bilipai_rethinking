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
    /// True when the feed is showing the offline bundled sample set. We
    /// expose this so the home view can render an "离线样例" caption and
    /// so the pagination footer can offer a "重新加载" action.
    @Published var isShowingBundledFallback = false

    private var page = 1
    private var requestGeneration: UInt64 = 0
    /// The maximum number of items the upstream endpoint will return in one
    /// request. Once we get fewer than this many results we know we are at
    /// the end of the feed.
    private let pageSize = 20

    func load(repository: BiliPaiRepository) async {
        let requestID = beginNewRequestGeneration()
        page = 1
        isLoading = true
        isLoadingMore = false
        hasMore = true
        errorMessage = nil
        // Always clear the bundled-fallback flag on a fresh load. Otherwise
        // a previous tap on "查看离线样例" would keep `isShowingBundledFallback`
        // = true even after the live API returns, and the user would see
        // the bundled list for a beat before the new data overwrites it.
        isShowingBundledFallback = false
        await loadPage(repository: repository, replacing: true, requestID: requestID)
        guard isCurrentRequest(requestID) else { return }
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
        let requestID = requestGeneration
        await loadPage(repository: repository, replacing: false, requestID: requestID)
        guard isCurrentRequest(requestID) else { return }
        isLoadingMore = false
    }

    /// "Next batch" action. The user has reached the bottom of the feed and
    /// tapped the footer button — we always increment the page and try
    /// again, even when the previous response was short. The Bilibili
    /// `popular` endpoint sometimes returns a 12-item page followed by
    /// another full 20-item page, so giving up on a short response is
    /// wrong. When even the retry returns nothing we drop into the
    /// bundled fallback so the user always has somewhere to scroll.
    func loadNextBatch(repository: BiliPaiRepository) async {
        guard !isLoading, !isLoadingMore else { return }
        guard category != .follow, category != .live else { return }
        isLoadingMore = true
        page += 1
        let requestID = requestGeneration
        await loadPage(repository: repository, replacing: false, requestID: requestID)
        guard isCurrentRequest(requestID) else { return }
        isLoadingMore = false
    }

    /// Explicit offline-mode toggle. The user has tapped the "查看离线样例"
    /// button on the error banner and wants to see the bundled sample set
    /// until the public endpoint comes back. Pull-to-refresh still goes
    /// through `load(...)` and re-tries the live API.
    func showBundledFallback(repository: BiliPaiRepository) {
        errorMessage = nil
        videos = repository.bundledFeed(for: category)
        isShowingBundledFallback = true
        hasMore = true
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

    private func loadPage(
        repository: BiliPaiRepository,
        replacing: Bool,
        requestID: UInt64
    ) async {
        do {
            if category == .follow {
                guard isCurrentRequest(requestID) else { return }
                videos = []
                liveRooms = []
                errorMessage = "登录后查看关注动态、关注直播和个人推荐。"
                hasMore = false
                isShowingBundledFallback = false
            } else if category == .live {
                let rooms = try await repository.liveRooms()
                guard isCurrentRequest(requestID) else { return }
                liveRooms = rooms
                videos = []
                hasMore = false
                isShowingBundledFallback = false
            } else {
                let next = try await repository.feed(
                    category: category,
                    searchQuery: searchQuery,
                    popularSubCategory: popularSubCategory,
                    page: page
                )
                guard isCurrentRequest(requestID) else { return }
                if replacing {
                    videos = next
                } else {
                    // Dedupe appended items by `bvid` so a "load next batch"
                    // gesture on a wrapped-around feed does not double up
                    // the same video twice in a row.
                    let existing = Set(videos.map(\.bvid))
                    let fresh = next.filter { !existing.contains($0.bvid) }
                    videos.append(contentsOf: fresh)
                }
                liveRooms = []
                // The repository is responsible for telling us when the
                // response came from the bundled offline sample set. When
                // it has, we keep `hasMore = true` so the footer surfaces
                // the "重新加载" / "换一批" action instead of a phantom next
                // page. Otherwise `hasMore` follows the pageSize heuristic
                // so we know whether to keep paginating.
                let fromBundled = page == 1 && next.allSatisfy { video in
                    BundledFeedService.knownBVids.contains(video.bvid)
                }
                isShowingBundledFallback = fromBundled
                hasMore = fromBundled
                    ? true
                    : categorySupportsPagination && next.count >= pageSize
            }
        } catch {
            guard isCurrentRequest(requestID) else { return }
            // Clear any stale `videos` so the user does not see a previous
            // batch (e.g. the bundled offline sample set) sitting under
            // the error banner. Without this, once the user tapped
            // "查看离线样例" in a prior session, every subsequent failed
            // pull-to-refresh would re-render the same MIT / WWDC /
            // Planet Earth entries from cache, masking the actual failure
            // and looking like "pull-to-refresh is broken".
            if replacing {
                videos = []
                liveRooms = []
                isShowingBundledFallback = false
                errorMessage = "内容加载失败，下拉重试。"
            } else {
                // Roll back the page bump so the next pull-to-refresh does not
                // skip the page we failed to load.
                page = max(1, page - 1)
                errorMessage = "加载更多失败：\(error.localizedDescription)"
            }
        }
    }

    private func beginNewRequestGeneration() -> UInt64 {
        requestGeneration &+= 1
        return requestGeneration
    }

    private func isCurrentRequest(_ requestID: UInt64) -> Bool {
        requestID == requestGeneration
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
                Task { @MainActor in
                    self.player?.play()
                }
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
