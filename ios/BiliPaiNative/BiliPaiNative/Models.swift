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

/// One playable Bilibili source.  The local HLS proxy turns
/// this into an HLS manifest on a 127.0.0.1 loopback HTTP
/// server (`LocalHLSProxyServer`), so a single `BiliPlayback`
/// is enough to start a video.
struct BiliPlayback: Hashable {
    /// `nil` for the rare legacy `durl` MP4 case; populated for
    /// the much-more-common DASH case (the case the proxy exists
    /// for).
    let dash: BiliDashSource?
    /// Legacy `durl` MP4 URL — used as a fallback when the
    /// upstream returns no `dash` field.  Also the slot for
    /// live HLS URLs (the proxy is unnecessary for those —
    /// AVPlayer consumes HLS natively and we just inject the
    /// `Referer` header on the AVURLAsset).
    let fallbackURL: URL?
    let referer: URL

    /// True if this playback can be served by the local HLS
    /// proxy.
    var isDASH: Bool { dash != nil }
}

/// `BiliDashSource` is the DASH description we extract from
/// B站's playurl response and feed to `LocalHLSProxyServer`.
/// The proxy synthesises an HLS master playlist from these
/// tracks, so AVPlayer consumes a format it already understands
/// natively.
///
/// Important: B站's `dash.video[].baseUrl` and
/// `dash.audio[].baseUrl` are each *one whole m4s file* (B站
/// does not publish a per-segment `SegmentTemplate` here). The
/// m3u8 generator therefore emits a media playlist with a
/// single `EXTINF` entry whose duration is the track's
/// `totalDuration`, and lets AVPlayer stream the file via HTTP
/// `Range` requests through the proxy.
struct BiliDashSource: Hashable {
    /// A single AdaptationSet, plus its Representation.
    /// We flatten audio + video variants into this struct
    /// because B站's DASH responses are simple enough that we
    /// can skip the full MPD Period/AdaptationSet tree.
    struct Track: Hashable {
        let baseURL: URL
        /// ISO BMFF `codecs` box string (e.g. `avc1.640028`,
        /// `mp4a.40.2`). Embedded into HLS via `CODECS`.
        let codecs: String
        /// Bandwidth in bits per second (B站's `bandwidth`
        /// field). Used in the master playlist's
        /// `EXT-X-STREAM-INF` `BANDWIDTH` attribute.
        let bandwidth: Int
        /// `mimeType` from the Representation, e.g.
        /// `video/mp4` / `audio/mp4`.
        let mimeType: String
        /// Total presentation duration in seconds — B站's
        /// `dash.duration` divided by 1000 (B站 publishes
        /// milliseconds here).
        let totalDuration: Double
    }

    let video: Track
    let audio: Track?
}

struct BiliLiveRoom: Identifiable, Hashable {
    let id: Int
    let title: String
    let hostName: String
    let areaName: String
    let coverURL: URL?
    let viewerCount: Int
}

/// Per-account overrides the App API needs to return a personalised
/// recommend list. Populated by `BiliPaiNativeApp.body.onAppear` from
/// the live `AuthStore` so that switching accounts in
/// `ProfileSettingsView` immediately takes effect on the next refresh.
///
/// `buvid3` is the device fingerprint the upstream uses to recognise
/// the client. When empty the App API gates the personalised response
/// and falls back to anonymous trending, which is why the iOS app
/// looked like 热门 when signed in.
///
/// `mid` is the active user's Bilibili ID. Sending it triggers the
/// personalised re-ranking; omitting it keeps the request valid but
/// downgrades the response to the anonymous flavour.
struct BiliAppConfig: Hashable {
    let buvid3: String?
    let mid: Int64
    let csrf: String?

    var isPersonalised: Bool {
        mid > 0 && (buvid3?.isEmpty == false)
    }
}

/// `BiliLiveStreamFormat` describes the streaming protocol a live
/// room exposes. Bilibili rooms typically offer both an FLV stream
/// (lowest latency, FFmpeg friendly) and an HLS stream (works with
/// stock players). The player toggle in `LivePlayerView` flips
/// between them.
enum BiliLiveStreamFormat: String, Codable, CaseIterable, Identifiable {
    case hls
    case flv

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hls: return "HLS"
        case .flv: return "FLV"
        }
    }
}

/// Stream URLs for a single live room, keyed by format. The HLS slot
/// may be absent on rooms whose CDN only exposes FLV, in which case
/// the player disables the toggle for that format.
struct BiliLivePlayback: Hashable {
    let roomID: Int
    let title: String
    let hostName: String
    let streams: [BiliLiveStreamFormat: URL]
    let referer: URL
}

/// Kinds of dynamic card the follow feed surfaces. The HTTP payload is
/// the same for all of them — they differ only by which `major.*`
/// module the upstream populates. The UI uses this enum to pick the
/// right card chrome (video card vs. 专栏 text vs. live-started banner
/// vs.转发 reposting the original post).
enum DynamicPostKind: String, Codable, Hashable {
    case video
    case article
    case bangumi
    case liveStarted = "live_started"
    case forward

    /// Best-effort guess based on whether the upstream payload
    /// populated an attached video. Forwarded posts keep the
    /// original attached video, so the follow tab can still render
    /// the attached content inline.
    static func infer(attachedVideo: BiliVideo?) -> DynamicPostKind {
        guard attachedVideo != nil else { return .forward }
        return .video
    }
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
    /// Best-effort classification of the card shape. The follow-feed
    /// DTO exposes the same `items[]` envelope for videos, 专栏, 番剧,
    /// 直播开播 and 转发, so the decoder does not always know which
    /// one the upstream populated. We infer the kind from which
    /// `major.*` module the payload carries and fall back to `.video`
    /// when an attached video is present. The UI uses this to pick the
    /// right card chrome — a 专栏 post has no thumbnail and should
    /// render as a long text block, a 直播开播 card should flash a
    /// "LIVE" badge, etc.
    var kind: DynamicPostKind {
        DynamicPostKind.infer(attachedVideo: attachedVideo)
    }
}

struct DynamicFeedPage: Hashable {
    let items: [DynamicPost]
    let nextOffset: String
    let hasMore: Bool
    /// True when the request could not be served because the user is
    /// signed out. Used by `HomeView` to render the existing "登录后
    /// 查看关注动态" prompt without distinguishing empty-state from
    /// signed-out-state in the view layer.
    let needsLogin: Bool

    init(items: [DynamicPost], nextOffset: String, hasMore: Bool, needsLogin: Bool = false) {
        self.items = items
        self.nextOffset = nextOffset
        self.hasMore = hasMore
        self.needsLogin = needsLogin
    }
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

struct ReplyRoute: Hashable {
    let video: BiliVideo
    let rootComment: BiliComment
}
