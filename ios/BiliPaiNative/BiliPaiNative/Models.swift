import Foundation

enum HomeCategory: String, CaseIterable, Identifiable {
    case recommend
    case popular
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommend: "Recommend"
        case .popular: "Popular"
        case .search: "Search"
        }
    }
}

struct BiliVideo: Identifiable, Hashable, Codable {
    var id: String { bvid.isEmpty ? "\(aid)" : bvid }

    let bvid: String
    let aid: Int
    let cid: Int
    let title: String
    let ownerName: String
    let coverURL: URL?
    let duration: Int
    let viewCount: Int
    let danmakuCount: Int
    let likeCount: Int
    let description: String
}

struct BiliPlayback: Hashable {
    let url: URL
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
}

struct DynamicPost: Identifiable, Hashable {
    let id = UUID()
    let author: String
    let text: String
    let timeLabel: String
    let attachedVideo: BiliVideo?
}
