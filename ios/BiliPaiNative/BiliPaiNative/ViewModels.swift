import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var category: HomeCategory = .recommend
    @Published var popularSubCategory: PopularSubCategory = .comprehensive
    @Published var searchQuery = ""
    @Published var videos: [BiliVideo] = []
    @Published var liveRooms: [BiliLiveRoom] = []
    /// Dynamic feed rendered on the 关注 tab. Lives in parallel to
    /// `videos` / `liveRooms` because the upstream envelope is a
    /// different shape (`offset` + `items[]`, not `page` + `videos[]`).
    /// `dynamicNeedsLogin` distinguishes the "signed-out, please log in"
    /// empty state from a legitimate empty page (a user with no
    /// follows yet).
    @Published var dynamicItems: [DynamicPost] = []
    @Published var dynamicHasMore = false
    @Published var dynamicNextOffset = ""
    @Published var dynamicNeedsLogin = false
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

    func load(repository: BiliPaiRepository, accountMid: Int64 = 0) async {
        let requestID = beginNewRequestGeneration()
        page = 1
        videos = [] // Clear immediately for visual feedback
        liveRooms = []
        // Reset dynamic-feed state on every fresh load so switching
        // tabs or tapping the home indicator doesn't leave a stale
        // "登录后查看关注动态" message on screen after the user signs in.
        dynamicItems = []
        dynamicHasMore = false
        dynamicNextOffset = ""
        dynamicNeedsLogin = false
        isLoading = true
        isLoadingMore = false
        hasMore = true
        errorMessage = nil
        // Always clear the bundled-fallback flag on a fresh load. Otherwise
        // a previous tap on "查看离线样例" would keep `isShowingBundledFallback`
        // = true even after the live API returns, and the user would see
        // the bundled list for a beat before the new data overwrites it.
        isShowingBundledFallback = false
        await loadPage(repository: repository, accountMid: accountMid, replacing: true, requestID: requestID)
        guard isCurrentRequest(requestID) else { return }
        isLoading = false
    }

    func loadMore(repository: BiliPaiRepository, accountMid: Int64 = 0) async {
        guard !isLoading, !isLoadingMore else { return }
        // Follow tab uses the dynamic-feed pagination (`offset`), not
        // the page-based one. Route it through its own branch so the
        // `categorySupportsPagination` short-circuit below stays
        // accurate for the video feeds.
        if category == .follow {
            guard dynamicHasMore, !dynamicNextOffset.isEmpty else { return }
            isLoadingMore = true
            let requestID = requestGeneration
            await loadDynamicPage(repository: repository, accountMid: accountMid, replacing: false, requestID: requestID)
            guard isCurrentRequest(requestID) else { return }
            isLoadingMore = false
            return
        }
        guard hasMore, category != .live else { return }
        // Some feed flavours always return the full list in a single response
        // (e.g. weekly/precious). Skip pagination for them so we do not
        // request the same page twice in a row.
        guard categorySupportsPagination else { return }
        isLoadingMore = true
        page += 1
        let requestID = requestGeneration
        await loadPage(repository: repository, accountMid: accountMid, replacing: false, requestID: requestID)
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
    func loadNextBatch(repository: BiliPaiRepository, accountMid: Int64 = 0) async {
        guard !isLoading, !isLoadingMore else { return }
        guard category != .follow, category != .live else { return }
        isLoadingMore = true
        page += 1
        let requestID = requestGeneration
        await loadPage(repository: repository, accountMid: accountMid, replacing: false, requestID: requestID)
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

    func applyIntentSearch(_ query: String, repository: BiliPaiRepository, accountMid: Int64 = 0) async {
        guard !query.isEmpty else { return }
        category = .search
        searchQuery = query
        await load(repository: repository, accountMid: accountMid)
    }

    private func loadPage(
        repository: BiliPaiRepository,
        accountMid: Int64,
        replacing: Bool,
        requestID: UInt64
    ) async {
        do {
            if category == .follow {
                await loadDynamicPage(repository: repository, accountMid: accountMid, replacing: replacing, requestID: requestID)
                return
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
                    recommendFreshIndex: replacing && category == .recommend ? recommendFreshIndex : 0,
                    isRefresh: replacing
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
                
                // App API usually returns ~10 items. Web API returns 20.
                let threshold = category == .recommend ? 8 : pageSize
                hasMore = fromBundled
                    ? true
                    : categorySupportsPagination && next.count >= threshold
            }
        } catch {
            guard isCurrentRequest(requestID) else { return }
            
            // Ignore cancellation errors - they are usually intentional (e.g. new request started)
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            
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

    /// Fetch a page of the follow dynamic feed. The upstream
    /// pagination model is `offset`, not `page`, so this is its own
    /// branch rather than a parameter on `loadPage(...)`.
    ///
    /// On anonymous access the API client short-circuits and returns
    /// an empty page with `needsLogin: true`. We surface that as a
    /// typed state on the model so the view can render the existing
    /// "登录后查看关注动态" prompt without a try/catch in the view.
    private func loadDynamicPage(
        repository: BiliPaiRepository,
        accountMid: Int64,
        replacing: Bool,
        requestID: UInt64
    ) async {
        let offset = replacing ? "" : dynamicNextOffset
        do {
            // `replacing == true` (i.e. a fresh load) invalidates the
            // cached followings so a pull-to-refresh always picks up
            // newly-followed UP masters. Pagination calls leave the
            // cache alone so we don't re-fetch the followings list
            // mid-scroll.
            let page = try await repository.attentionFeed(
                offset: offset,
                accountMid: accountMid,
                refreshFollowings: replacing
            )
            guard isCurrentRequest(requestID) else { return }
            if replacing {
                dynamicItems = page.items
            } else {
                // Dedupe by post id so a wrapped-around offset does
                // not double-up a card we have already rendered. Same
                // shape as the video-feed dedupe in `loadPage`.
                let existing = Set(dynamicItems.map(\.id))
                dynamicItems.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            dynamicNextOffset = page.nextOffset
            dynamicHasMore = page.hasMore && !dynamicNextOffset.isEmpty
            dynamicNeedsLogin = page.needsLogin
            errorMessage = nil
            hasMore = dynamicHasMore
        } catch {
            guard isCurrentRequest(requestID) else { return }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            if replacing {
                dynamicItems = []
                dynamicHasMore = false
                dynamicNextOffset = ""
                dynamicNeedsLogin = false
                errorMessage = "关注动态加载失败，下拉重试。"
            } else {
                errorMessage = "加载更多关注动态失败：\(error.localizedDescription)"
            }
        }
    }

    private func isCurrentRequest(_ requestID: UInt64) -> Bool {
        requestID == requestGeneration
    }
}

@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published var detail: BiliVideo
    @Published var playback: BiliPlayback?
    @Published var isPlaying: Bool = true
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

    private var nextCommentCursor: Int?
    // Tracks which progressive-batch the user is on. Index 0 → first page
    // (20 items), 1 → second (40), 2 → third (80), 3+ → fourth and beyond
    // (capped at 160). See `commentPageSize(forPage:)` for the lookup
    // table. The view-model owns this because the View layer should not
    // know about the page-size backoff — it only needs to call
    // `loadMoreComments`.
    private var currentCommentPage = 0

    /// Progressive comment batch sizes. The first few fetches are small
    /// so the video-detail view appears interactive fast; once the user
    /// starts scrolling we trade latency for throughput. The cap of 160
    /// matches the Bilibili web client and is the sweet spot on modern
    /// iPhones before List/ForEach updates start stuttering.
    private static let commentPageSizes: [Int] = [20, 40, 80, 160]
    private static func commentPageSize(forPage page: Int) -> Int {
        let clamped = max(0, page)
        guard clamped < commentPageSizes.count else { return 160 }
        return commentPageSizes[clamped]
    }

    init(video: BiliVideo) {
        self.detail = video
    }

    func load(repository: BiliPaiRepository) async {
        isLoading = true
        errorMessage = nil
        do {
            detail = try await repository.detail(for: detail)
            self.playback = try await repository.playback(for: detail)
            await loadComments(repository: repository)
        } catch let error as BilibiliAPIError {
            switch error {
            case .api(let message):
                errorMessage = message
            case .missingData:
                errorMessage = "该视频暂无可播放源。"
            case .missingIdentity:
                errorMessage = "无法识别该视频（缺少 aid/bvid）。"
            case .noPlayableFormat:
                errorMessage = "该视频的可用清晰度均不可播放（可能为地区限制或大会员专享）。"
            case .invalidURL, .http:
                errorMessage = "网络异常，请检查连接后重试。"
            }
            await loadComments(repository: repository)
        } catch {
            errorMessage = "播放失败：\(error.localizedDescription)"
            await loadComments(repository: repository)
        }
        isLoading = false
    }

    func teardown() {
        // All player-related teardown is now handled by the PlayerView itself
        // or through the playback object lifecycle.
    }

    private func loadComments(repository: BiliPaiRepository) async {
        commentsLoading = true
        commentsErrorMessage = nil
        nextCommentCursor = nil
        commentsHasMore = false
        commentsTotalCount = 0
        currentCommentPage = 0
        do {
            let page = try await repository.commentsPage(
                for: detail,
                pageSize: Self.commentPageSize(forPage: currentCommentPage)
            )
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
            currentCommentPage += 1
            let page = try await repository.commentsPage(
                for: detail,
                next: nextCommentCursor,
                pageSize: Self.commentPageSize(forPage: currentCommentPage)
            )
            let seen = Set(comments.map(\.id))
            comments.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            self.nextCommentCursor = page.next
            commentsHasMore = !page.isEnd && page.next != nil
            commentsTotalCount = max(commentsTotalCount, page.totalCount)
        } catch {
            // Roll the page index back so the next manual retry doesn't
            // skip a size (e.g. a flaky network on the 80 → 160 step
            // would otherwise jump straight to 160 on the next attempt).
            currentCommentPage = max(0, currentCommentPage - 1)
            commentsErrorMessage = "Could not load more comments."
        }
    }

    func submitComment(repository: BiliPaiRepository, message: String) async -> Bool {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            try await repository.postComment(for: detail, message: message)
            await loadComments(repository: repository)
            return true
        } catch {
            errorMessage = "评论失败：\(error.localizedDescription)"
            return false
        }
    }

    func performCommentAction(repository: BiliPaiRepository, rpid: Int, actionType: String) async {
        do {
            switch actionType {
            case "like":
                try await repository.likeComment(for: detail, rpid: rpid, action: 1)
            case "unlike":
                try await repository.likeComment(for: detail, rpid: rpid, action: 0)
            case "hate":
                try await repository.hateComment(for: detail, rpid: rpid, action: 1)
            default:
                break
            }
            // In a real app we'd update the local state without a full reload
            // for immediate feedback.
        } catch {
            bpLog("Comment action \(actionType) failed: \(error)")
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

    func submitReply(repository: BiliPaiRepository, message: String) async -> Bool {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            try await repository.postComment(for: video, message: message, root: rootComment.id, parent: rootComment.id)
            await load(repository: repository)
            return true
        } catch {
            errorMessage = "回复失败：\(error.localizedDescription)"
            return false
        }
    }

    func performCommentAction(repository: BiliPaiRepository, rpid: Int, actionType: String) async {
        do {
            switch actionType {
            case "like":
                try await repository.likeComment(for: video, rpid: rpid, action: 1)
            case "unlike":
                try await repository.likeComment(for: video, rpid: rpid, action: 0)
            case "hate":
                try await repository.hateComment(for: video, rpid: rpid, action: 1)
            default:
                break
            }
        } catch {
            bpLog("Reply action \(actionType) failed: \(error)")
        }
    }
}
