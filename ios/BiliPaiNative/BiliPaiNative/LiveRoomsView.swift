import SwiftUI

struct LiveRoomsView: View {
    let repository: BiliPaiRepository

    @StateObject private var model = LiveViewModel()
    private let columns = [GridItem(.adaptive(minimum: 172), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let error = model.errorMessage {
                    ErrorBanner(message: error)
                }
                if model.isLoading && model.rooms.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if model.rooms.isEmpty {
                    ContentUnavailableView(
                        model.errorMessage == nil ? "No live rooms found" : "Live rooms unavailable",
                        systemImage: "play.tv",
                        description: Text(model.errorMessage == nil ? "Wait for more rooms to appear." : "Bilibili did not return a public live-room list for this request.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.rooms) { room in
                            LiveRoomCard(room: room)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(BiliPaiTheme.pageBackground)
        .navigationTitle("Live")
        // Tapping a `LiveRoomCard` pushes a `LiveRoute.room(room)` onto
        // the router's navigation path. `LivePlayerView` then resolves
        // the playback URLs and drives the VLC player + HLS/FLV toggle.
        .navigationDestination(for: LiveRoute.self) { route in
            switch route {
            case .room(let room):
                LivePlayerView(room: room, repository: repository)
            }
        }
        .task {
            await model.load(repository: repository)
        }
    }
}

/// Live-room playback surface. Resolves the playback URLs on appear
/// (one network round-trip to `getRoomPlayInfo`), drives
/// `VLCPlayerView` with the URL for the active format, and lets the
/// user toggle HLS ↔ FLV in the toolbar. Switching format hot-swaps
/// the underlying media on the shared `PlayerController` via
/// `swapMedia(to:referer:)` — VLC's API does not let us hot-swap a
/// media object without a brief drop, but reusing the same player
/// keeps the play/pause state and the polling timer intact.
private struct LivePlayerView: View {
    let room: BiliLiveRoom
    let repository: BiliPaiRepository

    @State private var playback: BiliLivePlayback?
    @State private var errorMessage: String?
    @State private var format: BiliLiveStreamFormat = .flv
    /// Created lazily once `playback` is loaded, because the
    /// controller's init needs the active stream URL.
    @State private var controller: PlayerController?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                playerSurface
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                if let playback {
                    formatToggle(playback: playback)
                }
                metadataPanel
            }
        }
        .navigationTitle(room.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadPlayback()
        }
        .onChange(of: format) { _, newFormat in
            // HLS ↔ FLV toggle. Use `swapMedia` rather than
            // recreating the controller so the polling timer and
            // any buffer the player has already built up survive
            // the toggle. (A live stream re-buffers from the
            // current server time on either URL anyway, so the
            // saving is small but the playback is uninterrupted
            // instead of dropping to black for a frame.)
            guard let playback, let url = playback.streams[newFormat] else { return }
            controller?.swapMedia(to: url, referer: playback.referer.absoluteString)
        }
        .onDisappear {
            controller?.tearDown()
            controller = nil
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        if let controller {
            VLCPlayerView(controller: controller)
        } else if let errorMessage {
            ContentUnavailableView(
                "无法播放该直播间",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func formatToggle(playback: BiliLivePlayback) -> some View {
        let available = BiliLiveStreamFormat.allCases.filter { playback.streams[$0] != nil }
        if available.count > 1 {
            Picker("Stream format", selection: $format) {
                ForEach(available) { fmt in
                    Text(fmt.displayName).tag(fmt)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .background(Color.black.opacity(0.85))
        }
    }

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(room.title)
                .font(.headline)
            HStack(spacing: 8) {
                Text(room.hostName)
                Text("·")
                Text(room.areaName)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("\(room.viewerCount.compactCount) watching")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BiliPaiTheme.biliPink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(BiliPaiTheme.pageBackground)
    }

    private func loadPlayback() async {
        do {
            let resolved = try await repository.livePlayback(for: room)
            playback = resolved
            // Pick the first available format — HLS is usually
            // present and easier to debug, but FLV wins on older
            // CDNs. The picker reflects only the formats actually
            // returned by the upstream.
            if let first = BiliLiveStreamFormat.allCases.first(where: { resolved.streams[$0] != nil }) {
                format = first
            }
            // Build the shared controller the first time
            // playback loads. We pick the URL of the active
            // `format`; the HLS ↔ FLV `onChange` above calls
            // `swapMedia` for later switches rather than
            // recreating the player.
            if controller == nil, let url = resolved.streams[format] {
                controller = PlayerController(
                    url: url,
                    referer: resolved.referer.absoluteString
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = "直播间地址解析失败：\(error.localizedDescription)"
        }
    }
}
