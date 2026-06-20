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
    /// Whether the inline PiP button is wired and visible.
    /// Driven by the parent's `InlinePiPController.isPiPPossible`
    /// flag — we toggle this via a `NotificationCenter`
    /// subscription because the flag flips on the main thread
    /// without going through a SwiftUI-observable property.
    @State private var pipPossible: Bool = false
    /// Holds a strong reference to the inline PiP controller
    /// so its `AVPictureInPictureController` survives SwiftUI
    /// re-renders.  See `InlineAVPlayerView.swift` for why a
    /// strong ref is required.
    @StateObject private var pipHolder = InlinePiPHolder()
    /// Token returned by the PiP-possible observer so we can
    /// remove it on `onDisappear` (the modern non-deprecated
    /// `NotificationCenter` API requires the token).
    @State private var pipPossibleObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            // Inline AVPlayerLayer surface.  We use a custom
            // UIViewRepresentable (instead of SwiftUI's
            // `VideoPlayer`) so we can attach an
            // `AVPictureInPictureController` to the layer —
            // `VideoPlayer` hides the layer behind an
            // `AVPlayerViewController` and won't let us wire
            // PiP.  The holder retains the PiP controller so
            // the system doesn't tear down the session on
            // re-render.
            InlineAVPlayerRepresentable(
                player: controller.player,
                onPiPRequested: { triggerPiP() },
                holder: pipHolder
            )
            .onAppear {
                pipHolder.refreshPiPPossible()
                pipPossible = pipHolder.isPiPPossible
                pipPossibleObserver = NotificationCenter.default.addObserver(
                    forName: .bilipaiPiPPossibleChanged,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    pipHolder.refreshPiPPossible()
                    pipPossible = pipHolder.isPiPPossible
                }
            }
            .onDisappear {
                if let token = pipPossibleObserver {
                    NotificationCenter.default.removeObserver(token)
                    pipPossibleObserver = nil
                }
            }

            // Overlay sits ABOVE the AVPlayer surface but
            // below any future system chrome.  Custom
            // overlays (buffering, double-tap) keep their
            // previous behaviour.
            ZStack {
                if controller.isBuffering {
                    loadingOverlay
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                DoubleTapOverlay(
                    video: video,
                    repository: repository,
                    controller: controller
                )

                // PiP entry button.  Hidden until the system
                // reports PiP is possible — otherwise the
                // button looks broken when tapped.  Anchored
                // to the bottom-trailing corner so it doesn't
                // collide with the centred double-tap badges
                // or the fullscreen button (top-leading).
                if pipPossible && !controller.isPictureInPictureActive {
                    Button {
                        Haptics.tap()
                        triggerPiP()
                    } label: {
                        Image(systemName: "pip.enter")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(10)
                    .accessibilityLabel("Enter Picture in Picture")
                }
            }
        }
    }

    /// Push PiP start through the holder so it lands on the
    /// inline `AVPictureInPictureController`.  If PiP isn't
    /// possible yet (e.g. audio session is being configured),
    /// the holder logs and we silently no-op — the user can
    /// tap again once the system flips the flag.
    private func triggerPiP() {
        pipHolder.startPiP()
    }
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
        .background(
            .black.opacity(0.55),
            in: RoundedRectangle(
                cornerRadius: BiliPaiTheme.cornerRadius,
                style: BiliPaiTheme.cornerStyle
            )
        )
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

            AVPlayerSurfaceRepresentable(
                video: video,
                playback: playback,
                repository: repository,
                controller: controller
            ) {
                // Tapping outside the controls dismisses the
                // fullscreen cover, matching the "tap-to-dismiss"
                // gesture the rest of the app uses.
                dismiss()
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .safeAreaInset(edge: .top) {
            // Keep the BiliPai title pill above the system
            // transport so the user still sees which video they
            // are watching, even with AVKit's chrome. The share
            // button is anchored to the trailing edge so a long
            // video title shrinks the pill rather than clipping
            // the button off-screen.
            HStack(spacing: 8) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        .black.opacity(0.55),
                        in: RoundedRectangle(
                            cornerRadius: BiliPaiTheme.cornerRadius,
                            style: BiliPaiTheme.cornerStyle
                        )
                    )
                Spacer(minLength: 8)
                if let shareURL = video.shareURL {
                    ShareLink(
                        item: shareURL,
                        subject: Text(video.title),
                        label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(
                                    .black.opacity(0.55),
                                    in: Circle()
                                )
                        }
                    )
                    .accessibilityLabel(L10n.common.share)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
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
    let video: BiliVideo
    let playback: BiliPlayback
    let repository: BiliPaiRepository
    let controller: PlayerController
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let avController = AVPlayerViewController()
        avController.player = controller.player
        avController.showsPlaybackControls = true
        avController.videoGravity = .resizeAspect
        avController.allowsPictureInPicturePlayback = true
        avController.delegate = context.coordinator
        
        // Embed the custom overlays in the contentOverlayView.
        // This ensures they sit correctly between the video and the system controls.
        if let overlayView = avController.contentOverlayView {
            let overlay = FullscreenPlayerOverlay(
                video: video,
                repository: repository,
                controller: controller
            )
            let hostingController = UIHostingController(rootView: overlay)
            hostingController.view.backgroundColor = .clear
            context.coordinator.overlayHostingController = hostingController
            
            let view = hostingController.view!
            view.translatesAutoresizingMaskIntoConstraints = false
            overlayView.addSubview(view)
            
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
                view.widthAnchor.constraint(equalTo: overlayView.widthAnchor),
                view.heightAnchor.constraint(equalTo: overlayView.heightAnchor)
            ])
        }
        
        context.coordinator.avPlayerViewController = avController
        context.coordinator.onDismiss = onDismiss
        context.coordinator.playerController = self.controller
        
        return avController
    }

    func updateUIViewController(
        _ uiViewController: AVPlayerViewController,
        context: Context
    ) {
        if uiViewController.player !== controller.player {
            uiViewController.player = controller.player
        }
        context.coordinator.onDismiss = onDismiss
        context.coordinator.playerController = self.controller
        
        // Update the hosted SwiftUI view's state
        context.coordinator.overlayHostingController?.rootView = FullscreenPlayerOverlay(
            video: video,
            repository: repository,
            controller: controller
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        weak var avPlayerViewController: AVPlayerViewController?
        var playerController: PlayerController?
        var onDismiss: () -> Void = {}
        var overlayHostingController: UIHostingController<FullscreenPlayerOverlay>?
        
        // MARK: - AVPlayerViewControllerDelegate
        
        @MainActor
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            coordinator.animate(alongsideTransition: nil) { context in
                if !context.isCancelled {
                    self.onDismiss()
                }
            }
        }
        
        @MainActor
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            playerController?.setPiPActive(true)
        }
        
        @MainActor
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            playerController?.setPiPActive(false)
        }
        
        @MainActor
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }
    }
}

/// Extracted overlay for the fullscreen surface to be hosted
/// in AVPlayerViewController's contentOverlayView.
/// Combines the double-tap gesture, the long-press 2x speed gesture,
/// and the buffering indicator.
private struct FullscreenPlayerOverlay: View {
    let video: BiliVideo
    let repository: BiliPaiRepository
    @ObservedObject var controller: PlayerController

    @GestureState private var isLongPressing = false
    @State private var showingSpeedBadge = false

    var body: some View {
        ZStack {
            // Invisible gesture layer
            Color.clear
                .contentShape(Rectangle())
                // Long press for 2x speed
                // Using a sequence of LongPress + Drag ensures we don't steal
                // immediate single/double taps from the underlying views.
                .gesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .updating($isLongPressing) { value, state, _ in
                            switch value {
                            case .second(true, let drag):
                                state = drag != nil
                            default:
                                state = false
                            }
                        }
                )
                .onChange(of: isLongPressing) { _, isPressing in
                    if isPressing {
                        controller.setRate(2.0)
                        showingSpeedBadge = true
                        Haptics.medium()
                    } else {
                        controller.setRate(1.0)
                        showingSpeedBadge = false
                    }
                }
            
            DoubleTapOverlay(
                video: video,
                repository: repository,
                controller: controller
            )
            
            VStack {
                if showingSpeedBadge {
                    HStack {
                        Spacer()
                        Text("2.0x 快进中")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                .black.opacity(0.6),
                                in: RoundedRectangle(
                                    cornerRadius: BiliPaiTheme.cornerRadius,
                                    style: BiliPaiTheme.cornerStyle
                                )
                            )
                            .padding(.top, 40)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showingSpeedBadge)

            if controller.isBuffering {
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
                .background(
                    .black.opacity(0.6),
                    in: RoundedRectangle(
                        cornerRadius: BiliPaiTheme.cornerRadius,
                        style: BiliPaiTheme.cornerStyle
                    )
                )
                .transition(.opacity)
            }
        }
        .animation(.default, value: controller.isBuffering)
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
    /// First-launch gesture hint visibility. We start hidden
    /// and flip to `true` in `onAppear` when
    /// `didShowGestureHint` is still `false`. Auto-dismiss
    /// after 4s and on any tap. The two state values are
    /// kept separate so a SwiftUI re-evaluation that reads
    /// `didShowGestureHint` outside of an explicit user
    /// action cannot accidentally re-show the hint.
    @State private var isShowingHint: Bool = false
    /// In-flight 4s auto-dismiss task. Held so `onDisappear`
    /// can cancel it and a tap can cancel it before the
    /// sleep elapses.
    @State private var hintDismissTask: Task<Void, Never>?
    /// Persistent "did we ever show the hint" flag. Backed
    /// by `@AppStorage` so the hint appears exactly once per
    /// install, even across reinstall + iCloud restore
    /// scenarios where the OS may unmount the overlay
    /// without firing `onDisappear`.
    @AppStorage("bilipai.didShowGestureHint") private var didShowGestureHint: Bool = false
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
                // Single-tap recogniser — only used to dismiss
                // the first-launch gesture hint. Attached as a
                // `simultaneousGesture` so it does not steal
                // taps from the double-tap recogniser above
                // (SwiftUI dispatches both gestures; the
                // single-tap onEnded simply hides the hint
                // while the double-tap onEnded still runs the
                // seek/like animation).
                .simultaneousGesture(
                    TapGesture(count: 1)
                        .onEnded { dismissHint() }
                )
                .overlay {
                    if let badge {
                        DoubleTapBadge(symbol: badge.symbolName)
                            .id(badgeToken)
                            .transition(.scale.combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isShowingHint {
                        GestureHint()
                            .padding(.bottom, 28)
                            .padding(.horizontal, 20)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: badge)
                .animation(.easeInOut(duration: 0.25), value: isShowingHint)
        }
        .onAppear {
            // First-launch only. Subsequent opens read
            // `didShowGestureHint == true` and skip the
            // appearance transition entirely.
            guard !didShowGestureHint else { return }
            isShowingHint = true
            hintDismissTask?.cancel()
            hintDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                dismissHint()
            }
        }
        .onDisappear {
            // Cancelling the task prevents the closure from
            // re-running while the view is mid-tear-down —
            // without it we have observed the hint flipping
            // back to visible for one frame on the way out.
            hintDismissTask?.cancel()
            hintDismissTask = nil
            // Treat an early disappearance as a dismiss:
            // the inline DoubleTapOverlay tears down when
            // fullscreen is presented, which would cancel
            // the 4s timer before it fires. Mark the hint
            // as shown so the fullscreen overlay (or any
            // future inline re-mount) doesn't re-show it.
            if isShowingHint {
                isShowingHint = false
                didShowGestureHint = true
            }
        }
    }

    /// Persist the dismiss and tear down the in-flight
    /// auto-dismiss task. Idempotent — calling it twice in
    /// quick succession (tap + 4s timer) is a no-op the
    /// second time because the `guard isShowingHint` check
    /// short-circuits before any state writes.
    private func dismissHint() {
        guard isShowingHint else { return }
        isShowingHint = false
        // The flag is also written from `onDisappear` for
        // the early-tear-down path; writing it here too is
        // cheap and keeps the function idempotent.
        didShowGestureHint = true
        hintDismissTask?.cancel()
        hintDismissTask = nil
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

/// First-launch gesture legend shown on top of the player.
/// Surfaces the same three double-tap zones the gesture
/// recogniser handles (left = -10s, right = +10s, centre =
/// like), plus a hint about the system seek-bar. The pill
/// is non-interactive (`allowsHitTesting(false)`) so taps
/// fall through to the underlying `DoubleTapOverlay` and
/// dismiss the hint via the single-tap recogniser added in
/// the same overlay.
private struct GestureHint: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                hintIcon(symbol: "gobackward.10", title: "双击左侧", subtitle: "后退 10s")
                hintIcon(symbol: "heart.fill", title: "双击中心", subtitle: "点赞")
                hintIcon(symbol: "goforward.10", title: "双击右侧", subtitle: "前进 10s")
            }
            .font(.caption2)
            Text("底栏拖动可跳转进度")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.78))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            .black.opacity(0.6),
            in: RoundedRectangle(
                cornerRadius: BiliPaiTheme.cornerRadius,
                style: BiliPaiTheme.cornerStyle
            )
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.player.gestureHint)
    }

    /// One column in the legend. SF Symbol on top, two-line
    /// label below. Kept as a private helper so the
    /// `GestureHint` body stays scannable.
    private func hintIcon(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity)
    }
}
