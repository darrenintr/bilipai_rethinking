import SwiftUI

struct ProfileSettingsView: View {
    @AppStorage("bilipai.themeMode") private var themeMode: ThemeMode = .system
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .material3
    @AppStorage("bilipai.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("bilipai.backgroundAudio") private var backgroundAudio = false
    @AppStorage("bilipai.todayWatch") private var todayWatch = true

    var body: some View {
        List {
            Section {
                profileHeader
            }

            Section("常用入口") {
                ProfileQuickActionGrid(items: [
                    .init(title: "历史记录", subtitle: "History", symbol: "clock.arrow.circlepath"),
                    .init(title: "我的收藏", subtitle: "Favorite", symbol: "star"),
                    .init(title: "稍后再看", subtitle: "Watch later", symbol: "clock.badge.checkmark"),
                    .init(title: "离线缓存", subtitle: "Downloads", symbol: "arrow.down.circle"),
                    .init(title: "消息中心", subtitle: "Inbox", symbol: "tray"),
                    .init(title: "追番追剧", subtitle: "Bangumi", symbol: "play.square.stack")
                ])
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

    private var profileHeader: some View {
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
                HStack(spacing: 16) {
                    ProfileStat(label: "关注", value: "--")
                    ProfileStat(label: "粉丝", value: "--")
                    ProfileStat(label: "动态", value: "--")
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ProfileQuickAction: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
}

private struct ProfileQuickActionGrid: View {
    let items: [ProfileQuickAction]
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(items) { item in
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
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
            }
        }
        .padding(.vertical, 4)
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
