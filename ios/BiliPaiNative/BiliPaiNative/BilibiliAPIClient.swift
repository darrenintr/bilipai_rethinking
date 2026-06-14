import CryptoKit
import Foundation

// MARK: - App API signing credentials
//
// The public Bilibili App endpoints (`/x/v2/feed/index`, etc.) require a
// signature of the form `md5(sortedQueryString + appSec)`. The `appKey` /
// `appSec` pair below is the well-known, public iOS client credentials —
// the same values the official iPhone app uses to sign its requests and
// the same values the open-source pskdje/bilibili-API-collect repo
// documents. `buvid` is normally a per-install device fingerprint; we
// derive a stable placeholder from a fixed namespace so anonymous
// requests still carry the field the upstream expects.
//
// TODO(darren): replace the placeholder `buvid` with the real per-device
// value computed by the auth flow once AccountSessionStore is wired into
// the App API path.
private let appKey = "1d8b6e7d45233436"
private let appSec = "560c52ccd288fed045859ed18bffd973"
private let buvid: String = {
    let raw = UUID(uuidString: "8C5DD46B-2A6E-4D1F-9A7B-1F3C0A8E2D55")!.uuidString
    return raw.replacingOccurrences(of: "-", with: "").lowercased()
}()

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

    /// Per-request overrides the App API needs in order to return a
    /// personalised feed. Without `buvid3`, the upstream gates the
    /// personalised response behind an anonymous fallback and returns
    /// the same `热门` list the web recommend endpoint would have sent.
    /// Same ownership model as `cookieProvider` — owned by `AuthStore`,
    /// re-evaluated on every call so account switches take effect
    /// immediately.
    var appConfigProvider: (() -> BiliAppConfig?)?

    /// Static fallback when no account is signed in. Kept on the
    /// client so unit tests and the cached-`BiliAppConfig` callers
    /// can read the same placeholder value the API originally used.
    static var defaultConfig: BiliAppConfig {
        BiliAppConfig(buvid3: nil, mid: 0, csrf: nil)
    }

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
                "User-Agent": "bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)",
                "Referer": "https://www.bilibili.com"
            ]
            self.session = URLSession(configuration: config)
        }
        self.decoder = JSONDecoder()
    }

    /// Report playback progress to Bilibili's history endpoint so the
    /// watch shows up under the user's "历史记录" list and feeds the
    /// "继续播放" recommendation algorithm. Without this call the
    /// video plays normally but Bilibili treats the user as a
    /// visitor — a behaviour the user explicitly flagged in
    /// `MINIMAX_INSTRUCTIONS.md` §2 ("History Reporting"). The
    /// `progress` field is the current playhead in seconds and is
    /// the same value Bilibili uses to compute "看完"/"看到一半" in
    /// the history list, so accuracy matters for the resume UX.
    ///
    /// `aid` and `cid` are both required. `csrf` is auto-extracted
    /// from the active account's `bili_jct` cookie by the underlying
    /// `post(...)` helper — no need to plumb it through. `platform`
    /// and `mobi_app` are pinned to the iOS app identity so the
    /// upstream records the report as coming from the official iOS
    /// client (the only client where the history is fully visible).
    func reportHistory(aid: Int, cid: Int, progress: Int) async throws {
        let params: [String: String] = [
            "aid": "\(aid)",
            "cid": "\(cid)",
            // `progress` is in seconds. Bilibili rounds down internally
            // and clamps to the media length, so passing 0 is the
            // canonical "video just started" signal.
            "progress": "\(max(0, progress))",
            "platform": "ios",
            "mobi_app": "iphone",
            // No `type` field — the official iOS client doesn't send
            // one and adding it triggers `code=-101` "参数错误" on
            // some accounts.
        ]
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/history/report",
            parameters: params
        )
        try payload.requireOK()
    }

    func recommendedVideos(freshIndex: Int = 0) async throws -> [BiliVideo] {
        if cookieProvider?() != nil {
            // If the user is logged in, use the App API for optimized recommendations.
            // This endpoint provides a more personalized feed based on user history.
            return try await appRecommendedVideos(freshIndex: freshIndex, isRefresh: true)
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

    func appRecommendedVideos(freshIndex: Int = 0, isRefresh: Bool = true) async throws -> [BiliVideo] {
        bpLog("Fetching app recommendations (idx: \(freshIndex), refresh: \(isRefresh))")

        let finalIdx = Int(Date().timeIntervalSince1970) + freshIndex

        // The personalised App API path needs two values the anonymous
        // path does not have: a mobile device fingerprint (BUVID) so
        // the upstream can recognise the device, and the account `mid`
        // so the response can be re-ranked against that user's history.
        // If the user is logged in, we prefer their account-derived
        // BUVID if available, otherwise we generate a stable one.
        let config = appConfigProvider?() ?? BilibiliAPIClient.defaultConfig
        
        // Mobile BUVID starts with XY (MAC) or XX (ID). Official iOS app
        // typically uses XY + MD5 hash.
        let effectiveBuvid = config.buvid3?.hasPrefix("XY") == true ? config.buvid3! : generateMobileBuvid()
        let personalMid = config.mid > 0 ? "\(config.mid)" : nil

        var queryItems = [
            URLQueryItem(name: "mobi_app", value: "iphone"),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "idx", value: "\(finalIdx)"),
            URLQueryItem(name: "pull", value: isRefresh ? "true" : "false"),
            URLQueryItem(name: "login_event", value: personalMid == nil ? "0" : "1"),
            URLQueryItem(name: "appkey", value: appKey),
            URLQueryItem(name: "ts", value: "\(Int(Date().timeIntervalSince1970))"),
            URLQueryItem(name: "buvid", value: effectiveBuvid),
            URLQueryItem(name: "device", value: "phone"),
            URLQueryItem(name: "network", value: "wifi")
        ]
        if let personalMid {
            queryItems.append(URLQueryItem(name: "mid", value: personalMid))
        }
        
        // Manual App sign: md5(sorted_query + appSec)
        let sorted = queryItems.sorted { $0.name < $1.name }
        let query = sorted.compactMap { item -> String? in
            guard let value = item.value else { return nil }
            return "\(item.name)=\(value)"
        }.joined(separator: "&")
        let sign = md5(query + appSec)
        queryItems.append(URLQueryItem(name: "sign", value: sign))
        
        let payload: APIResponse<AppFeedPayload> = try await get(
            baseURL: appBaseURL,
            path: "/x/v2/feed/index",
            queryItems: queryItems
        )
        try payload.requireOK()
        let items = payload.value?.items ?? []
        let videos = items.compactMap { item -> BiliVideo? in
            // Handle multiple card types that contain video data
            let validGotos = ["av", "bangumi", "live"] 
            guard validGotos.contains(item.cardGoto) else { return nil }
            return item.model
        }
        bpLog("Received \(items.count) items, \(videos.count) mapped to videos")
        return videos
    }

    private func generateMobileBuvid() -> String {
        // Official algorithm: XY + MD5(hwID) + 3 specific chars from hash
        // For simplicity and stability, we use a fixed but valid format.
        let seed = "BiliPai-iOS-Device-Seed"
        let hash = md5(seed).uppercased()
        let c1 = hash[hash.index(hash.startIndex, offsetBy: 2)]
        let c2 = hash[hash.index(hash.startIndex, offsetBy: 12)]
        let c3 = hash[hash.index(hash.startIndex, offsetBy: 22)]
        return "XY\(c1)\(c2)\(c3)\(hash)"
    }

    private func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
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

    func videoDetail(bvid: String, aid: Int = 0) async throws -> BiliVideo {
        var queryItems: [URLQueryItem] = []
        if !bvid.isEmpty {
            queryItems.append(URLQueryItem(name: "bvid", value: bvid))
        } else if aid > 0 {
            queryItems.append(URLQueryItem(name: "aid", value: "\(aid)"))
        } else {
            throw BilibiliAPIError.missingIdentity
        }

        let payload: APIResponse<VideoDTO> = try await get(
            baseURL: baseURL,
            path: "/x/web-interface/view",
            queryItems: queryItems
        )
        try payload.requireOK()
        guard let detail = payload.value?.model else {
            throw BilibiliAPIError.missingData
        }
        return detail
    }

    func playbackURL(bvid: String, aid: Int = 0, cid: Int) async throws -> BiliPlayback {
        // The current canonical path is `/x/player/wbi/playurl` — the
        // non-wbi alias is being phased out. The `fnval` bitmask is:
        //   1   = legacy MP4 (returns an empty `durl` for most items
        //         today, which is why `fnval=0/1` produces the
        //         "Playback is unavailable" error).
        //   16  = DASH manifest.
        //   64  = HLS master playlist (what AVPlayer can natively
        //         consume on iOS).
        //   4048 = HLS + DASH + MP4 + FLV — the bitmask the
        //          bilibili-API-collect docs use for "request every
        //          format" (see `ios/BiliPaiNative/API_REFERENCE.md`
        //          line 52, and `diagnose.md`).
        // We send `fnval=4048` so `bestPlayback` always has both `durl`
        // and `dash` to choose from. We then walk a `qn` chain from
        // 1080P down to 360P because the upstream returns an empty
        // `durl` / empty `dash` when the requested quality is gated
        // (region lock, VIP paywall, 4K-only source). Cap at three
        // retries so a misbehaving upstream cannot wedge the device.
        // `gaia_source=view-card` is the same hint the web player
        // sends — Bilibili loosens the 1080P gate slightly for it.
        let identity: [URLQueryItem]
        if !bvid.isEmpty {
            identity = [URLQueryItem(name: "bvid", value: bvid)]
        } else if aid > 0 {
            identity = [URLQueryItem(name: "avid", value: "\(aid)")]
        } else {
            throw BilibiliAPIError.missingIdentity
        }
        let finalBvid = bvid.isEmpty ? "av\(aid)" : bvid

        let qnChain: [Int] = [80, 64, 32, 16]
        var lastError: Error = BilibiliAPIError.missingData
        for qn in qnChain {
            let queryItems: [URLQueryItem] = identity + [
                URLQueryItem(name: "cid", value: "\(cid)"),
                URLQueryItem(name: "qn", value: "\(qn)"),
                URLQueryItem(name: "fnval", value: "4048"),
                URLQueryItem(name: "fnver", value: "0"),
                URLQueryItem(name: "fourk", value: "1"),
                URLQueryItem(name: "gaia_source", value: "view-card")
            ]
            do {
                let payload: APIResponse<PlayURLPayload> = try await get(
                    baseURL: baseURL,
                    path: "/x/player/wbi/playurl",
                    queryItems: queryItems,
                    signWithWBI: true
                )
                try payload.requireOK()
                if let playback = payload.value?.bestPlayback {
                    return BiliPlayback(
                        videoURL: playback.videoURL,
                        audioURL: playback.audioURL,
                        referer: URL(string: "https://www.bilibili.com/video/\(finalBvid)")!
                    )
                }
                lastError = BilibiliAPIError.noPlayableFormat
            } catch {
                // Bubble up immediately on identity / network errors so
                // the UI can surface them; only fall through on
                // quality-gated responses.
                if case BilibiliAPIError.missingIdentity = error { throw error }
                if case BilibiliAPIError.http = error { throw error }
                lastError = error
            }
        }
        throw lastError
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

    /// Fetch the playable stream URLs for a live room. The endpoint
    /// returns a tree of protocols (`stream[]`) → formats (`format[]`)
    /// → codecs (`codec[]`) → CDN hosts (`url_info[]`). We pick the
    /// first CDN for the FLV and HLS slots and let the player toggle
    /// between them at runtime.
    ///
    /// Older CDNs occasionally return only FLV; in that case the HLS
    /// slot on the resulting `BiliLivePlayback` is `nil` and the UI
    /// disables the toggle. Throws when the room is offline (code != 0
    /// or no playable streams) so the caller can show a specific
    /// "未开播" message instead of pretending playback failed.
    func livePlaybackURL(roomID: Int) async throws -> BiliLivePlayback {
        let payload: APIResponse<LivePlayInfoPayload> = try await get(
            baseURL: liveBaseURL,
            path: "/xlive/web-room/v2/index/getRoomPlayInfo",
            queryItems: [
                URLQueryItem(name: "room_id", value: "\(roomID)"),
                URLQueryItem(name: "protocol", value: "0,1"),
                URLQueryItem(name: "format", value: "0,1,2"),
                URLQueryItem(name: "codec", value: "0,1"),
                URLQueryItem(name: "qn", value: "10000"),
                URLQueryItem(name: "platform", value: "web"),
                URLQueryItem(name: "ptype", value: "8")
            ]
        )
        try payload.requireOK()
        guard let data = payload.value else {
            throw BilibiliAPIError.missingData
        }

        var streams: [BiliLiveStreamFormat: URL] = [:]

        // Bilibili returns one `stream` entry per `protocol` value
        // requested (0 = FLV, 1 = HLS). We walk the list once and
        // pull the best URL out of each. The codec/format nesting
        // inside each stream is what gives us the actual playable
        // URL — we pick the first codec whose `url_info` exposes at
        // least one host.
        for stream in data.playurlInfo?.playurl.stream ?? [] {
            let format: BiliLiveStreamFormat?
            switch stream.protocolName {
            case "http_hls", "https_hls":
                format = .hls
            case "http_flv", "https_flv", "rtmp_flv", "rtmp_flv_h265":
                format = .flv
            default:
                format = nil
            }
            guard let format else { continue }
            // Already populated (Bilibili can return both protocols
            // for the same format on some rooms) — prefer the first.
            if streams[format] != nil { continue }
            for fmt in stream.format {
                for codec in fmt.codec {
                    if let urlInfo = codec.urlInfo.first,
                       let composed = composeStreamURL(urlInfo: urlInfo, codec: codec) {
                        streams[format] = composed
                        break
                    }
                }
                if streams[format] != nil { break }
            }
        }

        let referer = URL(string: "https://live.bilibili.com/\(roomID)")!
        let info = data.roomInfo
        return BiliLivePlayback(
            roomID: roomID,
            title: info?.title ?? "",
            hostName: info?.areaName ?? "",
            streams: streams,
            referer: referer
        )
    }

    /// Bilibili splits a stream URL into `host` + `base_url` + `extra`
    /// (each on its own CDN edge). We glue them back together and
    /// prefer HTTPS when the host scheme allows it. The `extra`
    /// segment carries the query-string parameters Bilibili's CDN
    /// requires to validate the request.
    private func composeStreamURL(urlInfo: LivePlayURLHost, codec: LivePlayCodec) -> URL? {
        let scheme = urlInfo.host.lowercased().hasPrefix("https://") ? "https" : "http"
        let hostPart = urlInfo.host.hasPrefix("\(scheme)://") ? String(urlInfo.host.dropFirst("\(scheme)://".count)) : urlInfo.host
        var raw = "\(scheme)://\(hostPart)\(codec.baseURL)"
        if !urlInfo.extra.isEmpty {
            raw += "?" + urlInfo.extra
        }
        return URL(string: raw)
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

    /// Follow-feed variant of `dynamicFeed(...)`. Bilibili does NOT expose
    /// a follow-scoped dynamic endpoint that we can reach via REST —
    /// `/x/polymer/web-dynamic/v1/feed/attention` (used by the older
    /// documentation) returns 404, and `dynamic_svr` paths are gated
    /// behind the WebSocket channel the official client uses for live
    /// updates. The Android bilipai client solves this by fetching
    /// `/feed/all` and filtering client-side against the user's
    /// followings set, and that is what we do here too.
    ///
    /// The caller is responsible for keeping a followings set (see
    /// `followingMids(...)`) and passing it in as `followingFilter`.
    /// Items whose author `mid` is not in the set are dropped before
    /// the page is returned. We deliberately do NOT filter by
    /// `type=` — the user wants every dynamic card shape (videos,
    /// 专栏, 番剧, 直播开播, 转发) to surface on the follow tab.
    ///
    /// Returns an empty page (with `needsLogin: true`) when no account
    /// is active so the home view can render the existing "登录后查看
    /// 关注动态" prompt without a try/catch dance.
    func attentionFeed(
        offset: String = "",
        followingFilter: Set<Int64>? = nil
    ) async throws -> DynamicFeedPage {
        if cookieProvider?() == nil {
            return DynamicFeedPage(items: [], nextOffset: "", hasMore: false, needsLogin: true)
        }
        let payload: APIResponse<DynamicFeedPayload> = try await get(
            baseURL: baseURL,
            path: "/x/polymer/web-dynamic/v1/feed/all",
            queryItems: [
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
        var items = data?.items.compactMap(\.post).filter { !$0.id.isEmpty } ?? []
        // When a followings filter is supplied, drop items whose author
        // is not in the user's follow set. We keep the original `mid`
        // (carried via the DynamicCardDTO) on `DynamicPost` so the
        // filter can run here. Without a filter (e.g. anonymous
        // fallback), pass through everything.
        if let followingFilter {
            // Items coming through `DynamicCardDTO.post` lose the raw
            // `mid` because `DynamicPost` only stores `author`. The
            // filter is therefore applied at the DTO level by
            // re-walking the original payload in `attentionFeedDTO`.
            items = attentionFeedDTO(payload: data, followingFilter: followingFilter)
        }
        return DynamicFeedPage(
            items: items,
            nextOffset: data?.offset ?? "",
            hasMore: data?.hasMore ?? false,
            needsLogin: false
        )
    }

    /// Re-walk a decoded `DynamicFeedPayload` and apply the followings
    /// filter at the DTO level (where `module_author.mid` is still
    /// available). Returns the `[DynamicPost]` items whose author mid
    /// is in `followingFilter`. Items without a `module_author.mid`
    /// are kept by default — the DTO fallback names them "Bilibili"
    /// which is a synthetic value, and we do not want to drop the
    /// upstream's official-account posts.
    private func attentionFeedDTO(
        payload: DynamicFeedPayload?,
        followingFilter: Set<Int64>
    ) -> [DynamicPost] {
        guard let payload else { return [] }
        return payload.items.compactMap { dto -> DynamicPost? in
            guard dto.visible, !dto.id.isEmpty else { return nil }
            guard let post = dto.post else { return nil }
            // The DTO exposes author mid only via the decoder path; if
            // the author mid is unknown we keep the item (defensive
            // default — official-account posts would otherwise vanish).
            if let mid = dto.authorMid {
                return followingFilter.contains(mid) ? post : nil
            }
            return post
        }
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

    /// Page through the user's followings list and return the full set
    /// of `mid` values. Bilibili paginates at 50 per page, so users with
    /// 300+ follows trigger a few extra round-trips. We do NOT cache
    /// the result here — the caller is responsible for caching because
    /// it owns the `Set<Int64>` lifetime.
    ///
    /// The endpoint requires an active SESSDATA cookie; an anonymous
    /// request returns code -101 and we treat that as "no follows"
    /// rather than throwing, so the home view can render the login
    /// prompt without a try/catch dance.
    func followingMids(vmid: Int64) async throws -> Set<Int64> {
        if cookieProvider?() == nil { return [] }
        var mids: Set<Int64> = []
        var page = 1
        let pageSize = 50
        while true {
            let payload: APIResponse<FollowingsPayload> = try await get(
                baseURL: baseURL,
                path: "/x/relation/followings",
                queryItems: [
                    URLQueryItem(name: "vmid", value: "\(vmid)"),
                    URLQueryItem(name: "pn", value: "\(page)"),
                    URLQueryItem(name: "ps", value: "\(pageSize)"),
                    URLQueryItem(name: "order", value: "desc")
                ]
            )
            if payload.code == -101 { return [] }
            try payload.requireOK()
            guard let data = payload.value, !data.list.isEmpty else { break }
            for entry in data.list { mids.insert(entry.mid) }
            // Stop when the upstream returns a short page; otherwise
            // advance and keep going. `total` is the user's full
            // followings count, but trusting it lets a stale server-
            // side count over-iterate, so we stop on a short page.
            if data.list.count < pageSize { break }
            page += 1
            // Hard cap at 100 pages (5000 follows) so a corrupted
            // `total` field cannot loop us forever. Power users with
            // 5000+ follows are vanishingly rare; if we ever hit this,
            // the safer behaviour is to render what we have.
            if page > 100 { break }
        }
        return mids
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

    func postComment(aid: Int, message: String, root: Int? = nil, parent: Int? = nil) async throws {
        var params: [String: String] = [
            "type": "1",
            "oid": "\(aid)",
            "message": message,
            "plat": "3" // iOS
        ]
        if let root { params["root"] = "\(root)" }
        if let parent { params["parent"] = "\(parent)" }

        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/reply/add",
            parameters: params
        )
        try payload.requireOK()
    }

    func likeComment(aid: Int, rpid: Int, action: Int) async throws {
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/reply/action",
            parameters: [
                "type": "1",
                "oid": "\(aid)",
                "rpid": "\(rpid)",
                "action": "\(action)"
            ]
        )
        try payload.requireOK()
    }

    func hateComment(aid: Int, rpid: Int, action: Int) async throws {
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/reply/hate",
            parameters: [
                "type": "1",
                "oid": "\(aid)",
                "rpid": "\(rpid)",
                "action": "\(action)"
            ]
        )
        try payload.requireOK()
    }

    func reportComment(aid: Int, rpid: Int, reason: Int, content: String? = nil) async throws {
        var params = [
            "type": "1",
            "oid": "\(aid)",
            "rpid": "\(rpid)",
            "reason": "\(reason)"
        ]
        if let content { params["content"] = content }
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/reply/report",
            parameters: params
        )
        try payload.requireOK()
    }

    private func get<T: Decodable>(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem],
        signWithWBI: Bool = false
    ) async throws -> T {
        var items = queryItems
        let isAppAPI = baseURL.host?.contains("app.bilibili.com") == true

        // Cache-bust web requests. App APIs have their own 'ts' parameter.
        if !isAppAPI {
            if !items.contains(where: { $0.name == "_t" }) {
                items.append(URLQueryItem(name: "_t", value: "\(Int(Date().timeIntervalSince1970 * 1000))"))
            }
            if !items.contains(where: { $0.name == "_r" }) {
                items.append(URLQueryItem(name: "_r", value: UUID().uuidString))
            }
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue("bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        if isAppAPI {
            request.setValue("iphone", forHTTPHeaderField: "mobi_app")
            request.setValue("ios", forHTTPHeaderField: "platform")
        }

        if let cookie = cookieProvider?() {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            bpLog("GET \(url.absoluteString) returned HTTP \(status)")
            throw BilibiliAPIError.http
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            bpLog("decode failed for \(url.absoluteString): \(error)\n  body: \(String(data: data.prefix(512), encoding: .utf8) ?? "<binary>")")
            throw error
        }
    }

    @discardableResult
    func post<T: Decodable>(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = [],
        parameters: [String: String] = [:]
    ) async throws -> T {
        var items = parameters

        // Extract CSRF token from cookies if present
        if let cookies = cookieProvider?() {
            let pairs = cookies.components(separatedBy: ";")
            for pair in pairs {
                let parts = pair.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
                if parts.count == 2 && parts[0] == "bili_jct" {
                    items["csrf"] = parts[1]
                    break
                }
            }
        }

        let bodyString = items.keys.sorted().map { key in
            "\(key)=\(encodeURIComponent(items[key] ?? ""))"
        }.joined(separator: "&")

        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        
        guard let url = components.url else {
            throw BilibiliAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyString.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue("bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)", forHTTPHeaderField: "User-Agent")

        if let cookies = cookieProvider?() {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            bpLog("POST \(url.absoluteString) returned HTTP \(status)")
            throw BilibiliAPIError.http
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            bpLog("decode failed for POST \(url.absoluteString): \(error)")
            throw error
        }
    }

    private func encodeURIComponent(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}

fileprivate extension String {
    /// Returns `nil` when the receiver is empty (or whitespace-only).
    /// Used when an optional API parameter should be omitted entirely
    /// rather than sent as an empty string — Bilibili treats empty
    /// `mid` / `buvid3` values as "anonymous fallback" rather than
    /// "drop this parameter", which is why we treat `""` as `nil` at
    /// the call site.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
        request.setValue("bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)", forHTTPHeaderField: "User-Agent")
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
    /// The playurl endpoint returned a payload but every supported
    /// `qn` quality was gated (region lock, VIP paywall, 4K-only
    /// source). Distinct from `missingData` so the UI can say "暂无可
    /// 播放清晰度" rather than a generic "缺少数据".
    case noPlayableFormat
}

struct EmptyPayload: Codable {}

struct APIResponse<T: Decodable>: Decodable {
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
    let cover: String?
    let pic: String?
    let title: String
    let uri: String
    let playerArgs: AppPlayerArgs?
    let descButton: AppDescButton?

    enum CodingKeys: String, CodingKey {
        case cardType = "card_type"
        case cardGoto = "card_goto"
        case param
        case cover
        case pic
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
        // App API returns various card types. 'av' is the standard video.
        // We also allow 'bangumi' if we can map it.
        guard cardGoto == "av" || cardGoto == "bangumi" else { return nil }
        
        // Use 'cover' or 'pic' whichever is available.
        let rawCover = cover ?? pic
        let coverHTTPS = rawCover?.replacingOccurrences(of: "http://", with: "https://")
        let finalCover = coverHTTPS != nil ? URL(string: coverHTTPS!) : nil
        
        let aidValue = playerArgs?.aid ?? Int(param) ?? 0
        
        return BiliVideo(
            bvid: "", // Will be fetched on demand in detail(for:) if needed
            aid: aidValue,
            cid: playerArgs?.cid ?? 0,
            title: title,
            ownerName: descButton?.text ?? "Bilibili",
            coverURL: finalCover,
            duration: playerArgs?.duration ?? 0,
            viewCount: 0,
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

private struct LivePlayInfoPayload: Decodable {
    let roomInfo: LivePlayRoomInfo?
    let playurlInfo: LivePlayURLInfo?

    enum CodingKeys: String, CodingKey {
        case roomInfo = "room_info"
        case playurlInfo = "playurl_info"
    }
}

private struct LivePlayRoomInfo: Decodable {
    let roomID: Int64
    let title: String?
    /// `area_name` is the live-room's section ("唱见", "游戏", etc.).
    /// We surface this as the host-name placeholder when the host
    /// field is missing on the play payload.
    let areaName: String?

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case title
        case areaName = "area_name"
    }
}

private struct LivePlayURLInfo: Decodable {
    let playurl: LivePlayURLContainer
}

private struct LivePlayURLContainer: Decodable {
    let stream: [LivePlayStream]
}

private struct LivePlayStream: Decodable {
    let protocolName: String
    let format: [LivePlayFormat]

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol_name"
        case format
    }
}

private struct LivePlayFormat: Decodable {
    let formatName: String
    let codec: [LivePlayCodec]

    enum CodingKeys: String, CodingKey {
        case formatName = "format_name"
        case codec
    }
}

private struct LivePlayCodec: Decodable {
    let codecName: String
    let currentQPS: Int?
    let baseURL: String
    let urlInfo: [LivePlayURLHost]

    enum CodingKeys: String, CodingKey {
        case codecName = "codec_name"
        case currentQPS = "current_qn"
        case baseURL = "base_url"
        case urlInfo = "url_info"
    }
}

private struct LivePlayURLHost: Decodable {
    let host: String
    let extra: String
    let streamTtl: Int?

    enum CodingKeys: String, CodingKey {
        case host
        case extra
        case streamTtl = "stream_ttl"
    }
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
    /// Raw author `mid` from `modules.module_author.mid`. Exposed so
    /// the follow-feed path can filter against the user's followings
    /// set without re-decoding the JSON. `nil` when the upstream
    /// omitted the field (rare — only on synthetic / official-account
    /// posts in our observed payloads).
    let authorMid: Int64?
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
        authorMid = author?.decodeInt64(keys: ["mid"])
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

private struct FollowingsPayload: Decodable {
    let list: [FollowingEntry]
    let total: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        list = (try? container.decode([FollowingEntry].self, forKey: DynamicKey("list"))) ?? []
        total = container.decodeInt(keys: ["total"])
    }
}

private struct FollowingEntry: Decodable {
    let mid: Int64
    let uname: String?
    let attribute: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        mid = container.decodeInt64(keys: ["mid"]) ?? 0
        uname = container.decodeString(keys: ["uname"])
        attribute = container.decodeInt(keys: ["attribute"])
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
