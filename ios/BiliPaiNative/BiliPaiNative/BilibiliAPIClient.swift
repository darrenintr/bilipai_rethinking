import AVFoundation
import Foundation

final class BilibiliAPIClient {
    private let baseURL = URL(string: "https://api.bilibili.com")!
    private let liveBaseURL = URL(string: "https://api.live.bilibili.com")!
    private let session: URLSession
    private let decoder: JSONDecoder
    /// Closure that returns the active account's `Cookie:` header, or
    /// `nil` when the user is signed out. The `BilibiliAPIClient` does
    /// not own the `AuthStore` so it stays decoupled from auth state —
    /// the closure is re-evaluated on every request, so switching
    /// accounts in `ProfileSettingsView` immediately takes effect.
    var cookieProvider: (() -> String?)?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // The default `URLSession.shared` returns immediately with
            // `NSURLErrorNotConnectedToInternet` on a weak link and never
            // retries. For the BiliPai public feeds that is the dominant
            // failure mode on first launch. A 15 s request / 60 s resource
            // timeout with `waitsForConnectivity = true` lets the request
            // ride out brief network drops without failing the whole feed.
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = true
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpAdditionalHeaders = [
                "User-Agent": "Mozilla/5.0 BiliPai-iOS/0.1",
                "Referer": "https://www.bilibili.com"
            ]
            self.session = URLSession(configuration: config)
        }
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

    func searchVideos(keyword: String, page: Int = 1) async throws -> [BiliVideo] {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/search/type",
            queryItems: [
                URLQueryItem(name: "search_type", value: "video"),
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "page", value: "\(page)")
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
        // Pinned comments arrive under `top_replies`; regular replies under
        // `replies`. Bilibili sometimes sends a thread where every visible
        // comment is pinned — without merging we'd show an empty list.
        let pinned = payload.value?.topReplies?.items ?? []
        let regular = payload.value?.replies?.items ?? []
        var seen = Set<Int>()
        var merged: [BiliComment] = []
        for dto in pinned + regular {
            let model = dto.model
            if seen.insert(model.id).inserted {
                merged.append(model)
            }
        }
        return merged
    }

    private func get<T: Decodable>(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> T {
        // Cache-bust every public-endpoint request. URLSession's shared
        // cache is shared across the app, and Bilibili returns
        // `Cache-Control: max-age=...` on the popular / recommend endpoints
        // — without the timestamp the second pull-to-refresh returns the
        // same `pn=1` payload from disk and the user sees the same batch.
        var items = queryItems
        items.append(URLQueryItem(name: "_t", value: "\(Int(Date().timeIntervalSince1970 * 1000))"))
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        guard let url = components.url else {
            throw BilibiliAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        // Belt-and-braces: even with the cache-busting query, force the
        // request itself to skip the URL cache. The session-level
        // `requestCachePolicy` is `.reloadIgnoringLocalCacheData` already,
        // but Bilibili also has its own CDN-side cache that the timestamp
        // parameter is the only reliable way to defeat.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 BiliPai-iOS/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // Inject the active account's cookies. The `comments` endpoint
        // returns `code: -352 风控` without a SESSDATA cookie, so this
        // is the line that makes the comments list load for signed-in
        // users. For signed-out users the closure returns nil and we
        // send the request anonymously (the public feeds work fine).
        if let cookie = cookieProvider?() {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Log the failure for the device console (Xcode → Window → Devices
            // and Simulators → Open Console). Pull-to-refresh still works
            // after this, but without the log the user has no way to know
            // whether the failure is a connectivity blip, a DNS issue, or a
            // Bilibili-side rate limit.
            NSLog("BiliPai: GET \(url.absoluteString) failed: \(error.localizedDescription)")
            throw error
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            NSLog("BiliPai: GET \(url.absoluteString) returned HTTP \(status)")
            throw BilibiliAPIError.http
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // The decoder failures we have seen are almost always one
            // missing/renamed field in a single video DTO, not a structural
            // change. Log the body so the next debugging session has the
            // raw JSON to work with.
            NSLog("BiliPai: decode failed for \(url.absoluteString): \(error)\n  body: \(String(data: data.prefix(512), encoding: .utf8) ?? "<binary>")")
            throw error
        }
    }
}

enum BilibiliAPIError: Error {
    case invalidURL
    case http
    case api(String)
    case missingData
    /// The endpoint we wanted to call requires an `aid` (or `bvid`) on the
    /// input and we have neither. Surfacing this as a typed error lets the
    /// caller show a clear "评论不可用" message instead of a generic
    /// "Could not load public comments." after a doomed network call.
    case missingIdentity
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

    /// Tolerant decoder: walks the response looking for a known list
    /// key (`item` / `list` / `result` / `archives`) and decodes each
    /// video *individually*. Any single malformed item is dropped
    /// instead of failing the whole page — a strict `try decoder.decode`
    /// of `[VideoDTO]` would crash the entire feed on one bad row.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        self.item = Self.decodeTolerant(in: container, key: "item")
        self.list = Self.decodeTolerant(in: container, key: "list")
        self.result = Self.decodeTolerant(in: container, key: "result")
        self.archives = Self.decodeTolerant(in: container, key: "archives")
    }

    /// Decodes an array of `VideoDTO` by falling back to a per-item
    /// pass when the strict decode throws. Returns `nil` when the
    /// key is absent (mirrors the previous `[VideoDTO]?` behaviour).
    private static func decodeTolerant(
        in container: KeyedDecodingContainer<DynamicKey>,
        key: String
    ) -> [VideoDTO]? {
        guard container.contains(DynamicKey(key)) else { return nil }
        if let strict = try? container.decode([VideoDTO].self, forKey: DynamicKey(key)) {
            return strict
        }
        // Per-item fallback: decode each element independently. Bad
        // entries are silently dropped — losing a single row is much
        // better than losing the whole page.
        if let lenient = try? container.decode([FailableDecodable<VideoDTO>].self, forKey: DynamicKey(key)) {
            return lenient.compactMap(\.value)
        }
        return nil
    }

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
    let replies: LenientCommentArray?
    let topReplies: LenientCommentArray?

    enum CodingKeys: String, CodingKey {
        case replies
        case topReplies = "top_replies"
    }
}

/// A wrapper that drops any reply that fails to decode, so a single
/// non-text reply (image, at-mention, emote, vote, …) does not take the
/// whole comment thread down with it. Bilibili mixes reply types in the
/// same array and the per-reply shape is not consistent enough to be
/// decoded all-or-nothing.
private struct LenientCommentArray: Decodable {
    let items: [CommentDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([FailableDecodable<CommentDTO>].self)
        self.items = raw.compactMap(\.value)
    }
}

private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            self.value = try container.decode(T.self)
        } catch {
            // Drop this element and keep going.
            self.value = nil
        }
    }
}

private struct CommentDTO: Decodable {
    let rpid: Int
    let member: Member
    let content: Content
    let like: Int
    let rcount: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rpid = try container.decode(Int.self, forKey: .rpid)
        member = try container.decode(Member.self, forKey: .member)
        content = try container.decode(Content.self, forKey: .content)
        like = try container.decodeIfPresent(Int.self, forKey: .like) ?? 0
        rcount = try container.decodeIfPresent(Int.self, forKey: .rcount)
    }

    enum CodingKeys: String, CodingKey {
        case rpid
        case member
        case content
        case like
        case rcount
    }

    var model: BiliComment {
        BiliComment(
            id: rpid,
            authorName: member.uname,
            avatarURL: member.avatarURL,
            message: content.message,
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

    /// Bilibili reply `content` shapes are not uniform. Text replies have
    /// `message`; image replies have `pictures`; at-mentions have
    /// `at_name_to_mid`; emotes have `emote`. We accept whichever field is
    /// present and synthesise a label for the non-text cases so the row
    /// still renders instead of failing the whole thread.
    struct Content: Decodable {
        let message: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            if let raw = try? container.decode(String.self, forKey: DynamicKey("message")) {
                message = raw.strippingHTML
            } else if container.contains(DynamicKey("pictures")) {
                message = "[图片评论]"
            } else if container.contains(DynamicKey("vote")) {
                message = "[投票]"
            } else if container.contains(DynamicKey("emote")) {
                message = "[表情]"
            } else {
                message = ""
            }
        }
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
