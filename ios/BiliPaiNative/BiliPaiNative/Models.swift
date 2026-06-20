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
    /// Owner's Bilibili `mid` (64-bit user id). Populated by
    /// `VideoDTO` from the `/x/web-interface/view` response;
    /// left at `0` for feed-entry shapes (HomeRecommendCard,
    /// dynamic-feed archive, history rows) where the upstream
    /// payload does not surface the owner's mid. Used by
    /// `BilibiliAPIClient.aiSummary(...)` as the required
    /// `up_mid` query parameter — a mismatched or missing
    /// owner id causes Bilibili's WBI rate-limiter to reject
    /// the request with -403 风控. The repository guard at
    /// `aiSummary(for:)` short-circuits when this is `0`.
    let ownerMid: Int64

    /// Optional timestamp (in seconds) to resume playback from.
    /// Used when opening a video from history or a direct link
    /// that carries a progress marker.
    var resumeTime: Double? = nil
}

extension BiliVideo {
    /// Canonical share URL for this video on bilibili.com.
    /// Centralised so the toolbar and fullscreen-player share
    /// buttons cannot drift. Returns `nil` for `bvid`-less
    /// rows (legacy `aid`-only entries); the share affordance
    /// silently hides in that case.
    var shareURL: URL? {
        guard !bvid.isEmpty else { return nil }
        return URL(string: "https://www.bilibili.com/video/\(bvid)")
    }
}

/// Bilibili's official "AI 视频总结" payload returned by
/// `/x/web-interface/view/conclusion/get`. The summary text is
/// Markdown-formatted prose from B站's NLP pipeline; the
/// outline is a chapter list with second-precision timestamps
/// that the player can seek to. We render `summary` via
/// `Text(.init(...))` so the native `LocalizedStringKey`
/// formatter handles `**bold**`, `_italic_`, and
/// `[link](url)` without pulling in a Markdown parser.
///
/// The endpoint returns this struct's `summary` and `outline`
/// populated for videos that have an AI summary yet. Videos
/// without one return `code != 0` and the repository layer
/// maps that to `nil` — the ViewModel treats `nil` as
/// "no section to render" rather than an error state.
struct BiliAISummary: Codable, Hashable {
    let summary: String
    let outline: [BiliAISummaryChapter]

    var isEmpty: Bool { summary.isEmpty && outline.isEmpty }
}

/// One chapter in the AI summary outline. Bilibili publishes
/// `timestamp` as raw seconds (an Int); the ViewModel renders
/// it as `HH:MM:SS` / `MM:SS` via `timestampLabel`. The
/// `content` field is a short paragraph elaborating the
/// chapter — used as the row subtitle.
struct BiliAISummaryChapter: Codable, Hashable, Identifiable {
    let title: String
    let content: String
    let timestamp: Int

    var id: Int { timestamp }

    var timestampLabel: String {
        let total = max(0, timestamp)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
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

    /// Optional timestamp (in seconds) to resume playback from.
    /// When set, the player seeks to this position before starting.
    var resumeTime: Double = 0

    /// When set, the bytes for `dash` live on disk in `directory`
    /// (an already-downloaded video).  `LocalHLSProxyServer` reads
    /// the init/media segments from the local files instead of the
    /// upstream CDN.  `referer` is preserved for any defensive
    /// header checks, but no upstream network calls are made.
    var localContext: LocalPlaybackContext?

    /// True if this playback can be served by the local HLS
    /// proxy.
    var isDASH: Bool { dash != nil || localContext != nil }
}

/// Pointer to an on-disk download that the local HLS proxy
/// should serve instead of fetching from the B 站 CDN.  Set on
/// `BiliPlayback.localContext` when `VideoDetailView` opens a
/// `DownloadRecord`; the proxy then re-routes the init / media
/// file handlers to `directory` instead of `currentPlayback`.
///
/// The struct is intentionally tiny — the heavy data
/// (`BiliDashSource` tracks, byte ranges, etc.) already lives
/// on `BiliPlayback.dash`.  The only thing the proxy needs to
/// know is *where on disk* to read the bytes from.
struct LocalPlaybackContext: Hashable {
    /// `Caches/BiliPai/Downloads/ready/{bvid}/`.  The init and
    /// media m4s files for the video and audio tracks live
    /// directly under this directory.
    let directory: URL
}

/// One row in `DownloadStore.records`.  Persisted as part of
/// `manifest.json`.
///
/// Path-storage note
/// -----------------
/// This struct deliberately holds **no** `URL` or string
/// path field.  The on-disk location
/// (`Caches/BiliPai/Downloads/ready/{bvid}/`) is recomputed
/// on every read from the `bvid` via
/// `DownloadStore.readyDirectory(for:)`.  iOS may rotate the
/// sandbox container UUID between launches (Build 126's
/// `443D6288-…` became Build 127's `579E46FD-…` in one
/// observed run), so persisting any absolute path would
/// silently rot on the next build and the player would 404
/// on every segment.  Only `bvid` is treated as a stable
/// identity; the directory URL is always derived at runtime.
struct DownloadRecord: Codable, Identifiable, Hashable {
    /// `bvid` doubles as the primary key (`BiliVideo.id` is
    /// `bvid ?? "\(aid)"`), and the on-disk directory name.
    var id: String { bvid }
    let bvid: String
    let aid: Int
    let cid: Int
    let title: String
    let ownerName: String
    let coverURL: URL?
    let duration: Int
    /// `BiliDashSource` as it existed at download time.  Needed
    /// by `LocalHLSProxyServer.serveLocal(...)` so the synthesised
    /// `playlist.m3u8` matches the on-disk bytes (byte ranges,
    /// codecs, bandwidth, …).  We keep the full source rather
    /// than a slim summary because the struct is tiny and the
    /// alternative — re-fetching the playurl API offline —
    /// is impossible.
    let dash: BiliDashSource
    let referer: URL
    let downloadedAt: Date
    let sizeBytes: Int64

    /// Re-hydrate the `BiliVideo` shape the rest of the app
    /// already speaks.  Used by `DownloadedVideosView` so the
    /// row does not have to know about the `DownloadRecord`
    /// shape itself.
    var video: BiliVideo {
        BiliVideo(
            bvid: bvid,
            aid: aid,
            cid: cid,
            title: title,
            ownerName: ownerName,
            coverURL: coverURL,
            duration: duration,
            viewCount: 0,
            danmakuCount: 0,
            likeCount: 0,
            description: "",
            ownerMid: 0
        )
    }
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
struct BiliDashSource: Hashable, Codable {
    struct ByteRange: Hashable, Codable {
        let offset: Int64
        let length: Int64

        var endOffset: Int64 {
            offset + length - 1
        }
    }

    /// A single AdaptationSet, plus its Representation.
    /// We flatten audio + video variants into this struct
    /// because B站's DASH responses are simple enough that we
    /// can skip the full MPD Period/AdaptationSet tree.
    struct Track: Hashable, Codable {
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
        /// Byte range containing the fMP4 init section
        /// (`ftyp`/`moov`). HLS fMP4 playlists must expose this
        /// through `#EXT-X-MAP`; without it AVPlayer stalls while
        /// parsing the media playlist.
        let initializationRange: ByteRange
        /// Absolute byte offset where the playable media data
        /// starts in the upstream Bili m4s file.  This is the
        /// first byte **after** the init section, so the
        /// `sidx` (Segment Index Box) that B站 puts between
        /// init and media is served as the first bytes of the
        /// media response.  Dropping the `sidx` makes AVPlayer
        /// abort the download mid-stream.
        let mediaStartOffset: Int64
        /// Total presentation duration in seconds — B站's
        /// `dash.duration` divided by 1000 (B站 publishes
        /// milliseconds here).
        let totalDuration: Double
        /// Optional dimensions for video tracks. Audio tracks
        /// leave these nil.
        let width: Int?
        let height: Int?
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

/// Sort order for the comment list. Persisted in `@AppStorage` so the
/// user's choice survives relaunch. `apiValue` matches Bilibili's
/// `/x/v2/reply/wbi/main` `mode` parameter: `3` is the default
/// ("热门"), `2` is chronological ("最新"). The reply-detail endpoint
/// (`/x/v2/reply/reply`) does not accept a `mode` parameter, so the
/// picker is gated to the main comment list.
enum CommentSort: String, CaseIterable, Identifiable, Codable {
    case hot
    case newest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hot: "最热"
        case .newest: "最新"
        }
    }

    /// Bilibili's `mode` query value. `nil` means "do not send a mode
    /// parameter" — Bilibili then uses its default (hot).
    var apiValue: Int? {
        switch self {
        case .hot: nil
        case .newest: 2
        }
    }
}

// MARK: - Music / Lyrics
//
// Bilibili exposes per-video lyric tracks through `/x/player/v2`'s
// `subtitle.subtitles[]` array. The tracks arrive as either
// protocol-relative JSON (the AI-generated / "AI 字幕" case) or LRC
// plain text (the human-uploaded case). The Music view unifies both
// into a `BiliLyricTrack` so the playback view never has to think
// about the underlying encoding.

/// One lyric track published by the player endpoint. The
/// `subtitle_url` is a protocol-relative URL — callers must
/// resolve it against `https:` before fetching.
struct BiliLyricInfo: Hashable, Codable {
    let id: Int64
    let lan: String
    let lanDoc: String
    /// Protocol-relative URL — prepended with `https:` to form a
    /// fetchable absolute URL. We keep the original so the model
    /// remains `Codable` round-trip-safe (the original may also
    /// already be absolute on rare tracks).
    let subtitleURL: String
    let author: String?

    enum CodingKeys: String, CodingKey {
        case id
        case lan
        case lanDoc = "lan_doc"
        case subtitleURL = "subtitle_url"
        case author
    }

    /// Compose a fetchable absolute URL by prepending `https:` if
    /// the upstream is protocol-relative. Returns `nil` when the
    /// URL string itself fails to parse — we treat that as "no
    /// lyric" so the UI shows the existing placeholder instead of
    /// a generic network error.
    var absoluteURL: URL? {
        let raw = subtitleURL.hasPrefix("//") ? "https:\(subtitleURL)" : subtitleURL
        return URL(string: raw)
    }
}

/// The fully-parsed lyric track the Music view scrolls. Stores
/// the per-line timings as an array of `BiliLyricLine` so the
/// player can binary-search for the active line in O(log n).
struct BiliLyricTrack: Hashable, Codable {
    let lines: [BiliLyricLine]
    let language: String

    /// `true` if the track has at least one parseable line.
    var isEmpty: Bool { lines.isEmpty }

    /// The index of the line active at `time` (in seconds). Lines
    /// whose `startTime` is in the future are skipped; if no line
    /// is active yet, returns `0` so the UI can show the first
    /// line as "pending". Returns `lines.count - 1` for time
    /// past the last line so we don't crash the scroll view.
    func index(at time: Double) -> Int {
        guard !lines.isEmpty else { return 0 }
        // NaN comparisons always return false, so a non-finite
        // `time` would fall through to "line 0" but with the
        // active-line highlight sitting on the wrong row.
        // Treat any non-finite value as "not yet started".
        guard time.isFinite else { return 0 }
        // Walk back from the end. Most lyric lookups hit a line
        // close to the current time so the linear-from-end walk
        // is faster than a full binary search in practice.
        var i = lines.count - 1
        while i > 0 {
            if lines[i].startTime <= time {
                return i
            }
            i -= 1
        }
        return 0
    }
}

/// One line of timed lyrics.
struct BiliLyricLine: Hashable, Codable, Identifiable {
    /// Position in the parent `BiliLyricTrack.lines` array. The
    /// line is `Identifiable` so a `ForEach` over the track can
    /// drive `ScrollViewReader` lookups.
    let startTime: Double
    let text: String
    /// Bilibili occasionally ships "metadata" lines (artist, album,
    /// composer) inside the same JSON / LRC document. They are not
    /// singable content, so the Music view downplays them — we
    /// surface a separate `isMetadata` flag.
    let isMetadata: Bool
    /// Stable parse-order identity for `ForEach`. Two lines can
    /// share the same `startTime` (chorus refrains with the same
    /// timestamp, dual-language lines that fire together, etc.) —
    /// using `startTime * 1000` as `id` made `ForEach` collide on
    /// duplicates, which broke `ScrollViewReader.scrollTo` and
    /// caused random "active line" mis-hits on iOS 18. The
    /// parser assigns a monotonically increasing `ordinal` so
    /// each line has a unique id that survives the post-sort.
    let ordinal: Int

    var id: Int { ordinal }
}

// MARK: - Music navigation routes

/// Navigation routes for the Music tab. Pushed onto the router's
/// `path` so the existing `.navigationDestination(for:)` machinery
/// resolves them into the right view.
enum MusicRoute: Hashable {
    /// Open the fullscreen music player for `video`. The view
    /// resolves the playback URL + lyric track on appear.
    case player(BiliVideo)
}
