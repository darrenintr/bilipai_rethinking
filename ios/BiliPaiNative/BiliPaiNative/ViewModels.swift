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
    private var recommendFreshIndex = 0
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
                    page: page,
                    recommendFreshIndex: replacing && category == .recommend ? recommendFreshIndex : 0
                )
                guard isCurrentRequest(requestID) else { return }
                if replacing && category == .recommend {
                    recommendFreshIndex += 1
                }
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
    @Published var commentsLoadingMore = false
    @Published var commentsErrorMessage: String?
    @Published var commentsHasMore = false
    @Published var commentsTotalCount = 0
    @Published var danmakuEnabled = true
    @Published var audioModeEnabled = false
    @Published var playbackSpeed: Float = 1

    private var failureObserver: NSObjectProtocol?
    private var rateObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var nextCommentCursor: Int?
    private var playback: BiliPlayback?
    private var recoveryTask: Task<Void, Never>?
    private var timeObserverToken: Any?
    private var lastObservedPlaybackTime: Double = 0
    private var stalledObservationCount = 0

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
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    func load(repository: BiliPaiRepository) async {
        isLoading = true
        errorMessage = nil
        do {
            detail = try await repository.detail(for: detail)
            let playback = try await repository.playback(for: detail)
            self.playback = playback
            self.player = try await makePlayer(playback: playback)
            installPlaybackObservers()
            await loadComments(repository: repository)
        } catch {
            errorMessage = "Playback is unavailable for this item without a valid public play URL."
            await loadComments(repository: repository)
        }
        isLoading = false
    }

    func teardown() {
        recoveryTask?.cancel()
        recoveryTask = nil
        removeTimeObserver()
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
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func loadComments(repository: BiliPaiRepository) async {
        commentsLoading = true
        commentsErrorMessage = nil
        nextCommentCursor = nil
        commentsHasMore = false
        commentsTotalCount = 0
        do {
            let page = try await repository.commentsPage(for: detail)
            comments = page.items
            nextCommentCursor = page.next
            commentsHasMore = !page.isEnd && page.next != nil
            commentsTotalCount = page.totalCount
        } catch BilibiliAPIError.missingIdentity {
            commentsErrorMessage = "评论不可用"
            comments = []
        } catch {
            commentsErrorMessage = "Could not load public comments."
            comments = []
        }
        commentsLoading = false
    }

    func loadMoreComments(repository: BiliPaiRepository) async {
        guard !commentsLoading, !commentsLoadingMore, commentsHasMore, let nextCommentCursor else { return }
        commentsLoadingMore = true
        defer { commentsLoadingMore = false }
        do {
            let page = try await repository.commentsPage(for: detail, next: nextCommentCursor)
            let seen = Set(comments.map(\.id))
            comments.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            self.nextCommentCursor = page.next
            commentsHasMore = !page.isEnd && page.next != nil
            commentsTotalCount = max(commentsTotalCount, page.totalCount)
        } catch {
            commentsErrorMessage = "Could not load more comments."
        }
    }

    private func makePlayer(playback: BiliPlayback) async throws -> AVPlayer {
        let item = try await makePlayerItem(playback: playback)
        let player = AVPlayer(playerItem: item)
        configure(player: player)
        return player
    }

    private func makePlayerItem(playback: BiliPlayback) async throws -> AVPlayerItem {
        if let audioURL = playback.audioURL {
            let composition = try await makeComposition(
                videoURL: playback.videoURL,
                audioURL: audioURL,
                referer: playback.referer
            )
            let item = AVPlayerItem(asset: composition)
            configure(item: item)
            return item
        }

        let asset = Self.makeAsset(url: playback.videoURL, referer: playback.referer)
        let item = AVPlayerItem(asset: asset)
        configure(item: item)
        return item
    }

    private func makeComposition(videoURL: URL, audioURL: URL, referer: URL) async throws -> AVMutableComposition {
        let videoAsset = Self.makeAsset(url: videoURL, referer: referer)
        let audioAsset = Self.makeAsset(url: audioURL, referer: referer)
        async let allVideoTracks = videoAsset.load(.tracks)
        async let allAudioTracks = audioAsset.load(.tracks)
        let composition = AVMutableComposition()
        let videoTracks = try await allVideoTracks.filter { $0.mediaType == .video }
        let audioTracks = try await allAudioTracks.filter { $0.mediaType == .audio }

        if let videoTrack = videoTracks.first,
           let targetVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let duration = try await videoAsset.load(.duration)
            try targetVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        }

        if let audioTrack = audioTracks.first,
           let targetAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let duration = try await audioAsset.load(.duration)
            try targetAudio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        }

        return composition
    }

    private func configure(item: AVPlayerItem) {
        item.preferredForwardBufferDuration = 30
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    }

    private func configure(player: AVPlayer) {
        player.automaticallyWaitsToMinimizeStalling = false
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = true
        player.currentItem?.preferredForwardBufferDuration = 30
        player.rate = playbackSpeed
    }

    private func installPlaybackObservers() {
        guard let player, let item = player.currentItem else { return }

        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        if let rateObserver {
            NotificationCenter.default.removeObserver(rateObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        removeTimeObserver()

        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                self.errorMessage = "播放失败：\(error?.localizedDescription ?? "未知错误")"
                await self.recoverPlaybackIfNeeded()
            }
        }

        rateObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.recoverPlaybackIfNeeded()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.stalledObservationCount = 0
        }

        lastObservedPlaybackTime = item.currentTime().seconds
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            let isTryingToPlay = player.timeControlStatus == .playing || player.rate > 0
            if isTryingToPlay, abs(seconds - self.lastObservedPlaybackTime) < 0.1 {
                self.stalledObservationCount += 1
            } else {
                self.stalledObservationCount = 0
            }
            self.lastObservedPlaybackTime = seconds
            if self.stalledObservationCount >= 2 {
                self.stalledObservationCount = 0
                Task { @MainActor in
                    await self.recoverPlaybackIfNeeded()
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func recoverPlaybackIfNeeded() async {
        guard recoveryTask == nil else { return }
        guard let playback else { return }
        let resumeTime = player?.currentTime() ?? .zero
        let shouldResumePlayback = (player?.rate ?? 0) > 0 || player?.timeControlStatus == .playing

        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recoveryTask = nil }
            do {
                let newItem = try await self.makePlayerItem(playback: playback)
                self.player?.replaceCurrentItem(with: newItem)
                if let player = self.player {
                    self.configure(player: player)
                }
                self.installPlaybackObservers()
                if resumeTime.seconds.isFinite, resumeTime.seconds > 0 {
                    await self.seekPlayer(to: resumeTime)
                }
                if shouldResumePlayback {
                    self.player?.playImmediately(atRate: self.playbackSpeed)
                }
                self.errorMessage = nil
            } catch {
                self.errorMessage = "播放恢复失败：\(error.localizedDescription)"
            }
        }
        await recoveryTask?.value
    }

    private static func makeAsset(url: URL, referer: URL) -> AVURLAsset {
        AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "Referer": referer.absoluteString,
                    "User-Agent": "Mozilla/5.0 BiliPai-iOS/0.1"
                ]
            ]
        )
    }

    private func seekPlayer(to time: CMTime) async {
        guard let player else { return }
        await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
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

@MainActor
final class ReplyListViewModel: ObservableObject {
    @Published var replies: [BiliComment] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMore = false
    @Published var errorMessage: String?
    @Published var totalCount = 0

    private var page = 1
    private let video: BiliVideo
    private let rootComment: BiliComment

    init(video: BiliVideo, rootComment: BiliComment) {
        self.video = video
        self.rootComment = rootComment
    }

    func load(repository: BiliPaiRepository) async {
        page = 1
        isLoading = true
        errorMessage = nil
        do {
            let pageResult = try await repository.repliesPage(for: video, root: rootComment.id, page: page)
            replies = pageResult.items
            hasMore = !pageResult.isEnd
            totalCount = pageResult.totalCount
        } catch {
            errorMessage = "无法加载回复。"
        }
        isLoading = false
    }

    func loadMore(repository: BiliPaiRepository) async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        page += 1
        do {
            let pageResult = try await repository.repliesPage(for: video, root: rootComment.id, page: page)
            let seen = Set(replies.map(\.id))
            replies.append(contentsOf: pageResult.items.filter { !seen.contains($0.id) })
            hasMore = !pageResult.isEnd
            totalCount = max(totalCount, pageResult.totalCount)
        } catch {
            page -= 1
        }
        isLoadingMore = false
    }
}
