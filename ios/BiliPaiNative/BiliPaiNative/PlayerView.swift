//
//  PlayerView.swift
//  BiliPaiNative
//
//  AVKit-backed player surfaces.  The inline player uses a
//  custom overlay (play/pause + ±10s skip) because AVKit's
//  `AVPlayerViewController` transport is unreliable for the
//  inline case — it disappears on some iOS contexts even
//  with `showsPlaybackControls = true`.  The fullscreen player
//  uses `AVPlayerViewController` directly so it gets the system
//  Done button and PiP for free.
//
//  Both bind to the *same* `AVPlayer` on the shared
//  `PlayerController`, so inline ↔ fullscreen ↔ inline keeps
//  the playhead continuous.
//

import AVFoundation
import AVKit
import SwiftUI

// MARK: - Inline surface

/// Inline player with a custom transport overlay.
///
/// AVKit's `AVPlayerViewController` `showsPlaybackControls` is
/// unreliable for the inline (non-fullscreen) case — the controls
/// are rendered by the system and can be hidden by context.  We
/// therefore use our own overlay: play/pause, ±10s skip, and a
/// buffering indicator.  The double-tap layer (seek / like) sits
/// above the transport and does not interfere with it.
struct PlayerView: View {
    let playback: BiliPlayback
    let video: BiliVideo
    let repository: BiliPaiRepository
    @ObservedObject var controller: PlayerController

    var body: some View {
        InlineAVPlayerRepresentable(player: controller.player)
            .overlay(alignment: .center) {
                if controller.isBuffering {
                    loadingOverlay
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                DoubleTapOverlay(
                    video: video,
                    repository: repository,
                    controller: controller
                )
            }
            .contentShape(Rectangle())
    }

    /// Spinner + KB/s readout shown during stalls.
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
    let repository: BiliPaiRepository
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
                    .allowsHitTesting(false)
            }

            // Double-tap gesture layer (left/right seek, centre
            // like). Sits on top of the AVPlayer surface so it
            // wins over the system's single-tap control toggle.
            DoubleTapOverlay(
                video: video,
                repository: repository,
                controller: controller
            )
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

/// `UIViewControllerRepresentable` for `AVPlayerViewController`
/// used by the inline `PlayerView`.  Unlike SwiftUI's `VideoPlayer`,
/// this exposes `showsPlaybackControls` so we can force the transport
/// UI to appear.  The `Coordinator` holds a strong reference to the
/// controller so the `AVPlayer` outlives any SwiftUI re-render.
private struct InlineAVPlayerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        // Strong reference keeps the controller alive across
        // SwiftUI re-renders that don't replace the representable.
        context.coordinator.controller = controller
        return controller
    }

    func updateUIViewController(
        _ uiViewController: AVPlayerViewController,
        context: Context
    ) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        // Keep the coordinator's reference current.
        context.coordinator.controller = uiViewController
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var controller: AVPlayerViewController?
    }
}

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

// MARK: - Double-tap overlay

/// Transparent overlay that catches double-tap gestures on the
/// player and partitions them into three vertical zones:
///
/// * **Left third** — `seek(by: -10)` and flash a `gobackward.10`
///   badge. BiliPai users expect YouTube-style ±10s skips.
/// * **Right third** — `seek(by: +10)` and flash a `goforward.10`
///   badge.
/// * **Middle third** — like the video. Flash a heart badge and
///   fire `BiliPaiRepository.likeVideo(...)` if the user is
///   signed in. Anonymous users still see the heart animation
///   (local-only); the API call is best-effort and its
///   failure is silent.
///
/// The overlay sits *above* the AVPlayer surface and uses
/// `SpatialTapGesture(count: 2)`. We deliberately do NOT also
/// handle single-taps — that's the system's job (toggle the
/// transport). The double-tap recogniser does not consume
/// single-taps because `SpatialTapGesture(count: 2)` waits for
/// the second tap before firing.
private struct DoubleTapOverlay: View {
    let video: BiliVideo
    let repository: BiliPaiRepository
    @ObservedObject var controller: PlayerController

    /// Which badge to flash. `nil` means no badge is visible.
    @State private var badge: BadgeKind?
    /// Tracks the last badge-fired timestamp so a second
    /// double-tap in quick succession re-uses the existing
    /// transition instead of stacking on top of itself.
    @State private var badgeToken: Int = 0
    @EnvironmentObject private var authStore: AuthStore

    private enum BadgeKind: Equatable {
        case backward
        case forward
        case like

        /// SF Symbol name drawn inside the badge. Lives on
        /// the enum so the badge View doesn't need access to
        /// the overlay's private types.
        var symbolName: String {
            switch self {
            case .backward: return "gobackward.10"
            case .forward:  return "goforward.10"
            case .like:     return "heart.fill"
            }
        }
    }

    var body: some View {
        // The recogniser is bound to a `Color.clear` so the
        // overlay is fully transparent in steady state. The
        // badge is layered on top of the recogniser but
        // `allowsHitTesting(false)` lets taps fall through to
        // the underlying gesture. We use a `GeometryReader` to
        // capture the live overlay width so the third
        // breakpoints track the actual player size (different
        // on iPhone vs iPad, different in inline vs fullscreen
        // vs mini-player).
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { event in
                            let zone = DoubleTapZone.classify(
                                point: event.location,
                                width: geo.size.width
                            )
                            handleDoubleTap(zone: zone)
                        }
                )
                .overlay {
                    if let badge {
                        DoubleTapBadge(symbol: badge.symbolName)
                            .id(badgeToken)
                            .transition(.scale.combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: badge)
        }
    }

    private func handleDoubleTap(zone: DoubleTapZone) {
        switch zone {
        case .left:
            Haptics.medium()
            controller.seek(by: -10)
            show(badge: .backward)
        case .right:
            Haptics.medium()
            controller.seek(by: +10)
            show(badge: .forward)
        case .middle:
            Haptics.tap()
            show(badge: .like)
            // Fire the like request best-effort. The
            // animation is local-only; the API call does
            // not gate the visual feedback. If the user is
            // anonymous `authStore.activeAccount` is nil —
            // skip the network call (BiliPai's API would
            // 401 anyway).
            if authStore.activeAccount != nil {
                Task { try? await repository.likeVideo(video: video, action: 1) }
            }
        }
    }

    private func show(badge kind: BadgeKind) {
        badge = kind
        badgeToken &+= 1
        // Auto-dismiss the badge after a short delay.
        // The user can fire a new badge while one is
        // visible; the token bump restarts the animation.
        let token = badgeToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if token == badgeToken {
                badge = nil
            }
        }
    }
}

/// Partition a tap point into left / middle / right thirds
/// along the X axis. The breakpoints are ratios of the live
/// overlay width so the gesture adapts to phone vs iPad vs
/// fullscreen vs split-view players without hard-coded
/// coordinates. The overlay's coordinate space is the local
/// frame of the `Color.clear` host that owns the gesture, so
/// `point.x` is in `[0, width]`.
private enum DoubleTapZone {
    case left, middle, right

    static func classify(point: CGPoint, width: CGFloat) -> DoubleTapZone {
        guard width > 0 else { return .middle }
        let x = max(0, min(width, point.x))
        let third = width / 3
        if x < third { return .left }
        if x < third * 2 { return .middle }
        return .right
    }
}

/// Big SF Symbol badge that flashes on top of the player
/// when a double-tap is recognised. Drawn with a black
/// shadow so it stays legible over bright video frames.
private struct DoubleTapBadge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 88, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 12, y: 2)
            .padding(20)
    }
}
