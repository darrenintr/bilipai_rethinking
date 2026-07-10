import Foundation

enum HomeCategory: String, CaseIterable, Identifiable, Sendable {
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

enum PopularSubCategory: String, CaseIterable, Identifiable, Sendable {
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

struct BiliVideo: Identifiable, Hashable, Codable, Sendable {
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

/// Public profile card for a Bilibili user. Returned by
/// `/x/space/wbi/acc/info` and surfaced on `UPProfileView` as
/// the header row. `sign` is the user's signature (a free-form
/// one-liner); `level` is the user-growth level (0-6); `vipType`
/// is the legacy VIP type code (0 = none). All optional fields
/// default to safe placeholders so a partial upstream response
/// (e.g. a banned or shadow-banned user) still renders.
struct BiliUserCard: Codable, Hashable, Sendable {
    let mid: Int64
    let name: String
    let faceURL: URL?
    let sign: String
    let level: Int
    let vipType: Int

    init(mid: Int64, name: String, faceURL: URL? = nil, sign: String = "", level: Int = 0, vipType: Int = 0) {
        self.mid = mid
        self.name = name
        self.faceURL = faceURL
        self.sign = sign
        self.level = level
        self.vipType = vipType
    }
}

/// Compact UP search result returned by Bilibili's
/// `/x/web-interface/wbi/search/type?search_type=bili_user`.
/// It is intentionally smaller than `BiliUserCard`: search rows need
/// avatar, name, follower count, and video count, while the full profile
/// screen still fetches the richer card once the user opens it.
struct BiliUserSearchResult: Identifiable, Hashable, Codable, Sendable {
    var id: Int64 { mid }

    let mid: Int64
    let name: String
    let faceURL: URL?
    let sign: String
    let fans: Int
    let videos: Int
}

/// One entry returned by the keystroke-rate suggest endpoint
/// `s.search.bilibili.com/main/suggest`.  The upstream wraps
/// the matched substring in `<em class="suggest_high_light">…</em>`
/// so the view can render the highlight as part of the row.
/// `displayName` strips those tags for plain-text contexts.
struct BiliSearchSuggestion: Identifiable, Hashable, Decodable, Sendable {
    var id: String { name }

    /// Raw upstream value — keeps the `<em>` highlight spans
    /// so the row renderer can render them.
    let name: String
    /// Optional bvid when the term resolves to a known video.
    /// Lets the iOS app jump straight to `VideoDetailView`
    /// without a second search-type round-trip.
    let bvid: String?
    /// Optional aid (article id) when the term resolves to a
    /// known 专栏 / 番剧 / 直播 entry.  Decoded as `Int` because
    /// the upstream sometimes sends it as a numeric string.
    let aid: String?
    /// Term type — 1 = tag, 2 = hot-word, 3 = history, etc.
    let termType: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case bvid
        case aid
        case termType = "term_type"
    }

    /// Plain-text name with the `<em>…</em>` highlight tags
    /// stripped.  Useful for accessibility labels and the
    /// on-submit echo.
    var displayName: String {
        name.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
    }
}

/// Aggregated "全部" search results across the five type slots.
/// `searchAll(keyword:page:)` on `BilibiliAPIClient` returns
/// this so the iOS app can render a merged result page in one
/// shot instead of running five separate `search-type` calls.
struct BiliAllSearchResults: Sendable {
    var videos: [BiliVideo] = []
    var users: [BiliUserSearchResult] = []
    var bangumi: [VideoDTO] = []    // raw DTOs; the UI can re-decode via BangumiCard
    var liveRooms: [VideoDTO] = []  // ditto
    var articles: [VideoDTO] = []   // ditto
}

// MARK: - 番剧 (Bangumi / PGC season)
//
// Minimal data shapes for the bangumi timeline surface.  The
// upstream `/pgc/web/timeline` endpoint returns a list of
// "days" (周一 through 周日) and each day carries the season
// cards that update that day.  We don't reproduce the full
// upstream schema — just the fields the home timeline UI
// surfaces (cover, title, latest-episode index, share URL).
// Detailed season / episode metadata is loaded on demand via
// the `seasonId` if/when we add a detail view; out of scope
// for this first pass.

/// One season card in the bangumi timeline.  The cell renders
/// `cover`, `title`, and `updateDescription` ("更新至第 12 话"
/// / "已完结" / "即将开播" / etc.) and on tap opens
/// `shareURL` in the system handler (SFSafariViewController
/// or the official app via Universal Links).  We don't
/// navigate to an in-app detail screen — the web surface
/// already carries episodes, comments, and the official
/// player.
struct BangumiCard: Identifiable, Hashable, Sendable {
    let seasonId: Int64
    let title: String
    let coverURL: URL?
    let updateDescription: String
    let badgeText: String?
    let shareURL: URL?
    var id: Int64 { seasonId }
}

/// One day in the weekly timeline.  Sorted ascending by
/// `weekday` (1 = Monday, 7 = Sunday) so the timeline always
/// starts on the same weekday in the UI regardless of when
/// the user opens the screen.  Cards inside a day are in
/// upstream order (typically: most-viewed first).
struct BangumiDay: Identifiable, Hashable, Sendable {
    let weekday: Int          // 1 = Mon … 7 = Sun
    let weekdayLabel: String  // localized "周一" … "周日"
    let date: String?         // upstream-supplied "MM-DD" for the upcoming slot
    let cards: [BangumiCard]
    var id: Int { weekday }
}

extension BangumiDay {
    /// Localised "周一" … "周日" for the upstream
    /// `day_of_week` (1 = Monday … 7 = Sunday).  Used by
    /// the timeline section header; mirrors what
    /// `BilibiliAPIClient.bangumiTimeline(...)` already
    /// attaches via `weekdayLabel`, but kept here for
    /// unit tests and any test-only fixtures that build a
    /// `BangumiDay` by hand.
    static func weekdayLabel(for weekday: Int) -> String {
        switch weekday {
        case 1: "周一"
        case 2: "周二"
        case 3: "周三"
        case 4: "周四"
        case 5: "周五"
        case 6: "周六"
        case 7: "周日"
        default: "周\(weekday)"
        }
    }
}

    var isEmpty: Bool {
        videos.isEmpty && users.isEmpty && bangumi.isEmpty
            && liveRooms.isEmpty && articles.isEmpty
    }
}

/// Relation between the signed-in user and another UP. Mirrors
/// Bilibili's `/x/relation` `attribute` field — `1` is followed,
/// `2` is the special "悄悄关注" (silent follow) state, `6` is
/// blocked. Anything else (including the unsigned-in case, where
/// the endpoint refuses to answer) collapses to `.notRelated`
/// so the ViewModel can decide whether to show a "Follow" CTA
/// or skip the button entirely.
enum BiliRelation: Int, Codable, Hashable, Sendable {
    case notRelated = 0
    case followed = 1
    case silentFollow = 2
    case blocked = 6

    init(attribute: Int) {
        self = BiliRelation(rawValue: attribute) ?? .notRelated
    }

    /// `true` when the user is already following this UP in any
    /// capacity. The follow button shows the inverse action
    /// ("已关注" / "取消关注") and a different icon based on this.
    var isFollowing: Bool {
        self == .followed || self == .silentFollow
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
///
/// Field provenance — every field below is documented in the
/// upstream `bilibili-API-collect` repo at
/// `docs/video/summary.md` (B站's official API spec).  Do not
/// invent fields: this endpoint is not backwards-compatible and
/// B站 has previously broken downstream clients when they
/// relied on undocumented shapes.
struct BiliAISummary: Codable, Hashable, Sendable {
    /// One-paragraph summary of the whole video. Markdown
    /// formatted by B站's NLP pipeline. May be empty when
    /// `resultType == 0`.
    let summary: String
    /// Chapter outline. Empty when `resultType` is `0` or `1`;
    /// always populated when `resultType == 2`.
    let outline: [BiliAISummaryChapter]
    /// AI-generated subtitle cards. The upstream doc shows
    /// `subtitle[]` with one element containing `part_subtitle`
    /// bullets. Not surfaced in the detail view today but
    /// decoded so future builds can fall back to it for
    /// transcripts when the AI summary is missing.
    let subtitle: [BiliAISummarySubtitle]
    /// `0` = no summary (B站 rejected the video — sensitive
    /// content, gated region, etc.); `1` = summary text only;
    /// `2` = summary + outline. Mirrors `data.code` from the
    /// upstream envelope.
    let resultType: Int
    /// Upstream-supplied like counter for the AI summary. The
    /// POST `/x/web-interface/view/conclusion/set` endpoint
    /// (SESSDATA + bili_jct required) updates this value.
    let likeNum: Int
    /// Upstream-supplied dislike counter for the AI summary.
    let dislikeNum: Int
    /// Upstream summary id, required by the
    /// `/x/web-interface/view/conclusion/set` like/dislike
    /// endpoint. Persisted so a future "like the summary"
    /// button can fire the POST without re-fetching.
    let stid: String

    var isEmpty: Bool {
        summary.isEmpty && outline.isEmpty && subtitle.isEmpty
    }

    /// Wire → Swift field map. B站 ships snake_case; Swift
    /// convention here is camelCase. Hand-rolled rather than
    /// `JSONDecoder.keyDecodingStrategy` because the rest of
    /// this file uses synthesized Codable for fields that
    /// already match the wire format.
    private enum CodingKeys: String, CodingKey {
        case summary, outline, subtitle, stid
        case resultType = "result_type"
        case likeNum = "like_num"
        case dislikeNum = "dislike_num"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        outline = try c.decodeIfPresent([BiliAISummaryChapter].self, forKey: .outline) ?? []
        subtitle = try c.decodeIfPresent([BiliAISummarySubtitle].self, forKey: .subtitle) ?? []
        resultType = try c.decodeIfPresent(Int.self, forKey: .resultType) ?? 0
        likeNum = try c.decodeIfPresent(Int.self, forKey: .likeNum) ?? 0
        dislikeNum = try c.decodeIfPresent(Int.self, forKey: .dislikeNum) ?? 0
        stid = try c.decodeIfPresent(String.self, forKey: .stid) ?? ""
    }

    init(summary: String,
         outline: [BiliAISummaryChapter],
         subtitle: [BiliAISummarySubtitle] = [],
         resultType: Int = 2,
         likeNum: Int = 0,
         dislikeNum: Int = 0,
         stid: String = "") {
        self.summary = summary
        self.outline = outline
        self.subtitle = subtitle
        self.resultType = resultType
        self.likeNum = likeNum
        self.dislikeNum = dislikeNum
        self.stid = stid
    }
}

/// One chapter in the AI summary outline. Bilibili publishes
/// `timestamp` as raw seconds (an Int); the ViewModel renders
/// it as `HH:MM:SS` / `MM:SS` via `timestampLabel`.
///
/// The wire shape (per `bilibili-API-collect`) is
/// `{title, part_outline: [{timestamp, content}, ...], timestamp}` —
/// each chapter has its own bullet list. Tapping a chapter
/// title seeks to the chapter's start; tapping a bullet seeks
/// to that bullet's start. Earlier Paladala builds decoded
/// `outline[i].content` directly, which is null on the wire —
/// the chapter body was rendering empty as a result.
struct BiliAISummaryChapter: Codable, Hashable, Identifiable, Sendable {
    let title: String
    /// Bullet points elaborating this chapter. Each bullet has
    /// its own seek-to timestamp; tapping one seeks the player
    /// to that exact moment. Empty for `resultType == 1`.
    let partOutline: [BiliAISummaryBullet]
    /// Chapter start timestamp in seconds.
    let timestamp: Int

    var id: Int { timestamp }

    var timestampLabel: String {
        Self.formatTimestamp(seconds: timestamp)
    }

    static func formatTimestamp(seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private enum CodingKeys: String, CodingKey {
        case title, timestamp
        case partOutline = "part_outline"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        partOutline = try c.decodeIfPresent([BiliAISummaryBullet].self, forKey: .partOutline) ?? []
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp) ?? 0
    }

    init(title: String,
         partOutline: [BiliAISummaryBullet],
         timestamp: Int) {
        self.title = title
        self.partOutline = partOutline
        self.timestamp = timestamp
    }
}

/// One bullet inside an AI summary chapter. Each bullet has
/// its own timestamp the player can seek to; `content` is a
/// one-line description of the bullet.
struct BiliAISummaryBullet: Codable, Hashable, Identifiable, Sendable {
    let content: String
    let timestamp: Int

    var id: Int { timestamp }

    var timestampLabel: String {
        BiliAISummaryChapter.formatTimestamp(seconds: timestamp)
    }

    private enum CodingKeys: String, CodingKey {
        case content, timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp) ?? 0
    }

    init(content: String, timestamp: Int) {
        self.content = content
        self.timestamp = timestamp
    }
}

/// AI subtitle card. The upstream serves at most one entry
/// here (the array always has length 0 or 1); the actual
/// subtitle line list lives inside `partSubtitle`. Decoded
/// today so the data is on hand when we want to surface an
/// auto-generated transcript.
struct BiliAISummarySubtitle: Codable, Hashable, Identifiable, Sendable {
    let partSubtitle: [BiliAISummarySubtitleLine]
    let timestamp: Int
    let title: String

    var id: Int { timestamp }

    private enum CodingKeys: String, CodingKey {
        case timestamp, title
        case partSubtitle = "part_subtitle"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partSubtitle = try c.decodeIfPresent([BiliAISummarySubtitleLine].self, forKey: .partSubtitle) ?? []
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    }

    init(partSubtitle: [BiliAISummarySubtitleLine], timestamp: Int, title: String) {
        self.partSubtitle = partSubtitle
        self.timestamp = timestamp
        self.title = title
    }
}

struct BiliAISummarySubtitleLine: Codable, Hashable, Identifiable, Sendable {
    let content: String
    let startTimestamp: Double
    let endTimestamp: Double

    var id: Double { startTimestamp }

    private enum CodingKeys: String, CodingKey {
        case content
        case startTimestamp = "start_timestamp"
        case endTimestamp = "end_timestamp"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        // Wire uses ints (seconds); decoder accepts both via
        // the type system falling through to `Double`.
        startTimestamp = try c.decodeIfPresent(Double.self, forKey: .startTimestamp)
            ?? Double(try c.decodeIfPresent(Int.self, forKey: .startTimestamp) ?? 0)
        endTimestamp = try c.decodeIfPresent(Double.self, forKey: .endTimestamp)
            ?? Double(try c.decodeIfPresent(Int.self, forKey: .endTimestamp) ?? 0)
    }

    init(content: String, startTimestamp: Double, endTimestamp: Double) {
        self.content = content
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
    }
}

/// One playable Bilibili source.  The local HLS proxy turns
/// this into an HLS manifest on a 127.0.0.1 loopback HTTP
/// server (`LocalHLSProxyServer`), so a single `BiliPlayback`
/// is enough to start a video.
struct BiliPlayback: Hashable, Sendable {
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
///
/// `mergedVideo` / `mergedAudio` carry the canonical single-file
/// path the new merge step writes at download-complete time.
/// When present, `AVPlayerController` short-circuits the proxy
/// entirely and plays the merged mp4 via
/// `AVMutableComposition` — eliminating the upstream-offset
/// byte-range math the previous layout depended on (and that
/// silently broke on every offset shift, see the recent
/// `Fix downloaded video local ranges` commit).  `nil` for
/// either field means the merged file is missing (legacy
/// download before the merge step landed, or Caches purge) —
/// callers should fall back to the proxy path with the 4-file
/// layout under `directory`.
struct LocalPlaybackContext: Hashable, Sendable {
    /// `Caches/Paladala/Downloads/ready/{bvid}/`.  The init and
    /// media m4s files for the video and audio tracks live
    /// directly under this directory.
    let directory: URL
    /// `directory/video.mp4` — the post-merge single-file video
    /// track.  `nil` when the merge step has not yet run for
    /// this download.
    let mergedVideo: URL?
    /// `directory/audio.mp4` — the post-merge single-file audio
    /// track.  `nil` when the download is video-only or the
    /// merge step has not yet run.
    let mergedAudio: URL?
}

/// One row in `DownloadStore.records`.  Persisted as part of
/// `manifest.json`.
///
/// Path-storage note
/// -----------------
/// This struct deliberately holds **no** `URL` or string
/// path field.  The on-disk location
/// (`Caches/Paladala/Downloads/ready/{bvid}/`) is recomputed
/// on every read from the `bvid` via
/// `DownloadStore.readyDirectory(for:)`.  iOS may rotate the
/// sandbox container UUID between launches (Build 126's
/// `443D6288-…` became Build 127's `579E46FD-…` in one
/// observed run), so persisting any absolute path would
/// silently rot on the next build and the player would 404
/// on every segment.  Only `bvid` is treated as a stable
/// identity; the directory URL is always derived at runtime.
struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
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
struct BiliDashSource: Hashable, Codable, Sendable {
    struct ByteRange: Hashable, Codable, Sendable {
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
    struct Track: Hashable, Codable, Sendable {
        let baseURL: URL
        /// CDN failover URLs B站 ships alongside `baseUrl` in
        /// the playurl response (per
        /// `bilibili-API-collect/docs/video/videostream_url.md`,
        /// both `backup_url` and `backupUrl` keys surface). The
        /// `LocalHLSProxyServer` cycles through these when the
        /// primary host returns 5xx, times out, or stalls
        /// mid-segment. Order is upstream's preference —
        /// `backup_url[0]` is B站's own first-choice failover,
        /// `[1]` is the secondary, etc.
        ///
        /// Empty in the rare cases B站 only publishes a single
        /// host (mostly old or region-locked videos). The
        /// proxy treats `backupURLs.isEmpty` as "no failover
        /// available; surface the upstream error to the user".
        let backupURLs: [URL]
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
        /// Byte range of the DASH segment index (`sidx`) box.
        /// The proxy fetches this via Range request at serve
        /// time, parses the real `moof+mdat` fragments, and uses
        /// those as the source of truth for the generated HLS
        /// playlist. Required for spec-conformant fMP4 HLS — see
        /// `MP4Fragment.swift` for the parser and the rationale
        /// for why equal-byte splitting was wrong.
        ///
        /// Optional: some older B 站 responses omit the sidx
        /// range (a `SegmentBase` is published but lacks
        /// `index_range`). In that case the proxy falls back to
        /// a single direct-MP4 segment instead of fabricating
        /// equal-byte media segments.
        let indexRange: ByteRange?
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

        /// All host candidates for this track — primary first,
        /// then backups in upstream's preferred order. Mirrors
        /// `LocalHLSProxyServer`'s failover cursor so the
        /// proxy and the player can reason about "where we
        /// are" without touching `currentPlayback`.
        var allHosts: [URL] {
            [baseURL] + backupURLs
        }
    }

    let video: Track
    let audio: Track?
}

struct BiliLiveRoom: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let hostName: String
    let areaName: String
    let coverURL: URL?
    let viewerCount: Int
}

/// Per-account overrides the App API needs to return a personalised
/// recommend list. Populated by `PaladalaApp.body.onAppear` from
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
struct BiliAppConfig: Hashable, Sendable {
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
enum BiliLiveStreamFormat: String, Codable, CaseIterable, Identifiable, Sendable {
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
struct BiliLivePlayback: Hashable, Sendable {
    let roomID: Int
    let title: String
    let hostName: String
    /// CDN candidates for the HLS playlist, in the order the
    /// upstream returned them. The HLS proxy (or AVPlayer on the
    /// direct path) walks the list when the current host errors.
    /// Empty when the room only exposes FLV.
    let hlsCandidates: [URL]
    /// CDN candidates for the FLV stream, same ordering rules.
    /// Empty when the room only exposes HLS.
    let flvCandidates: [URL]
    let referer: URL

    /// First HLS candidate, or `nil` when the room is FLV-only.
    var hlsURL: URL? { hlsCandidates.first }
    /// First FLV candidate, or `nil` when the room is HLS-only.
    var flvURL: URL? { flvCandidates.first }
}

/// Kinds of dynamic card the follow feed surfaces. The HTTP payload is
/// the same for all of them — they differ only by which `major.*`
/// module the upstream populates. The UI uses this enum to pick the
/// right card chrome (video card vs. 专栏 text vs. live-started banner
/// vs.转发 reposting the original post).
enum DynamicPostKind: String, Codable, Hashable, Sendable {
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

struct BiliComment: Identifiable, Hashable, Sendable {
    let id: Int
    let authorName: String
    let avatarURL: URL?
    let message: String
    let likeCount: Int
    let replyCount: Int
    let replies: [BiliComment]
}

struct CommentPage: Hashable, Sendable {
    let items: [BiliComment]
    let next: Int?
    let isEnd: Bool
    let totalCount: Int
}

struct DynamicPost: Identifiable, Hashable, Sendable {
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

struct DynamicFeedPage: Hashable, Sendable {
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

struct HistoryCursorState: Hashable, Sendable {
    let max: Int64
    let viewAt: Int64
    let business: String
}

struct HistoryEntry: Identifiable, Hashable, Sendable {
    let id: String
    let video: BiliVideo
    let viewedAt: Int64
    let progress: Int
}

struct HistoryPageResult: Hashable, Sendable {
    let items: [HistoryEntry]
    let nextCursor: HistoryCursorState?
}

struct FavoriteFolderSummary: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let coverURL: URL?
    let mediaCount: Int
    let ownerName: String
}

struct FavoriteFolderVideosPage: Hashable, Sendable {
    let title: String
    let videos: [BiliVideo]
    let hasMore: Bool
}

struct ReplyRoute: Hashable, Sendable {
    let video: BiliVideo
    let rootComment: BiliComment
}

/// Navigation route to a UP (content creator) public profile.
/// Pushed onto the router's `path` by `AppRouter.openUP(mid:)`
/// and resolved by `RootView`'s `navigationDestination(for:)`
/// into `UPProfileView`. Lives here (not in `AppRouter.swift`)
/// so it can be `Hashable` alongside the other route values
/// without a circular import.
enum UPProfileRoute: Hashable, Sendable {
    case up(mid: Int64)
}

/// Sort order for the comment list. Persisted in `@AppStorage` so the
/// user's choice survives relaunch. `apiValue` matches Bilibili's
/// `/x/v2/reply/wbi/main` `mode` parameter: `3` is the default
/// ("热门"), `2` is chronological ("最新"). The reply-detail endpoint
/// (`/x/v2/reply/reply`) does not accept a `mode` parameter, so the
/// picker is gated to the main comment list.
enum CommentSort: String, CaseIterable, Identifiable, Codable, Sendable {
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
struct BiliLyricInfo: Hashable, Codable, Sendable {
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
struct BiliLyricTrack: Hashable, Codable, Sendable {
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
struct BiliLyricLine: Hashable, Codable, Identifiable, Sendable {
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

// MARK: - Video Danmaku

/// One timed danmaku entry from `https://comment.bilibili.com/{cid}.xml`.
/// The first field in `p` is the start time in seconds; the second is
/// Bilibili's display mode (`1` scrolling, `4` bottom, `5` top, etc.).
struct BiliDanmakuItem: Hashable, Codable, Identifiable, Sendable {
    let id: Int
    let time: Double
    let mode: Int
    let fontSize: Int
    let color: Int
    let text: String
}

// MARK: - Music navigation routes

/// Navigation routes for the Music tab. Pushed onto the router's
/// `path` so the existing `.navigationDestination(for:)` machinery
/// resolves them into the right view.
enum MusicRoute: Hashable, Sendable {
    /// Open the fullscreen music player for `video`. The view
    /// resolves the playback URL + lyric track on appear.
    case player(BiliVideo)
}
