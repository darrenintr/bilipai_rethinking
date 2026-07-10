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

    /// Local state for the FFmpeg + VideoToolbox test surface.
    /// Tapping the entry in the "诊断工具" section sets this to
    /// `true` and the `.sheet` modifier at the bottom of `body`
    /// presents `FFmpegTestView`.  This is the only way to reach
    /// the FFmpeg stack from production UI right now — it lives in
    /// the profile screen so internal testers can find it without
    /// adding a permanent Settings tab.
    @State private var showingFFmpegTest = false

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        List {
            Section {
                profileHeader
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
                    .init(title: "追番追剧", subtitle: "Bangumi", symbol: "play.square.stack")
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
                HStack {
                    Label("界面设计", systemImage: "square.grid.3x3.square")
                    Spacer()
                    Text("STREET MINIMAL")
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(PaladalaTheme.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(PaladalaTheme.biliPink)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.hairlineWidth
                                )
                        }
                }
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

                // FFmpeg + VideoToolbox test surface.  Opens a
                // sheet that lets the tester pick a local MP4 and
                // verify the FFmpeg demuxer → VideoToolbox hardware
                // decode path works.  This is the iOS 26 Beta MPSGraph
                // workaround diagnostic entry — production playback
                // is still routed through AVPlayer, this surface
                // exists only to validate the alternative path.
                Button {
                    showingFFmpegTest = true
                } label: {
                    PluginRow(title: "FFmpeg 播放测试",
                              subtitle: "iOS 26 Beta 临时通道：选本地 MP4 验证 VideoToolbox 硬解",
                              symbol: "ant.fill")
                }
                .buttonStyle(.plain)

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
        }
        .sheet(isPresented: $showingFFmpegTest) {
            FFmpegTestView()
                .paladalaSheetGlass()
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

    private var signedOutHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Rectangle()
                    .fill(PaladalaTheme.biliPink)
                    .frame(width: 62, height: 62)
                    .overlay(
                        Text("BP")
                            .font(PaladalaTheme.FontRole.cardTitle)
                            .foregroundStyle(PaladalaTheme.ink)
                    )
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                VStack(alignment: .leading, spacing: 5) {
                    Text("未登录")
                        .font(PaladalaTheme.FontRole.headline)
                        .textCase(.uppercase)
                    Text("登录后同步历史、收藏、关注和稍后再看")
                        .font(PaladalaTheme.FontRole.bodySmall)
                        .foregroundStyle(PaladalaTheme.mutedInk)
                }
            }
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
        .padding(.vertical, 8)
    }

    private func signedInHeader(account: StoredAccount) -> some View {
        HStack(spacing: 14) {
            avatar(for: account)
            VStack(alignment: .leading, spacing: 5) {
                Text(account.name)
                    .font(PaladalaTheme.FontRole.headline)
                    .foregroundStyle(PaladalaTheme.ink)
                    .textCase(.uppercase)
                Text("UID: \(account.mid)")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
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
    }

    @ViewBuilder
    private func avatar(for account: StoredAccount) -> some View {
        if let url = account.faceURL {
            ResilientImage(url: url, maximumPixelSize: 192)
                .frame(width: 62, height: 62)
                .clipShape(Rectangle())
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
        } else {
            Rectangle()
                .fill(PaladalaTheme.biliPink)
                .frame(width: 62, height: 62)
                .overlay(
                    Text(String(account.name.prefix(1)))
                        .font(.title3.weight(.black))
                        .foregroundStyle(PaladalaTheme.ink)
                )
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
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
