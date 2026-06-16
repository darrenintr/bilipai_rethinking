//
//  PlayerView.swift
//  BiliPaiNative
//
//  AVKit-backed player surfaces.  The previous version of this
//  file hand-rolled the inline and fullscreen controls (play /
//  pause / scrubber / 5s skip / loading overlay) on top of an
//  `AVPlayerLayer` mounted by `AVPlayerSurfaceView`.  That code
//  had two problems the user reported in build 81:
//
//    1. The custom `Slider` for the fullscreen scrubber could
//       drive the playhead past a valid range and crash the
//       app when AVPlayer refused the seek.
//    2. The whole overlay was 430+ lines of brittle custom
//       state (auto-hide, tap-to-toggle, two-source-of-truth
//       scrubber binding) that AVKit's transport already does
//       for free.
//
//  Both surfaces now use AVKit's system UI:
//    * Inline  → SwiftUI `VideoPlayer` (wraps `AVPlayerViewController`).
//    * Fullscreen → `AVPlayerViewController` in a `UIViewControllerRepresentable`,
//      which gives the system "Done" button that SwiftUI's
//      `VideoPlayer` lacks.
//
//  Both bind to the *same* `AVPlayer` on the shared
//  `PlayerController`, so inline ↔ fullscreen ↔ inline keeps
//  the playhead continuous (the user wanted this preserved when
//  we moved from VLC → AVPlayer in build 80).
//
//  We keep a small loading overlay (spinner + KB/s) on top of
//  the system UI because the user explicitly asked for the
//  network rate to be surfaced during stalls.
//

import AVFoundation
import AVKit
import SwiftUI

// MARK: - Inline surface

/// SwiftUI `VideoPlayer` wrapper for the inline detail view.  The
/// system provides play / pause / scrubber / time labels /
/// AirPlay / PiP.  The custom code is just the loading overlay.
struct PlayerView: View {
    let playback: BiliPlayback
    let video: BiliVideo
    @ObservedObject var controller: PlayerController

    var body: some View {
        VideoPlayer(player: controller.player)
            .overlay(alignment: .center) {
                if controller.isBuffering {
                    loadingOverlay
                        .transition(.opacity)
                }
            }
    }

    /// Spinner + KB/s readout.  Drawn on top of the system
    /// transport so the user sees it during a stall, even if
    /// they have already hidden the system controls.
    private var loadingOverlay: some View {
        VStack(spacing: 6) {
            ProgressView()
                .tint(.white)
                .controlSize(.regular)
            Text(formatNetworkSpeed(controller.networkSpeed))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading video")
    }

    /// Format a bytes/second value into the most readable unit.
    /// 0 reads as "—" so a brand-new buffer (where AVPlayer has
    /// not yet computed a rate) is not mistaken for a stalled
    /// connection.
    private func formatNetworkSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

// MARK: - Fullscreen surface

/// Fullscreen overlay player.  We present this inside
/// `.fullScreenCover` from `VideoDetailView` and let AVKit drive
/// the controls — there is no BiliPai-branded scrubber, no
/// custom auto-hide, no tap-to-toggle.  AVKit's
/// `AVPlayerViewController` brings a system "Done" button (which
/// the SwiftUI `VideoPlayer` does not), AirPlay routing, and
/// optional Picture-in-Picture for free.  Seek failures are
/// handled inside AVKit by clamping the scrubber to a valid
/// range — the build-81 crash from `Slider.onEditingChanged`
/// driving `player.seek(to:)` past the end of the playable
/// bytes is no longer reachable.
///
/// The `PlayerController` is owned by `VideoDetailView`; this
/// view only binds the existing `AVPlayer` into an
/// `AVPlayerViewController`, so the playhead and play / pause
/// state stay continuous across inline ↔ fullscreen.
struct FullscreenPlayerView: View {
    let video: BiliVideo
    let playback: BiliPlayback
    @ObservedObject var controller: PlayerController

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AVPlayerSurfaceRepresentable(player: controller.player) {
                // Tapping outside the controls dismisses the
                // fullscreen cover, matching the "tap-to-dismiss"
                // gesture the rest of the app uses.
                dismiss()
            }
            .ignoresSafeArea()

            if controller.isBuffering {
                loadingOverlay
                    .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .safeAreaInset(edge: .top) {
            // Keep the BiliPai title pill above the system
            // transport so the user still sees which video they
            // are watching, even with AVKit's chrome.
            HStack {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    /// Spinner + KB/s readout for the fullscreen surface.
    /// Same shape as the inline overlay, sized up because
    /// fullscreen has more room.
    private var loadingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
                .controlSize(.large)
            Text(formatNetworkSpeed(controller.networkSpeed))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading video")
    }

    private func formatNetworkSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

// MARK: - UIKit bridge

/// `UIViewControllerRepresentable` for `AVPlayerViewController`,
/// used by `FullscreenPlayerView`.  SwiftUI's `VideoPlayer`
/// already wraps this class for the inline case, but it does
/// not expose the system "Done" button that `.fullScreenCover`
/// callers expect — going one layer down gives us the
/// `doneButton` (and `enterFullScreen`/`exitFullScreen` /
/// AirPlay / PiP for free if we ever need them).
///
/// We hold a strong reference to the controller in the
/// `Coordinator` so the `AVPlayer` outlives any SwiftUI
/// re-render of the representable.  When the view is replaced
/// the controller's `viewController` weak ref goes nil and the
/// next `updateUIViewController` no-ops.  The
/// `PlayerController` itself is owned by `VideoDetailView` and
/// torn down on `onDisappear`.
private struct AVPlayerSurfaceRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        // `entersFullScreenWhenPlaybackBeginsOnTouch` defaults
        // to true on iPhone.  Leave it on; we are already in a
        // `fullScreenCover` so the system will simply no-op the
        // toggle.
        context.coordinator.controller = controller
        context.coordinator.onDismiss = onDismiss
        return controller
    }

    func updateUIViewController(
        _ uiViewController: AVPlayerViewController,
        context: Context
    ) {
        // The `AVPlayer` is stable for the lifetime of the
        // representable; no-op the update path.
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        context.coordinator.onDismiss = onDismiss
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var controller: AVPlayerViewController?
        var onDismiss: () -> Void = {}
    }
}
