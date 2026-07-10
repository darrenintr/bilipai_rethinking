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
// Both share the `PaladalaRepository` for the network calls and
// `PlayerController` (the same one `VideoDetailView` uses) for
// playback. The Music view never instantiates its own
// `AVPlayer` — it goes through the same controller so the audio
// session, the Lock Screen now-playing info, and the
// `WatchSession` reporting all stay consistent across the
// regular video player and the music player.

struct MusicHomeView: View {
    let repository: PaladalaRepository

    @StateObject private var model = MusicViewModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    private var columns: [GridItem] {
        if horizontalSizeClass == .regular {
            return Array(
                repeating: GridItem(.flexible(), spacing: 32, alignment: .top),
                count: 2
            )
        }
        return [GridItem(.flexible(), alignment: .top)]
    }

    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let error = model.errorMessage {
                    ErrorBanner(message: error)
                }
                if model.isLoading && model.videos.isEmpty {
                    SkeletonGrid(
                        columns: horizontalSizeClass == .regular ? 2 : 1,
                        columnSpacing: 32,
                        rowSpacing: 32
                    )
                        .padding(.top, 4)
                } else if model.videos.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 32) {
                        ForEach(model.videos) { video in
                            Button {
                                Haptics.tap()
                                diagLog(.music, "MusicCard tap", details: [
                                    "bvid": video.bvid,
                                    "title": video.title
                                ])
                                router.openMusic(video)
                            } label: {
                                MusicCard(video: video)
                            }
                            .buttonStyle(PaladalaPressBounceButtonStyle())
                        }
                    }
                }
            }
            .padding(PaladalaTheme.contentPadding)
        }
        .background(Color.clear)
        .scrollIndicators(.hidden)
        .navigationTitle(L10n.music.title)
        .task {
            diagLog(.music, "MusicHomeView appeared")
        }
        .onDisappear {
            diagLog(.music, "MusicHomeView disappeared")
        }
        .task(id: "music-load") {
            // PR-A Task 9: see HomeView.task for the same
            // seed-then-load pattern. The id makes this re-fire
            // on explicit user actions, but the didBootstrap gate
            // makes it a no-op for re-appearances with cached data.
            if !model.didBootstrap {
                if let cached = await FeedCacheWarmer.shared.seedFromCache(key: "music") {
                    model.seedFromCache(cached)
                }
                model.markBootstrapped()
                LaunchMetrics.shared.mark(.firstFeedCached)
                await Task.yield()
                LaunchMetrics.shared.mark(.firstFeedNetworkStart)
                await model.load(repository: repository)
                LaunchMetrics.shared.mark(.firstFeedNetworkComplete)
            }
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
        ContentUnavailableView(
            model.errorMessage == nil ? L10n.music.empty : L10n.music.networkError,
            systemImage: "music.note.list",
            description: Text(L10n.music.emptyHint)
        )
        .frame(maxWidth: .infinity, minHeight: 260)
        .overlay(alignment: .bottom) {
            Button {
                Haptics.tap()
                Task { await model.refresh(repository: repository) }
            } label: {
                Label(L10n.common.retry, systemImage: "arrow.clockwise")
            }
            .buttonStyle(PaladalaGlassButtonStyle(materialDesign: materialDesign))
            .padding(.bottom, 24)
        }
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

    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                cover
                Text(video.duration.mmss)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.74))
                    .padding(12)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .frame(height: PaladalaTheme.borderWidth)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(video.title)
                    .font(PaladalaTheme.FontRole.headline)
                    .foregroundStyle(PaladalaTheme.ink)
                    .textCase(.uppercase)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                Text(video.ownerName)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(video.viewCount.compactCount, systemImage: "play.fill")
                    Spacer(minLength: 0)
                    Text(L10n.music.audioOnly)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(PaladalaTheme.biliPink)
                        .foregroundStyle(PaladalaTheme.ink)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.hairlineWidth
                                )
                        }
                }
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.mutedInk)
            }
            .padding(PaladalaTheme.Spacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .paladalaCardSurface(materialDesign)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if let url = video.coverURL {
            // Use `.contentMode: .fit` (NOT `.fill`) so the 1:1
            // aspect ratio actually resolves to a bounded square.
            //
            // With `.fill`, SwiftUI treats the constraint as
            // "size in both dimensions ≥ the parent's proposed
            // size, possibly overflowing".  Inside a
            // `LazyVGrid` cell the proposed height is unbounded
            // (the VStack height grows with content), so the
            // aspect-ratio modifier asks for `height ≥ ∞` while
            // maintaining 1:1 — SwiftUI gives back an unbounded
            // height and the cover stretches to fill the entire
            // VStack content area, making cards visually overlap
            // each other as the user scrolls.
            //
            // With `.fit`, the constraint becomes "size in both
            // dimensions ≤ proposed".  Width is bounded (cell
            // width minus padding) so the 1:1 ratio forces
            // height = width.  This matches how `VideoCard` and
            // `LiveRoomCard` render their covers (both use
            // `.fit`).
            ResilientImage(url: url, maximumPixelSize: 720)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            Rectangle()
                .fill(PaladalaTheme.coolGray)
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(PaladalaTheme.biliPink)
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
    let repository: PaladalaRepository

    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var playback: BiliPlayback?
    @State private var lyrics: BiliLyricTrack?
    @State private var errorMessage: String?
    /// Created lazily once `playback` is loaded.
    @State private var controller: PlayerController?

    var body: some View {
        ZStack {
            streetBackground
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                artworkSection
                    .frame(maxHeight: 320)
                metadataAndControls
                    .padding(.top, 20)
                // Only mount the lyric pane once the controller is
                // alive — `LyricScrollView` observes the controller
                // for `currentTime`, so without a controller the
                // active-line highlight would be stuck on line 0.
                if let controller {
                    LyricScrollView(
                        track: lyrics,
                        controller: controller,
                        onSeek: { [weak controller] timestamp in
                            controller?.seek(to: timestamp)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    lyricPlaceholder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PaladalaTheme.contentPadding)
            .padding(.top, PaladalaTheme.Spacing.l)
            if let errorMessage {
                errorOverlay(errorMessage)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(L10n.music.audioOnly)
                        .font(PaladalaTheme.FontRole.labelMono)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(PaladalaTheme.biliPink)
                        .foregroundStyle(PaladalaTheme.ink)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.hairlineWidth
                                )
                        }
                    Text(video.title)
                        .font(PaladalaTheme.FontRole.cardTitle)
                        .lineLimit(1)
                }
            }
        }
        .task {
            diagLog(.music, "MusicPlayerView appeared", details: [
                "bvid": video.bvid,
                "title": video.title
            ])
            await loadPlayback()
            await loadLyrics()
        }
        .onDisappear {
            diagLog(.music, "MusicPlayerView disappeared", details: [
                "bvid": video.bvid,
                "hadController": controller != nil
            ])
            controller?.tearDown()
            controller = nil
        }
    }

    /// Shown until `controller` finishes its first `refresh()` —
    /// the lyric pane has no useful state to render before the
    /// player reports its first `currentTime`.
    private var lyricPlaceholder: some View {
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

    // MARK: - View sections

    private var streetBackground: some View {
        PaladalaTheme.canvas
            .ignoresSafeArea()
    }

    private var artworkSection: some View {
        Group {
            if let url = video.coverURL {
                // See `VideoCard.coverImage` for the sizing story.
                // Same Rectangle() + .aspectRatio(1, .fit) + overlay
                // pattern — applying .aspectRatio directly to
                // `ResilientImage` (a ZStack) was the same pre-2d1105d1
                // fragile pattern. On first paint the ZStack's largest
                // child is the placeholder ProgressView, so the
                // artwork collapsed to a tiny box until the URL
                // bytes landed; with the explicit Shape container the
                // box is a deterministic 1:1 of the parent width
                // from the very first layout pass.
                Rectangle()
                    .fill(.clear)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        ResilientImage(url: url)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                    .clipShape(Rectangle())
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                    .background {
                        Rectangle()
                            .fill(PaladalaTheme.ink)
                            .offset(
                                x: PaladalaTheme.hardShadowOffset,
                                y: PaladalaTheme.hardShadowOffset
                            )
                    }
            } else {
                Rectangle()
                    .fill(PaladalaTheme.biliPink)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 80, weight: .light))
                            .foregroundStyle(.white)
                    )
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                    .background {
                        Rectangle()
                            .fill(PaladalaTheme.ink)
                            .offset(
                                x: PaladalaTheme.hardShadowOffset,
                                y: PaladalaTheme.hardShadowOffset
                            )
                    }
            }
        }
        .padding(.horizontal, 36)
    }

    private var metadataAndControls: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(PaladalaTheme.FontRole.headline)
                    .foregroundStyle(PaladalaTheme.ink)
                    .textCase(.uppercase)
                    .lineLimit(2)
                Text(video.ownerName)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 36) {
                Button {
                    Haptics.tap()
                    seek(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2.weight(.black))
                        .frame(width: 52, height: 52)
                        .background(PaladalaTheme.paper)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.borderWidth
                                )
                        }
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
                Button {
                    Haptics.tap()
                    togglePlay()
                } label: {
                    Image(systemName: (controller?.isPlaying ?? false) ? "pause.fill" : "play.fill")
                        .font(.system(size: 38, weight: .black))
                        .foregroundStyle(PaladalaTheme.ink)
                        .frame(width: 64, height: 64)
                        .background(PaladalaTheme.biliPink)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.borderWidth
                                )
                        }
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
                Button {
                    Haptics.tap()
                    seek(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title2.weight(.black))
                        .frame(width: 52, height: 52)
                        .background(PaladalaTheme.paper)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.borderWidth
                                )
                        }
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
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
                .foregroundStyle(PaladalaTheme.biliPink)
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
            .buttonStyle(PaladalaGlassButtonStyle(materialDesign: .liquidGlass))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaladalaTheme.paper)
    }

    // MARK: - Player lifecycle

    private func loadPlayback() async {
        diagLog(.music, "MusicPlayerView.loadPlayback start", details: [
            "bvid": video.bvid,
            "qn": 80
        ])
        do {
            let resolved = try await repository.playback(for: video, qn: 80)
            playback = resolved
            if controller == nil {
                controller = PlayerController(playback: resolved, video: video)
            }
            errorMessage = nil
            diagLog(.music, "MusicPlayerView.loadPlayback success", details: [
                "bvid": video.bvid,
                "isDASH": resolved.dash != nil,
                "hasFallback": false
            ])
        } catch {
            errorMessage = "\(error.localizedDescription)"
            diagLog(.music, "MusicPlayerView.loadPlayback failed", details: [
                "bvid": video.bvid,
                "error": "\(error)",
                "localized": error.localizedDescription
            ])
        }
    }

    private func loadLyrics() async {
        diagLog(.music, "MusicPlayerView.loadLyrics start", details: [
            "bvid": video.bvid
        ])
        do {
            let track = try await repository.videoLyrics(for: video)
            // Tiny delay so the user sees the loading placeholder
            // for at least a frame — otherwise the lyrics pop in
            // so fast it looks like a render bug.
            try? await Task.sleep(nanoseconds: 200_000_000)
            lyrics = track
            diagLog(.music, "MusicPlayerView.loadLyrics success", details: [
                "bvid": video.bvid,
                "lineCount": track?.lines.count ?? 0
            ])
        } catch {
            // Non-fatal: the view falls back to "no lyrics" copy.
            lyrics = nil
            diagLog(.music, "MusicPlayerView.loadLyrics failed", details: [
                "bvid": video.bvid,
                "error": "\(error)",
                "localized": error.localizedDescription
            ])
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
    /// Observed directly so the view re-renders every time the
    /// player's periodic time observer publishes a new
    /// `currentTime`. Reading the value at the call site
    /// (`controller?.currentTime ?? 0`) wouldn't subscribe
    /// SwiftUI to the `@Published` change, leaving the
    /// active-line highlight stuck on whichever line was
    /// active at first render.
    @ObservedObject var controller: PlayerController
    /// PR-5 (M5): last-seen active-line index so we only call
    /// `proxy.scrollTo` when the line actually changes.  Without
    /// this cache every `currentTime` tick (now throttled to 1 Hz
    /// but still every second) re-runs `scrollTo(id, anchor: .center)`
    /// with the same target, churning the scroll view and
    /// re-animating the active-line highlight.
    @State private var lastActiveIndex: Int?
    /// Fires when the user taps a lyric line. The owner wires
    /// this to `controller.seek(to:)` — without it the tap
    /// only flips a `@State` and never moves the playhead.
    let onSeek: (Double) -> Void

    @State private var userScrolledAt: Date?
    @State private var userSelectedLineID: Int?

    /// Reuse the bottom-line index from the track so we don't
    /// recompute on every `currentTime` tick.
    private var activeIndex: Int {
        track?.index(at: controller.currentTime) ?? 0
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
                        VStack(alignment: .leading, spacing: 14) {
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
                                    // The whole point of Apple-Music-style
                                    // lyrics: tap a line to jump there.
                                    // Without this the tap only flipped
                                    // the highlight and the user had to
                                    // slide back to the playhead.
                                    onSeek(line.startTime)
                                }
                            }
                            Color.clear.frame(height: 80)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                    }
                    .onChange(of: controller.currentTime) { _, newTime in
                        guard !isInUserSeekWindow, !track.lines.isEmpty else { return }
                        // Look up the active index for `newTime`
                        // explicitly — `activeIndex` reads from the
                        // *previous* `currentTime` until SwiftUI
                        // re-evaluates `body`, and the animation
                        // would otherwise target the wrong line.
                        let next = track.index(at: newTime)
                        if next == lastActiveIndex { return }
                        lastActiveIndex = next
                        let id = track.lines[next].id
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
            .font(isActive ? PaladalaTheme.FontRole.sectionHeader : PaladalaTheme.FontRole.body)
            .foregroundStyle(foreground)
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            .padding(.horizontal, isActive ? 8 : 0)
            .padding(.vertical, isActive ? 6 : 2)
            .background(isActive ? PaladalaTheme.biliPink : Color.clear)
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .frame(width: 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.24), value: isActive)
    }

    private var foreground: Color {
        if isActive { return PaladalaTheme.ink }
        if isSelected { return PaladalaTheme.biliPink.opacity(0.7) }
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
                // `max(0.1, …)` keeps the slider usable while
                // `duration` is still unknown (the very first
                // frame). Showing `0:00 / 0:00` would suggest the
                // track is empty; the placeholder label below
                // makes the loading state explicit.
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
                        // PR-C Task 3: 200 ms hop via structured
                        // sleep. The view is a struct so there is
                        // no `self` to retain; SwiftUI will
                        // discard the @State mutation if the
                        // view is torn down in the meantime.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            dragging = false
                        }
                    }
                }
            )
            .tint(PaladalaTheme.biliPink)

            HStack {
                Text(formatTime(dragging ? dragValue : controller.currentTime))
                Spacer()
                Text(formatDuration(controller.duration))
            }
            .font(PaladalaTheme.FontRole.labelMono)
            .foregroundStyle(PaladalaTheme.mutedInk)
            .monospacedDigit()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// Mirrors Apple's loading hint for an unknown track length.
    /// The diagnostic logs (Paladala_Diagnostic_*.txt) show the
    /// first frame after the controller init reports
    /// `duration = 0` because the AVPlayer hasn't parsed the
    /// master playlist yet; rendering that as "0:00" implied a
    /// 3-second clip on a 462-second track, which made the
    /// progress bar look broken.
    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—:—" }
        return formatTime(seconds)
    }
}

// MARK: - Liquid-glass nav bar modifier
//
// Mirrors the modifier LiveRoomsView uses for the same purpose.

private struct LiquidGlassNavBarModifier: ViewModifier {
    let materialDesign: MaterialDesign

    func body(content: Content) -> some View {
        if materialDesign == .liquidGlass {
            content.paladalaNavBarGlass(.liquidGlass)
        } else {
            content
        }
    }
}
