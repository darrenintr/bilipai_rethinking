import Foundation
import SwiftUI

final class PaladalaRepository: ObservableObject {
    let apiClient: BilibiliAPIClient
    private let bundled: BundledFeedService

    init(apiClient: BilibiliAPIClient, bundled: BundledFeedService = BundledFeedService()) {
        self.apiClient = apiClient
        self.bundled = bundled
    }

    /// Hook a callback that fires when the underlying `apiClient`
    /// detects a 401 session-expiry response. The repository takes
    /// the closure so the app can install it once during `onAppear`
    /// without having to reach into the API client directly.
    ///
    /// The closure fires at most once per session-expiry burst —
    /// the API client latches the failure so a feed-load that
    /// fans out into 6 API calls doesn't pop the login sheet 6
    /// times. `AuthStore.completeLogin(_:)` resets the latch so
    /// the *next* session-expiry can re-fire.
    func onSessionExpired(_ handler: @escaping () -> Void) {
        apiClient.onAuthFailure = handler
    }

    /// Fetch a single page of feed items.
    ///
    /// The supported categories accept a `page` query parameter on the
    /// upstream endpoint. The categorisation-only feeds (follow, live) ignore
    /// `page` because the iOS client does not have a paginated public source
    /// for them.
    ///
    /// When every public endpoint fails we surface the error rather than
    /// silently substituting the bundled sample set — silently swapping in
    /// a 6-item static list on every refresh hides connectivity and
    /// `风控` issues from the user. The bundled set is still available via
    func feed(
        category: HomeCategory,
        searchQuery: String,
        popularSubCategory: PopularSubCategory,
        page: Int = 1,
        recommendFreshIndex: Int = 0,
        isRefresh: Bool = true
    ) async throws -> [BiliVideo] {
        switch category {
        case .recommend:
            // Keep the 推荐 tab on the personalised recommendation surface
            // for every batch. Falling back to `popularVideos(page: 2)` after
            // the first 20 items makes the feed stop feeling account-ranked.
            do {
                let webRcmd = try await apiClient.recommendedVideos(freshIndex: recommendFreshIndex)
                if !webRcmd.isEmpty { return webRcmd }
            } catch {
                bpLog("Web API rcmd failed: \(error)")
            }

            if let appRcmd = try? await apiClient.appRecommendedVideos(freshIndex: recommendFreshIndex, isRefresh: isRefresh), !appRcmd.isEmpty {
                return appRcmd
            }

            if page == 1 {
                if let popular = try? await apiClient.popularVideos(page: page), !popular.isEmpty {
                    return popular
                }
                if let ranking = try? await apiClient.rankingVideos(), !ranking.isEmpty {
                    return ranking
                }
                if let weekly = try? await apiClient.weeklyMustWatchVideos(), !weekly.isEmpty {
                    return weekly
                }
            }
            return []
        case .follow:
            return []
        case .popular:
            switch popularSubCategory {
            case .comprehensive:
                return try await apiClient.popularVideos(page: page)
            case .ranking:
                return try await apiClient.rankingVideos()
            case .weekly:
                return try await apiClient.weeklyMustWatchVideos()
            case .precious:
                return try await apiClient.preciousVideos()
            }
        case .live:
            return []
        case .anime, .game, .knowledge, .tech:
            guard let tid = category.regionTid else { return [] }
            return try await apiClient.regionVideos(tid: tid, page: page)
        case .search:
            return try await apiClient.searchVideos(keyword: searchQuery, page: page)
        }
    }

    /// Explicit offline-mode entry point: returns the bundled sample
    /// set without touching the network. The home view calls this
    /// only after the user taps "查看离线样例" on the error banner;
    /// pull-to-refresh goes through `feed(...)` and never falls
    /// through here.
    func bundledFeed(for category: HomeCategory) -> [BiliVideo] {
        bundled.samples(for: category)
    }

    func detail(for video: BiliVideo) async throws -> BiliVideo {
        guard !video.bvid.isEmpty || video.aid > 0 else { return video }
        return try await apiClient.videoDetail(bvid: video.bvid, aid: video.aid)
    }

    /// Fetch the playable URL for `video`. `qn` is the
    /// Bilibili `accept_quality` ladder code — 80 = 1080P high
    /// quality, 64 = 720P high quality, 32 = 480P clear, 16 =
    /// 360P smooth. The `BilibiliAPIClient` reorders its qn
    /// retry chain so `qn` is tried first, falling back to
    /// lower qualities on the same call (gated / VIP-only 1080P
    /// drops to 720P automatically). Default 80 keeps the
    /// previous "ask for HD first" behaviour.
    func playback(for video: BiliVideo, qn: Int = 80) async throws -> BiliPlayback {
        let cid = video.cid
        var pb: BiliPlayback
        if cid > 0 {
            pb = try await apiClient.playbackURL(
                bvid: video.bvid,
                aid: video.aid,
                cid: cid,
                preferredQn: qn
            )
        } else {
            let detail = try await apiClient.videoDetail(bvid: video.bvid, aid: video.aid)
            pb = try await apiClient.playbackURL(
                bvid: detail.bvid,
                aid: detail.aid,
                cid: detail.cid,
                preferredQn: qn
            )
        }
        pb.resumeTime = video.resumeTime ?? 0
        return pb
    }

    func liveRooms() async throws -> [BiliLiveRoom] {
        try await apiClient.liveRooms()
    }

    // MARK: - Music

    /// Fetch a page of the 音乐 region feed. The repository is a
    /// thin pass-through here because the music endpoint is just a
    /// re-skinned `/x/web-interface/dynamic/region` call — no extra
    /// transformation needed.
    func musicVideos(page: Int = 1) async throws -> [BiliVideo] {
        try await apiClient.musicVideos(page: page)
    }

    /// Fetch the lyric track for `video`. Returns `nil` when:
    ///   * the video has no subtitle track (most VOD uploads);
    ///   * the upstream returns no Chinese-language lyric;
    ///   * the lyric JSON / LRC text fails to parse.
    /// The Music view treats all three as "lyrics unavailable"
    /// and shows the cover art full-bleed instead of a half-broken
    /// lyrics pane.
    func videoLyrics(for video: BiliVideo) async throws -> BiliLyricTrack? {
        // We need a real `cid` to query the player endpoint. The
        // feed entries usually carry one; if not, fall back to a
        // single detail fetch.
        var cid = video.cid
        if cid <= 0 {
            let detail = try await apiClient.videoDetail(bvid: video.bvid, aid: video.aid)
            cid = detail.cid
        }
        guard cid > 0 else { return nil }
        guard let info = try await apiClient.videoLyricInfo(cid: cid) else { return nil }
        let text = try await apiClient.videoLyricText(info: info)
        return BiliLyricParser.parse(text: text, language: info.lanDoc.isEmpty ? info.lan : info.lanDoc)
    }

    /// Resolve the playable stream URLs for a live room. The result
    /// contains zero, one, or both HLS and FLV slots depending on
    /// what the room's CDN exposes — the player UI is responsible for
    /// disabling whichever toggle is unavailable.
    func livePlayback(for room: BiliLiveRoom) async throws -> BiliLivePlayback {
        try await apiClient.livePlaybackURL(roomID: room.id)
    }

    func commentsPage(for video: BiliVideo, next: Int? = nil, pageSize: Int = 20, sort: CommentSort = .hot) async throws -> CommentPage {
        let aid = video.aid
        if aid > 0 {
            return try await apiClient.commentsPage(aid: aid, next: next, pageSize: pageSize, sort: sort)
        }
        if !video.bvid.isEmpty {
            let detail = try await apiClient.videoDetail(bvid: video.bvid)
            if detail.aid > 0 {
                return try await apiClient.commentsPage(aid: detail.aid, next: next, pageSize: pageSize, sort: sort)
            }
        }
        // Neither the feed entry nor the video-detail fallback produced an
        // `aid` we can call the comment endpoint with. Surface a typed error
        // so the UI can show a specific "评论不可用" message instead of
        // pretending the request failed for some other reason.
        throw BilibiliAPIError.missingIdentity
    }

    func repliesPage(for video: BiliVideo, root rpid: Int, page: Int = 1) async throws -> CommentPage {
        let aid = video.aid
        if aid > 0 {
            return try await apiClient.repliesPage(aid: aid, rpid: rpid, pn: page)
        }
        if !video.bvid.isEmpty {
            let detail = try await apiClient.videoDetail(bvid: video.bvid)
            if detail.aid > 0 {
                return try await apiClient.repliesPage(aid: detail.aid, rpid: rpid, pn: page)
            }
        }
        throw BilibiliAPIError.missingIdentity
    }

    func postComment(for video: BiliVideo, message: String, root: Int? = nil, parent: Int? = nil) async throws {
        let aid = video.aid > 0 ? video.aid : try await apiClient.videoDetail(bvid: video.bvid).aid
        try await apiClient.postComment(aid: aid, message: message, root: root, parent: parent)
    }

    func likeComment(for video: BiliVideo, rpid: Int, action: Int) async throws {
        let aid = video.aid > 0 ? video.aid : try await apiClient.videoDetail(bvid: video.bvid).aid
        try await apiClient.likeComment(aid: aid, rpid: rpid, action: action)
    }

    func hateComment(for video: BiliVideo, rpid: Int, action: Int) async throws {
        let aid = video.aid > 0 ? video.aid : try await apiClient.videoDetail(bvid: video.bvid).aid
        try await apiClient.hateComment(aid: aid, rpid: rpid, action: action)
    }

    func reportComment(for video: BiliVideo, rpid: Int, reason: Int, content: String? = nil) async throws {
        let aid = video.aid > 0 ? video.aid : try await apiClient.videoDetail(bvid: video.bvid).aid
        try await apiClient.reportComment(aid: aid, rpid: rpid, reason: reason, content: content)
    }

    /// Report a single history tick. The caller decides cadence — the
    /// canonical pattern is `progress=0` on playback start and
    /// every 30s thereafter. The repository resolves `aid` from the
    /// video (or fetches the detail by `bvid` if the feed entry
    /// only carried a `bvid`) and pulls the matching `cid` from
    /// the most recent detail load. Failures are non-fatal: the
    /// caller should catch and `bpLog` rather than surface to the
    /// user — a missed history tick does not affect playback.
    func reportHistory(for video: BiliVideo, cid: Int, progress: Int) async throws {
        let aid = video.aid > 0 ? video.aid : try await apiClient.videoDetail(bvid: video.bvid).aid
        try await apiClient.reportHistory(aid: aid, cid: cid, progress: progress)
    }

    /// Lower-level variant that takes already-resolved identifiers.
    /// `WatchSession` (in `WatchSession.swift`) calls this every
    /// 30 seconds; it has no `BiliVideo` because the timer runs
    /// across the inline ↔ fullscreen transition and the video
    /// object is not always in hand.
    func reportHistoryForWatchSession(aid: Int, cid: Int, progress: Int) async throws {
        try await apiClient.reportHistory(aid: aid, cid: cid, progress: progress)
    }

    func dynamicFeed(offset: String = "") async throws -> DynamicFeedPage {
        try await apiClient.dynamicFeed(offset: offset)
    }

    /// Logged-in-only attention feed. Because Bilibili does not
    /// expose a follow-scoped dynamic REST endpoint (`/feed/attention`
    /// returns 404), we mirror the Android paladala approach: fetch the
    /// user's followings once, then filter `/feed/all` client-side.
    ///
    /// The followings set is fetched lazily and reused across paginated
    /// requests until the caller invalidates it (e.g. on account
    /// switch or pull-to-refresh). Re-fetching per page would balloon
    /// a 323-follow user into 6-7 round-trips per scroll, which is why
    /// we cache.
    ///
    /// Returns an empty page with `needsLogin: true` when the user is
    /// signed out so the home view can render the existing "登录后
    /// 查看关注动态" prompt without a try/catch dance.
    private var cachedFollowings: (accountMid: Int64, mids: Set<Int64>)?

    func attentionFeed(
        offset: String = "",
        accountMid: Int64,
        refreshFollowings: Bool = false
    ) async throws -> DynamicFeedPage {
        if refreshFollowings { cachedFollowings = nil }
        let mids = try await ensureFollowings(for: accountMid)
        return try await apiClient.attentionFeed(offset: offset, followingFilter: mids)
    }

    /// Drop the cached followings set. Call on account switch so the
    /// next follow-feed load fetches the new account's followings
    /// instead of returning the previous user's filter.
    func invalidateFollowingsCache() {
        cachedFollowings = nil
    }

    private func ensureFollowings(for accountMid: Int64) async throws -> Set<Int64> {
        if let cached = cachedFollowings, cached.accountMid == accountMid {
            return cached.mids
        }
        let mids = try await apiClient.followingMids(vmid: accountMid)
        cachedFollowings = (accountMid, mids)
        return mids
    }

    func history(cursor: HistoryCursorState? = nil) async throws -> HistoryPageResult {
        try await apiClient.history(cursor: cursor)
    }

    func watchLaterVideos() async throws -> [BiliVideo] {
        try await apiClient.watchLaterVideos()
    }

    /// Add `video` to the user's Watch Later list. Resolves the
    /// `aid` from the feed entry, falling back to a detail fetch
    /// when only the `bvid` is known. Mirrors the symmetry of the
    /// other comment / history helpers in this file.
    func addToWatchLater(video: BiliVideo) async throws {
        let aid = video.aid > 0 ? video.aid : try await apiClient.videoDetail(bvid: video.bvid).aid
        try await apiClient.addToWatchLater(aid: aid)
    }

    /// Symmetric counterpart to `addToWatchLater`. Used by the
    /// destructive option in the long-press context menu on a
    /// Watch Later row (so the user can pull the video back out
    /// without opening the list).
    func removeFromWatchLater(video: BiliVideo) async throws {
        let aid = video.aid > 0 ? video.aid : try await apiClient.videoDetail(bvid: video.bvid).aid
        try await apiClient.removeFromWatchLater(aid: aid)
    }

    /// Like (or unlike) a video. The centre-tap heart gesture on
    /// the inline player calls this with `action=1` for a like and
    /// `action=2` to clear an existing like. The server response
    /// is not consumed — the local heart animation is the only
    /// feedback.
    func likeVideo(video: BiliVideo, action: Int) async throws {
        let aid = video.aid > 0 ? video.aid : try await apiClient.videoDetail(bvid: video.bvid).aid
        try await apiClient.likeVideo(aid: aid, action: action)
    }

    /// Fetch Bilibili's official AI 视频总结 for a video.
    ///
    /// Returns `nil` when:
    ///   - the video has no AI summary yet (upstream returns a
    ///     non-zero `code`)
    ///   - the user is anonymous (-101)
    ///   - the request hits 风控 (-403 / -352)
    ///
    /// The ViewModel treats all three as "no section to render".
    ///
    /// `ownerMid == 0` short-circuits because the request would
    /// fail without a known `up_mid`; this is the feed-entry
    /// shape (`HomeRecommendCard`, dynamic-feed archive, history
    /// rows) whose `BiliVideo.ownerMid` is `0`. The detail view's
    /// `load(...)` always replaces `model.detail` with the full
    /// `VideoDTO` shape (which carries the real `ownerMid`) before
    /// invoking `loadAISummary`, so the guard is purely defensive.
    func aiSummary(for video: BiliVideo) async throws -> BiliAISummary? {
        guard video.ownerMid != 0, video.cid != 0 else { return nil }
        return try await apiClient.aiSummary(
            bvid: video.bvid,
            aid: video.aid,
            cid: video.cid,
            upMid: video.ownerMid
        )
    }

    func favoriteFolders(mid: Int64) async throws -> [FavoriteFolderSummary] {
        try await apiClient.favoriteFolders(mid: mid)
    }

    func favoriteVideos(mediaID: Int64, page: Int = 1) async throws -> FavoriteFolderVideosPage {
        try await apiClient.favoriteVideos(mediaID: mediaID, page: page)
    }

    /// Fetch following, follower, and dynamic counts for the given user.
    /// Returns a tuple of strings formatted for the profile stat pills.
    func userStats(mid: Int64) async throws -> (following: String, follower: String, dynamic: String) {
        // Fetch independently so one flaky public endpoint does
        // not blank the whole stats row. In practice
        // `/x/space/nav/num` is more brittle than relation
        // stats, so preserving 粉丝 / 关注 is better than
        // failing the combined tuple.
        async let relationResult = try? await apiClient.userRelationStat(mid: mid)
        async let dynamicResult = try? await apiClient.userDynamicCount(mid: mid)

        let (relation, dynamic) = await (relationResult, dynamicResult)
        return (
            following: relation?.following.compactCount ?? "--",
            follower: relation?.follower.compactCount ?? "--",
            dynamic: dynamic?.compactCount ?? "--"
        )
    }

    /// Fetch a user's public profile card. Thin pass-through to
    /// `BilibiliAPIClient.userCardInfo(mid:)`; exists so
    /// `UPProfileViewModel` calls the repository (not the raw
    /// client) for symmetry with `userStats(mid:)` and the
    /// other user-scoped helpers above.
    func userCardInfo(mid: Int64) async throws -> BiliUserCard {
        try await apiClient.userCardInfo(mid: mid)
    }

    /// Page through a UP's published videos. Thin pass-through
    /// to `BilibiliAPIClient.userVideos(mid:page:)`. The
    /// `(videos, hasMore)` shape mirrors
    /// `FavoriteFolderVideosPage` so `UPProfileViewModel` can
    /// reuse the same pagination pattern as
    /// `HistoryListViewModel` / `FavoriteFolderVideosViewModel`.
    func userVideos(mid: Int64, page: Int = 1) async throws -> (videos: [BiliVideo], hasMore: Bool) {
        try await apiClient.userVideos(mid: mid, page: page)
    }

    /// Related videos for `bvid`. Powers the "next up" rail at
    /// the bottom of `VideoDetailView` and the auto-play-next
    /// queue in `VideoDetailViewModel`. Returns an empty array
    /// on empty `bvid` or any upstream error — the rail degrades
    /// to "no recommendations" rather than throwing into the
    /// view body.
    func relatedVideos(bvid: String) async throws -> [BiliVideo] {
        try await apiClient.relatedVideos(bvid: bvid)
    }

    /// Follow / unfollow a UP. `act` matches Bilibili's
    /// `/x/relation/modify` parameter: `1` for follow,
    /// `2` for unfollow, `3` for "悄悄关注". Returns the
    /// upstream `code` so the ViewModel can react to
    /// failure (-101, 22001, etc) with localised copy.
    @discardableResult
    func modifyRelation(target mid: Int64, act: Int) async throws -> Int {
        try await apiClient.modifyRelation(target: mid, act: act)
    }

    /// Check whether the signed-in user follows `mid`. The
    /// `selfMid` parameter exists because Bilibili's `/x/relation`
    /// endpoint requires the signed-in user's own mid; signed-
    /// out callers always see `.notRelated` so the follow
    /// button shows "关注" instead of an inconsistent
    /// "已关注" state.
    func userRelation(target mid: Int64, selfMid: Int64) async throws -> BiliRelation {
        try await apiClient.userRelation(target: mid, selfMid: selfMid)
    }

    /// Fetch a UP's own dynamic posts. Reuses the
    /// `DynamicFeedPage` shape so the UP profile's "动态"
    /// tab can render with the same card chrome as the
    /// follow feed.
    func userDynamic(hostMid: Int64, offset: String = "") async throws -> DynamicFeedPage {
        try await apiClient.userDynamic(hostMid: hostMid, offset: offset)
    }

    /// Fetch a UP's public favorite folders.
    /// Returns an empty array when `upMid == 0` so signed-out
    /// callers don't trip the upstream -101 guard.
    func userFavoriteFolders(upMid: Int64) async throws -> [FavoriteFolderSummary] {
        try await apiClient.userFavoriteFolders(upMid: upMid)
    }
}
