import AVFoundation
import Combine
import SwiftUI

/// Single source of truth for the active video player. Hoists both
/// `PlayerController` and `WatchSession` out of `VideoDetailView`
/// so the player survives the view's dismissal: when the user taps
/// "back" (or swipes back) the inline surface goes away but the
/// `AVPlayer` keeps running, the history reporter keeps ticking,
/// and a floating mini-player surfaces at the bottom-trailing of
/// `RootView`.
///
/// Lifecycle
/// ---------
/// 1. `VideoDetailView` calls `bind(video:playback:repository:)` in
///    `.onChange(of: model.playback)`. The store creates a
///    `PlayerController` (which starts the local HLS proxy for VOD
///    DASH) and starts a `WatchSession`.
/// 2. `VideoDetailView.onDisappear` calls `detachInline()`. The
///    store flips `isShowingMiniPlayer` to `true`; the player keeps
///    playing. The `MiniPlayerOverlay` becomes visible.
/// 3. The user taps the mini-player; `MiniPlayerOverlay` calls
///    `router.openVideo(currentVideo)` which re-pushes the video
///    onto the navigation path. `VideoDetailView` re-mounts and
///    re-binds. `bind` is idempotent: if `currentVideo.id` matches
///    and the controller is alive, the store skips the rebuild, so
///    the playhead is continuous and `progress=0` is not re-fired.
/// 4. The user taps the mini-player's "X" — `close()` tears down the
///    controller and the watch session. The local HLS proxy is
///    stopped, and `isShowingMiniPlayer` flips back to `false`.
@MainActor
final class MiniPlayerStore: ObservableObject {
    @Published private(set) var currentVideo: BiliVideo?
    @Published private(set) var controller: PlayerController?
    @Published private(set) var isShowingMiniPlayer: Bool = false

    /// Mirror of the controller's `@Published` state so SwiftUI
    /// views observing the store can react to playhead changes
    /// without holding a direct reference to the controller.
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying: Bool = true
    @Published private(set) var isBuffering: Bool = false
    @Published private(set) var networkSpeed: Double = 0

    private var watchSession: WatchSession?
    private var cancellables: Set<AnyCancellable> = []

    /// Bind a new playback to the store. Idempotent: if the same
    /// video is already bound, the call returns without rebuilding
    /// the controller or re-firing `WatchSession.start()`.
    func bind(video: BiliVideo, playback: BiliPlayback, repository: PaladalaRepository) {
        if let current = currentVideo,
           current.id == video.id,
           let existing = controller,
           hasResolvedDuration(existing) {
            // The controller is already bound to the same video.
            // Keep the existing controller and the existing watch
            // session (don't double-report `progress=0`).
            diagLog(.playback, "MiniPlayerStore.bind: idempotent re-bind", details: ["videoID": video.id])
            return
        }

        // Switching to a different video (or first bind). Tear down
        // any previous controller first so the local HLS proxy is
        // free to be re-served with the new DASH source.
        teardownController()

        let newController = PlayerController(playback: playback, video: video)
        controller = newController
        currentVideo = video

        // Mirror the controller's @Published state into the store.
        // `objectWillChange` would be more efficient but Combine
        // makes it tricky to fold multiple sources into a single
        // stream, and a 4-state mirror is cheap enough.
        cancellables.removeAll()
        cancellables.insert(
            newController.$currentTime
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.currentTime = $0 }
        )
        cancellables.insert(
            newController.$duration
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.duration = $0 }
        )
        cancellables.insert(
            newController.$isPlaying
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.isPlaying = $0 }
        )
        cancellables.insert(
            newController.$isBuffering
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.isBuffering = $0 }
        )
        cancellables.insert(
            newController.$networkSpeed
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.networkSpeed = $0 }
        )

        // Start the history reporter. WatchSession reads
        // `currentTime` and `isPlaying` from the controller every
        // 30 seconds.
        let session = WatchSession(
            repository: repository,
            aid: video.aid,
            cid: video.cid,
            getCurrentSeconds: { [weak newController] in newController?.currentTime ?? 0 },
            isActive: { [weak newController] in newController?.isPlaying ?? false }
        )
        session.start()
        watchSession = session
        diagLog(.playback, "MiniPlayerStore.bind: created new controller", details: ["videoID": video.id])
    }

    /// Called by `VideoDetailView.onDisappear` (outside the
    /// fullscreen grace window) to surface the mini-player. The
    /// controller keeps running; only the inline surface goes
    /// away.
    ///
    /// If the user has disabled `miniPlayerOnExit` in
    /// `ProfileSettingsView` we tear the controller down
    /// instead — the user explicitly opted out, so leaving the
    /// video screen should fully stop playback, not leave a
    /// floating window behind.
    func detachInline() {
        guard controller != nil else { return }
        guard !isShowingMiniPlayer else { return }
        if UserDefaults.standard.bool(forKey: "paladala.miniPlayerOnExit") == false {
            // Default is "on" — `@AppStorage` writes `true` on
            // first toggle but leaves the key absent otherwise.
            // Treat the absent state as "on" so existing users
            // don't suddenly lose the mini-player after the
            // upgrade. `bool(forKey:)` returns `false` for an
            // absent key, which is exactly the behaviour we
            // want.
            diagLog(.playback, "MiniPlayerStore.detachInline: miniPlayerOnExit=false → teardown")
            teardownController()
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isShowingMiniPlayer = true
        }
    }

    /// User tapped the mini-player's "X". Tear down the controller
    /// and stop the watch session. The local HLS proxy is shut
    /// down inside `PlayerController.tearDown()`.
    func close() {
        teardownController()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isShowingMiniPlayer = false
        }
    }

    /// User tapped the mini-player to expand back into the inline
    /// surface. We just flip the flag; the parent's navigation
    /// push re-mounts `VideoDetailView` which calls `bind` (which
    /// is idempotent).
    func expand() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isShowingMiniPlayer = false
        }
    }

    func play() {
        controller?.player.play()
    }

    func pause() {
        controller?.player.pause()
    }

    func togglePlayPause() {
        guard let player = controller?.player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func seek(to seconds: Double) {
        guard let player = controller?.player else { return }
        let target = max(0, min(seconds, duration))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func teardownController() {
        watchSession?.stop()
        watchSession = nil
        controller?.tearDown()
        controller = nil
        cancellables.removeAll()
        currentVideo = nil
        currentTime = 0
        duration = 0
        isPlaying = true
        isBuffering = false
        networkSpeed = 0
    }

    /// True when the controller's player item has a finite, non-NaN
    /// duration. Used by `bind` to decide whether a re-bind of the
    /// same video can skip rebuilding the controller — if the
    /// duration has resolved, the controller is fully primed and the
    /// re-bind would just no-op. If it's still `.nan` / `.zero`
    /// (typical for the first ~250 ms after binding to a new
    /// playback), the caller wants to be sure we get a fresh
    /// controller on the next opportunity, so we treat the existing
    /// one as "not yet ready" and fall through to the rebuild path.
    private func hasResolvedDuration(_ controller: PlayerController) -> Bool {
        guard let seconds = controller.player.currentItem?.asset.duration.seconds else {
            return false
        }
        return seconds.isFinite && seconds > 0
    }
}
