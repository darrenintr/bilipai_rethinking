import Foundation

final class BiliPaiRepository {
    private let apiClient: BilibiliAPIClient

    init(apiClient: BilibiliAPIClient) {
        self.apiClient = apiClient
    }

    func feed(
        category: HomeCategory,
        searchQuery: String,
        popularSubCategory: PopularSubCategory
    ) async throws -> [BiliVideo] {
        switch category {
        case .recommend:
            do {
                let videos = try await apiClient.recommendedVideos()
                if !videos.isEmpty { return videos }
            } catch {
                // Recommendations are personalization-sensitive; popular videos are the public fallback.
            }
            return try await apiClient.popularVideos()
        case .follow:
            return []
        case .popular:
            switch popularSubCategory {
            case .comprehensive:
                return try await apiClient.popularVideos()
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
            return try await apiClient.regionVideos(tid: tid)
        case .search:
            return try await apiClient.searchVideos(keyword: searchQuery)
        }
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

    func comments(for video: BiliVideo) async throws -> [BiliComment] {
        let aid = video.aid
        if aid > 0 {
            return try await apiClient.comments(aid: aid)
        }
        let detail = try await apiClient.videoDetail(bvid: video.bvid)
        return try await apiClient.comments(aid: detail.aid)
    }

    func dynamicPosts() -> [DynamicPost] {
        let recent = IntentRecentVideoStore.recentVideos().first
        return [
            DynamicPost(
                author: "BiliPai",
                text: "The iOS client is using public Bilibili endpoints for feed, search, detail, and playback URL discovery.",
                timeLabel: "Now",
                attachedVideo: recent?.video
            ),
            DynamicPost(
                author: "Player",
                text: "The production port keeps player business rules in services and leaves SwiftUI focused on state and layout.",
                timeLabel: "Today",
                attachedVideo: nil
            )
        ]
    }
}
