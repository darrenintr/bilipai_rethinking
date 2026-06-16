import AVKit
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

/// Live-room playback surface.  Resolves the playback URLs on
/// appear (one network round-trip to `getRoomPlayInfo`) and
/// drives AVKit's `VideoPlayer` (a `AVPlayerViewController` in
/// SwiftUI clothing) with the HLS URL.  AVPlayer can only
/// consume HLS — the FLV path was previously handled by VLC
/// but is no longer supported, so the format toggle was
/// dropped from the toolbar.
private struct LivePlayerView: View {
    let room: BiliLiveRoom
    let repository: BiliPaiRepository

    @State private var playback: BiliLivePlayback?
    @State private var errorMessage: String?
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
                metadataPanel
            }
        }
        .navigationTitle(room.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadPlayback()
        }
        .onDisappear {
            controller?.tearDown()
            controller = nil
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        if let controller {
            // `VideoPlayer` wraps `AVPlayerViewController` and
            // gives the live room a system-standard HLS
            // transport (play / pause / time labels / AirPlay /
            // PiP).  The `AVPlayer` is the shared one on
            // `PlayerController`, so toggling between this
            // surface and any future fullscreen view keeps
            // playback continuous.
            VideoPlayer(player: controller.player)
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
            // Build the shared controller the first time
            // playback loads. AVPlayer can consume HLS natively
            // but cannot decode FLV — the FLV path was previously
            // handled by VLC. With the move to AVPlayer, the
            // controller is created from the HLS URL when the
            // room offers one. If only FLV is offered, we surface
            // a friendly error and skip controller init.
            if let hlsURL = resolved.streams[.hls] {
                if controller == nil {
                    let livePlayback = BiliPlayback(
                        dash: nil,
                        fallbackURL: hlsURL,
                        referer: resolved.referer
                    )
                    controller = PlayerController(playback: livePlayback)
                }
            } else {
                errorMessage = "该直播间仅提供 FLV 流，AVPlayer 暂不支持。请改用支持 FLV 的客户端。"
                controller = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = "直播间地址解析失败：\(error.localizedDescription)"
        }
    }
}
