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
    /// `format` is kept for API parity with the previous VLC
    /// version, but AVPlayer only consumes HLS. The picker only
    /// ever offers the single HLS option (or nothing), so the
    /// `format` state does not actually drive a user choice any
    /// more.
    @State private var format: BiliLiveStreamFormat = .hls
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
            // AVPlayer can only play HLS; if anything ever
            // flips `format` to FLV (e.g. a future toggle) we
            // surface a hint and refuse to swap.  With the
            // current picker logic this branch is dead.
            guard newFormat == .hls,
                  let playback,
                  let url = playback.streams[.hls] else {
                errorMessage = "AVPlayer 暂不支持 FLV 流。"
                return
            }
            let livePlayback = BiliPlayback(
                dash: nil,
                fallbackURL: url,
                referer: playback.referer
            )
            // Re-instantiating the controller is the simplest
            // way to swap media on AVPlayer — `swapMedia` is a
            // no-op shim kept for API parity.
            controller?.tearDown()
            controller = PlayerController(playback: livePlayback)
        }
        .onDisappear {
            controller?.tearDown()
            controller = nil
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        if let controller {
            AVPlayerSurfaceView(controller: controller, surface: .standalone)
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
        // AVPlayer only consumes HLS — FLV is disabled so the
        // user cannot pick a format we cannot play.
        let available = playback.streams[.hls] != nil
            ? [BiliLiveStreamFormat.hls]
            : [BiliLiveStreamFormat]()
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
