import SwiftUI

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var followingCount: String = "--"
    @Published var followerCount: String = "--"
    @Published var dynamicCount: String = "--"
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
}

struct ProfileSettingsView: View {
    let repository: PaladalaRepository
    @StateObject private var profileModel = ProfileViewModel()
    @AppStorage("paladala.themeMode") private var themeMode: ThemeMode = .system
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    @AppStorage("paladala.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("paladala.backgroundAudio") private var backgroundAudio = false
    @AppStorage("paladala.todayWatch") private var todayWatch = true
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
                Picker("界面设计", selection: $materialDesign) {
                    ForEach(MaterialDesign.allCases) { design in
                        Text(design.title).tag(design)
                    }
                }
                .onChange(of: materialDesign) { _, newValue in
                    ICloudSync.shared.mirror(
                        key: "paladala.materialDesign",
                        value: newValue.rawValue
                    )
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
                Toggle("今日看什么", isOn: $todayWatch)
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
        .background(Color.clear)
        .navigationTitle("我的")
        .task(id: authStore.activeAccount?.mid) {
            if let mid = authStore.activeAccount?.mid {
                await profileModel.loadStats(mid: mid, repository: repository)
            }
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
                Circle()
                    .fill(PaladalaTheme.biliPink)
                    .frame(width: 62, height: 62)
                    .overlay(Text("BP").font(.title3.weight(.black)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 5) {
                    Text("未登录")
                        .font(.title2.weight(.bold))
                    Text("登录后同步历史、收藏、关注和稍后再看")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                router.openLogin()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                    Text("登录 Bilibili 账号")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle)
                        .fill(PaladalaTheme.biliPink.opacity(0.12))
                )
                .foregroundStyle(PaladalaTheme.biliPink)
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
                    .font(.title2.weight(.bold))
                Text("UID: \(account.mid)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    ProfileStat(label: "关注", value: profileModel.followingCount)
                    ProfileStat(label: "粉丝", value: profileModel.followerCount)
                    ProfileStat(label: "动态", value: profileModel.dynamicCount)
                }
                .padding(.top, 2)
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
            ResilientImage(url: url)
                .frame(width: 62, height: 62)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(PaladalaTheme.biliPink)
                .frame(width: 62, height: 62)
                .overlay(
                    Text(String(account.name.prefix(1)))
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                )
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
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        PaladalaGlassContainer(materialDesign: materialDesign, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(items) { item in
                    Button {
                        guard let route = route(for: item) else { return }
                        router.open(route)
                    } label: {
                        quickActionCard(item)
                    }
                    .buttonStyle(.plain)
                    .disabled(route(for: item) == nil)
                    .opacity(route(for: item) == nil ? 0.5 : 1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func quickActionCard(_ item: ProfileQuickAction) -> some View {
        VStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.title3)
                .foregroundStyle(PaladalaTheme.biliPink)
                .frame(width: 32, height: 32)
            Text(item.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Text(item.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
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
                .font(.caption.weight(.bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                .foregroundStyle(PaladalaTheme.biliPink)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
