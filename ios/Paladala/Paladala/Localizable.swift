import Foundation

/// Type-safe localizable strings.
///
/// Usage:
///   Text(L10n.common.cancel)
///   Label(L10n.player.play, systemImage: "play.fill")
///
/// All keys are declared as static properties of nested namespaces
/// (`common.*`, `player.*`, `comments.*`, `a11y.*`). The actual
/// translations live in the three `Localizable.strings` files
/// (zh-Hans, zh-Hant, en) and are resolved by Foundation's
/// `String(localized:)` machinery.
enum L10n {

    // MARK: - Common UI

    enum common {
        static let cancel = String(localized: "common.cancel", defaultValue: "取消")
        static let confirm = String(localized: "common.confirm", defaultValue: "确认")
        static let retry = String(localized: "common.retry", defaultValue: "重试")
        static let done = String(localized: "common.done", defaultValue: "完成")
        static let close = String(localized: "common.close", defaultValue: "关闭")
        static let share = String(localized: "common.share", defaultValue: "分享")
        static let openInBrowser = String(localized: "common.openInBrowser", defaultValue: "浏览器打开")
        static let copyLink = String(localized: "common.copyLink", defaultValue: "复制链接")
        static let skip = String(localized: "common.skip", defaultValue: "跳过")
        static let `continue` = String(localized: "common.continue", defaultValue: "继续")
    }

    // MARK: - Tabs / Navigation

    enum tabs {
        static let home = String(localized: "tabs.home", defaultValue: "首页")
        static let dynamic = String(localized: "tabs.dynamic", defaultValue: "动态")
        static let live = String(localized: "tabs.live", defaultValue: "直播")
        static let profile = String(localized: "tabs.profile", defaultValue: "我的")
        static let music = String(localized: "tabs.music", defaultValue: "音乐")
    }

    // MARK: - Music

    enum music {
        /// Tab / list title.
        static let title = String(localized: "music.title", defaultValue: "音乐")
        /// Empty-state headline when the music region returns no
        /// videos for the current page.
        static let empty = String(localized: "music.empty", defaultValue: "暂无音乐")
        static let emptyHint = String(localized: "music.emptyHint", defaultValue: "稍后再来，下拉刷新试试。")
        static let networkError = String(localized: "music.networkError", defaultValue: "音乐列表加载失败")
        /// "未找到歌词" placeholder shown in the lyrics pane.
        static let noLyrics = String(localized: "music.noLyrics", defaultValue: "这首歌暂无歌词")
        /// "纯享" badge on the music tab card / now-playing bar
        /// to signal "audio only — no video surface".
        static let audioOnly = String(localized: "music.audioOnly", defaultValue: "纯享")
        /// "歌词" pane header.
        static let lyricsHeader = String(localized: "music.lyrics", defaultValue: "歌词")
        static let artwork = String(localized: "music.artwork", defaultValue: "封面")
    }

    // MARK: - Home / categories

    enum home {
        static let recommended = String(localized: "home.recommended", defaultValue: "推荐")
        static let follow = String(localized: "home.follow", defaultValue: "关注")
        static let popular = String(localized: "home.popular", defaultValue: "热门")
        static let live = String(localized: "home.live", defaultValue: "直播")
        static let bangumi = String(localized: "home.bangumi", defaultValue: "追番")
        static let gaming = String(localized: "home.gaming", defaultValue: "游戏")
        static let knowledge = String(localized: "home.knowledge", defaultValue: "知识")
        static let tech = String(localized: "home.tech", defaultValue: "科技")
        static let refresh = String(localized: "home.refresh", defaultValue: "刷新")
    }

    // MARK: - Live

    enum live {
        /// "N 人在看" — used as a label next to the viewer count.
        static func watching(_ count: Int) -> String {
            String(
                localized: "live.watching",
                defaultValue: "\(count.compactCount) 人在看"
            )
        }
        /// "正在直播" badge.
        static let badge = String(localized: "live.badge", defaultValue: "LIVE")
        static let resolutionFailed = String(localized: "live.resolutionFailed", defaultValue: "直播间地址解析失败")
        static let streamOffline = String(localized: "live.streamOffline", defaultValue: "主播已下播")
        static let networkError = String(localized: "live.networkError", defaultValue: "网络异常，请检查连接后重试")
    }

    // MARK: - Video detail

    enum video {
        static let comments = String(localized: "video.comments", defaultValue: "评论")
        static let noComments = String(localized: "video.noComments", defaultValue: "暂无评论")
        static let noCommentsHint = String(localized: "video.noCommentsHint", defaultValue: "成为第一个评论的人")
        static let commentError = String(localized: "video.commentError", defaultValue: "评论加载失败")
        static let subtitles = String(localized: "video.subtitles", defaultValue: "字幕")
        static let danmaku = String(localized: "video.danmaku", defaultValue: "弹幕")
        static let danmakuComingSoon = String(localized: "video.danmakuComingSoon", defaultValue: "弹幕 (即将推出)")
        static let noPlayableFormat = String(localized: "video.noPlayableFormat", defaultValue: "该视频的可用清晰度均不可播放（可能为地区限制或大会员专享）")
        static let addToWatchLater = String(localized: "video.addToWatchLater", defaultValue: "稍后再看")
        static let removeFromWatchLater = String(localized: "video.removeFromWatchLater", defaultValue: "从稍后再看中移除")
        static let removeFromHistory = String(localized: "video.removeFromHistory", defaultValue: "从历史记录中移除")
        /// "查看全部 N 条回复 >"
        static func viewAllReplies(_ count: Int) -> String {
            String(
                localized: "video.viewAllReplies",
                defaultValue: "查看全部 \(count) 条回复 >"
            )
        }
        /// Send-button label (发表).
        static let publish = String(localized: "video.publish", defaultValue: "发布")
        static let fullscreen = String(localized: "video.fullscreen", defaultValue: "全屏")
        static let pip = String(localized: "video.pip", defaultValue: "画中画")
        static let airplay = String(localized: "video.airplay", defaultValue: "隔空播放")
        /// Sleep timer menu: "15 / 30 / 60 / 关闭" minutes.
        static let shareLANStream = String(localized: "video.shareLANStream", defaultValue: "LAN stream")
        static let shareLANStreamFailed = String(localized: "video.shareLANStreamFailed", defaultValue: "LAN sharing failed")
        enum sleepTimer {
            static let title = String(localized: "video.sleepTimer.title", defaultValue: "定时关闭")
            static let off = String(localized: "video.sleepTimer.off", defaultValue: "关闭")
            static let minutes15 = String(localized: "video.sleepTimer.15m", defaultValue: "15 分钟")
            static let minutes30 = String(localized: "video.sleepTimer.30m", defaultValue: "30 分钟")
            static let minutes60 = String(localized: "video.sleepTimer.60m", defaultValue: "60 分钟")
        }
    }

    // MARK: - Comment threads (replies)

    enum replies {
        static let empty = String(localized: "replies.empty", defaultValue: "暂无回复")
        static let emptyHint = String(localized: "replies.emptyHint", defaultValue: "成为第一个回复的人")
    }

    // MARK: - Player (the VLC / AVPlayer surface)

    enum player {
        static let play = String(localized: "player.play", defaultValue: "播放")
        static let pause = String(localized: "player.pause", defaultValue: "暂停")
        static let buffering = String(localized: "player.buffering", defaultValue: "缓冲中…")
        static let speed = String(localized: "player.speed", defaultValue: "倍速")
        static let quality = String(localized: "player.quality", defaultValue: "清晰度")
        static let qualityAuto = String(localized: "player.qualityAuto", defaultValue: "自动")
        static let quality360 = String(localized: "player.quality360", defaultValue: "360P")
        static let quality480 = String(localized: "player.quality480", defaultValue: "480P")
        static let quality720 = String(localized: "player.quality720", defaultValue: "720P")
        static let quality1080 = String(localized: "player.quality1080", defaultValue: "1080P")
        /// 1080P 高码率 — the gated 1080P high-bitrate variant
        /// (qn=112) that B站 serves when VIP is active. Distinct
        /// from `quality1080` because the menu shows them side
        /// by side and the high-bitrate variant is the one
        /// typically required for HDR / Dolby Vision sources.
        static let quality1080Plus = String(localized: "player.quality1080Plus", defaultValue: "1080P 高码率")
        /// 1080P 60fps (qn=116). Requires 大会员.
        static let quality1080P60 = String(localized: "player.quality1080P60", defaultValue: "1080P 60帧")
        static let quality1080Hi = String(localized: "player.quality1080Hi", defaultValue: "1080P Hi-Res")
        static let quality4K = String(localized: "player.quality4K", defaultValue: "4K")
        static let quality4KHi = String(localized: "player.quality4KHi", defaultValue: "4K Hi-Res")
        static let quality4KHDR = String(localized: "player.quality4KHDR", defaultValue: "4K HDR")
        static let qualityHDR = String(localized: "player.qualityHDR", defaultValue: "HDR")
        static let qualityDolby = String(localized: "player.qualityDolby", defaultValue: "杜比视界")
        static let quality8K = String(localized: "player.quality8K", defaultValue: "8K")
        static let quality8KHDR = String(localized: "player.quality8KHDR", defaultValue: "8K HDR")
        /// Audio quality menu label. Mirrors `quality` for video
        /// but reads "音质" in zh-Hans; the toolbar icon
        /// already differentiates the two.
        static let audioQuality = String(localized: "player.audioQuality", defaultValue: "音质")
        /// 64 kbps AAC (low). Default for non-VIP users that
        /// picked nothing yet — universally available, AVPlayer
        /// consumes it natively.
        static let audioQuality64 = String(localized: "player.audioQuality64", defaultValue: "64K")
        /// 128 kbps AAC (standard). Default for first-launch
        /// users — matches the web player's fallback.
        static let audioQuality128 = String(localized: "player.audioQuality128", defaultValue: "128K")
        /// 192 kbps Dolby Atmos / 高码率 audio. Gated behind
        /// 大会员; the toolbar dims the row for non-VIP users.
        static let audioQuality192 = String(localized: "player.audioQuality192", defaultValue: "192K 杜比")
        /// 320 kbps Hi-Res AAC. Gated behind 大会员.
        static let audioQuality320 = String(localized: "player.audioQuality320", defaultValue: "320K Hi-Res")
        static let gestureHint = String(localized: "player.gestureHint", defaultValue: "双击左侧后退 10s · 双击右侧前进 10s · 双击中心点赞")
    }

    // MARK: - VIP / 大会员

    enum vip {
        /// Generic 大会员 chip text (used by the monthly tier).
        static let title = String(localized: "vip.title", defaultValue: "大会员")
        /// 年大会员 — annual membership badge.
        static let annualTitle = String(localized: "vip.annualTitle", defaultValue: "年度大会员")
        /// 十年大会员 — the 10-year commemorative membership.
        static let tenYearTitle = String(localized: "vip.tenYearTitle", defaultValue: "十年大会员")
        /// 超级大会员 (Super VIP) — B站's top tier.
        static let superTitle = String(localized: "vip.superTitle", defaultValue: "超级大会员")
        /// Tiny chip text appended to gated quality / audio menu
        /// rows so the user can see at a glance why the row is
        /// dimmed for non-VIP accounts. Rendered with the same
        /// pink as the regular VIP chip.
        static let lockedBadge = String(localized: "vip.lockedBadge", defaultValue: "大会员")
        /// "你还不是大会员，登录后可享受高清画质" style hint shown
        /// when the user taps a gated quality while signed out.
        static let upgradeHint = String(localized: "vip.upgradeHint", defaultValue: "登录大会员账号后可解锁此画质")
        /// Title of the upgrade alert shown when a signed-in,
        /// non-VIP user picks a VIP-gated quality. Keeps the
        /// upgrade path a single tap away from the quality menu.
        static let requiredTitle = String(localized: "vip.requiredTitle", defaultValue: "需要大会员")
        /// Body of the upgrade alert shown when a signed-in,
        /// non-VIP user picks a VIP-gated quality. Mirrors the
        /// tone of the B站 web player's "请开通大会员后重试" prompt
        /// so the user knows the action unlocks the row they
        /// just tapped.
        static let requiredHint = String(localized: "vip.requiredHint", defaultValue: "该画质/音质需要开通大会员")
        /// Title of the upgrade alert shown when a user *was* a
        /// 大会员 but the membership has lapsed (`vip.status == 0`
        /// or `-40103` from the playurl).
        static let expiredTitle = String(localized: "vip.expiredTitle", defaultValue: "大会员已到期")
        /// Body of the expired alert. Steers the user to the
        /// renewal page rather than the login sheet (they are
        /// already signed in; the cookie is fine).
        static let expiredHint = String(localized: "vip.expiredHint", defaultValue: "你的大会员已到期，续费后即可解锁")
        /// Primary action label on the upgrade alert — opens
        /// B站's account management page where the user can
        /// purchase / renew the membership.
        static let actionUpgrade = String(localized: "vip.actionUpgrade", defaultValue: "去开通/续费")
        /// Secondary action label on the upgrade alert when the
        /// user is signed out. Opens the local login sheet so
        /// they can sign in with a VIP account that already
        /// has an active subscription.
        static let actionLogin = String(localized: "vip.actionLogin", defaultValue: "去登录")
        /// Status line on the profile header — `${kind} · 到期
        /// ${date}`. Falls back to `${kind} · 已过期` when the
        /// due date is in the past.
        static func status(_ kind: String, due: Date?) -> String {
            if let due {
                let f = DateFormatter()
                f.dateStyle = .medium
                f.timeStyle = .none
                f.locale = Locale(identifier: "zh_CN")
                return "\(kind) · 到期 \(f.string(from: due))"
            }
            return kind
        }
    }

    // MARK: - Mini-player

    enum miniPlayer {
        static let pause = String(localized: "miniPlayer.pause", defaultValue: "暂停")
        static let play = String(localized: "miniPlayer.play", defaultValue: "播放")
        static let expand = String(localized: "miniPlayer.expand", defaultValue: "展开播放器")
        static let close = String(localized: "miniPlayer.close", defaultValue: "关闭")
        static func label(for title: String) -> String {
            String(
                localized: "miniPlayer.label",
                defaultValue: "正在播放：\(title)"
            )
        }
    }

    // MARK: - Login / Auth

    enum login {
        static let title = String(localized: "login.title", defaultValue: "扫码登录")
        static let statusWaiting = String(localized: "login.statusWaiting", defaultValue: "请使用手机 B 站 App 扫描二维码")
        static let statusScanned = String(localized: "login.statusScanned", defaultValue: "已扫描，请在手机上确认登录")
        static let statusExpired = String(localized: "login.statusExpired", defaultValue: "二维码已过期，请关闭后重试")
        static let statusError = String(localized: "login.statusError", defaultValue: "登录失败，请稍后重试")
        static let statusSuccess = String(localized: "login.statusSuccess", defaultValue: "登录成功")
        static let ctaSignIn = String(localized: "login.ctaSignIn", defaultValue: "立即登录")
        static let ctaSignOut = String(localized: "login.ctaSignOut", defaultValue: "退出登录")
    }

    // MARK: - Errors

    enum errors {
        static let network = String(localized: "errors.network", defaultValue: "网络异常，请检查连接后重试")
        static let rateLimit = String(localized: "errors.rateLimit", defaultValue: "操作太频繁，请稍后再试")
        static let unauthorized = String(localized: "errors.unauthorized", defaultValue: "登录已过期，请重新登录")
        static let parse = String(localized: "errors.parse", defaultValue: "数据解析失败")
        static let unknown = String(localized: "errors.unknown", defaultValue: "出错了，请稍后重试")
        static let retry = String(localized: "errors.retry", defaultValue: "重试")
        static let empty = String(localized: "errors.empty", defaultValue: "暂无内容")
    }

    // MARK: - Settings

    enum settings {
        static let appearance = String(localized: "settings.appearance", defaultValue: "外观")
        static let playback = String(localized: "settings.playback", defaultValue: "播放设置")
        static let plugins = String(localized: "settings.plugins", defaultValue: "插件中心")
        static let diagnostics = String(localized: "settings.diagnostics", defaultValue: "系统与诊断")
        static let theme = String(localized: "settings.theme", defaultValue: "主题")
        static let material = String(localized: "settings.material", defaultValue: "设计风格")
        static let defaultTab = String(localized: "settings.defaultTab", defaultValue: "启动时打开")
        static let defaultSpeed = String(localized: "settings.defaultSpeed", defaultValue: "默认播放倍速")
        static let backgroundAudio = String(localized: "settings.backgroundAudio", defaultValue: "后台播放音频")
        static let clearCache = String(localized: "settings.clearCache", defaultValue: "清除缓存")
        static let iCloudSync = String(localized: "settings.iCloudSync", defaultValue: "iCloud 同步")
        static let iCloudSyncHint = String(localized: "settings.iCloudSyncHint", defaultValue: "在登录了同一 Apple ID 的设备间同步稍后再看、历史记录和偏好")
        static let accountSwitcher = String(localized: "settings.accountSwitcher", defaultValue: "切换账号")
        static let reOnboarding = String(localized: "settings.reOnboarding", defaultValue: "重新查看新手引导")
        static let logViewer = String(localized: "settings.logViewer", defaultValue: "运行日志")
        static let diagnosticReport = String(localized: "settings.diagnosticReport", defaultValue: "深度诊断报告")
        /// Watch-later quick action — currently a placeholder.
        static let watchLaterComingSoon = String(localized: "settings.watchLaterComingSoon", defaultValue: "稍后再看 (即将推出)")
    }

    // MARK: - About page

    enum about {
        /// Navigation title for the 关于 screen.
        static let title = String(localized: "about.title", defaultValue: "关于")
        /// Row label: the human-readable marketing version
        /// (e.g. "0.5.1"). The build number is on a separate
        /// row right below.
        static let version = String(localized: "about.version", defaultValue: "版本")
        /// Row label: the monotonically increasing build
        /// number that the CI workflow bumps on every run
        /// (e.g. "195").
        static let build = String(localized: "about.build", defaultValue: "构建号")
        /// Row label: the per-build "特别辨识号" (special
        /// identifier), formatted as `PD-XXXX-XXXX-XXXX`.
        /// Tapping the row copies the identifier to the
        /// clipboard.
        static let identifier = String(localized: "about.identifier", defaultValue: "唯一辨识号")
        /// Short message that appears at the bottom of the
        /// screen for ~1.4 s after the user taps the
        /// identifier row, confirming the copy.
        static let identifierCopied = String(localized: "about.identifierCopied", defaultValue: "已复制到剪贴板")
        /// Row label: how the running binary is distributed
        /// (debug / TestFlight / App Store / etc.).  Renders
        /// the localisable `debug` / `testflight` / etc.
        /// value below it.
        static let releaseType = String(localized: "about.releaseType", defaultValue: "发布类型")
        /// Row label: free-form channel tag set by the build
        /// (e.g. "ci", "local", "appstore").  Renders the
        /// raw value as a monospaced string.
        static let channel = String(localized: "about.channel", defaultValue: "渠道")
        /// Row label: the short git commit SHA baked into
        /// the build.  Hidden entirely when the build is
        /// local (no commit recorded).
        static let commit = String(localized: "about.commit", defaultValue: "提交")
        /// Row label: the ISO-8601 timestamp the CI workflow
        /// captured at build time.  Renders as
        /// `yyyy-MM-dd HH:mm zzz`.
        static let buildDate = String(localized: "about.buildDate", defaultValue: "构建时间")
        /// Row label: the bundle identifier (e.g.
        /// `com.dt.paladala`).
        static let bundleId = String(localized: "about.bundleId", defaultValue: "Bundle ID")
        /// Button label that triggers the GitHub Releases
        /// lookup.
        static let checkForUpdates = String(localized: "about.checkForUpdates", defaultValue: "检查更新")
        /// Inline status shown under the button while the
        /// network call is in flight.
        static let checking = String(localized: "about.checking", defaultValue: "正在检查…")
        /// Status shown when the remote tag is older than
        /// or equal to the local build.  The remote tag is
        /// appended after the `·` so the user can see which
        /// version we compared against.
        static let upToDate = String(localized: "about.upToDate", defaultValue: "已是最新版本")
        /// Status shown when the remote tag is newer than
        /// the local build.  The remote tag follows after
        /// the `·`.
        static let updateAvailable = String(localized: "about.updateAvailable", defaultValue: "发现新版本")
        /// Status shown when the network call fails or the
        /// API returns a non-2xx response.  Appended after
        /// an `exclamationmark.triangle` glyph.
        static let updateFailed = String(localized: "about.updateFailed", defaultValue: "检查更新失败，请稍后重试")
        /// Button label on the update-available row that
        /// opens the GitHub release page for the new tag.
        static let viewRelease = String(localized: "about.viewRelease", defaultValue: "查看发布")
        /// Button label on the dev-build row that opens the
        /// repository's releases tab so the tester can grab
        /// the latest unsigned IPA manually.
        static let openOnGitHub = String(localized: "about.openOnGitHub", defaultValue: "在 GitHub 上打开")
        /// Status shown when the running build is a
        /// development / sideloaded binary; the update
        /// checker always recommends grabbing the latest
        /// release instead of trying to compare versions.
        static let devBuild = String(localized: "about.devBuild", defaultValue: "当前为开发构建，不参与版本比较")
        // Release-type display names.  Each value pairs with
        // `ReleaseType.displayName` in AppVersion.swift.
        static let debug = String(localized: "about.releaseType.debug", defaultValue: "调试")
        static let appStore = String(localized: "about.releaseType.appStore", defaultValue: "App Store")
        static let testflight = String(localized: "about.releaseType.testflight", defaultValue: "TestFlight")
        static let enterprise = String(localized: "about.releaseType.enterprise", defaultValue: "企业分发")
        static let sideload = String(localized: "about.releaseType.sideload", defaultValue: "侧载")
        static let unknown = String(localized: "about.releaseType.unknown", defaultValue: "未知")
    }

    // MARK: - Accessibility

    enum a11y {
        static let homeCategory = String(localized: "a11y.homeCategory", defaultValue: "首页分类")
        static let subCategory = String(localized: "a11y.subCategory", defaultValue: "二级分类")
        static let commentLike = String(localized: "a11y.commentLike", defaultValue: "点赞评论")
        static let replyLike = String(localized: "a11y.replyLike", defaultValue: "点赞回复")
        static let quickAction = String(localized: "a11y.quickAction", defaultValue: "快捷入口")
        static let sidebarTab = String(localized: "a11y.sidebarTab", defaultValue: "侧边栏标签")
        static let collapseSidebar = String(localized: "a11y.collapseSidebar", defaultValue: "收起侧边栏")
    }

    // MARK: - Onboarding

    enum onboarding {
        static let page1Title = String(localized: "onboarding.page1.title", defaultValue: "为 B 站而生")
        static let page1Subtitle = String(localized: "onboarding.page1.subtitle", defaultValue: "首页、动态、直播、追番，一个应用就够了")
        static let page2Title = String(localized: "onboarding.page2.title", defaultValue: "顺手就走的播放")
        static let page2Subtitle = String(localized: "onboarding.page2.subtitle", defaultValue: "小窗播放、画中画、后台音频 — 切换应用也不中断")
        static let page3Title = String(localized: "onboarding.page3.title", defaultValue: "登录后更强")
        static let page3Subtitle = String(localized: "onboarding.page3.subtitle", defaultValue: "登录后同步历史记录、收藏夹和稍后再看")
        static let ctaStart = String(localized: "onboarding.ctaStart", defaultValue: "开始")
        static let ctaSkip = String(localized: "onboarding.ctaSkip", defaultValue: "跳过")
    }

    // MARK: - AI 视频总结

    enum aiSummary {
        /// "AI 视频总结" — chip header for the AI summary section.
        /// Mirrors the upstream "AI 小助手" label for users who
        /// are familiar with the web player.
        static let title = String(localized: "aiSummary.title", defaultValue: "AI 视频总结")
        /// "章节" — small heading above the chapter outline list.
        static let chapters = String(localized: "aiSummary.chapters", defaultValue: "章节")
        /// "跳转到此位置" — VoiceOver hint on each outline chapter
        /// and bullet row. Both rows are tap-to-seek, so the
        /// hint is identical for both.
        static let seekHint = String(localized: "aiSummary.seekHint", defaultValue: "跳转到此位置")
    }

    // MARK: - SponsorBlock 拦截恰饭

    enum sponsorBlock {
        static let title = String(localized: "sponsorBlock.title", defaultValue: "拦截恰饭")
        static let enable = String(localized: "sponsorBlock.enable", defaultValue: "启用拦截恰饭")
        static let autoSkip = String(localized: "sponsorBlock.autoSkip", defaultValue: "自动跳过")
        static let minVotes = String(localized: "sponsorBlock.minVotes", defaultValue: "最低投票数")
        static let categories = String(localized: "sponsorBlock.categories", defaultValue: "拦截类别")
        static let report = String(localized: "sponsorBlock.report", defaultValue: "上报恰饭片段")
        static let viewSegments = String(localized: "sponsorBlock.viewSegments", defaultValue: "查看已加载的片段")
        static let timeSaved = String(localized: "sponsorBlock.timeSaved", defaultValue: "已节省时间")
        static let submit = String(localized: "sponsorBlock.submit", defaultValue: "提交")
        static let submitSuccess = String(localized: "sponsorBlock.submitSuccess", defaultValue: "提交成功！感谢您的贡献。")
        static let enabled = String(localized: "sponsorBlock.enabled", defaultValue: "已开启")
    }
}

// MARK: - Bundle resolution helper
//
// `String(localized:)` already picks the right .strings file based
// on the current locale. This file is here as a stable namespace
// for future helpers (e.g. plural-aware formatting, table lookup).
