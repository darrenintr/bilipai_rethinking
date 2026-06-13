import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// SwiftUI wrapper around `AVPlayerViewController`.
///
/// We use `AVPlayerViewController` rather than SwiftUI's `VideoPlayer` because
/// the system controller gives us reliable, idiomatic fullscreen / AirPlay /
/// PiP affordances on every iOS version we support, whereas the SwiftUI
/// `VideoPlayer` only exposes a fullscreen button when the parent context
/// allows it. Wrapping the controller directly also gives us a hook for
/// the custom fullscreen overlay rendered on top of the inline view.
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var allowsPictureInPicture: Bool = true

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = allowsPictureInPicture
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        // The native fullscreen button still works on tap, but we also surface
        // our own button so the affordance is obvious.
        controller.allowsVideoFrameAnalysis = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

/// Fullscreen overlay player. Reused by `VideoDetailView` when the user taps
/// the fullscreen button — we present this inside `.fullScreenCover` and
/// render our own minimal controls so the experience is consistent with the
/// rest of the BiliPai visual language.
struct FullscreenPlayerView: View {
    let video: BiliVideo
    let player: AVPlayer

    @Environment(\.dismiss) private var dismiss
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            PlayerView(player: player, allowsPictureInPicture: false)
                .ignoresSafeArea()

            if controlsVisible {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleControls()
        }
        .onAppear {
            scheduleControlsHide()
        }
        .onDisappear {
            hideTask?.cancel()
        }
    }

    private var controlsOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel("Exit fullscreen")

                Spacer()

                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
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
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.18)) {
                    controlsVisible = false
                }
            }
        }
    }
}
