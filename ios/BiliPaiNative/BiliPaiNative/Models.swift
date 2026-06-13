import Foundation

enum HomeCategory: String, CaseIterable, Identifiable {
    case recommend
    case follow
    case popular
    case live
    case anime
    case game
    case knowledge
    case tech
    case search

    var id: String { rawValue }

    static let androidTabs: [HomeCategory] = [
        .recommend,
        .follow,
        .popular,
        .live,
        .anime,
        .game,
        .knowledge,
        .tech
    ]

    var title: String {
        switch self {
        case .recommend: "推荐"
        case .follow: "关注"
        case .popular: "热门"
        case .live: "直播"
        case .anime: "追番"
        case .game: "游戏"
        case .knowledge: "知识"
        case .tech: "科技"
        case .search: "搜索"
        }
    }

    var regionTid: Int? {
        switch self {
        case .anime: 13
        case .game: 4
        case .knowledge: 36
        case .tech: 188
        default: nil
        }
    }
}

enum PopularSubCategory: String, CaseIterable, Identifiable {
    case comprehensive
    case ranking
    case weekly
    case precious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comprehensive: "综合热门"
        case .ranking: "排行榜"
        case .weekly: "每周必看"
        case .precious: "入站必刷"
        }
    }
}

struct BiliVideo: Identifiable, Hashable, Codable {
    var id: String { bvid.isEmpty ? "\(aid)" : bvid }

    let bvid: String
    let aid: Int
    let cid: Int
    var title: String
    let ownerName: String
    let coverURL: URL?
    let duration: Int
    var viewCount: Int
    var danmakuCount: Int
    var likeCount: Int
    let description: String
}

struct BiliPlayback: Hashable {
    let videoURL: URL
    let audioURL: URL?
    let referer: URL
}

struct BiliLiveRoom: Identifiable, Hashable {
    let id: Int
    let title: String
    let hostName: String
    let areaName: String
    let coverURL: URL?
    let viewerCount: Int
}

struct BiliComment: Identifiable, Hashable {
    let id: Int
    let authorName: String
    let avatarURL: URL?
    let message: String
    let likeCount: Int
    let replyCount: Int
    let replies: [BiliComment]
}

struct CommentPage: Hashable {
    let items: [BiliComment]
    let next: Int?
    let isEnd: Bool
    let totalCount: Int
}

struct DynamicPost: Identifiable, Hashable {
    let id: String
    let author: String
    let authorAvatarURL: URL?
    let text: String
    let timeLabel: String
    let attachedVideo: BiliVideo?
}

struct DynamicFeedPage: Hashable {
    let items: [DynamicPost]
    let nextOffset: String
    let hasMore: Bool
}

struct HistoryCursorState: Hashable {
    let max: Int64
    let viewAt: Int64
    let business: String
}

struct HistoryEntry: Identifiable, Hashable {
    let id: String
    let video: BiliVideo
    let viewedAt: Int64
    let progress: Int
}

struct HistoryPageResult: Hashable {
    let items: [HistoryEntry]
    let nextCursor: HistoryCursorState?
}

struct FavoriteFolderSummary: Identifiable, Hashable {
    let id: Int64
    let title: String
    let coverURL: URL?
    let mediaCount: Int
    let ownerName: String
}

struct FavoriteFolderVideosPage: Hashable {
    let title: String
    let videos: [BiliVideo]
    let hasMore: Bool
}
