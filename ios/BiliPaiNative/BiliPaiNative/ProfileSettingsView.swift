import SwiftUI

struct ProfileSettingsView: View {
    @AppStorage("bilipai.themeMode") private var themeMode = "system"
    @AppStorage("bilipai.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("bilipai.backgroundAudio") private var backgroundAudio = false
    @AppStorage("bilipai.todayWatch") private var todayWatch = true

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Circle()
                        .fill(BiliPaiTheme.biliPink)
                        .frame(width: 62, height: 62)
                        .overlay(Text("BP").font(.title3.weight(.black)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BiliPai")
                            .font(.title2.weight(.bold))
                        Text("Anonymous public API mode")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("Appearance") {
                Picker("Theme", selection: $themeMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Label("Bili pink accent", systemImage: "paintpalette")
            }

            Section("Playback") {
                Toggle("Danmaku by default", isOn: $danmakuEnabled)
                Toggle("Background audio", isOn: $backgroundAudio)
                Label("Playback speed: 0.5x to 2.0x", systemImage: "speedometer")
            }

            Section("Plugin Center") {
                Toggle("Today Watch", isOn: $todayWatch)
                PluginRow(title: "SponsorBlock", subtitle: "Policy surface ready for a service implementation", symbol: "forward.end")
                PluginRow(title: "AdBlock", subtitle: "Feed filter rules mirror the Kotlin plugin shape", symbol: "eye.slash")
                PluginRow(title: "Danmaku Plus", subtitle: "Keyword and density settings for the player overlay", symbol: "text.bubble")
            }
        }
        .navigationTitle("Mine")
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
