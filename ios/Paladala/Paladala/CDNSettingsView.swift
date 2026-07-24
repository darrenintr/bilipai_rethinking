import SwiftUI

struct CDNSettingsView: View {
    @StateObject private var manager = CDNManager.shared
    @State private var nodes: [CDNManager.Node] = []
    @State private var selectedRegion = "全部"
    @AppStorage(CDNManager.enabledKey) private var enabled = false

    private var regions: [String] { ["全部"] + Array(Set(nodes.map(\.region))).sorted() }
    private var visibleNodes: [CDNManager.Node] {
        selectedRegion == "全部" ? nodes : nodes.filter { $0.region == selectedRegion }
    }

    var body: some View {
        List {
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
