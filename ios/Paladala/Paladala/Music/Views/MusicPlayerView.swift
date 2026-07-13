import AVFoundation
import Combine
import SwiftUI

// MARK: - Music player
//
// Moved from MusicHomeView.swift as part of the music section
// reintroduction (Phase 0b — directory regrouping). Behaviour is
// byte-for-byte identical to the original; only the file location
// and the file-level documentation header changed.
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