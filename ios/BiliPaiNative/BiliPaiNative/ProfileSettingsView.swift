import SwiftUI

struct ProfileSettingsView: View {
    let repository: BiliPaiRepository
    @AppStorage("bilipai.themeMode") private var themeMode: ThemeMode = .system
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .material3
    @AppStorage("bilipai.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("bilipai.backgroundAudio") private var backgroundAudio = false
    @AppStorage("bilipai.todayWatch") private var todayWatch = true

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        List {
            Section {
                profileHeader
            }

            Section("常用入口") {
                ProfileQuickActionGrid(items: [
                    .init(title: "历史记录", subtitle: "History", symbol: "clock.arrow.circlepath", destination: .history),
                    .init(title: "我的收藏", subtitle: "Favorite", symbol: "star", destination: .favorites),
                    .init(title: "稍后再看", subtitle: "Watch later", symbol: "clock.badge.checkmark", destination: .watchLater),
                    .init(title: "离线缓存", subtitle: "Downloads", symbol: "arrow.down.circle"),
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
                Picker("界面设计", selection: $materialDesign) {
                    ForEach(MaterialDesign.allCases) { design in
                        Text(design.title).tag(design)
                    }
                }
                PluginRow(title: "iOS 预设", subtitle: "对齐 Android 版默认 UiPreset.IOS", symbol: "iphone")
                PluginRow(title: "Bili 粉强调色", subtitle: "保留 BiliPai 的粉色主色", symbol: "paintpalette")
            }

            Section("播放设置") {
                Toggle("默认开启弹幕", isOn: $danmakuEnabled)
                Toggle("后台音频", isOn: $backgroundAudio)
                PluginRow(title: "倍速播放", subtitle: "0.5x 到 2.0x", symbol: "speedometer")
                PluginRow(title: "小窗/PIP", subtitle: "下一步对齐 Android MiniPlayerManager", symbol: "rectangle.inset.filled")
            }

            Section("插件中心") {
                Toggle("今日看什么", isOn: $todayWatch)
                PluginRow(title: "SponsorBlock", subtitle: "跳过片段策略入口", symbol: "forward.end")
                PluginRow(title: "AdFilter", subtitle: "首页过滤与洞察入口", symbol: "eye.slash")
                PluginRow(title: "Danmaku Plus", subtitle: "弹幕增强设置入口", symbol: "text.bubble")
            }
        }
        .navigationTitle("我的")
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
                    .fill(BiliPaiTheme.biliPink)
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
                    RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle)
                        .fill(BiliPaiTheme.biliPink.opacity(0.12))
                )
                .foregroundStyle(BiliPaiTheme.biliPink)
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
                    ProfileStat(label: "关注", value: "--")
                    ProfileStat(label: "粉丝", value: "--")
                    ProfileStat(label: "动态", value: "--")
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
                .fill(BiliPaiTheme.biliPink)
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
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    var destination: Destination? = nil
}

private struct ProfileQuickActionGrid: View {
    let items: [ProfileQuickAction]
    let repository: BiliPaiRepository
    @EnvironmentObject private var authStore: AuthStore
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(items) { item in
                if let destination = destinationView(for: item) {
                    NavigationLink {
                        destination
                    } label: {
                        quickActionCard(item)
                    }
                    .buttonStyle(.plain)
                } else {
                    quickActionCard(item)
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
                .foregroundStyle(BiliPaiTheme.biliPink)
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
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
    }

    private func destinationView(for item: ProfileQuickAction) -> AnyView? {
        guard authStore.activeAccount != nil else { return nil }
        switch item.destination {
        case .history:
            return AnyView(HistoryListView(repository: repository))
        case .favorites:
            if let mid = authStore.activeAccount?.mid {
                return AnyView(FavoriteFoldersView(repository: repository, mid: mid))
            }
            return nil
        case .watchLater:
            return AnyView(WatchLaterListView(repository: repository))
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
                .foregroundStyle(BiliPaiTheme.biliPink)
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
