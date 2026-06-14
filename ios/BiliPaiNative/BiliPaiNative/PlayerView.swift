import SwiftUI
import UIKit

/// SwiftUI wrapper around `VLCPlayerView`, which in turn hosts a
/// `VLCMediaPlayer` from MobileVLCKit.
///
/// We moved off `AVPlayerViewController` in commit 5f1d9f2d because the
/// official iOS player chokes on Bilibili's custom `Referer`-gated DASH
/// manifests, whereas VLC's FFmpeg-based pipeline negotiates the headers
/// transparently. `VLCPlayerView` keeps a single `VLCMediaPlayer` alive
/// for the lifetime of the `BiliPlayback` and exposes only the play /
/// pause controls we actually need in the inline surface.
struct PlayerView: View {
    let playback: BiliPlayback
    @Binding var isPlaying: Bool

    init(playback: BiliPlayback, isPlaying: Binding<Bool> = .constant(true)) {
        self.playback = playback
        self._isPlaying = isPlaying
    }

    var body: some View {
        VLCPlayerView(
            url: playback.videoURL,
            referer: "https://www.bilibili.com",
            isPlaying: $isPlaying
        )
    }
}

/// Fullscreen overlay player. Reused by `VideoDetailView` when the user taps
/// the fullscreen button — we present this inside `.fullScreenCover` and
/// render our own minimal controls so the experience is consistent with the
/// rest of the BiliPai visual language.
///
/// Controls include a top bar (dismiss + title) and a bottom bar (large
/// play/pause, scrubber). Tapping anywhere on the player surface toggles
/// the controls; the X button stays usable even when the controls are
/// visible because the tap-to-toggle is wired with `.simultaneousGesture`
/// (a plain `.onTapGesture` on the ZStack would steal the button tap on
/// the same hit-test region — that was the source of the "can't get out of
/// fullscreen" bug).
struct FullscreenPlayerView: View {
    let video: BiliVideo
    let playback: BiliPlayback

    @Environment(\.dismiss) private var dismiss
    @State private var isPlaying = true
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerView(playback: playback, isPlaying: $isPlaying)
                .ignoresSafeArea()

            if controlsVisible {
                controlsOverlay
                    .transition(.opacity)
            } else {
                tapToShowHint
                    .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .contentShape(Rectangle())
        // `.simultaneousGesture` lets button taps inside the overlay still
        // register instead of being eaten by the background tap-to-toggle.
        .simultaneousGesture(
            TapGesture().onEnded { toggleControls() }
        )
        .onAppear {
            scheduleControlsHide()
        }
        .onDisappear {
            hideTask?.cancel()
        }
    }

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                hideTask?.cancel()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel("Exit fullscreen")

            Text(video.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())

            Spacer()
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 24) {
            Spacer()

            Button {
                isPlaying.toggle()
                if controlsVisible { scheduleControlsHide() }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Spacer()
        }
    }

    private var tapToShowHint: some View {
        VStack {
            Spacer()
            Text("Tap to show controls")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // The hint must not block the tap-to-show gesture.
        .allowsHitTesting(false)
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            controlsVisible.toggle()
        }
        if controlsVisible {
            scheduleControlsHide()
        } else {
            hideTask?.cancel()
        }
    }

    private func scheduleControlsHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.18)) {
                    controlsVisible = false
                }
            }
        }
    }
}
