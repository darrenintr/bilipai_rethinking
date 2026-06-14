import Foundation
import SwiftUI

final class BiliPaiRepository: ObservableObject {
    let apiClient: BilibiliAPIClient
    private let bundled: BundledFeedService

    init(apiClient: BilibiliAPIClient, bundled: BundledFeedService = BundledFeedService()) {
        self.apiClient = apiClient
        self.bundled = bundled
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
    /// `bundled.samples(for:)` for explicit offline-mode use.
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
            if page == 1 {
                do {
                    let videos = try await apiClient.appRecommendedVideos(freshIndex: recommendFreshIndex, isRefresh: isRefresh)
                    if !videos.isEmpty { return videos }
                } catch {
                    bpLog("App API rcmd failed: \(error)")
                }
                // Fallback to web-side recommend if logged in but App API failed
                if let webRcmd = try? await apiClient.recommendedVideos(freshIndex: recommendFreshIndex), !webRcmd.isEmpty {
                    return webRcmd
                }
                if let popular = try? await apiClient.popularVideos(page: page), !popular.isEmpty {
                    return popular
                }
                if let ranking = try? await apiClient.rankingVideos(), !ranking.isEmpty {
                    return ranking
                }
                if let weekly = try? await apiClient.weeklyMustWatchVideos(), !weekly.isEmpty {
                    return weekly
                }
                return []
            }
            return try await apiClient.popularVideos(page: page)
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
        guard !video.bvid.isEmpty else { return video }
        return try await apiClient.videoDetail(bvid: video.bvid)
    }

    func playback(for video: BiliVideo) async throws -> BiliPlayback {
        let cid = video.cid
        if cid > 0 {
            return try await apiClient.playbackURL(bvid: video.bvid, cid: cid)
        }
        let detail = try await apiClient.videoDetail(bvid: video.bvid)
        return try await apiClient.playbackURL(bvid: detail.bvid, cid: detail.cid)
    }

    func liveRooms() async throws -> [BiliLiveRoom] {
        try await apiClient.liveRooms()
    }

    /// Resolve the playable stream URLs for a live room. The result
    /// contains zero, one, or both HLS and FLV slots depending on
    /// what the room's CDN exposes — the player UI is responsible for
    /// disabling whichever toggle is unavailable.
    func livePlayback(for room: BiliLiveRoom) async throws -> BiliLivePlayback {
        try await apiClient.livePlaybackURL(roomID: room.id)
    }

    func commentsPage(for video: BiliVideo, next: Int? = nil) async throws -> CommentPage {
        let aid = video.aid
        if aid > 0 {
            return try await apiClient.commentsPage(aid: aid, next: next)
        }
        if !video.bvid.isEmpty {
            let detail = try await apiClient.videoDetail(bvid: video.bvid)
            if detail.aid > 0 {
                return try await apiClient.commentsPage(aid: detail.aid, next: next)
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

    func dynamicFeed(offset: String = "") async throws -> DynamicFeedPage {
        try await apiClient.dynamicFeed(offset: offset)
    }

    /// Logged-in-only attention feed. Because Bilibili does not
    /// expose a follow-scoped dynamic REST endpoint (`/feed/attention`
    /// returns 404), we mirror the Android bilipai approach: fetch the
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

    func favoriteFolders(mid: Int64) async throws -> [FavoriteFolderSummary] {
        try await apiClient.favoriteFolders(mid: mid)
    }

    func favoriteVideos(mediaID: Int64, page: Int = 1) async throws -> FavoriteFolderVideosPage {
        try await apiClient.favoriteVideos(mediaID: mediaID, page: page)
    }
}
