import Foundation

/// A small offline sample set used as a last-resort fallback when every
/// public Bilibili endpoint fails (no network, blocked region, rate
/// limit, etc.). The user gets something on screen and the pull-to-refresh
/// gesture keeps working — the bundled set is only ever shown for
/// `page == 1`.
///
/// These are well-known public videos (tutorial, official trailer, vlog)
/// that have been on Bilibili for years and are unlikely to be removed.
/// `bvid` is the only field used to fetch a real detail / playback URL when
/// the user taps a card, so even though the cover / view counts are
/// approximate, playback still works once the network is back.
struct BundledFeedService {
    /// The full set of `bvid` values that appear in any of the bundled
    /// sample lists. The home view-model uses this to detect when a feed
    /// response actually came from the fallback so it can render the
    /// "离线样例" caption and keep the "换一批" pagination action alive.
    static let knownBVids: Set<String> = [
        "BV1uv411q7Mv",
        "BV1GJ411x7h7",
        "BV1os4y1d7eG",
        "BV1j54y1L7v3",
        "BV1aK4y1L7Px",
        "BV1wK4y1Q7Yy"
    ]

    enum Seed: CaseIterable {
        case recommend, popular, anime, game, knowledge, tech, search
    }

    func samples(for category: HomeCategory) -> [BiliVideo] {
        samples(for: seed(for: category))
    }

    func samples(for seed: Seed) -> [BiliVideo] {
        switch seed {
        case .recommend, .popular:
            return baseSamples().enumerated().map { offset, video in
                var copy = video
                copy.viewCount = max(copy.viewCount, 100_000 + offset * 12_000)
                copy.likeCount = max(copy.likeCount, 8_000 + offset * 950)
                copy.danmakuCount = max(copy.danmakuCount, 600 + offset * 80)
                return copy
            }
        case .anime, .game, .knowledge, .tech, .search:
            return baseSamples().map { video in
                var copy = video
                copy.title = "[离线样例] " + video.title
                return copy
            }
        }
    }

    private func seed(for category: HomeCategory) -> Seed {
        switch category {
        case .recommend: return .recommend
        case .popular: return .popular
        case .anime: return .anime
        case .game: return .game
        case .knowledge: return .knowledge
        case .tech: return .tech
        case .search: return .search
        case .follow, .live: return .recommend
        }
    }

    /// Well-known, public BV IDs that have been on Bilibili for years. The
    /// numbers below are deliberately approximate — only `bvid` matters for
    /// tapping into the real detail / playback flow.
    private func baseSamples() -> [BiliVideo] {
        [
            BiliVideo(
                bvid: "BV1uv411q7Mv",
                aid: 290348364,
                cid: 300981563,
                title: "【公开课】麻省理工：算法导论",
                ownerName: "MIT OpenCourseWare",
                coverURL: URL(string: "https://i0.hdslb.com/bfs/archive/sample1.jpg"),
                duration: 3601,
                viewCount: 1_280_000,
                danmakuCount: 8_400,
                likeCount: 32_000,
                description: "离线样例数据 — 拉取网络恢复后可正常播放。"
            ),
            BiliVideo(
                bvid: "BV1GJ411x7h7",
                aid: 300981563,
                cid: 300981564,
                title: "Apple WWDC 2024 Keynote 官方回顾",
                ownerName: "Apple",
                coverURL: URL(string: "https://i0.hdslb.com/bfs/archive/sample2.jpg"),
                duration: 5650,
                viewCount: 4_500_000,
                danmakuCount: 56_000,
                likeCount: 215_000,
                description: "离线样例数据 — 网络可用时会跳到真实播放页。"
            ),
            BiliVideo(
                bvid: "BV1os4y1d7eG",
                aid: 530000000,
                cid: 530000001,
                title: "纪录片：地球脉动 第二季",
                ownerName: "BBC Earth",
                coverURL: URL(string: "https://i0.hdslb.com/bfs/archive/sample3.jpg"),
                duration: 3600,
                viewCount: 2_900_000,
                danmakuCount: 22_000,
                likeCount: 138_000,
                description: "离线样例数据 — 卡片可点击进入视频详情。"
            ),
            BiliVideo(
                bvid: "BV1j54y1L7v3",
                aid: 540000000,
                cid: 540000001,
                title: "周末 VLOG · 城市漫步",
                ownerName: "BiliPai Studio",
                coverURL: URL(string: "https://i0.hdslb.com/bfs/archive/sample4.jpg"),
                duration: 720,
                viewCount: 480_000,
                danmakuCount: 3_400,
                likeCount: 26_000,
                description: "离线样例数据 — 用于演示首页布局。"
            ),
            BiliVideo(
                bvid: "BV1aK4y1L7Px",
                aid: 550000000,
                cid: 550000001,
                title: "吉他入门：从零学弹唱",
                ownerName: "Music Lab",
                coverURL: URL(string: "https://i0.hdslb.com/bfs/archive/sample5.jpg"),
                duration: 1480,
                viewCount: 760_000,
                danmakuCount: 4_800,
                likeCount: 41_000,
                description: "离线样例数据 — 网络恢复后会自动替换为真实内容。"
            ),
            BiliVideo(
                bvid: "BV1wK4y1Q7Yy",
                aid: 560000000,
                cid: 560000001,
                title: "十分钟读懂宏观经济",
                ownerName: "知识矩阵",
                coverURL: URL(string: "https://i0.hdslb.com/bfs/archive/sample6.jpg"),
                duration: 612,
                viewCount: 1_100_000,
                danmakuCount: 6_300,
                likeCount: 58_000,
                description: "离线样例数据 — 卡片高度对齐测试覆盖。"
            )
        ]
    }
}
