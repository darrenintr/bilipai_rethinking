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
        static let todayWatch = String(localized: "home.todayWatch", defaultValue: "今日看什么")
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
        static let quality4K = String(localized: "player.quality4K", defaultValue: "4K")
        static let gestureHint = String(localized: "player.gestureHint", defaultValue: "双击左侧后退 10s · 双击右侧前进 10s · 双击中心点赞")
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
}

// MARK: - Bundle resolution helper
//
// `String(localized:)` already picks the right .strings file based
// on the current locale. This file is here as a stable namespace
// for future helpers (e.g. plural-aware formatting, table lookup).
