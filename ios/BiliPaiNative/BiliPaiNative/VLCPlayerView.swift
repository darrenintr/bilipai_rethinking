import SwiftUI
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// Owns a `VLCMediaPlayer` and exposes the bits the SwiftUI side needs:
/// a published `isPlaying` flag, the playhead `currentTime` and total
/// `duration` in seconds, plus `skip`/`seek`/`toggle` commands.
///
/// The player view itself (`VLCPlayerView`) is a thin `UIViewRepresentable`
/// that hands the media player to the controller in `makeUIView` and
/// forwards play/pause updates from the controller on every SwiftUI
/// re-render. Centralising state in a controller means the fullscreen
/// overlay (skip / scrub / play-pause) and the inline surface share one
/// truth source and can stay simple value-typed views.
@MainActor
final class PlayerController: ObservableObject {
    /// Playhead position in seconds. Updated by `refresh()` on a 0.5s
    /// poll — `VLCMediaPlayer.time` is KVO-observable but a Timer is
    /// simpler and 2Hz is plenty for a progress bar.
    @Published private(set) var currentTime: Double = 0
    /// Total media length in seconds. 0 while the media is still
    /// parsing — the scrubber clamps to 0.1 to avoid a divide-by-zero
    /// in `Slider`'s `in:` parameter.
    @Published private(set) var duration: Double = 0
    /// `true` when the media should be playing. SwiftUI controls mutate
    /// this binding; the VLCPlayerView's `updateUIView` reconciles it
    /// against the underlying `mediaPlayer.isPlaying` (VLC can pause
    /// on its own when buffering or hitting EOF).
    @Published var isPlaying: Bool = true

    /// Weak so the controller never extends the media player's life —
    /// the player is owned by `VLCPlayerView.Coordinator` and freed
    /// when SwiftUI tears the representable down.
    #if canImport(MobileVLCKit)
    fileprivate weak var mediaPlayer: VLCMediaPlayer?
    #endif
    private var pollTimer: Timer?

    init() {}

    #if canImport(MobileVLCKit)
    /// Called by `VLCPlayerView.makeUIView` once the underlying
    /// `VLCMediaPlayer` exists. Starts the playhead poll.
    fileprivate func attach(_ player: VLCMediaPlayer) {
        mediaPlayer = player
        startPolling()
    }
    #endif

    /// Called from `FullscreenPlayerView.onDisappear` so the 0.5s
    /// poll timer stops when the overlay is dismissed. Safe to call
    /// multiple times.
    func detach() {
        stopPolling()
        #if canImport(MobileVLCKit)
        mediaPlayer = nil
        #endif
    }

    deinit {
        // `Timer.invalidate()` is thread-safe; the controller itself
        // is @MainActor-isolated so the published properties stay
        // consistent, but the timer holds a closure that dispatches
        // back to the main actor and reads `mediaPlayer` (which is
        // already nil by the time deinit runs on the main actor).
        pollTimer?.invalidate()
    }

    func play() {
        #if canImport(MobileVLCKit)
        mediaPlayer?.play()
        #endif
    }

    func pause() {
        #if canImport(MobileVLCKit)
        mediaPlayer?.pause()
        #endif
    }

    /// Flip the published `isPlaying` and reflect it in the underlying
    /// player. The next `refresh()` tick will reconcile any drift
    /// (e.g. VLC auto-paused on buffering).
    func toggle() {
        isPlaying.toggle()
        if isPlaying { play() } else { pause() }
    }

    /// Skip the playhead by `seconds` (positive or negative), clamped
    /// to `[0, duration]`. Used by the 5-second skip buttons in the
    /// fullscreen overlay.
    func skip(by seconds: Double) {
        #if canImport(MobileVLCKit)
        guard let player = mediaPlayer else { return }
        // `media` is optional on `VLCMediaPlayer`; nil means no media
        // is loaded yet (e.g. tap arrived during the first
        // `play()`). Treat as 0 length in that case so a positive
        // skip is clamped to 0 instead of crashing.
        let totalMs = max(0, player.media?.length.intValue ?? 0)
        let currentMs = player.time.intValue
        let raw = Double(currentMs) + seconds * 1000
        let clampedMs = Int32(min(Double(totalMs), max(0, raw)))
        player.time = VLCTime(int: clampedMs)
        currentTime = Double(clampedMs) / 1000
        #endif
    }

    /// Seek to an absolute time in seconds, clamped to `[0, duration]`.
    /// Called when the user releases the scrubber — see
    /// `FullscreenPlayerView` for the debounce logic.
    func seek(to seconds: Double) {
        #if canImport(MobileVLCKit)
        guard let player = mediaPlayer else { return }
        let totalSeconds = max(0, Double(player.media?.length.intValue ?? 0) / 1000)
        let target = min(totalSeconds, max(0, seconds))
        let targetMs = Int32(target * 1000)
        player.time = VLCTime(int: targetMs)
        currentTime = target
        #endif
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        #if canImport(MobileVLCKit)
        guard let player = mediaPlayer else { return }
        let ms = player.time.intValue
        if ms >= 0 {
            currentTime = Double(ms) / 1000
        }
        // `media` is optional on `VLCMediaPlayer`; skip the duration
        // update when nil so the scrubber keeps its last-known value
        // (typically 0) instead of briefly showing NaN.
        let length = player.media?.length.intValue ?? 0
        if length > 0 {
            duration = Double(length) / 1000
        }
        if player.isPlaying != isPlaying {
            isPlaying = player.isPlaying
        }
        #endif
    }
}

/// A robust FFmpeg-based player view using MobileVLCKit.
/// This replaces AVPlayer to support Bilibili's DASH streams and custom headers.
struct VLCPlayerView: UIViewRepresentable {
    let url: URL
    let referer: String
    @ObservedObject var controller: PlayerController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black

        #if canImport(MobileVLCKit)
        let mediaPlayer = VLCMediaPlayer()
        mediaPlayer.drawable = view

        let media = VLCMedia(url: url)
        // Add Bilibili-specific headers to bypass CDN protection
        media.addOptions([
            "http-referrer": referer,
            "http-user-agent": "bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)"
        ])

        mediaPlayer.media = media
        context.coordinator.mediaPlayer = mediaPlayer
        context.coordinator.lastBoundURL = url
        controller.attach(mediaPlayer)

        if controller.isPlaying {
            mediaPlayer.play()
        }
        #else
        let label = UILabel()
        label.text = "VLCKit not linked — live playback is unavailable in this build."
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
        #endif

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        #if canImport(MobileVLCKit)
        guard let mediaPlayer = context.coordinator.mediaPlayer else { return }

        // Hot-swap media when the URL changes (VOD → VOD, VOD → live,
        // HLS ↔ FLV toggle in `LivePlayerView`). VLC's API requires
        // `stop()` + reassign `media` — a plain `play()` after a media
        // change is a no-op. The URL diff guards against rebuilding
        // the media on every SwiftUI re-render.
        if context.coordinator.lastBoundURL != url {
            mediaPlayer.stop()
            let media = VLCMedia(url: url)
            media.addOptions([
                "http-referrer": referer,
                "http-user-agent": "bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)"
            ])
            mediaPlayer.media = media
            context.coordinator.lastBoundURL = url
        }

        if controller.isPlaying && !mediaPlayer.isPlaying {
            mediaPlayer.play()
        } else if !controller.isPlaying && mediaPlayer.isPlaying {
            mediaPlayer.pause()
        }
        #endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        #if canImport(MobileVLCKit)
        var mediaPlayer: VLCMediaPlayer?
        var lastBoundURL: URL?
        #endif
    }
}
