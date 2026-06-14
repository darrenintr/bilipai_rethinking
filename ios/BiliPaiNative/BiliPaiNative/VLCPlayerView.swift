import SwiftUI
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

enum PlayerDrawableSurface: String {
    case inline
    case fullscreen
    case standalone
}

/// Owns a `VLCMediaPlayer` for its entire lifetime and exposes the
/// bits the SwiftUI side needs: the playhead `currentTime`, total
/// `duration`, the play/pause flag, the buffering indicator, and the
/// network read rate. Also owns `skip`/`seek`/`toggle` commands.
///
/// The `VLCPlayerView` representable is a thin wrapper that points
/// the player's `drawable` at a `UIView` and releases it on
/// dismantle. Hoisting ownership of the `VLCMediaPlayer` up to the
/// controller is what lets the inline `PlayerView` and the
/// `FullscreenPlayerView` share one player — when the user goes
/// fullscreen, the inline `UIView` is dismantled and the fullscreen
/// one is created, but the underlying player (and its playhead /
/// play-pause state) keeps playing across the handoff. The user
/// expects the same video to keep going at the same timestamp
/// whether or not the fullscreen is up.
///
/// Centralising state in a controller also means the fullscreen
/// overlay (skip / scrub / play-pause) and the inline surface share
/// one truth source and can stay simple value-typed views.
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
    /// this binding; the polling `refresh()` reconciles it against
    /// `mediaPlayer.isPlaying` (VLC can pause on its own when
    /// buffering or hitting EOF).
    @Published var isPlaying: Bool = true
    /// `true` while VLC is opening the network stream or buffering
    /// frames. Drives the loading-spinner overlay in both
    /// `PlayerView` and `FullscreenPlayerView`.
    @Published private(set) var isBuffering: Bool = false
    /// Network read rate in bytes/second. 0 when idle. Sourced
    /// from `VLCMedia.statistics.inputBitrate` on each 0.5s poll
    /// so the value the user sees is at most half a second stale.
    /// The loading overlay formats this as KB/s or MB/s.
    ///
    /// `VLCMediaPlayer` itself does not expose a `statistics`
    /// property — the stats live on the underlying `VLCMedia`.
    /// `inputBitrate` is in bits per second (VLC's C struct uses
    /// `int32_t`); we divide by 8 to convert to bytes/second
    /// before publishing.
    @Published private(set) var networkSpeed: Double = 0

    #if canImport(MobileVLCKit)
    /// Strong ownership of the media player. The controller
    /// outlives both the inline and the fullscreen `UIView`s, so
    /// the player keeps decoding across the inline ↔ fullscreen
    /// transition — only the drawable (the visible `UIView`) is
    /// swapped when the user enters / leaves fullscreen.
    let mediaPlayer: VLCMediaPlayer
    #endif
    /// Weak ref to whichever `UIView` is currently the player's
    /// drawable. Tracked only so `detach(currentView:)` can clear
    /// the drawable only if it still belongs to the view that
    /// called detach — the inline view detaching must not wipe a
    /// fullscreen view that just took over the drawable.
    private weak var attachedView: UIView?
    private var preferredSurface: PlayerDrawableSurface = .standalone
    private var attachedSurface: PlayerDrawableSurface?
    private var pollTimer: Timer?

    init(url: URL, referer: String) {
        diagLog(.playback, "Initializing PlayerController", details: ["url": url.absoluteString])
        #if canImport(MobileVLCKit)
        let player = VLCMediaPlayer()
        let media = VLCMedia(url: url)
        // Bilibili's CDN gates the DASH / FLV manifests on these
        // headers; without them the upstream returns 403.
        media.addOptions([
            "http-referrer": referer,
            "http-user-agent": "bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)"
        ])
        player.media = media
        self.mediaPlayer = player
        // Start playback as soon as the controller exists — even
        // before any `UIView` is attached. The audio plays in the
        // background; when the first view attaches the frames just
        // start landing on it. This is what makes the inline ↔
        // fullscreen handoff seamless.
        if isPlaying {
            player.play()
        }
        #endif
        startPolling()
    }

    #if canImport(MobileVLCKit)
    /// Hot-swap the underlying media without dropping controller
    /// state. Used by the live format toggle (HLS ↔ FLV in
    /// `LivePlayerView`). VLC's API requires `stop()` + reassign
    /// `media` to actually start a new URL — a plain `play()`
    /// after a media change is a no-op.
    func swapMedia(to url: URL, referer: String) {
        mediaPlayer.stop()
        let media = VLCMedia(url: url)
        media.addOptions([
            "http-referrer": referer,
            "http-user-agent": "bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)"
        ])
        mediaPlayer.media = media
        if isPlaying {
            mediaPlayer.play()
        }
    }
    #endif

    func preferDrawableSurface(_ surface: PlayerDrawableSurface) {
        preferredSurface = surface
        diagLog(.playback, "Preferred drawable surface changed", details: ["surface": surface.rawValue])
    }

    /// Make `view` the player's drawable. Safe to call multiple
    /// times — re-attaching the same view (e.g. on every SwiftUI
    /// re-render) just re-points the property. This is what
    /// makes the inline ↔ fullscreen handoff work: the inline
    /// view re-claims the drawable after the fullscreen is
    /// dismissed.
    func attach(drawable view: UIView, surface: PlayerDrawableSurface) {
        guard surface == .standalone || surface == preferredSurface else {
            diagLog(.playback, "Drawable attach ignored for inactive surface", details: [
                "surface": surface.rawValue,
                "preferred": preferredSurface.rawValue,
                "view": String(describing: view)
            ])
            return
        }
        if attachedView === view, attachedSurface == surface {
            return
        }
        #if canImport(MobileVLCKit)
        let previousView = attachedView
        let previousSurface = attachedSurface
        let isSurfaceSwap = previousView != nil && (previousView !== view || previousSurface != surface)
        let shouldResumeAfterSwap = isSurfaceSwap && (mediaPlayer.isPlaying || isPlaying)

        diagLog(.playback, "Attaching drawable", details: [
            "surface": surface.rawValue,
            "view": String(describing: view),
            "isSurfaceSwap": isSurfaceSwap,
            "wasPlaying": shouldResumeAfterSwap
        ])

        if isSurfaceSwap {
            mediaPlayer.drawable = nil
        }
        attachedView = view
        attachedSurface = surface
        mediaPlayer.drawable = view

        if shouldResumeAfterSwap {
            refreshRenderingAfterDrawableSwap(surface: surface)
        }
        #endif
    }

    #if canImport(MobileVLCKit)
    /// MobileVLCKit can keep decoding audio while failing to repaint
    /// after its drawable moves from the inline view to the fullscreen
    /// view. A short pause/play after a real surface swap forces the
    /// renderer to bind to the newly attached UIView without resetting
    /// the media or losing the playhead.
    private func refreshRenderingAfterDrawableSwap(surface: PlayerDrawableSurface) {
        diagLog(.playback, "Refreshing VLC rendering after drawable swap", details: ["surface": surface.rawValue])
        mediaPlayer.pause()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            guard self.attachedSurface == surface else {
                diagLog(.playback, "Skipped render refresh for stale surface", details: [
                    "surface": surface.rawValue,
                    "attachedSurface": self.attachedSurface?.rawValue ?? "none"
                ])
                return
            }
            self.mediaPlayer.play()
            self.isPlaying = true
            diagLog(.playback, "VLC rendering refresh completed", details: ["surface": surface.rawValue])
        }
    }
    #endif

    /// Release the drawable if it still belongs to the calling
    /// view. Passing `currentView` is what makes the inline ↔
    /// fullscreen handoff safe: the inline view's dismantle can
    /// not wipe the fullscreen view's drawable claim, and
    /// vice-versa. Safe to call when the controller is no longer
    /// holding that view as its drawable.
    func detach(currentView: UIView, surface: PlayerDrawableSurface) {
        #if canImport(MobileVLCKit)
        guard attachedView === currentView else {
            diagLog(.playback, "Drawable detach ignored for stale surface", details: [
                "surface": surface.rawValue,
                "attachedSurface": attachedSurface?.rawValue ?? "none",
                "view": String(describing: currentView)
            ])
            return
        }
        diagLog(.playback, "Detaching drawable", details: ["surface": surface.rawValue, "view": String(describing: currentView)])
        // `VLCMediaPlayer.drawable` is typed `Any?` so it can hold
        // a CALayer, NSView, or UIView depending on the platform.
        // Cast to `UIView` so we can use `===` — `===` on `Any?`
        // is not allowed because the compiler cannot prove the
        // operand is a class type.
        if let drawable = mediaPlayer.drawable as? UIView, drawable === currentView {
            mediaPlayer.drawable = nil
        }
        if attachedView === currentView {
            attachedView = nil
            attachedSurface = nil
        }
        #endif
    }

    /// Stop the player and the polling timer. Called from
    /// `VideoDetailView.onDisappear` so a navigated-away video
    /// frees the decoded buffer instead of playing silent audio
    /// in the background. The next `init` creates a fresh
    /// `VLCMediaPlayer` from scratch.
    func tearDown() {
        stopPolling()
        #if canImport(MobileVLCKit)
        mediaPlayer.stop()
        #endif
    }

    func play() {
        #if canImport(MobileVLCKit)
        mediaPlayer.play()
        #endif
    }

    func pause() {
        #if canImport(MobileVLCKit)
        mediaPlayer.pause()
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
        // `media` is optional on `VLCMediaPlayer`; nil means no media
        // is loaded yet (e.g. tap arrived during the first
        // `play()`). Treat as 0 length so a positive skip is
        // clamped to 0 instead of crashing.
        let totalMs = max(0, mediaPlayer.media?.length.intValue ?? 0)
        let currentMs = mediaPlayer.time.intValue
        let raw = Double(currentMs) + seconds * 1000
        let clampedMs = Int32(min(Double(totalMs), max(0, raw)))
        mediaPlayer.time = VLCTime(int: clampedMs)
        currentTime = Double(clampedMs) / 1000
        #endif
    }

    /// Seek to an absolute time in seconds, clamped to `[0, duration]`.
    /// Called when the user releases the scrubber — see
    /// `FullscreenPlayerView` for the debounce logic.
    func seek(to seconds: Double) {
        #if canImport(MobileVLCKit)
        let totalSeconds = max(0, Double(mediaPlayer.media?.length.intValue ?? 0) / 1000)
        let target = min(totalSeconds, max(0, seconds))
        let targetMs = Int32(target * 1000)
        mediaPlayer.time = VLCTime(int: targetMs)
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
        let ms = mediaPlayer.time.intValue
        if ms >= 0 {
            currentTime = Double(ms) / 1000
        }
        // `media` is optional on `VLCMediaPlayer`; skip the duration
        // update when nil so the scrubber keeps its last-known value
        // (typically 0) instead of briefly showing NaN.
        let length = mediaPlayer.media?.length.intValue ?? 0
        if length > 0 {
            duration = Double(length) / 1000
        }
        if mediaPlayer.isPlaying != isPlaying {
            isPlaying = mediaPlayer.isPlaying
            diagLog(.playback, "isPlaying changed by player", details: ["isPlaying": isPlaying])
        }
        // Buffering = VLC's state machine is in opening or
        // buffering. The state value is the most reliable signal —
        // `isPlaying` flips false during the first 100-200ms before
        // the network completes the manifest fetch, but it can
        // also be true while `state == .buffering` if VLC has not
        // yet decided to pause. The state check is robust to
        // either case.
        // [FIX] Force isBuffering false if the player is actually playing,
        // to avoid the spinner sticking while video is visible.
        let state = mediaPlayer.state
        let newBuffering = (state == .opening || state == .buffering) && !isPlaying
        if newBuffering != isBuffering {
            isBuffering = newBuffering
            diagLog(.playback, "isBuffering changed", details: ["isBuffering": isBuffering, "vlcState": state.rawValue, "isPlaying": isPlaying])
        }
        // `inputBitrate` is in bits/second; convert to bytes/sec
        // for the overlay. 0 while VLC has not yet computed a
        // rate (e.g. before the manifest is parsed).
        networkSpeed = Double(mediaPlayer.media?.statistics.inputBitrate ?? 0) / 8.0
        #endif
    }

    deinit {
        // `Timer.invalidate()` is thread-safe. We do not stop the
        // mediaPlayer here because `tearDown` is the explicit
        // teardown path — calling `stop()` from deinit on a
        // @MainActor class would also have to bridge the actor,
        // and the controller outliving the player is not the
        // normal path (the parent's `tearDown` should fire first).
        pollTimer?.invalidate()
    }
}

/// Owns the periodic history-reporting `Timer` for one playback
/// session. The official Bilibili iOS client calls
/// `POST /x/v2/history/report` with `progress=0` on play start and
/// every 30 seconds during playback — without that cadence the
/// video plays fine but never shows up in the user's "历史记录"
/// list (the "visitor watch" symptom in `MINIMAX_INSTRUCTIONS.md`
/// §2). This helper isolates the timer so both the inline
/// `PlayerView` and the fullscreen overlay can share the exact
/// same scheduling logic without each view re-implementing it.
///
/// `start(...)` is fire-and-forget: failures are caught and
/// `bpLog`'d so a flaky network never breaks playback. A missed
/// tick just means the history entry's progress is a few seconds
/// behind — Bilibili recomputes it on the next successful call.
@MainActor
final class WatchSession {
    private let repository: BiliPaiRepository
    private let aid: Int
    private let cid: Int
    private let getCurrentSeconds: () -> Double
    private let isActive: () -> Bool
    private var timer: Timer?
    /// Tracks the last time we fired so we can throttle a
    /// "play then immediately pause" pair — without this, a quick
    /// tap on play/pause could fire two `progress=0` reports back
    /// to back and overwrite the resume point.
    private var lastFire: Date = .distantPast

    private static let reportInterval: TimeInterval = 30
    private static let minimumGap: TimeInterval = 5

    init(
        repository: BiliPaiRepository,
        aid: Int,
        cid: Int,
        getCurrentSeconds: @escaping () -> Double,
        isActive: @escaping () -> Bool
    ) {
        self.repository = repository
        self.aid = aid
        self.cid = cid
        self.getCurrentSeconds = getCurrentSeconds
        self.isActive = isActive
    }

    /// Begin reporting. Sends `progress=0` immediately, then every
    /// `reportInterval` seconds. Idempotent — calling `start` while
    /// already running is a no-op so SwiftUI re-renders don't queue
    /// duplicate timers.
    func start() {
        guard timer == nil else { return }
        guard aid > 0, cid > 0 else {
            // The video either came from a feed entry that only
            // had a `bvid` (no `aid`) or the detail load failed to
            // populate a `cid` — the history endpoint requires both,
            // so we silently skip rather than spam bpLog on every
            // play. The user can still see the watch in their local
            // client, it just won't sync to Bilibili's history.
            return
        }
        // Fire the first report immediately so the watch shows up
        // in the history list even if the user only watches for
        // <30s.
        fire(progress: 0)
        timer = Timer.scheduledTimer(withTimeInterval: Self.reportInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    /// Cancel the timer. Safe to call from `onDisappear`; the next
    /// `start` will fire a fresh `progress=0` to mark the new
    /// session start.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Throttle: if the user just paused (or just opened the
        // view and `start` fired <5s ago) skip the report to avoid
        // a noisy pair of `progress=...` ticks.
        guard Date().timeIntervalSince(lastFire) >= Self.minimumGap else { return }
        guard isActive() else { return }
        let progress = Int(max(0, getCurrentSeconds().rounded()))
        fire(progress: progress)
    }

    private func fire(progress: Int) {
        lastFire = Date()
        Task { [repository, aid, cid] in
            do {
                try await repository.reportHistoryForWatchSession(
                    aid: aid,
                    cid: cid,
                    progress: progress
                )
            } catch {
                // Non-fatal: bpLog the failure so the in-app log
                // export surfaces it, but do not propagate — the
                // user is mid-watch, retrying on the next tick is
                // the right behaviour.
                bpLog("history report failed (aid=\(aid) progress=\(progress)): \(error)")
            }
        }
    }
}

/// A robust FFmpeg-based player view using MobileVLCKit.
/// This replaces AVPlayer to support Bilibili's DASH streams and custom headers.
///
/// The `VLCMediaPlayer` itself is owned by `PlayerController` (not
/// by this representable). `VLCPlayerView`'s only job is to point
/// the player's `drawable` at the underlying `UIView` and release
/// that pointer when SwiftUI tears the view down. Hoisting the
/// player up to the controller is what lets the inline
/// `PlayerView` and the `FullscreenPlayerView` share one player —
/// when the user goes fullscreen, the inline `UIView` is
/// dismantled and the fullscreen one is created, but the same
/// `VLCMediaPlayer` keeps playing across the handoff.
final class VLCPlayerContainerView: UIView {
    var onReadyForDrawable: ((VLCPlayerContainerView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        notifyIfReady()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        notifyIfReady()
    }

    private func notifyIfReady() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        onReadyForDrawable?(self)
    }
}

struct VLCPlayerView: UIViewRepresentable {
    @ObservedObject var controller: PlayerController
    let surface: PlayerDrawableSurface

    init(controller: PlayerController, surface: PlayerDrawableSurface = .standalone) {
        self.controller = controller
        self.surface = surface
    }

    func makeUIView(context: Context) -> UIView {
        let view = VLCPlayerContainerView()
        view.backgroundColor = .black

        #if canImport(MobileVLCKit)
        let coordinator = context.coordinator
        view.onReadyForDrawable = { [weak coordinator] readyView in
            coordinator?.attachIfReady(controller: controller, view: readyView, surface: surface)
        }
        context.coordinator.attachIfReady(controller: controller, view: view, surface: surface)
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
        // Re-attach on every re-render. This is cheap (a single
        // property assignment) and essential for the inline ↔
        // fullscreen handoff: when the fullscreen is dismissed,
        // the inline view re-renders inside the parent and needs
        // to re-claim the drawable. Without this, the inline
        // surface would stay frozen on the last frame it showed
        // before the fullscreen took over.
        // `drawable` is `Any?`; cast to `UIView` for `===`.
        guard let playerView = uiView as? VLCPlayerContainerView else { return }
        let coordinator = context.coordinator
        playerView.onReadyForDrawable = { [weak coordinator] readyView in
            coordinator?.attachIfReady(controller: controller, view: readyView, surface: surface)
        }
        if let drawable = controller.mediaPlayer.drawable as? UIView, drawable !== playerView {
            context.coordinator.attachIfReady(controller: controller, view: playerView, surface: surface)
        } else if controller.mediaPlayer.drawable == nil {
            context.coordinator.attachIfReady(controller: controller, view: playerView, surface: surface)
        }
        #endif
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // `coordinator.detach` only clears the drawable if the
        // current drawable is still `uiView`, so this is safe to
        // call from the inline view's dismantle while a
        // fullscreen view has already taken over the drawable.
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    class Coordinator {
        weak var controller: PlayerController?
        weak var view: VLCPlayerContainerView?
        var surface: PlayerDrawableSurface = .standalone

        func attachIfReady(controller: PlayerController, view: VLCPlayerContainerView, surface: PlayerDrawableSurface) {
            self.controller = controller
            self.view = view
            self.surface = surface
            guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
                diagLog(.playback, "Drawable attach deferred until layout", details: ["surface": surface.rawValue, "view": String(describing: view)])
                return
            }
            controller.attach(drawable: view, surface: surface)
        }

        func detach() {
            guard let controller = controller, let view = view else { return }
            view.onReadyForDrawable = nil
            controller.detach(currentView: view, surface: surface)
        }
    }
}
