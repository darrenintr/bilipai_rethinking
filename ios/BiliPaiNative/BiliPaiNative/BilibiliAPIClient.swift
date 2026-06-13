import AVFoundation
import CryptoKit
import Foundation

final class BilibiliAPIClient {
    private let baseURL = URL(string: "https://api.bilibili.com")!
    private let appBaseURL = URL(string: "https://app.bilibili.com")!
    private let liveBaseURL = URL(string: "https://api.live.bilibili.com")!
    private let session: URLSession
    private let decoder: JSONDecoder
    private let wbiSigner = WbiSigner()
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

    func recommendedVideos(freshIndex: Int = 0) async throws -> [BiliVideo] {
        if cookieProvider?() != nil {
            // If the user is logged in, use the App API for optimized recommendations.
            // This endpoint provides a more personalized feed based on user history.
            return try await appRecommendedVideos()
        }

        // The canonical path per the pskdje/bilibili-API-collect docs is
        // `/x/web-interface/wbi/index/top/feed/rcmd` (note the `wbi`
        // segment). The shorter non-wbi path is the legacy alias and
        // Bilibili 風控 is stricter on it for anonymous iOS clients —
        // hits it returns 200 with an empty `item` array, which the
        // user sees as "same batch on every pull-to-refresh".
        let payload: APIResponse<VideoListPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/wbi/index/top/feed/rcmd",
            queryItems: [
                URLQueryItem(name: "ps", value: "20"),
                URLQueryItem(name: "fresh_type", value: "4"),
                URLQueryItem(name: "fresh_idx", value: "\(freshIndex)"),
                URLQueryItem(name: "feed_version", value: "V8"),
                URLQueryItem(name: "web_location", value: "1430650"),
                URLQueryItem(name: "y_num", value: "\(freshIndex)")
            ],
            signWithWBI: true
        )
        try payload.requireOK()
        return payload.value?.videos.map(\.model) ?? []
    }

    func appRecommendedVideos() async throws -> [BiliVideo] {
        // App-side recommendation endpoint: https://app.bilibili.com/x/v2/feed/index
        // This provides a high-quality feed similar to the mobile app when logged in.
        let payload: APIResponse<AppFeedPayload> = try await get(
            baseURL: appBaseURL,
            path: "/x/v2/feed/index",
            queryItems: [
                URLQueryItem(name: "mobi_app", value: "iphone"),
                URLQueryItem(name: "platform", value: "ios"),
                URLQueryItem(name: "idx", value: "\(Int(Date().timeIntervalSince1970))"),
                URLQueryItem(name: "pull", value: "true"),
                URLQueryItem(name: "login_event", value: "0")
            ]
        )
        try payload.requireOK()
        return payload.value?.items.compactMap(\.model) ?? []
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
            path: "/x/web-interface/wbi/search/type",
            queryItems: [
                URLQueryItem(name: "search_type", value: "video"),
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "page_size", value: "20"),
                URLQueryItem(name: "platform", value: "pc"),
                URLQueryItem(name: "web_location", value: "1430654")
            ],
            signWithWBI: true
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
        // The current canonical path is `/x/player/wbi/playurl` — the
        // non-wbi alias is being phased out. `fnval=1` requests the MP4
        // stream (DASH); `fnval=0` was the legacy FLV-only flag and the
        // endpoint now returns an empty `durl` array with that value,
        // which is why every video was previously failing the
        // `bestURL` check and falling through to "Playback is
        // unavailable". `gaia_source=view-card` is the same hint the
        // web player sends — Bilibili loosens the 1080P gate slightly
        // for this source.
        let payload: APIResponse<PlayURLPayload> = try await get(
            baseURL: baseURL,
            path: "/x/player/wbi/playurl",
            queryItems: [
                URLQueryItem(name: "bvid", value: bvid),
                URLQueryItem(name: "cid", value: "\(cid)"),
                URLQueryItem(name: "qn", value: "64"),
                URLQueryItem(name: "fnval", value: "64"), // Request HLS (Master Playlist)
                URLQueryItem(name: "fnver", value: "0"),
                URLQueryItem(name: "fourk", value: "1"),
                URLQueryItem(name: "gaia_source", value: "view-card")
            ],
            signWithWBI: true
        )
        try payload.requireOK()
        guard let playback = payload.value?.bestPlayback else {
            throw BilibiliAPIError.missingData
        }
        return BiliPlayback(
            videoURL: playback.videoURL,
            audioURL: playback.audioURL,
            referer: URL(string: "https://www.bilibili.com/video/\(bvid)")!
        )
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

    func dynamicFeed(type: String = "all", offset: String = "") async throws -> DynamicFeedPage {
        let payload: APIResponse<DynamicFeedPayload> = try await get(
            baseURL: baseURL,
            path: "/x/polymer/web-dynamic/v1/feed/all",
            queryItems: [
                URLQueryItem(name: "type", value: type),
                URLQueryItem(name: "offset", value: offset),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "features", value: "itemOpusStyle,listOnlyfans,opusBigCover,commentsNewVersion,onlyfansVote,onlyfansAssetsV2,decorationCard,forwardListHidden,ugcDelete"),
                URLQueryItem(name: "timezone_offset", value: "-480"),
                URLQueryItem(name: "platform", value: "web"),
                URLQueryItem(name: "web_location", value: "333.1365")
            ]
        )
        try payload.requireOK()
        let data = payload.value
        return DynamicFeedPage(
            items: data?.items.compactMap(\.post).filter { !$0.id.isEmpty } ?? [],
            nextOffset: data?.offset ?? "",
            hasMore: data?.hasMore ?? false
        )
    }

    func history(cursor: HistoryCursorState? = nil, pageSize: Int = 30) async throws -> HistoryPageResult {
        var queryItems = [URLQueryItem(name: "ps", value: "\(pageSize)")]
        if let cursor {
            if cursor.max > 0 {
                queryItems.append(URLQueryItem(name: "max", value: "\(cursor.max)"))
            }
            if cursor.viewAt > 0 {
                queryItems.append(URLQueryItem(name: "view_at", value: "\(cursor.viewAt)"))
            }
            if !cursor.business.isEmpty {
                queryItems.append(URLQueryItem(name: "business", value: cursor.business))
            }
        }
        let payload: APIResponse<HistoryPayload> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/history/cursor",
            queryItems: queryItems
        )
        try payload.requireOK()
        let data = payload.value
        return HistoryPageResult(
            items: data?.items.compactMap(\.entry) ?? [],
            nextCursor: data?.cursor?.cursorState
        )
    }

    func watchLaterVideos() async throws -> [BiliVideo] {
        let payload: APIResponse<WatchLaterPayload> = try await get(
            baseURL: baseURL,
            path: "/x/v2/history/toview",
            queryItems: []
        )
        try payload.requireOK()
        return payload.value?.list.compactMap(\.video) ?? []
    }

    func favoriteFolders(mid: Int64) async throws -> [FavoriteFolderSummary] {
        let payload: APIResponse<FavoriteFoldersPayload> = try await get(
            baseURL: baseURL,
            path: "/x/v3/fav/folder/created/list-all",
            queryItems: [
                URLQueryItem(name: "up_mid", value: "\(mid)")
            ]
        )
        try payload.requireOK()
        return payload.value?.list.compactMap(\.folder) ?? []
    }

    func favoriteVideos(mediaID: Int64, page: Int = 1) async throws -> FavoriteFolderVideosPage {
        let payload: APIResponse<FavoriteResourcesPayload> = try await get(
            baseURL: baseURL,
            path: "/x/v3/fav/resource/list",
            queryItems: [
                URLQueryItem(name: "media_id", value: "\(mediaID)"),
                URLQueryItem(name: "pn", value: "\(page)"),
                URLQueryItem(name: "ps", value: "20"),
                URLQueryItem(name: "platform", value: "web")
            ]
        )
        try payload.requireOK()
        let info = payload.value?.info
        let medias = payload.value?.medias.compactMap(\.video) ?? []
        return FavoriteFolderVideosPage(
            title: info?.title ?? "收藏夹",
            videos: medias,
            hasMore: payload.value?.hasMore ?? false
        )
    }

    func commentsPage(aid: Int, next: Int? = nil, pageSize: Int = 20) async throws -> CommentPage {
        guard aid > 0 else {
            return CommentPage(items: [], next: nil, isEnd: true, totalCount: 0)
        }
        // The current canonical path is `/x/v2/reply/wbi/main`. The
        // payload shape changed alongside it: pinned/UP主置顶 replies
        // now live under `data.upper.top` (an object keyed by rpid),
        // not the legacy `data.top_replies` array. We decode both
        // shapes so an old cache or a flaky CDN edge that still serves
        // the legacy field does not produce an empty list.
        var queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "oid", value: "\(aid)"),
            URLQueryItem(name: "mode", value: "3"),
            URLQueryItem(name: "ps", value: "\(pageSize)")
        ]
        if let next {
            queryItems.append(URLQueryItem(name: "next", value: "\(next)"))
        }
        let payload: APIResponse<CommentPayload> = try await get(
            baseURL: baseURL,
            path: "/x/v2/reply/wbi/main",
            queryItems: queryItems,
            signWithWBI: true
        )
        try payload.requireOK()
        // Pinned comments arrive under `upper.top`; regular replies under
        // `replies`. The legacy `top_replies` array is read defensively
        // for caches that still serve it. Bilibili sometimes sends a
        // thread where every visible comment is pinned — without
        // merging we'd show an empty list.
        let pinned = payload.value?.upperTop?.values.map(\.model) ?? []
        let legacyPinned = payload.value?.topReplies?.items.map(\.model) ?? []
        let regular = payload.value?.replies?.items.map(\.model) ?? []
        var seen = Set<Int>()
        var merged: [BiliComment] = []
        for model in pinned + legacyPinned + regular {
            if seen.insert(model.id).inserted {
                merged.append(model)
            }
        }
        return CommentPage(
            items: merged,
            next: payload.value?.cursor?.next,
            isEnd: payload.value?.cursor?.isEnd ?? true,
            totalCount: payload.value?.cursor?.allCount ?? merged.count
        )
    }

    func repliesPage(aid: Int, rpid: Int, pn: Int = 1, pageSize: Int = 20) async throws -> CommentPage {
        let payload: APIResponse<CommentPayload> = try await get(
            baseURL: baseURL,
            path: "/x/v2/reply/reply",
            queryItems: [
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "oid", value: "\(aid)"),
                URLQueryItem(name: "root", value: "\(rpid)"),
                URLQueryItem(name: "pn", value: "\(pn)"),
                URLQueryItem(name: "ps", value: "\(pageSize)")
            ]
        )
        try payload.requireOK()
        let items = payload.value?.replies?.items.map(\.model) ?? []
        return CommentPage(
            items: items,
            next: (payload.value?.cursor?.isEnd ?? true) ? nil : pn + 1,
            isEnd: payload.value?.cursor?.isEnd ?? true,
            totalCount: payload.value?.cursor?.allCount ?? 0
        )
    }

    private func get<T: Decodable>(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem],
        signWithWBI: Bool = false
    ) async throws -> T {
        // Cache-bust every public-endpoint request. URLSession's shared
        // cache is shared across the app, and Bilibili returns
        // `Cache-Control: max-age=...` on the popular / recommend endpoints
        // — without the timestamp the second pull-to-refresh returns the
        // same `pn=1` payload from disk and the user sees the same batch.
        // We belt-and-braces this with three independent layers:
        //   1. `_t` is the request time in epoch ms. Bilibili's CDN
        //      ignores any GET that matches the previous timestamp.
        //   2. `_r` is a UUID — even two pulls in the same millisecond
        //      (e.g. UIKit coalescing two Tasks) get unique URLs.
        //   3. The session + per-request `cachePolicy =
        //      .reloadIgnoringLocalCacheData` and the explicit
        //      `Cache-Control: no-cache` header stop URLSession from
        //      serving a cached body before the network call even
        //      leaves the device.
        var items = queryItems
        let nonce = UUID().uuidString

        // Only add cache-busting if not already present in queryItems
        if !items.contains(where: { $0.name == "_t" }) {
            items.append(URLQueryItem(name: "_t", value: "\(Int(Date().timeIntervalSince1970 * 1000))"))
        }
        if !items.contains(where: { $0.name == "_r" }) {
            items.append(URLQueryItem(name: "_r", value: nonce))
        }

        if signWithWBI {
            items = try await wbiSigner.sign(queryItems: items, using: session)
        }
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

        // Specialized headers for App API
        if baseURL.host?.contains("app.bilibili.com") == true {
            request.setValue("iphone", forHTTPHeaderField: "mobi_app")
            request.setValue("ios", forHTTPHeaderField: "platform")
            // The app API is stricter about UA.
            request.setValue("bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)", forHTTPHeaderField: "User-Agent")
        }

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

private actor WbiSigner {
    private struct CachedKeys {
        let imgKey: String
        let subKey: String
        let fetchedAt: Date
    }

    private let mixinKeyEncTab = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52
    ]
    private let keyTTL: TimeInterval = 6 * 60 * 60
    private let navURL = URL(string: "https://api.bilibili.com/x/web-interface/nav")!
    private var cachedKeys: CachedKeys?

    func sign(queryItems: [URLQueryItem], using session: URLSession) async throws -> [URLQueryItem] {
        let keys = try await loadKeys(using: session)
        let mixinKey = buildMixinKey(imgKey: keys.imgKey, subKey: keys.subKey)
        let timestamp = String(Int(Date().timeIntervalSince1970))

        var params: [String: String] = [:]
        for item in queryItems {
            guard let value = item.value else { continue }
            params[item.name] = value.replacingOccurrences(of: #"[!'()*]"#, with: "", options: .regularExpression)
        }
        params["wts"] = timestamp

        let sorted = params.keys.sorted().map { key in
            "\(key)=\(encodeURIComponent(params[key] ?? ""))"
        }.joined(separator: "&")
        params["w_rid"] = md5(sorted + mixinKey)

        return params.keys.sorted().map { key in
            URLQueryItem(name: key, value: params[key])
        }
    }

    private func loadKeys(using session: URLSession) async throws -> CachedKeys {
        if let cachedKeys, Date().timeIntervalSince(cachedKeys.fetchedAt) < keyTTL {
            return cachedKeys
        }

        var request = URLRequest(url: navURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 BiliPai-iOS/0.1", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let payload = try JSONDecoder().decode(WbiNavResponse.self, from: data)
        let imgURL = payload.data.wbiImg.imgURL
        let subURL = payload.data.wbiImg.subURL
        let keys = CachedKeys(
            imgKey: imgURL.deletingPathExtension().lastPathComponent,
            subKey: subURL.deletingPathExtension().lastPathComponent,
            fetchedAt: Date()
        )
        cachedKeys = keys
        return keys
    }

    private func buildMixinKey(imgKey: String, subKey: String) -> String {
        let source = Array(imgKey + subKey)
        let mixed = mixinKeyEncTab.compactMap { index in
            index < source.count ? source[index] : nil
        }
        return String(mixed.prefix(32))
    }

    private func encodeURIComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        return value.unicodeScalars.map { scalar in
            if allowed.contains(scalar) {
                return String(scalar)
            }
            let bytes = String(scalar).utf8.map { String(format: "%%%02X", $0) }
            return bytes.joined()
        }.joined()
    }

    private func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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

private struct WbiNavResponse: Decodable {
    let data: WbiNavData
}

private struct WbiNavData: Decodable {
    let wbiImg: WbiImage

    enum CodingKeys: String, CodingKey {
        case wbiImg = "wbi_img"
    }
}

private struct WbiImage: Decodable {
    let imgURL: URL
    let subURL: URL

    enum CodingKeys: String, CodingKey {
        case imgURL = "img_url"
        case subURL = "sub_url"
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

private struct AppFeedPayload: Decodable {
    let items: [AppFeedItemDTO]
}

private struct AppFeedItemDTO: Decodable {
    let cardType: String
    let cardGoto: String
    let param: String
    let cover: URL?
    let title: String
    let uri: String
    let playerArgs: AppPlayerArgs?
    let descButton: AppDescButton?

    enum CodingKeys: String, CodingKey {
        case cardType = "card_type"
        case cardGoto = "card_goto"
        case param
        case cover
        case title
        case uri
        case playerArgs = "player_args"
        case descButton = "desc_button"
    }

    struct AppPlayerArgs: Decodable {
        let aid: Int
        let cid: Int
        let duration: Int
    }

    struct AppDescButton: Decodable {
        let text: String
    }

    var model: BiliVideo? {
        guard cardGoto == "av" else { return nil }
        return BiliVideo(
            bvid: "", // App API doesn't always provide bvid directly, we'll rely on aid
            aid: playerArgs?.aid ?? Int(param) ?? 0,
            cid: playerArgs?.cid ?? 0,
            title: title,
            ownerName: descButton?.text ?? "Bilibili",
            coverURL: cover,
            duration: playerArgs?.duration ?? 0,
            viewCount: 0, // Not provided in Int form in this DTO
            danmakuCount: 0,
            likeCount: 0,
            description: ""
        )
    }
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

    var bestPlayback: (videoURL: URL, audioURL: URL?)? {
        // iOS 15+ has native support for HLS. Bilibili returns HLS master
        // playlist in `durl` when `fnval=64` is requested.
        if let url = durl?.first?.url {
            return (videoURL: url, audioURL: nil)
        }
        guard let dash else { return nil }
        let preferredVideo = dash.video.first { video in
            video.codecs.localizedCaseInsensitiveContains("avc")
                || video.codecs.localizedCaseInsensitiveContains("h264")
        } ?? dash.video.first
        guard let preferredVideo else { return nil }
        return (videoURL: preferredVideo.baseURL, audioURL: dash.audio.first?.baseURL)
    }

    struct DURL: Decodable {
        let url: URL
    }

    struct Dash: Decodable {
        let video: [DashVideo]
        let audio: [DashMedia]
    }

    struct DashVideo: Decodable {
        let baseURL: URL
        let codecs: String

        enum CodingKeys: String, CodingKey {
            case baseURL = "baseUrl"
            case codecs
        }
    }

    struct DashMedia: Decodable {
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

private struct DynamicFeedPayload: Decodable {
    let items: [DynamicCardDTO]
    let offset: String
    let hasMore: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        items = (try? container.decode([DynamicCardDTO].self, forKey: DynamicKey("items"))) ?? []
        offset = container.decodeString(keys: ["offset"]) ?? ""
        hasMore = container.decodeBool(keys: ["has_more"]) ?? false
    }
}

private struct DynamicCardDTO: Decodable {
    let id: String
    let visible: Bool
    let authorName: String
    let authorAvatarURL: URL?
    let text: String
    let attachedVideo: BiliVideo?
    let timeLabel: String

    var post: DynamicPost? {
        guard visible else { return nil }
        return DynamicPost(
            id: id,
            author: authorName,
            authorAvatarURL: authorAvatarURL,
            text: text,
            timeLabel: timeLabel,
            attachedVideo: attachedVideo
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        id = container.decodeString(keys: ["id_str"]) ?? UUID().uuidString
        visible = container.decodeBool(keys: ["visible"]) ?? true

        let modules = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("modules"))
        let author = try? modules?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("module_author"))
        authorName = author?.decodeString(keys: ["name"]) ?? "Bilibili"
        authorAvatarURL = author?.decodeString(keys: ["face"])?.httpsURL
        let pubTs = author?.decodeInt64(keys: ["pub_ts"]) ?? 0
        timeLabel = pubTs > 0 ? Self.relativeTimeLabel(from: pubTs) : "刚刚"

        let moduleDynamic = try? modules?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("module_dynamic"))
        let desc = try? moduleDynamic?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("desc"))
        let major = try? moduleDynamic?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("major"))
        let archive = try? major?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("archive"))
        let opus = try? major?.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("opus"))

        let descText = desc?.decodeString(keys: ["text"])?.strippingHTML ?? ""
        let archiveTitle = archive?.decodeString(keys: ["title"])?.strippingHTML ?? ""
        let opusSummary = opus?.decodeString(keys: ["summary", "title"])?.strippingHTML ?? ""
        text = [descText, opusSummary, archiveTitle].first(where: { !$0.isEmpty }) ?? ""

        if let archive {
            let bvid = archive.decodeString(keys: ["bvid"]) ?? ""
            let aid = archive.decodeInt(keys: ["aid", "id"]) ?? 0
            let cid = archive.decodeInt(keys: ["cid"]) ?? 0
            let coverURL = archive.decodeString(keys: ["cover"])?.httpsURL
            let duration = archive.decodeInt(keys: ["duration"]) ?? 0
            let stat = try? archive.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("stat"))
            attachedVideo = BiliVideo(
                bvid: bvid,
                aid: aid,
                cid: cid,
                title: archiveTitle.isEmpty ? "视频动态" : archiveTitle,
                ownerName: authorName,
                coverURL: coverURL,
                duration: duration,
                viewCount: stat?.decodeInt(keys: ["play", "view"]) ?? 0,
                danmakuCount: stat?.decodeInt(keys: ["danmaku"]) ?? 0,
                likeCount: stat?.decodeInt(keys: ["like"]) ?? 0,
                description: descText
            )
        } else {
            attachedVideo = nil
        }
    }

    private static func relativeTimeLabel(from timestamp: Int64) -> String {
        let delta = max(0, Int(Date().timeIntervalSince1970) - Int(timestamp))
        switch delta {
        case ..<60:
            return "刚刚"
        case ..<3600:
            return "\(max(1, delta / 60)) 分钟前"
        case ..<86_400:
            return "\(max(1, delta / 3600)) 小时前"
        default:
            return "\(max(1, delta / 86_400)) 天前"
        }
    }
}

private struct HistoryPayload: Decodable {
    let items: [HistoryItemDTO]
    let cursor: HistoryCursorDTO?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        items = (try? container.decode([HistoryItemDTO].self, forKey: DynamicKey("list"))) ?? []
        cursor = try? container.decode(HistoryCursorDTO.self, forKey: DynamicKey("cursor"))
    }
}

private struct HistoryCursorDTO: Decodable {
    let max: Int64
    let viewAt: Int64
    let business: String

    enum CodingKeys: String, CodingKey {
        case max
        case viewAt = "view_at"
        case business
    }

    var cursorState: HistoryCursorState? {
        guard max > 0 || viewAt > 0 || !business.isEmpty else { return nil }
        return HistoryCursorState(max: max, viewAt: viewAt, business: business)
    }
}

private struct HistoryItemDTO: Decodable {
    let title: String
    let coverURL: URL?
    let ownerName: String
    let ownerFaceURL: URL?
    let ownerMID: Int64
    let duration: Int
    let progress: Int
    let viewedAt: Int64
    let stat: VideoStatsDTO?
    let historyBVID: String
    let historyCID: Int
    let historyOID: Int64

    var entry: HistoryEntry {
        let video = BiliVideo(
            bvid: historyBVID,
            aid: Int(historyOID),
            cid: historyCID,
            title: title,
            ownerName: ownerName,
            coverURL: coverURL,
            duration: duration,
            viewCount: stat?.view ?? 0,
            danmakuCount: stat?.danmaku ?? 0,
            likeCount: stat?.like ?? 0,
            description: ""
        )
        return HistoryEntry(
            id: historyBVID.isEmpty ? "\(historyOID):\(viewedAt)" : historyBVID,
            video: video,
            viewedAt: viewedAt,
            progress: progress
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        title = container.decodeString(keys: ["title"]) ?? "Untitled"
        coverURL = (container.decodeString(keys: ["cover", "pic"]) ?? "").httpsURL
        ownerName = container.decodeString(keys: ["author_name"]) ?? "Unknown"
        ownerFaceURL = (container.decodeString(keys: ["author_face"]) ?? "").httpsURL
        ownerMID = container.decodeInt64(keys: ["author_mid"]) ?? 0
        duration = container.decodeInt(keys: ["duration"]) ?? 0
        progress = container.decodeInt(keys: ["progress"]) ?? -1
        viewedAt = container.decodeInt64(keys: ["view_at"]) ?? 0
        stat = try? container.decode(VideoStatsDTO.self, forKey: DynamicKey("stat"))
        let history = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("history"))
        historyBVID = history?.decodeString(keys: ["bvid"]) ?? ""
        historyCID = history?.decodeInt(keys: ["cid"]) ?? 0
        historyOID = history?.decodeInt64(keys: ["oid"]) ?? 0
    }
}

private struct FavoriteFoldersPayload: Decodable {
    let list: [FavoriteFolderDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        list = (try? container.decode([FavoriteFolderDTO].self, forKey: DynamicKey("list"))) ?? []
    }
}

private struct FavoriteFolderDTO: Decodable {
    let id: Int64
    let title: String
    let coverURL: URL?
    let mediaCount: Int
    let ownerName: String

    enum CodingKeys: String, CodingKey {
        case id
        case fid
        case title
        case cover
        case mediaCount = "media_count"
        case upper
    }

    var folder: FavoriteFolderSummary {
        FavoriteFolderSummary(
            id: id,
            title: title,
            coverURL: coverURL,
            mediaCount: mediaCount,
            ownerName: ownerName
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        id = Int64(container.decodeInt(keys: ["id", "fid"]) ?? 0)
        title = container.decodeString(keys: ["title"]) ?? "收藏夹"
        coverURL = (container.decodeString(keys: ["cover"]) ?? "").httpsURL
        mediaCount = container.decodeInt(keys: ["media_count"]) ?? 0
        let upper = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("upper"))
        ownerName = upper?.decodeString(keys: ["name"]) ?? ""
    }
}

private struct FavoriteResourcesPayload: Decodable {
    let info: FavoriteInfoDTO?
    let medias: [FavoriteMediaDTO]
    let hasMore: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        info = try? container.decode(FavoriteInfoDTO.self, forKey: DynamicKey("info"))
        medias = (try? container.decode([FavoriteMediaDTO].self, forKey: DynamicKey("medias"))) ?? []
        hasMore = container.decodeBool(keys: ["has_more"]) ?? false
    }
}

private struct FavoriteInfoDTO: Decodable {
    let title: String
}

private struct FavoriteMediaDTO: Decodable {
    let id: Int64
    let bvid: String
    let title: String
    let coverURL: URL?
    let duration: Int
    let progress: Int
    let viewedAt: Int64
    let ownerName: String
    let stat: VideoStatsDTO?
    let cid: Int

    var video: BiliVideo {
        BiliVideo(
            bvid: bvid,
            aid: Int(id),
            cid: cid,
            title: title,
            ownerName: ownerName,
            coverURL: coverURL,
            duration: duration,
            viewCount: stat?.view ?? 0,
            danmakuCount: stat?.danmaku ?? 0,
            likeCount: stat?.like ?? 0,
            description: ""
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        id = Int64(container.decodeInt(keys: ["id"]) ?? 0)
        bvid = container.decodeString(keys: ["bvid", "bv_id"]) ?? ""
        title = container.decodeString(keys: ["title"])?.strippingHTML ?? "Untitled"
        coverURL = (container.decodeString(keys: ["cover"]) ?? "").httpsURL
        duration = container.decodeInt(keys: ["duration"]) ?? 0
        progress = container.decodeInt(keys: ["progress"]) ?? 0
        viewedAt = container.decodeInt64(keys: ["view_at"]) ?? 0
        let upper = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("upper"))
        ownerName = upper?.decodeString(keys: ["name"]) ?? "Unknown"
        let cntInfo = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("cnt_info"))
        stat = cntInfo.map { nested in
            VideoStatsDTO(
                view: nested.decodeInt(keys: ["play"]) ?? 0,
                danmaku: nested.decodeInt(keys: ["danmaku"]) ?? 0,
                like: nested.decodeInt(keys: ["collect"]) ?? 0
            )
        }
        let ugc = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("ugc"))
        cid = ugc?.decodeInt(keys: ["first_cid"]) ?? 0
    }
}

private struct WatchLaterPayload: Decodable {
    let list: [WatchLaterItemDTO]
}

private struct WatchLaterItemDTO: Decodable {
    let aid: Int64
    let bvid: String
    let cid: Int
    let title: String
    let coverURL: URL?
    let duration: Int
    let ownerName: String
    let stat: VideoStatsDTO?

    var video: BiliVideo {
        BiliVideo(
            bvid: bvid,
            aid: Int(aid),
            cid: cid,
            title: title,
            ownerName: ownerName,
            coverURL: coverURL,
            duration: duration,
            viewCount: stat?.view ?? 0,
            danmakuCount: stat?.danmaku ?? 0,
            likeCount: stat?.like ?? 0,
            description: ""
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        aid = Int64(container.decodeInt(keys: ["aid"]) ?? 0)
        bvid = container.decodeString(keys: ["bvid"]) ?? ""
        cid = container.decodeInt(keys: ["cid"]) ?? 0
        title = container.decodeString(keys: ["title"]) ?? "Untitled"
        coverURL = (container.decodeString(keys: ["pic"]) ?? "").httpsURL
        duration = container.decodeInt(keys: ["duration"]) ?? 0
        let owner = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey("owner"))
        ownerName = owner?.decodeString(keys: ["name"]) ?? "Unknown"
        stat = try? container.decode(VideoStatsDTO.self, forKey: DynamicKey("stat"))
    }
}

private struct VideoStatsDTO: Decodable {
    let view: Int
    let danmaku: Int
    let like: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        view = container.decodeInt(keys: ["view", "play"]) ?? 0
        danmaku = container.decodeInt(keys: ["danmaku"]) ?? 0
        like = container.decodeInt(keys: ["like", "favorite", "collect"]) ?? 0
    }

    init(view: Int, danmaku: Int, like: Int) {
        self.view = view
        self.danmaku = danmaku
        self.like = like
    }
}

private struct CommentPayload: Decodable {
    let replies: LenientCommentArray?
    /// Legacy field — kept for the occasional cache that still serves
    /// the old `top_replies` array shape. New WBI responses deliver
    /// pinned comments under `upper.top` (a dict keyed by rpid) instead.
    let topReplies: LenientCommentArray?
    /// New (WBI) shape: pinned/UP主置顶 replies nested under
    /// `data.upper.top` as a dict keyed by `rpid`.
    let upperTop: PinnedCommentDict?
    let cursor: CommentCursorDTO?

    enum CodingKeys: String, CodingKey {
        case replies
        case topReplies = "top_replies"
        case upper
        case cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replies = try container.decodeIfPresent(LenientCommentArray.self, forKey: .replies)
        topReplies = try container.decodeIfPresent(LenientCommentArray.self, forKey: .topReplies)
        cursor = try? container.decode(CommentCursorDTO.self, forKey: .cursor)
        if let upper = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: .upper) {
            upperTop = try? upper.decode(PinnedCommentDict.self, forKey: DynamicKey("top"))
        } else {
            upperTop = nil
        }
    }
}

private struct CommentCursorDTO: Decodable {
    let next: Int?
    let isEnd: Bool
    let allCount: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        next = container.decodeInt(keys: ["next"])
        isEnd = container.decodeBool(keys: ["is_end"]) ?? true
        allCount = container.decodeInt(keys: ["all_count"]) ?? 0
    }
}

/// `data.upper.top` is a dict keyed by `rpid` on the WBI endpoint, not
/// an array. Each value is a full `CommentDTO`.
private struct PinnedCommentDict: Decodable {
    let values: [CommentDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: FailableDecodable<CommentDTO>].self)
        values = raw.values.compactMap(\.value)
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
    let replies: LenientCommentArray?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rpid = try container.decode(Int.self, forKey: .rpid)
        member = try container.decode(Member.self, forKey: .member)
        content = try container.decode(Content.self, forKey: .content)
        like = try container.decodeIfPresent(Int.self, forKey: .like) ?? 0
        rcount = try container.decodeIfPresent(Int.self, forKey: .rcount)
        replies = try container.decodeIfPresent(LenientCommentArray.self, forKey: .replies)
    }

    enum CodingKeys: String, CodingKey {
        case rpid
        case member
        case content
        case like
        case rcount
        case replies
    }

    var model: BiliComment {
        BiliComment(
            id: rpid,
            authorName: member.uname,
            avatarURL: member.avatarURL,
            message: content.message,
            likeCount: like,
            replyCount: rcount ?? 0,
            replies: replies?.items.map(\.model) ?? []
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

    func decodeInt64(keys: [String]) -> Int64? {
        for key in keys {
            if let value = try? decode(Int64.self, forKey: DynamicKey(key)) {
                return value
            }
            if let value = try? decode(Int.self, forKey: DynamicKey(key)) {
                return Int64(value)
            }
            if let string = try? decode(String.self, forKey: DynamicKey(key)), let value = Int64(string) {
                return value
            }
        }
        return nil
    }

    func decodeBool(keys: [String]) -> Bool? {
        for key in keys {
            if let value = try? decode(Bool.self, forKey: DynamicKey(key)) {
                return value
            }
            if let value = try? decode(Int.self, forKey: DynamicKey(key)) {
                return value != 0
            }
            if let string = try? decode(String.self, forKey: DynamicKey(key)) {
                switch string.lowercased() {
                case "1", "true":
                    return true
                case "0", "false":
                    return false
                default:
                    break
                }
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
