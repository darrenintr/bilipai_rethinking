import Foundation

final class BiliPaiRepository {
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
    func feed(
        category: HomeCategory,
        searchQuery: String,
        popularSubCategory: PopularSubCategory,
        page: Int = 1
    ) async throws -> [BiliVideo] {
        switch category {
        case .recommend:
            if page == 1 {
                do {
                    let videos = try await apiClient.recommendedVideos()
                    if !videos.isEmpty { return videos }
                } catch {
                    // Recommendations are personalization-sensitive; popular videos are the public fallback.
                }
                do {
                    let popular = try await apiClient.popularVideos(page: page)
                    if !popular.isEmpty { return popular }
                } catch {
                    // Both recommend and popular failed. The page-1 fallback
                    // surfaces a small bundled sample set so the user has
                    // something to look at while pull-to-refresh retries;
                    // pagination is a no-op on bundled data.
                    if page == 1 {
                        return bundled.samples(for: .recommend)
                    }
                    throw error
                }
                return bundled.samples(for: .recommend)
            }
            do {
                return try await apiClient.popularVideos(page: page)
            } catch {
                if page == 1 { return bundled.samples(for: .popular) }
                throw error
            }
        case .follow:
            return []
        case .popular:
            switch popularSubCategory {
            case .comprehensive:
                do {
                    return try await apiClient.popularVideos(page: page)
                } catch {
                    if page == 1 { return bundled.samples(for: .popular) }
                    throw error
                }
            case .ranking:
                do {
                    return try await apiClient.rankingVideos()
                } catch {
                    return bundled.samples(for: .popular)
                }
            case .weekly:
                do {
                    return try await apiClient.weeklyMustWatchVideos()
                } catch {
                    return bundled.samples(for: .popular)
                }
            case .precious:
                do {
                    return try await apiClient.preciousVideos()
                } catch {
                    return bundled.samples(for: .popular)
                }
            }
        case .live:
            return []
        case .anime, .game, .knowledge, .tech:
            guard let tid = category.regionTid else { return [] }
            do {
                return try await apiClient.regionVideos(tid: tid, page: page)
            } catch {
                if page == 1 { return bundled.samples(for: category) }
                throw error
            }
        case .search:
            do {
                return try await apiClient.searchVideos(keyword: searchQuery, page: page)
            } catch {
                if page == 1 && !searchQuery.isEmpty {
                    return bundled.samples(for: .search)
                }
                throw error
            }
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
        if !video.bvid.isEmpty {
            let detail = try await apiClient.videoDetail(bvid: video.bvid)
            if detail.aid > 0 {
                return try await apiClient.comments(aid: detail.aid)
            }
        }
        // Neither the feed entry nor the video-detail fallback produced an
        // `aid` we can call the comment endpoint with. Surface a typed error
        // so the UI can show a specific "评论不可用" message instead of
        // pretending the request failed for some other reason.
        throw BilibiliAPIError.missingIdentity
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
