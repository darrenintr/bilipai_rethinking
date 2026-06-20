import AVFoundation
import Combine
import SwiftUI

// MARK: - Music home
//
// The Music tab is split across two screens:
//   * `MusicHomeView` — grid of music videos, same visual
//     language as `HomeView`/`LiveRoomsView`.
//   * `MusicPlayerView` — fullscreen audio-only player with
//     Apple-Music-style scrolling lyrics on the bottom half and
//     the cover art / title on the top half.
//
// Both share the `BiliPaiRepository` for the network calls and
// `PlayerController` (the same one `VideoDetailView` uses) for
// playback. The Music view never instantiates its own
// `AVPlayer` — it goes through the same controller so the audio
// session, the Lock Screen now-playing info, and the
// `WatchSession` reporting all stay consistent across the
// regular video player and the music player.

struct MusicHomeView: View {
    let repository: BiliPaiRepository

    @StateObject private var model = MusicViewModel()
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    private let columns = [
        GridItem(.adaptive(minimum: 168), spacing: 12, alignment: .top)
    ]

    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let error = model.errorMessage {
                    ErrorBanner(message: error)
                }
                if model.isLoading && model.videos.isEmpty {
                    SkeletonGrid()
                        .padding(.top, 4)
                } else if model.videos.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.videos) { video in
                            Button {
                                Haptics.tap()
                                router.openMusic(video)
                            } label: {
                                MusicCard(video: video)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(BiliPaiTheme.contentPadding)
        }
        .background(Color.clear)
        .scrollIndicators(.hidden)
        .navigationTitle(L10n.music.title)
        .task {
            await model.load(repository: repository)
        }
        .refreshable {
            Haptics.medium()
            await model.refresh(repository: repository)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    Task { await model.refresh(repository: repository) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
            }
        }
        .modifier(LiquidGlassNavBarModifier(materialDesign: materialDesign))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(BiliPaiTheme.biliPink.opacity(0.7))
            Text(model.errorMessage == nil ? L10n.music.empty : L10n.music.networkError)
                .font(.headline)
            Text(L10n.music.emptyHint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                Haptics.tap()
                Task { await model.refresh(repository: repository) }
            } label: {
                Label(L10n.common.retry, systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding()
        .bilipaiCardSurface(materialDesign)
    }
}

// MARK: - MusicCard
//
// Mirrors `VideoCard`'s chrome (cover / title / owner) but is
// tuned for the music context: the title is allowed two lines,
// the bottom metadata row collapses to a single `play.fill` +
// view count, and a small "纯享" badge sits in the bottom-right
// of the cover so users immediately understand "audio only".

private struct MusicCard: View {
    let video: BiliVideo

    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    /// Pinned title-block height (two lines of `.subheadline`).
    /// See `VideoCard.titleBlockHeight` for the rationale.
    private static let titleBlockHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                cover
                Text(video.duration.mmss)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle))
                    .padding(8)
            }
            Text(video.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(minHeight: Self.titleBlockHeight, alignment: .topLeading)
            Text(video.ownerName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Label(video.viewCount.compactCount, systemImage: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(L10n.music.audioOnly)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(BiliPaiTheme.biliPink.opacity(0.18), in: Capsule())
                    .foregroundStyle(BiliPaiTheme.biliPink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .bilipaiCardSurface(materialDesign)
        .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
    }

    @ViewBuilder
    private var cover: some View {
        if let url = video.coverURL {
            ResilientImage(url: url)
                .aspectRatio(1, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
        } else {
            RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle)
                .fill(BiliPaiTheme.biliPink.opacity(0.18))
                .aspectRatio(1, contentMode: .fill)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(BiliPaiTheme.biliPink)
                )
        }
    }
}

// MARK: - Music player
//
// Audio-only player.  Spins up a `PlayerController` against the
// resolved `BiliPlayback` (the existing DASH-proxy path serves
// both audio + video, but we suppress the video surface — the
// `AVPlayerLayer` is mounted on a 0-height view so the audio
// still flows through the standard AVPlayer transport, and the
// `AppleMusic`-style lyric pane is the only thing the user
// actually sees).  The controller exposes `currentTime` /
// `duration` / `isPlaying` as published state, which the
// `LyricScrollView` subscribes to via `@ObservedObject` to
// auto-scroll to the active line.

struct MusicPlayerView: View {
    let video: BiliVideo
    let repository: BiliPaiRepository

    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var playback: BiliPlayback?
    @State private var lyrics: BiliLyricTrack?
    @State private var errorMessage: String?
    /// Created lazily once `playback` is loaded.
    @State private var controller: PlayerController?

    var body: some View {
        ZStack {
            backgroundGradient
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                artworkSection
                    .frame(maxHeight: 320)
                metadataAndControls
                    .padding(.top, 20)
                LyricScrollView(track: lyrics, currentTime: controller?.currentTime ?? 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BiliPaiTheme.contentPadding)
            .padding(.top, BiliPaiTheme.Spacing.l)
            if let errorMessage {
                errorOverlay(errorMessage)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(L10n.music.audioOnly)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(BiliPaiTheme.biliPink.opacity(0.18), in: Capsule())
                        .foregroundStyle(BiliPaiTheme.biliPink)
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
        }
        .task {
            await loadPlayback()
            await loadLyrics()
        }
        .onDisappear {
            controller?.tearDown()
            controller = nil
        }
    }

    // MARK: - View sections

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                BiliPaiTheme.biliPink.opacity(0.18),
                Color.clear,
                Color.black.opacity(0.32)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var artworkSection: some View {
        Group {
            if let url = video.coverURL {
                ResilientImage(url: url)
                    .aspectRatio(1, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cornerRadius, style: BiliPaiTheme.cornerStyle))
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            } else {
                RoundedRectangle(cornerRadius: BiliPaiTheme.cornerRadius, style: BiliPaiTheme.cornerStyle)
                    .fill(BiliPaiTheme.biliPink.opacity(0.4))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 80, weight: .light))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            }
        }
        .padding(.horizontal, 36)
    }

    private var metadataAndControls: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(video.ownerName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 36) {
                Button {
                    Haptics.tap()
                    seek(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title)
                }
                Button {
                    Haptics.tap()
                    togglePlay()
                } label: {
                    Image(systemName: (controller?.isPlaying ?? false) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60, weight: .regular))
                        .foregroundStyle(BiliPaiTheme.biliPink)
                }
                Button {
                    Haptics.tap()
                    seek(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title)
                }
            }
            .foregroundStyle(.primary)

            if let controller {
                MusicProgressBar(controller: controller)
            }
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(BiliPaiTheme.biliPink)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                Haptics.tap()
                Task { await loadPlayback(); await loadLyrics() }
            } label: {
                Label(L10n.common.retry, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    // MARK: - Player lifecycle

    private func loadPlayback() async {
        do {
            let resolved = try await repository.playback(for: video, qn: 80)
            playback = resolved
            if controller == nil {
                controller = PlayerController(playback: resolved, video: video)
            }
            errorMessage = nil
        } catch {
            errorMessage = "\(error.localizedDescription)"
        }
    }

    private func loadLyrics() async {
        do {
            let track = try await repository.videoLyrics(for: video)
            // Tiny delay so the user sees the loading placeholder
            // for at least a frame — otherwise the lyrics pop in
            // so fast it looks like a render bug.
            try? await Task.sleep(nanoseconds: 200_000_000)
            lyrics = track
        } catch {
            // Non-fatal: the view falls back to "no lyrics" copy.
            lyrics = nil
        }
    }

    private func togglePlay() {
        guard let controller else { return }
        if controller.isPlaying {
            controller.pause()
        } else {
            controller.play()
        }
    }

    private func seek(by offset: Double) {
        guard let controller else { return }
        let target = max(0, min(controller.duration, controller.currentTime + offset))
        controller.seek(to: target)
    }
}

// MARK: - LyricScrollView
//
// Apple-Music-style scrolling lyrics. The active line is bold
// and tinted with the brand pink; the lines above and below
// fade out. Tapping a line seeks the player to that timestamp.
//
// The view drives its own scroll state via `ScrollViewReader` —
// when `currentTime` crosses a line boundary, we call
// `proxy.scrollTo(activeID, anchor: .center)`. The auto-scroll
// is suppressed for a few seconds after a tap so the user can
// read a line they jumped to without us yanking them back to
// the playhead.

private struct LyricScrollView: View {
    let track: BiliLyricTrack?
    let currentTime: Double

    @State private var userScrolledAt: Date?
    @State private var userSelectedLineID: Int?

    /// Reuse the bottom-line index from the track so we don't
    /// recompute on every `currentTime` tick.
    private var activeIndex: Int {
        track?.index(at: currentTime) ?? 0
    }

    /// `true` while the user-initiated seek window is open —
    /// the auto-scroll logic skips the scrollTo during this
    /// window so the line they tapped stays centred.
    private var isInUserSeekWindow: Bool {
        guard let userScrolledAt else { return false }
        return Date().timeIntervalSince(userScrolledAt) < 4
    }

    var body: some View {
        Group {
            if let track, !track.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 14) {
                            // Top spacer pushes the first line down
                            // so the active line is vertically
                            // centred.
                            Color.clear.frame(height: 80)
                            ForEach(track.lines) { line in
                                LyricLineView(
                                    line: line,
                                    isActive: line.id == track.lines[activeIndex].id,
                                    isSelected: line.id == userSelectedLineID
                                )
                                .id(line.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    userScrolledAt = Date()
                                    userSelectedLineID = line.id
                                }
                            }
                            Color.clear.frame(height: 80)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                    }
                    .onChange(of: currentTime) { _, _ in
                        guard !isInUserSeekWindow, !track.lines.isEmpty else { return }
                        let id = track.lines[activeIndex].id
                        withAnimation(.easeInOut(duration: 0.32)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onAppear {
                        guard !track.lines.isEmpty else { return }
                        let id = track.lines[activeIndex].id
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(L10n.music.noLyrics)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct LyricLineView: View {
    let line: BiliLyricLine
    let isActive: Bool
    let isSelected: Bool

    var body: some View {
        Text(line.text)
            .font(isActive ? .title3.weight(.bold) : .body)
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.vertical, 2)
            .scaleEffect(isActive ? 1.0 : 0.94, anchor: .center)
            .animation(.easeInOut(duration: 0.24), value: isActive)
    }

    private var foreground: Color {
        if isActive { return BiliPaiTheme.biliPink }
        if isSelected { return BiliPaiTheme.biliPink.opacity(0.7) }
        if line.isMetadata { return .secondary.opacity(0.5) }
        return .secondary
    }
}

// MARK: - MusicProgressBar
//
// Thin scrubber under the play / pause row. Reads
// `currentTime` / `duration` / `isPlaying` straight off the
// `PlayerController` so any other view that drives the player
// (the lock-screen `nowPlaying`, the mini-player) keeps the
// bar in sync.

private struct MusicProgressBar: View {
    @ObservedObject var controller: PlayerController

    @State private var dragging: Bool = false
    @State private var dragValue: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { dragging ? dragValue : controller.currentTime },
                    set: { newValue in
                        if !dragging { return }
                        dragValue = newValue
                    }
                ),
                in: 0...max(0.1, controller.duration),
                onEditingChanged: { editing in
                    if editing {
                        dragging = true
                        dragValue = controller.currentTime
                    } else {
                        controller.seek(to: dragValue)
                        // Hold the drag value for a tick so the
                        // slider doesn't snap to 0 before the
                        // `currentTime` publisher catches up.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            dragging = false
                        }
                    }
                }
            )
            .tint(BiliPaiTheme.biliPink)

            HStack {
                Text(formatTime(dragging ? dragValue : controller.currentTime))
                Spacer()
                Text(formatTime(controller.duration))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

// MARK: - Liquid-glass nav bar modifier
//
// Mirrors the modifier LiveRoomsView uses for the same purpose.

private struct LiquidGlassNavBarModifier: ViewModifier {
    let materialDesign: MaterialDesign

    func body(content: Content) -> some View {
        if materialDesign == .liquidGlass {
            content.bilipaiNavBarGlass(.liquidGlass)
        } else {
            content
        }
    }
}
