import AVFoundation
import SwiftUI

/// Floating mini-player shown when the user navigates away from
/// `VideoDetailView`. Renders the live `AVPlayerLayer` (so the user
/// sees the actual video frame, not a static thumbnail), along
/// with play/pause, expand, and close buttons. Pan down > 80pt to
/// dismiss (calls `store.close()`).
///
/// The overlay is anchored to the bottom-trailing of `RootView`,
/// above the tab bar. It's a free-floating glass card that adapts
/// to the user's `MaterialDesign` preference.
struct MiniPlayerOverlay: View {
    @EnvironmentObject private var store: MiniPlayerStore
    @EnvironmentObject private var router: AppRouter
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        if let video = store.currentVideo,
           let controller = store.controller,
           store.isShowingMiniPlayer {
            HStack(spacing: 10) {
                AVPlayerThumbnailView(player: controller.player)
                    .frame(width: 110, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cornerRadius, style: BiliPaiTheme.cornerStyle))
                    .overlay {
                        RoundedRectangle(cornerRadius: BiliPaiTheme.cornerRadius, style: BiliPaiTheme.cornerStyle)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(video.ownerName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    progressBar
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Haptics.selection()
                    store.togglePlayPause()
                } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isPlaying ? "Pause" : "Play")

                Button {
                    Haptics.tap()
                    if let video = store.currentVideo {
                        router.openVideo(video)
                    }
                    store.expand()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand to inline player")

                Button {
                    Haptics.tap()
                    store.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close mini-player")
            }
            .padding(10)
            .frame(width: 320, height: 84)
            .background {
                if materialDesign == .liquidGlass {
                    Color.clear.bilipaiCardSurface(.liquidGlass)
                } else {
                    RoundedRectangle(cornerRadius: BiliPaiTheme.cornerRadius, style: BiliPaiTheme.cornerStyle)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: BiliPaiTheme.cornerRadius, style: BiliPaiTheme.cornerStyle)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
                }
            }
            .offset(y: max(0, dragOffset))
            .gesture(
                DragGesture()
                    .onChanged { dragOffset = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height > 80 {
                            Haptics.tap()
                            store.close()
                        }
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mini player for \(video.title)")
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let total = store.duration > 0 ? store.duration : 1
            let progress = min(1, store.currentTime / total)
            ZStack(alignment: .leading) {
                RoundedRectangle(
                    cornerRadius: BiliPaiTheme.cornerRadius,
                    style: BiliPaiTheme.cornerStyle
                )
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 2)
                RoundedRectangle(
                    cornerRadius: BiliPaiTheme.cornerRadius,
                    style: BiliPaiTheme.cornerStyle
                )
                    .fill(BiliPaiTheme.biliPink)
                    .frame(width: geo.size.width * progress, height: 2)
            }
        }
        .frame(height: 2)
    }
}

/// `UIViewRepresentable` that hosts an `AVPlayerLayer` for the
/// mini-player's video frame. The custom `UIView` overrides
/// `+layerClass` so the layer is an `AVPlayerLayer` — that's the
/// cheapest way to get a real video surface inside a SwiftUI
/// overlay without wrapping the whole `AVPlayerViewController`.
private struct AVPlayerThumbnailView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        didSet {
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
        }
    }
}
