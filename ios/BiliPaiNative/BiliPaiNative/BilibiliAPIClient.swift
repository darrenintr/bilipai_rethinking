import AVFoundation
import Foundation

final class BilibiliAPIClient {
    private let baseURL = URL(string: "https://api.bilibili.com")!
    private let liveBaseURL = URL(string: "https://api.live.bilibili.com")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    func recommendedVideos() async throws -> [BiliVideo] {
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/index/top/feed/rcmd",
            queryItems: [
                URLQueryItem(name: "ps", value: "20"),
                URLQueryItem(name: "fresh_type", value: "4"),
                URLQueryItem(name: "feed_version", value: "V8")
            ]
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func popularVideos(page: Int = 1) async throws -> [BiliVideo] {
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/popular",
            queryItems: [
                URLQueryItem(name: "ps", value: "20"),
                URLQueryItem(name: "pn", value: "\(page)")
            ]
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func rankingVideos() async throws -> [BiliVideo] {
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/ranking/v2",
            queryItems: [
                URLQueryItem(name: "rid", value: "0"),
                URLQueryItem(name: "type", value: "all")
            ]
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func preciousVideos() async throws -> [BiliVideo] {
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/popular/precious",
            queryItems: []
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func weeklyMustWatchVideos() async throws -> [BiliVideo] {
        let listPayload: APIResponse<WeeklySeriesListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/popular/series/list",
            queryItems: []
        )
        try listPayload.requireOK()
        let latestNumber = listPayload.value?.list.map(\.number).max() ?? 1
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/popular/series/one",
            queryItems: [URLQueryItem(name: "number", value: "\(latestNumber)")]
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func regionVideos(tid: Int, page: Int = 1) async throws -> [BiliVideo] {
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/dynamic/region",
            queryItems: [
                URLQueryItem(name: "rid", value: "\(tid)"),
                URLQueryItem(name: "pn", value: "\(page)"),
                URLQueryItem(name: "ps", value: "30")
            ]
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func searchVideos(keyword: String) async throws -> [BiliVideo] {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/search/type",
            queryItems: [
                URLQueryItem(name: "search_type", value: "video"),
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "page", value: "1")
            ]
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func videoDetail(bvid: String) async throws -> BiliVideo {
        let payload: APIResponse<VideoDTO> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/view",
            queryItems: [URLQueryItem(name: "bvid", value: bvid)]
        )
        try payload.requireOK()
        guard let detail = payload.value?.model else {
            throw BilibiliAPIError.missingData
        }
        return detail
    }

    func playbackURL(bvid: String, cid: Int) async throws -> BiliPlayback {
        let payload: APIResponse<PlayURLPayload> = try await get(
            baseURL: baseURL,
            path: "/x/player/playurl",
            queryItems: [
                URLQueryItem(name: "bvid", value: bvid),
                URLQueryItem(name: "cid", value: "\(cid)"),
                URLQueryItem(name: "qn", value: "64"),
                URLQueryItem(name: "fnval", value: "0"),
                URLQueryItem(name: "fourk", value: "1")
            ]
        )
        try payload.requireOK()
        guard let url = payload.value?.bestURL else {
            throw BilibiliAPIError.missingData
        }
        return BiliPlayback(url: url, referer: URL(string: "https://www.bilibili.com/video/\(bvid)")!)
    }

    func liveRooms() async throws -> [BiliLiveRoom] {
        let payload: APIResponse<LiveRoomPayload> = try await get(
            baseURL: liveBaseURL,
            path: "/room/v3/area/getRoomList",
            queryItems: [
                URLQueryItem(name: "parent_area_id", value: "0"),
                URLQueryItem(name: "area_id", value: "0"),
                URLQueryItem(name: "page_size", value: "30"),
                URLQueryItem(name: "sort_type", value: "online"),
                URLQueryItem(name: "page", value: "1")
            ]
        )
        try payload.requireOK()
        return payload.value?.list.map(\.model) ?? []
    }

    func comments(aid: Int) async throws -> [BiliComment] {
        guard aid > 0 else { return [] }
        let payload: APIResponse<CommentPayload> = try await get(
            baseURL: baseURL,
            path: "/x/v2/reply/main",
            queryItems: [
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "oid", value: "\(aid)"),
                URLQueryItem(name: "mode", value: "3"),
                URLQueryItem(name: "ps", value: "20")
            ]
        )
        try payload.requireOK()
        return payload.value?.replies?.map(\.model) ?? []
    }

    private func get<T: Decodable>(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        guard let url = components.url else {
            throw BilibiliAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 BiliPai-iOS/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BilibiliAPIError.http
        }
        return try decoder.decode(T.self, from: data)
    }
}

enum BilibiliAPIError: Error {
    case invalidURL
    case http
    case api(String)
    case missingData
}

private struct APIResponse<T: Decodable>: Decodable {
    let code: Int?
    let message: String?
    let data: T?
    let result: T?

    var value: T? {
        data ?? result
    }

    func requireOK() throws {
        if let code, code != 0 {
            throw BilibiliAPIError.api(message ?? "Bilibili API returned code \(code)")
        }
    }
}

private struct VideoListPayload: Decodable {
    let item: [VideoDTO]?
    let list: [VideoDTO]?
    let result: [VideoDTO]?
    let archives: [VideoDTO]?

    var videos: [VideoDTO] {
        item ?? list ?? result ?? archives ?? []
    }
}

private struct WeeklySeriesListPayload: Decodable {
    let list: [WeeklySeriesPeriod]
}

private struct WeeklySeriesPeriod: Decodable {
    let number: Int
}

private struct VideoDTO: Decodable {
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

    var model: BiliVideo {
        BiliVideo(
            bvid: bvid,
            aid: aid,
            cid: cid,
            title: title,
            ownerName: ownerName,
            coverURL: coverURL,
            duration: duration,
            viewCount: viewCount,
            danmakuCount: danmakuCount,
            likeCount: likeCount,
            description: description
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        bvid = container.decodeString(keys: ["bvid", "param"]) ?? ""
        aid = container.decodeInt(keys: ["aid", "id"]) ?? 0
        cid = container.decodeInt(keys: ["cid"]) ?? 0
        title = container.decodeString(keys: ["title"])?.strippingHTML ?? "Untitled"
        coverURL = container.decodeString(keys: ["pic", "cover"])?.httpsURL
        duration = container.decodeInt(keys: ["duration"]) ?? 0
        description = container.decodeString(keys: ["desc", "description"]) ?? ""

        let owner = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("owner"))
        let args = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("args"))
        ownerName = owner?.decodeString(keys: ["name"]) ?? args?.decodeString(keys: ["up_name"]) ?? "Unknown"

        let stat = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("stat"))
        viewCount = stat?.decodeInt(keys: ["view", "view_count"]) ?? container.decodeInt(keys: ["play"]) ?? 0
        danmakuCount = stat?.decodeInt(keys: ["danmaku"]) ?? container.decodeInt(keys: ["danmaku"]) ?? 0
        likeCount = stat?.decodeInt(keys: ["like"]) ?? 0
    }
}

private struct PlayURLPayload: Decodable {
    let durl: [DURL]?
    let dash: Dash?

    var bestURL: URL? {
        if let url = durl?.first?.url {
            return url
        }
        return dash?.video.first?.baseURL
    }

    struct DURL: Decodable {
        let url: URL
    }

    struct Dash: Decodable {
        let video: [DashVideo]
    }

    struct DashVideo: Decodable {
        let baseURL: URL

        enum CodingKeys: String, CodingKey {
            case baseURL = "baseUrl"
        }
    }
}

private struct LiveRoomPayload: Decodable {
    let list: [LiveRoomDTO]
}

private struct LiveRoomDTO: Decodable {
    let roomid: Int
    let title: String
    let uname: String
    let areaName: String
    let coverURL: URL?
    let online: Int

    var model: BiliLiveRoom {
        BiliLiveRoom(
            id: roomid,
            title: title,
            hostName: uname,
            areaName: areaName,
            coverURL: coverURL,
            viewerCount: online
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        roomid = container.decodeInt(keys: ["roomid"]) ?? 0
        title = container.decodeString(keys: ["title"]) ?? "直播间"
        uname = container.decodeString(keys: ["uname"]) ?? "Unknown"
        areaName = container.decodeString(keys: ["area_name", "area_v2_name", "parent_name"]) ?? ""
        coverURL = container.decodeString(keys: ["cover", "user_cover", "system_cover", "show_cover"])?.httpsURL
        online = container.decodeInt(keys: ["online"]) ?? 0
    }
}

private struct CommentPayload: Decodable {
    let replies: [CommentDTO]?
}

private struct CommentDTO: Decodable {
    let rpid: Int
    let member: Member
    let content: Content
    let like: Int
    let rcount: Int?

    var model: BiliComment {
        BiliComment(
            id: rpid,
            authorName: member.uname,
            avatarURL: member.avatarURL,
            message: content.message.strippingHTML,
            likeCount: like,
            replyCount: rcount ?? 0
        )
    }

    struct Member: Decodable {
        let uname: String
        let avatarURL: URL?

        enum CodingKeys: String, CodingKey {
            case uname
            case avatarURL = "avatar"
        }
    }

    struct Content: Decodable {
        let message: String
    }
}

private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private extension KeyedDecodingContainer where K == DynamicKey {
    func decodeString(keys: [String]) -> String? {
        for key in keys {
            if let value = try? decode(String.self, forKey: DynamicKey(key)) {
                return value
            }
            if let value = try? decode(Int.self, forKey: DynamicKey(key)) {
                return "\(value)"
            }
        }
        return nil
    }

    func decodeInt(keys: [String]) -> Int? {
        for key in keys {
            if let value = try? decode(Int.self, forKey: DynamicKey(key)) {
                return value
            }
            if let string = try? decode(String.self, forKey: DynamicKey(key)), let value = Int(string) {
                return value
            }
        }
        return nil
    }
}

private extension String {
    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    var httpsURL: URL? {
        let source = hasPrefix("//") ? "https:\(self)" : self
        guard var components = URLComponents(string: source) else { return nil }
        if components.scheme == "http" {
            components.scheme = "https"
        }
        return components.url
    }
}
