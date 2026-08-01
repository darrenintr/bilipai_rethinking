import SwiftUI

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var followingCount: String = "--"
    @Published var followerCount: String = "--"
    @Published var dynamicCount: String = "--"
    @Published var coinBalance: String = "--"
    @Published var isLoading = false

    func loadStats(mid: Int64, repository: PaladalaRepository) async {
        guard mid > 0 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let stats = try await repository.userStats(mid: mid)
            followingCount = stats.following
            followerCount = stats.follower
            dynamicCount = stats.dynamic
        } catch {
            bpLog("Failed to load profile stats: \(error)")
        }
    }

    /// Load the signed-in user's 硬币 balance for the header chip.
    /// Independent of `loadStats` so a coin-endpoint hiccup never
    /// blanks the follow/fan counts (and vice-versa).
    func loadCoinBalance(repository: PaladalaRepository) async {
        do {
            let coins = try await repository.coinBalance()
            // Bilibili returns the balance as a float; it is always a
            // whole number in practice, so render without decimals.
            coinBalance = String(Int(coins.rounded()))
        } catch {
            bpLog("Failed to load coin balance: \(error)")
        }
    }
}

struct ProfileSettingsView: View {
    let repository: PaladalaRepository
    @StateObject private var profileModel = ProfileViewModel()
    @AppStorage("paladala.themeMode") private var themeMode: ThemeMode = .system
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    @AppStorage("paladala.designVariant") private var designVariant: DesignVariant = .streetRedesign
    @AppStorage("paladala.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("paladala.backgroundAudio") private var backgroundAudio = false
    /// When `true` (default), navigating away from a playing
    /// video shrinks the player into the floating mini-player
    /// overlay; the user can re-tap to expand. When `false`,
    /// the controller tears down immediately so the audio
    /// stops and no floating window is left behind. Read by
    /// `MiniPlayerStore.detachInline()`.
    @AppStorage("paladala.miniPlayerOnExit") private var miniPlayerOnExit: Bool = true
    @AppStorage("paladala.autoPlayNext") private var autoPlayNext: Bool = false
    /// iCloud sync toggle stub. Defaults to `false` because the
    /// CloudKit / `NSUbiquitousKeyValueStore` plumbing does not
    /// exist yet — the toggle is rendered disabled with a
    /// "即将推出" hint so the user can see where the feature
    /// will land once it ships. Backing storage is created here
    /// so the user's eventual pick survives across launches.
    @AppStorage("paladala.iCloudSync") private var iCloudSync = false
    /// When on, the next playurl request dumps its first 4 KB
    /// of body to the diagnostic log.  Used to figure out what
    /// the upstream HLS slot is actually called.  Default off
    /// so the diagnostic export stays readable in normal use.
    @AppStorage("paladala.dumpPlayURL") private var dumpPlayURL = false
    // Backing key shared with `Analytics` (`Analytics.optInKey`).
    // Default-on so the in-app diagnostic log captures installs;
    // user can flip off in 我的 → 系统与诊断 to silence all
    // `Analytics.log(...)` calls without uninstalling.  Survives
    // app restarts.
    @AppStorage("analytics.optIn") private var analyticsOptIn: Bool = true

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        // iOS Native: standard .listStyle(.insetGrouped) — gives
        // the Settings app look (rounded section cards, grouped
        // background, hairline separators).  Street keeps the
        // default style so the hard-edged chrome (1.5pt ink borders
        // from `paladalaCardSurface` etc.) reads as designed.
        let isNative = PaladalaTheme.activeVariant == .iosNative
        Group {
            if isNative {
                listContent.listStyle(.insetGrouped)
            } else {
                listContent
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        List {
            Section {
                profileHeader
            }

            // Account-scoped status + manual refresh. Lives
            // immediately under the header so the user can
            // confirm the badge without scrolling. The launch
            // hook in `PaladalaApp.body.onAppear` already
            // fires a silent nav refresh; this section makes
            // the *result* visible and gives the user a way
            // to force a fresh fetch if the cached state
            // looks stale.
            if authStore.activeAccount != nil {
                Section {
                    vipStatusRow
                    Button {
                        Task { await authStore.refreshActiveAccountVip() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                            Text("刷新大会员状态")
                            if authStore.isRefreshingVip {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(authStore.isRefreshingVip)
                } header: {
                    Text("账号")
                } footer: {
                    Text("从 B 站服务器拉取 大会员 状态。新开通 / 续费后可能需要几分钟生效，点此可立即刷新。")
                }
            }

            Section("常用入口") {
                ProfileQuickActionGrid(items: [
                    // 离线缓存 is first so the downloads list is
                    // the top-most landmark on the profile screen —
                    // discoverable from here AND from the Home tab
                    // top toolbar.
                    .init(title: "离线缓存", subtitle: "Downloads", symbol: "arrow.down.circle", destination: .downloads),
                    .init(title: "历史记录", subtitle: "History", symbol: "clock.arrow.circlepath", destination: .history),
                    .init(title: "我的收藏", subtitle: "Favorite", symbol: "star", destination: .favorites),
                    .init(title: "稍后再看", subtitle: "Watch later", symbol: "clock.badge.checkmark", destination: .watchLater),
                    .init(title: "消息中心", subtitle: "Inbox", symbol: "tray"),
                    .init(title: "追番追剧", subtitle: "Bangumi", symbol: "play.square.stack", destination: .bangumi)
                ], repository: repository)
            }

            Section("外观") {
                Picker("主题", selection: $themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: themeMode) { _, newValue in
                    // iCloud mirror: store the raw value
                    // string (not the enum) so the system
                    // key-value store can serialise it
                    // across devices without depending on
                    // a shared Codable schema.
                    ICloudSync.shared.mirror(
                        key: "paladala.themeMode",
                        value: newValue.rawValue
                    )
                }
                Picker("界面设计", selection: $designVariant) {
                    // Same legacy-classic filter as the onboarding
                    // picker — only the two shipped design languages
                    // are offered.
                    ForEach(DesignVariant.userFacingCases) { variant in
                        Text(variant.title).tag(variant)
                    }
                }
                .onChange(of: designVariant) { _, newValue in
                    // The picker writes to `UserDefaults`
                    // automatically; we additionally reapply
                    // it to the static `PaladalaTheme` enum
                    // so all computed tokens flip in the
                    // current render pass.  iCloud-mirrored
                    // so the choice follows the user across
                    // their other devices.
                    PaladalaTheme.apply(newValue)
                    ICloudSync.shared.mirror(
                        key: "paladala.designVariant",
                        value: newValue.rawValue
                    )
                }
                Text(designVariant.blurb)
                    .font(PaladalaTheme.FontRole.bodySmall)
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }

            Section("播放设置") {
                Toggle("默认开启弹幕", isOn: $danmakuEnabled)
                    .onChange(of: danmakuEnabled) { _, newValue in
                        ICloudSync.shared.mirror(
                            key: "paladala.danmakuEnabled",
                            value: newValue
                        )
                    }
                Toggle("后台音频", isOn: $backgroundAudio)
                    .onChange(of: backgroundAudio) { _, newValue in
                        ICloudSync.shared.mirror(
                            key: "paladala.backgroundAudio",
                            value: newValue
                        )
                    }
                // YouTube-style "autoplay next recommended video"
                // when the current one ends. Disabled by default
                // because the recommendation surface needs the
                // home feed context; users who enable it get the
                // next-up card surfaced in the player overlay's
                // last-30s phase.
                Toggle("自动播放下一集", isOn: $autoPlayNext)
                // Keep the floating mini-player when the user
                // navigates away from a playing video. Default
                // on. Disabling tears the controller down on
                // `VideoDetailView.onDisappear` instead.
                Toggle("离开后保留小窗播放", isOn: $miniPlayerOnExit)
            }

            Section {
                // Commit 10 wired `ICloudSync` against
                // `NSUbiquitousKeyValueStore`. The toggle is
                // now live: when the device has no iCloud
                // account (`ICloudSync.shared.isAvailable`
                // is `false`) we render the toggle as
                // disabled with a hint pointing the user
                // at the system Settings.app. When the
                // account is present, flipping the switch
                // mirrors the four preference keys through
                // `ICloudSync` and they round-trip to the
                // user's other devices.
                Toggle(isOn: $iCloudSync) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.settings.iCloudSync)
                            .font(.subheadline)
                        Text(L10n.settings.iCloudSyncHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!ICloudSync.shared.isAvailable)
                .opacity(ICloudSync.shared.isAvailable ? 1 : 0.5)
            } header: {
                Text("iCloud 同步")
            } footer: {
                if !ICloudSync.shared.isAvailable {
                    // Surfacing the system-Settings deep
                    // link here means a user without an
                    // iCloud account can fix that and come
                    // back — the toggle is otherwise
                    // permanently greyed out.
                    Link("前往系统设置登录 iCloud",
                         destination: URL(string: UIApplication.openSettingsURLString)!)
                        .font(.caption2)
                } else {
                    Text("开启后，主题、界面设计、弹幕与后台音频会同步到登录了同一 Apple ID 的其他设备。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("播放源") {
                NavigationLink {
                    CDNSettingsView()
                } label: {
                    PluginRow(title: "CDN 播放源", subtitle: "手动切换节点 · 测速并选择", symbol: "antenna.radiowaves.left.and.right")
                }
            }

            Section("插件中心") {
                NavigationLink {
                    SponsorBlockSettingsView()
                } label: {
                    PluginRow(
                        title: "拦截恰饭",
                        subtitle: SponsorBlockManager.shared.isEnabled
                            ? "SponsorBlock · 社区标注 · 已开启"
                            : "SponsorBlock · 社区标注广告跳过",
                        symbol: "shield.lefthalf.filled"
                    )
                }
                // User-installed / bundled JSON plugins.
                // Sits inside the same 插件中心 section so the
                // navigation visually groups all plugin-shaped
                // features together. Reads from
                // `PluginManager.shared.plugins`; @ObservedObject
                // re-renders the row when the array changes.
                NavigationLink {
                    PluginsSettingsView()
                } label: {
                    PluginRow(
                        title: "我的插件",
                        subtitle: "\(PluginManager.shared.plugins.count) 个已安装 · 含 \(PluginManager.shared.plugins.filter { $0.enabled }.count) 个已启用",
                        symbol: "puzzlepiece.extension"
                    )
                }
            }

            Section {
                Button {
                    withAnimation {
                        UserDefaults.standard.set(false, forKey: "paladala.didOnboard")
                    }
                } label: {
                    Label("重新查看引导", systemImage: "questionmark.circle")
                }
                .buttonStyle(.plain)
            } header: {
                Text("引导")
            } footer: {
                Text("重新展示首次使用的引导页，了解 Paladala 的各项功能。")
            }

            // 关于 — push the dedicated AboutView so the
            // user can read the build identifier and trigger
            // a release-check without leaving the profile
            // tab.  Subtitle mirrors the version line on the
            // about page so the entry previews what's
            // inside.
            Section("关于") {
                NavigationLink {
                    AboutView()
                } label: {
                    PluginRow(
                        title: "关于 Paladala",
                        subtitle: "\(AppVersion.current.versionLine) · \(AppVersion.current.identifierDisplay)",
                        symbol: "info.circle"
                    )
                }
            }

            Section("系统与诊断") {
                // The previous implementation used a sheet with an
                // `if let url = logExportURL` content closure
                // which had a SwiftUI re-evaluation race: the
                // first tap showed a blank sheet, the second
                // tap showed the iOS share sheet.  Pushing a
                // dedicated screen makes the URL lifecycle
                // local to the view and removes the race.
                NavigationLink {
                    LogViewerView()
                } label: {
                    PluginRow(title: "运行日志",
                              subtitle: "查看 / 搜索 / 分享 bpLog 输出",
                              symbol: "doc.text")
                }
                // 深度诊断报告 — now lands on a dedicated screen
                // (`DeepDiagnosticReportView`) that owns the
                // generate-and-share flow.  The screen pulls a
                // snapshot of every signal the engineer needs
                // (system info, lifecycle, downloads,
                // on-disk byte counts, bpLog tail) and pops
                // the iOS share sheet with a single tap.
                NavigationLink {
                    DeepDiagnosticReportView()
                } label: {
                    PluginRow(title: "深度诊断报告",
                              subtitle: "推荐算法 / 播放 / 全屏排查 · 一键导出",
                              symbol: "doc.text.magnifyingglass")
                }

                // Diagnostic dump toggle.  When on, the next
                // playurl request logs its raw response body to
                // the diagnostic export.  Used to figure out
                // what shape B站's HLS slot actually takes.
                Toggle(isOn: $dumpPlayURL) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("记录 playurl 原始响应")
                            .font(.subheadline)
                        Text("下次播放视频时,把 B 站返回的 JSON 前 4 KB 写入日志")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Analytics opt-out.  When on, `Analytics.log`,
                // `Analytics.recordError`, and
                // `Analytics.breadcrumb` all become no-ops
                // (guarded in `Analytics.swift`).  When off,
                // the calls route to the in-app `DiagnosticLogger`
                // via `bpLog` so the user can still inspect them
                // through `LogViewerView`.
                Toggle(isOn: $analyticsOptIn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("分享使用统计")
                            .font(.subheadline)
                        Text("在应用内诊断日志中记录使用统计,帮助改进 App")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Link(destination: URL(string: "https://github.com/darrenintr/pure-bilibili-rethinking")!) {
                    PluginRow(title: "GitHub 仓库", subtitle: "开源项目地址", symbol: "link")
                }
                .buttonStyle(.plain)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .background(PaladalaTheme.canvas)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: authStore.activeAccount?.mid) {
            if let mid = authStore.activeAccount?.mid {
                await profileModel.loadStats(mid: mid, repository: repository)
                await profileModel.loadCoinBalance(repository: repository)
            }
            // The launch-time hook in `PaladalaApp.body.onAppear`
            // fires a silent nav refresh, but the user can be
            // minutes late to the profile tab and meanwhile have
            // bought a 大会员 in another client. Re-run the
            // refresh when the profile mounts so the row above
            // shows the *latest* badge without the user needing
            // to tap the manual button. Idempotent on the
            // `isRefreshingVip` latch inside `AuthStore` so a
            // concurrent launch-time fetch is no-op-ed.
            await authStore.refreshActiveAccountVip()
        }
    }

    @ViewBuilder
    private var profileHeader: some View {
        if let account = authStore.activeAccount {
            signedInHeader(account: account)
        } else {
            signedOutHeader
        }
    }

    /// Status row for the "账号" section. Renders the active
    /// account's 大会员 chip in the same shape `signedInHeader`
    /// uses, plus a one-line "上次刷新" stamp so the user can
    /// see whether the launch-time silent fetch actually ran.
    /// `nil` for the badge is a real (and common) state — the
    /// user has not bought a 大会员, or their membership
    /// lapsed — so the row collapses to a plain "未开通" line
    /// rather than hiding the section entirely.
    @ViewBuilder
    private var vipStatusRow: some View {
        if let account = authStore.activeAccount {
            if let badge = account.vipBadge, badge.isActive {
                HStack(spacing: 10) {
                    VipBadgeView(badge: badge, size: .standard)
                    Text(badge.text)
                        .font(PaladalaTheme.FontRole.bodySmall)
                        .foregroundStyle(.primary)
                    Spacer()
                    if badge.isExpired {
                        Text("已到期")
                            .font(PaladalaTheme.FontRole.labelMono)
                            .foregroundStyle(.red)
                    } else if let due = badge.dueDate {
                        Text("到期 \(Self.shortDateFormatter.string(from: due))")
                            .font(PaladalaTheme.FontRole.labelMono)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "crown")
                        .foregroundStyle(.secondary)
                    Text("当前账号未开通大会员")
                        .font(PaladalaTheme.FontRole.bodySmall)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    /// `yyyy-MM-dd` formatter shared by the VIP row and any
    /// future "expired on" surface. Stays on a static
    /// formatter because constructing a new `DateFormatter`
    /// per render is one of the quieter SwiftUI perf traps.
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @ViewBuilder
    private var signedOutHeader: some View {
        let isNative = PaladalaTheme.activeVariant == .iosNative
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: isNative ? 16 : 0, style: .continuous)
                    .fill(PaladalaTheme.biliPink)
                    .frame(width: 62, height: 62)
                    .overlay(
                        Text("BP")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                    )
                    .overlay {
                        if !isNative {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.borderWidth
                                )
                        }
                    }
                VStack(alignment: .leading, spacing: 5) {
                    Text("未登录")
                        .font(isNative ? PaladalaTheme.IOSNative.headline
                                       : PaladalaTheme.FontRole.headline)
                        .textCase(isNative ? nil : .uppercase)
                    Text("登录后同步历史、收藏、关注和稍后再看")
                        .font(isNative ? PaladalaTheme.IOSNative.subheadline
                                       : PaladalaTheme.FontRole.bodySmall)
                        .foregroundStyle(isNative ? .secondary : PaladalaTheme.mutedInk)
                }
            }
            if isNative {
                Button {
                    router.openLogin()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                        Text("登录 Bilibili 账号")
                            .font(.body.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.accentColor)
            } else {
                Button {
                    router.openLogin()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                        Text("登录 Bilibili 账号")
                            .font(PaladalaTheme.FontRole.labelMono)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PaladalaTheme.biliPink)
                    .foregroundStyle(PaladalaTheme.ink)
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                    .background {
                        Rectangle()
                            .fill(PaladalaTheme.ink)
                            .offset(
                                x: PaladalaTheme.hardShadowOffset,
                                y: PaladalaTheme.hardShadowOffset
                            )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func signedInHeader(account: StoredAccount) -> some View {
        let isNative = PaladalaTheme.activeVariant == .iosNative
        let header = HStack(spacing: 14) {
            avatar(for: account)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(account.name)
                        .font(isNative ? PaladalaTheme.IOSNative.headline
                                       : PaladalaTheme.FontRole.headline)
                        .foregroundStyle(
                            vipBadgeNicknameColor(for: account.vipBadge)
                                ?? (isNative ? Color.primary : PaladalaTheme.ink)
                        )
                        .textCase(isNative ? nil : .uppercase)
                    if let badge = account.vipBadge, badge.isActive {
                        VipBadgeView(badge: badge, size: .standard)
                    }
                }
                Text("UID: \(account.mid)")
                    .font(isNative ? PaladalaTheme.IOSNative.footnote
                                   : PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    ProfileStat(label: "关注", value: profileModel.followingCount)
                    ProfileStat(label: "粉丝", value: profileModel.followerCount)
                    ProfileStat(label: "动态", value: profileModel.dynamicCount)
                }
                .padding(.top, 2)
                Label(profileModel.coinBalance, systemImage: "bitcoinsign.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PaladalaTheme.biliPink)
                    .padding(.top, 1)
                    .accessibilityLabel("硬币余额 \(profileModel.coinBalance)")
            }
            Spacer()
            Menu {
                Button(role: .destructive) {
                    authStore.signOut()
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        if isNative {
            // iOS Native: card chrome around the header.  The
            // user card on the system Settings app uses
            // secondarySystemGroupedBackground inside a grouped
            // page — same idiom here.
            header
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
        } else {
            header
        }
    }

    @ViewBuilder
    private func avatar(for account: StoredAccount) -> some View {
        let isNative = PaladalaTheme.activeVariant == .iosNative
        let size: CGFloat = 62
        if let url = account.faceURL {
            ResilientImage(url: url, maximumPixelSize: 192)
                .frame(width: size, height: size)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: isNative ? 16 : 0,
                        style: .continuous
                    )
                )
                .overlay {
                    if !isNative {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: isNative ? 16 : 0, style: .continuous)
                .fill(PaladalaTheme.biliPink)
                .frame(width: size, height: size)
                .overlay(
                    Text(String(account.name.prefix(1)))
                        .font(.title3.weight(.black))
                        .foregroundStyle(PaladalaTheme.ink)
                )
                .overlay {
                    if !isNative {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                }
        }
    }
}

private struct ProfileQuickAction: Identifiable {
    enum Destination {
        case history
        case favorites
        case watchLater
        /// Local downloads list.  Unlike the other
        /// destinations, the downloads list is reachable
        /// without signing in — the user can still play
        /// their already-downloaded videos while signed
        /// out.  `route(for:)` therefore returns
        /// `.downloads` for this case without an active
        /// account.
        case downloads
        /// 追番 weekly timeline.  Mirrors the dedicated
        /// `MainTab.bangumi` tab so the user can deep-link
        /// from the profile screen (or from a search result
        /// whose `card_goto` is `bangumi`) without leaving
        /// their current tab.
        case bangumi
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    var destination: Destination? = nil
}

private struct ProfileQuickActionGrid: View {
    let items: [ProfileQuickAction]
    let repository: PaladalaRepository
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var router: AppRouter
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items) { item in
                Button {
                    guard let route = route(for: item) else { return }
                    router.open(route)
                } label: {
                    quickActionCard(item)
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
                .disabled(route(for: item) == nil)
                .opacity(route(for: item) == nil ? 0.5 : 1)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func quickActionCard(_ item: ProfileQuickAction) -> some View {
        VStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.title3.weight(.black))
                .foregroundStyle(PaladalaTheme.ink)
                .frame(width: 32, height: 32)
            Text(item.title)
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.ink)
                .lineLimit(1)
            Text(item.subtitle)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(PaladalaTheme.mutedInk)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .padding(.horizontal, 4)
        .paladalaCardSurface(materialDesign)
    }

    private func route(for item: ProfileQuickAction) -> ProfileRoute? {
        switch item.destination {
        case .history:
            return authStore.activeAccount != nil ? .history : nil
        case .favorites:
            if let mid = authStore.activeAccount?.mid {
                return .favorites(mid: mid)
            }
            return nil
        case .watchLater:
            return authStore.activeAccount != nil ? .watchLater : nil
        case .downloads:
            // Downloads are reachable signed-out — the
            // user can still play their already-downloaded
            // videos on airplane mode, which is the entire
            // point of the feature.
            return .downloads
        case .bangumi:
            // 追番 is reachable signed-out (PGC content is
            // public). Switches to the dedicated tab via
            // `AppRouter.openBangumiTimeline()` so the user
            // lands in the right place.
            return .bangumiTimeline
        case nil:
            return nil
        }
    }
}

private struct ProfileStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.ink)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PaladalaTheme.mutedInk)
        }
    }
}

private struct PluginRow: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.black))
                .foregroundStyle(PaladalaTheme.ink)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(title)
                    .font(PaladalaTheme.FontRole.cardTitle)
                    .foregroundStyle(PaladalaTheme.ink)
                Text(subtitle)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
        }
    }
}
