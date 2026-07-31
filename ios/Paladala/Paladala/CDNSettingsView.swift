import SwiftUI

struct CDNSettingsView: View {
    @StateObject private var manager = CDNManager.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @State private var nodes: [CDNManager.Node] = []
    @State private var selectedRegion = "全部"
    @AppStorage(CDNManager.enabledKey) private var enabled = false

    private var regions: [String] { ["全部"] + Array(Set(nodes.map(\.region))).sorted() }
    private var visibleNodes: [CDNManager.Node] {
        selectedRegion == "全部" ? nodes : nodes.filter { $0.region == selectedRegion }
    }

    /// The first enabled plugin's CDN pin, or `nil` if no
    /// plugin is overriding the host. Read on every render so
    /// toggling a plugin in the "插件中心" screen flips this
    /// row without a manual refresh.
    private var activePluginPin: String? {
        for plugin in pluginManager.plugins where plugin.enabled {
            if let host = plugin.rules?.cdn?.pinHost, !host.isEmpty {
                return host
            }
        }
        return nil
    }

    var body: some View {
        List {
            // Plugin-status banner. Surfaces the *effective*
            // host the player is using, including plugin pins
            // that the user would otherwise have to dig into
            // 插件中心 to discover. The banner is informational
            // (not actionable) so a non-VIP user who enabled
            // the bundled `cdn-bj-pin` plugin years ago
            // understands why their host is not the one they
            // picked in the manual picker below.
            Section {
                HStack(spacing: 10) {
                    Image(systemName: activePluginPin != nil ? "puzzlepiece.extension.fill" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(activePluginPin != nil ? PaladalaTheme.biliPink : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        if let pin = activePluginPin {
                            Text("插件已强制切换节点")
                                .font(PaladalaTheme.FontRole.labelMono)
                            Text(pin)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else if enabled, !manager.selectedHost.isEmpty {
                            Text("手动节点生效中")
                                .font(PaladalaTheme.FontRole.labelMono)
                            Text(manager.selectedHost)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("使用 B 站默认节点")
                                .font(PaladalaTheme.FontRole.labelMono)
                            Text("无插件 / 未启用手动切换")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            } header: {
                Text("当前生效")
            } footer: {
                Text("优先级：插件强制 > 手动选择 > B 站默认。插件 pin 在「插件中心」管理。")
            }
            Section {
                Toggle("启用手动 CDN", isOn: $enabled)
                Text("按照 CCB 的思路，仅替换播放地址中的媒体节点，保留 B 站签名参数。切换后重新打开视频或点击重试即可生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("当前节点") {
                HStack {
                    Text(manager.selectedHost).font(.subheadline.monospaced())
                    Spacer()
                    if enabled { Text("已启用").foregroundStyle(.green).font(.caption) }
                }
                Picker("地区", selection: $selectedRegion) {
                    ForEach(regions, id: \.self) { Text($0).tag($0) }
                }
            }
            Section {
                Button {
                    Task { await manager.test(nodes: Array(visibleNodes.prefix(40))) }
                } label: {
                    Label(manager.isTesting ? "测速中…" : "测试当前列表", systemImage: "speedometer")
                }
                .disabled(manager.isTesting || visibleNodes.isEmpty)
                if !manager.results.isEmpty {
                    ForEach(manager.results) { result in
                        Button {
                            manager.selectedHost = result.node.host
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(result.node.host).font(.caption.monospaced())
                                    Text(result.node.region).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let ms = result.latencyMs {
                                    Text("\(ms) ms").foregroundStyle(ms < 150 ? .green : ms < 400 ? .orange : .red)
                                } else { Text("失败").foregroundStyle(.red) }
                                if manager.selectedHost == result.node.host { Image(systemName: "checkmark.circle.fill") }
                            }
                        }.buttonStyle(.plain)
                    }
                }
            } header: { Text("测速与选择") } footer: {
                Text("测速使用 HEAD/Range 请求，只测节点可达性和延迟，不批量下载视频；低延迟不一定代表实际视频吞吐最高，建议以播放稳定性为准。")
            }
        }
        .navigationTitle("CDN 播放源")
        .task { nodes = await manager.nodes() }
    }
}
