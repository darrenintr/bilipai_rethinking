import SwiftUI
import UIKit

/// SwiftUI wrapper around `AVPlayerSurfaceView`, which in turn
/// hosts the `AVPlayerLayer` owned by the shared
/// `PlayerController`.
///
/// We previously used `VLCPlayerView` (FFmpeg-based) for the
/// same role, but VLC's MP4 stack could not consume B站's
/// DASH-format manifests without manual plumbing. The new
/// `AVPlayer` + local HLS proxy path lets the system player
/// handle the manifest natively, with the proxy injecting the
/// `Referer` header on our behalf.
///
/// The `PlayerController` is created and owned by
/// `VideoDetailView` (not by this view) so the same player is
/// shared with the `FullscreenPlayerView`. The user can go
/// inline → fullscreen → inline and the playhead and play/pause
/// state stay continuous across the transition — the
/// `AVPlayer` instance stays alive; only the visible
/// `AVPlayerLayer` is moved between the inline and fullscreen
/// `UIView`s.
struct PlayerView: View {
    let playback: BiliPlayback
    let video: BiliVideo
    @ObservedObject var controller: PlayerController

    @State private var showCenterControl = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            AVPlayerSurfaceView(controller: controller, surface: .inline)

            // The inline surface gets a single play/pause control
            // (centre, large, auto-hides while playing). The
            // fullscreen overlay renders the full control set
            // (dismiss / skip / scrubber) — the inline surface is
            // already a small box on the detail screen and adding
            // 5 buttons would crowd the layout. Tapping anywhere
            // toggles the control; auto-hide matches the
            // fullscreen's behaviour for consistency.
            if showCenterControl || !controller.isPlaying {
                centerControl
                    .transition(.opacity)
            }

            // Loading overlay: a small spinner + the current
            // network read rate. The user said "show the
            // progress or the network speed is the best" — VLC
            // does not expose a buffered-fraction, so the
            // network rate (KB/s) is the only meaningful number
            // we can show while `state == .opening / .buffering`.
            if controller.isBuffering {
                loadingOverlay
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleCenterControl() }
        .onAppear {
            // Show the play/pause immediately when paused so the
            // user can resume. While playing it auto-hides 2s in.
            if !controller.isPlaying { showCenterControl = true }
            else { scheduleCenterHide() }
        }
        .onDisappear {
            hideTask?.cancel()
        }
    }

    private var centerControl: some View {
        Button {
            controller.toggle()
            toggleCenterControl()
        } label: {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.black.opacity(0.55), in: Circle())
        }
        .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
    }

    /// Spinner + KB/s readout. Drawn over the video surface but
    /// below the play/pause button so the user can still tap to
    /// pause while a load is in flight.
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
    /// 0 reads as "—" so a brand-new buffer (where VLC has not yet
    /// computed a rate) is not mistaken for a stalled connection.
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

    private func toggleCenterControl() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showCenterControl.toggle()
        }
        if showCenterControl && controller.isPlaying {
            scheduleCenterHide()
        } else {
            hideTask?.cancel()
        }
    }

    private func scheduleCenterHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showCenterControl = false
                }
            }
        }
    }
}

/// Fullscreen overlay player. Reused by `VideoDetailView` when the user
/// taps the fullscreen button — we present this inside `.fullScreenCover`
/// and render our own controls so the experience is consistent with the
/// rest of the BiliPai visual language.
///
/// Controls layout (top → bottom):
///   1. Top bar: dismiss X (large, left) + video title pill.
///   2. Centre: 5s skip back, play/pause, 5s skip forward.
///   3. Bottom bar: current time, scrubber, total time.
///
/// The previous version stacked everything in the centre of the ZStack
/// because the VStack had no frame and the inner `Spacer` collapsed
/// to zero height — making the top and bottom bars look like a single
/// cramped row in the middle of the screen. The new
/// `.frame(maxWidth: .infinity, maxHeight: .infinity)` pins the VStack
/// to the ZStack's edges so the top bar hugs the top safe area, the
/// centre controls sit in the middle, and the scrubber hugs the
/// bottom safe area.
///
/// The X button used to be a `headline` 18pt icon in a small circle —
/// easy to miss. It is now a 44pt hit target with the icon at 17pt
/// bold, sitting at the leading edge of the top bar where every
/// fullscreen player convention puts it. The tap-to-toggle lives on
/// the video layer (behind the controls), so a tap on a control
/// button is absorbed by the button and does not bubble down to
/// hide the overlay.
///
/// The `PlayerController` is created and owned by the parent
/// `VideoDetailView`, not by this view. The user can go
/// inline → fullscreen → inline and the playhead and play/pause
/// state stay continuous across the transition — the same
/// `AVPlayer` keeps playing while only the visible
/// `AVPlayerLayer`'s parent `UIView` is swapped.
struct FullscreenPlayerView: View {
    let video: BiliVideo
    let playback: BiliPlayback
    @ObservedObject var controller: PlayerController

    @Environment(\.dismiss) private var dismiss
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    /// Local mirror of the scrubber position while the user is
    /// dragging — see `scrubberBinding` for the two-source-of-truth
    /// dance with `controller.currentTime`.
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The video layer carries the tap-to-toggle. Tapping it
            // while the controls are hidden brings them back. When
            // the controls are visible, `controlsOverlay` is in
            // front and intercepts taps first — the tap on the video
            // never fires, so the user does not accidentally hide
            // the controls by tapping the centre play button.
            AVPlayerSurfaceView(controller: controller, surface: .fullscreen)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if controlsVisible {
                controlsOverlay
                    .transition(.opacity)
            }

            // Loading overlay: spinner + KB/s. Drawn on top of
            // the controls so the user always sees it during a
            // stall, even if the auto-hide task has already
            // hidden the rest of the chrome.
            if controller.isBuffering {
                loadingOverlay
                    .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            // Sync the local scrub mirror to whatever the
            // controller already knows. With the shared-controller
            // design this is the playhead the inline surface was
            // last showing — the fullscreen picks up exactly
            // where the inline left off.
            scrubValue = controller.currentTime
            scheduleControlsHide()
        }
        .onDisappear {
            hideTask?.cancel()
        }
    }

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            centerControls
            Spacer(minLength: 0)
            bottomBar
        }
        // Pin the VStack to the full ZStack so the topBar, centre, and
        // bottomBar each sit at their respective edges instead of
        // collapsing into a stacked group in the middle.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                hideTask?.cancel()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
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

            Spacer(minLength: 0)
        }
    }

    private var centerControls: some View {
        HStack(spacing: 36) {
            Spacer()

            // 5-second skip back ("past 5 seconds" in the user's
            // phrasing). 44pt hit target, system symbol at 22pt.
            Button {
                controller.skip(by: -5)
                scheduleControlsHide()
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel("Skip back 5 seconds")

            // Play/pause. The 72pt target is the largest of the
            // three centre controls and matches the AVPlayer look.
            Button {
                controller.toggle()
                scheduleControlsHide()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.black.opacity(0.6), in: Circle())
            }
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            Button {
                controller.skip(by: 5)
                scheduleControlsHide()
            } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel("Skip forward 5 seconds")

            Spacer()
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text(formatTime(isScrubbing ? scrubValue : controller.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)

            Slider(
                value: scrubberBinding,
                // `max(0.1, duration)` keeps Slider happy when the
                // media is still loading and the duration is 0 —
                // Slider's `in:` requires `lower < upper`.
                in: 0...max(0.1, controller.duration),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        // Only seek when the user lifts their finger,
                        // not on every drag tick — that would queue
                        // hundreds of seek calls per second.
                        controller.seek(to: scrubValue)
                        scheduleControlsHide()
                    }
                }
            )
            .tint(.white)

            Text(formatTime(controller.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    /// Spinner + KB/s readout for the fullscreen surface. Larger
    /// than the inline variant because the fullscreen has more
    /// room and the user is at arm's length, not a thumb-tap
    /// away.
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

    /// Format a bytes/second value into the most readable unit.
    /// 0 reads as "—" so a brand-new buffer (where VLC has not yet
    /// computed a rate) is not mistaken for a stalled connection.
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

    /// Two-source-of-truth binding for the scrubber. While the user
    /// is dragging, the slider writes to the local `scrubValue` so
    /// the thumb tracks their finger precisely. While the controller
    /// is updating the playhead on its 0.5s poll, the slider reads
    /// from `controller.currentTime` so the thumb keeps moving
    /// without the user having to release.
    private var scrubberBinding: Binding<Double> {
        Binding(
            get: { isScrubbing ? scrubValue : controller.currentTime },
            set: { newValue in
                scrubValue = newValue
            }
        )
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
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
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.18)) {
                    controlsVisible = false
                }
            }
        }
    }
}
