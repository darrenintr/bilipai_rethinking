//
//  AVPlayerController.swift
//  Paladala
//
//  `PlayerController` powered by `AVPlayer` + a 127.0.0.1-local
//  HLS proxy (`LocalHLSProxyServer`).  Replaces the previous
//  AliPlayer / VLC paths so the app no longer depends on any
//  third-party player SDK.
//
//  Why this shape
//  --------------
//  * The controller owns the `AVPlayer` and the published state
//    (`currentTime`, `duration`, `isPlaying`, `isBuffering`,
//    `networkSpeed`) that the rest of the app reads.  `WatchSession`
//    samples `currentTime` and `isPlaying` every 30 seconds.
//  * The view layer is now AVKit — `VideoPlayer` for the inline
//    surface and a thin `UIViewControllerRepresentable` around
//    `AVPlayerViewController` for the fullscreen surface.  Both
//    bind to the same `AVPlayer`, so the inline ↔ fullscreen
//    transition keeps the playhead continuous.  Play, pause, and
//    seek are all driven by the system UI; the controller no
//    longer exposes custom `play` / `pause` / `seek` methods.
//  * VOD DASH playback is fed to AVPlayer as
//    `http://127.0.0.1:NNNN/playlist.m3u8`.  The proxy server
//    synthesises a master + child playlists from the B站 DASH
//    payload, and proxies the underlying m4s segments with the
//    right `Referer`.
//  * Live HLS and legacy `durl` MP4 are played directly via
//    `AVURLAsset` with the `Referer` header injected.  AVPlayer
//    consumes HLS natively, so the proxy is unnecessary for
//    that case.
//

import AVFoundation
import Combine
import CoreMedia
import MediaPlayer
import UIKit

// MARK: - Player error types

/// Errors surfaced in the player overlay.  Each case maps to a
/// specific `AVPlayerItem` failure mode so the user gets a
/// meaningful message instead of a generic spinner.
///
/// Plain value type — no MainActor, no UIKit dependencies — so
/// it can be declared at file scope under Swift 5.0 without
/// triggering concurrency checks.
enum PlayerPlaybackError: Equatable {
    /// AVPlayer gave up on the item (codec rejection,
    /// unsupported container, etc.).  `detail` is the
    /// `AVPlayerItemErrorLogEntry.errorComment` text when available.
    case itemFailed(detail: String?)
    /// The item stopped mid-stream (network dropout,
    /// server-side error, CDN reset).  `detail` is the
    /// `AVPlayerItemFailedToPlayToEndTimeErrorKey` text.
    case stoppedMidStream(detail: String?)
    /// The proxy server returned a hard error after all retries.
    /// `code` is the HTTP status (e.g. 502).
    case proxyFailed(code: Int)
    /// AVPlayer is buffering but the stall has lasted more
    /// than 10 seconds.  Tracked separately so we don't
    /// immediately show the overlay for a brief network hiccup.
    case prolongedStall

    var title: String {
        switch self {
        case .itemFailed:       return "无法播放此视频"
        case .stoppedMidStream: return "播放中断"
        case .proxyFailed:      return "服务器连接失败"
        case .prolongedStall:   return "加载缓慢"
        }
    }

    var message: String {
        switch self {
        case .itemFailed(let detail):
            if let d = detail, !d.isEmpty {
                return d
            }
            return "视频格式不支持或播放源已失效。"
        case .stoppedMidStream(let detail):
            if let d = detail, !d.isEmpty {
                return d
            }
            return "网络连接中断，请检查网络后重试。"
        case .proxyFailed(let code):
            return "视频代理服务器返回错误（\(code)），请稍后重试。"
        case .prolongedStall:
            return "加载时间过长，可能是网络问题。"
        }
    }

    var recoveryAction: RecoveryAction {
        switch self {
        case .itemFailed:       return .retryPlayback
        case .stoppedMidStream: return .retryPlayback
        case .proxyFailed:      return .retryPlayback
        case .prolongedStall:   return .retrySeek
        }
    }
}

enum RecoveryAction {
    case retryPlayback   // full playback re-init (DASH re-fetch)
    case retrySeek       // seek to current time (buffer refetch)

    var buttonLabel: String {
        switch self {
        case .retryPlayback: return "重新播放"
        case .retrySeek:     return "重新加载"
        }
    }
}

@MainActor
final class PlayerController: ObservableObject {
    // MARK: published state

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying: Bool = true
    @Published private(set) var isBuffering: Bool = false
    @Published private(set) var isPictureInPictureActive: Bool = false
    @Published private(set) var playerError: PlayerPlaybackError?
    @Published private(set) var networkSpeed: Double = 0

    // MARK: underlying AVPlayer

    /// The single `AVPlayer` instance the view layer binds to
    /// (`VideoPlayer(player: controller.player)` and the
    /// `AVPlayerViewController` in fullscreen both use this).
    /// Owned for the lifetime of the controller; `tearDown` calls
    /// `pause()` and removes the observers but does not
    /// deallocate the player (it lives as long as the controller
    /// does).
    let player: AVPlayer
    private let playerItem: AVPlayerItem
    private let asset: AVURLAsset
    /// `true` if this controller is fed by the local HLS proxy
    /// (the VOD DASH path).  When `false`, the asset is a direct
    /// `AVURLAsset` (live HLS or legacy MP4) and the proxy is
    /// not involved.
    private let usesProxy: Bool

    // MARK: observers / timer

    private var pollTimer: Timer?
    private var observers: Set<NSKeyValueObservation> = []
    private var statusObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    /// Token returned by `addPeriodicTimeObserver`.  We hold it
    /// to keep the observer alive and to remove it on
    /// `tearDown`.  `AVPlayer.currentTime` is a method, not a
    /// KVO-observable property, so the per-frame time updates
    /// come from a periodic time observer instead.
    private var timeObserver: Any?

    // MARK: network speed tracking

    private var lastBytesAt: Date = .distantPast
    private var lastBytes: Int64 = 0

    /// Rate-limit gate for the diagnostic `loadedTimeRanges`
    /// log.  AVPlayer fires KVO on every chunk that arrives
    /// (multiple per second during buffer fill); without
    /// throttling, the diagnostic log would drown in one
    /// line per chunk.  We emit at most once every 500 ms.
    private var lastRangesLogAt: Date = .distantPast

    // MARK: now-playing metadata

    /// Title shown in `MPNowPlayingInfoCenter`.  Set from the
    /// optional `video:` parameter to the init when the controller
    /// is bound from `MiniPlayerStore.bind(video:…)`.  Falls back
    /// to a generic label for live-room controllers (which never
    /// get a `BiliVideo`).
    private let nowPlayingTitle: String
    private let nowPlayingArtist: String
    private let nowPlayingCoverURL: URL?
    /// Cached artwork.  Built once when the coverURL resolves,
    /// then handed to `MPMediaItemArtwork` on every Now Playing
    /// refresh so we don't re-wrap a `UIImage` twice a second.
    private var nowPlayingArtwork: MPMediaItemArtwork?

    // MARK: lifecycle

    init(playback: BiliPlayback, video: BiliVideo? = nil) {
        diagLog(.playback, "Initialising AVPlayerController", details: [
            "isDASH": playback.isDASH,
            "referer": playback.referer.absoluteString
        ])

        self.nowPlayingTitle = video?.title ?? "直播"
        self.nowPlayingArtist = video?.ownerName ?? "Paladala"
        self.nowPlayingCoverURL = video?.coverURL

        let referer = playback.referer.absoluteString
        let asset: AVURLAsset
        let usesProxy: Bool

        if playback.dash != nil {
            // VOD DASH path: stand up the local HLS proxy and
            // point AVPlayer at the synthesised master playlist.
            // The proxy holds the dash source / referer and
            // serves the manifests + segment bytes.
            do {
                try LocalHLSProxyServer.shared.serve(playback: playback)
            } catch {
                diagLog(.playback,
                        "Failed to start LocalHLSProxyServer",
                        details: ["error": error.localizedDescription])
            }
            // The `waitForReady()` method blocks on a semaphore until the
            // NWListener fires its `.ready` state callback on the
            // proxy's queue, or until the 2-second timeout elapses.
            // Compared to the previous `while + Thread.sleep` polling
            // loop this uses far less CPU (no thread wake every 10 ms)
            // and is explicit about the intent.  The semaphore waits
            // on the proxy's serial `queue`, which is safe to block —
            // the queue has no async work pending at init time.
            guard let baseURL = LocalHLSProxyServer.shared.waitForReady() else {
                fatalError("LocalHLSProxyServer did not become ready in time")
            }
            let playlistURL = baseURL.appendingPathComponent("playlist.m3u8")
            asset = AVURLAsset(url: playlistURL)
            usesProxy = true
            diagLog(.playback,
                    "AVPlayerController bound to local HLS proxy",
                    details: ["url": playlistURL.absoluteString])
        } else if let fallback = playback.fallbackURL {
            // Direct URL path: live HLS or legacy MP4.  AVPlayer
            // can consume either directly, but B站's CDN still
            // gates segments on the `Referer` header.  Inject
            // it through `AVURLAssetHTTPHeaderFieldsKey` so
            // every sub-request (m3u8 + ts) carries it.
            asset = AVURLAsset(
                url: fallback,
                options: [
                    "AVURLAssetHTTPHeaderFieldsKey": [
                        "Referer": referer,
                        "User-Agent":
                            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 "
                            + "like Mac OS X) AppleWebKit/605.1.15 "
                            + "(KHTML, like Gecko) Version/18.0 "
                            + "Mobile/15E148 Safari/604.1",
                    ]
                ]
            )
            usesProxy = false
            diagLog(.playback,
                    "AVPlayerController using direct asset",
                    details: ["url": fallback.absoluteString])
        } else {
            fatalError("BiliPlayback has no DASH source and no fallback")
        }

        self.asset = asset
        self.usesProxy = usesProxy

        let item = AVPlayerItem(asset: asset)
        
        // Optimization: Seek to the resume time *before* assigning the player
        // to the view controller (or here, before assigning the item to the
        // player). This is more efficient as the media only loads at the
        // actual start time.
        if playback.resumeTime > 0 {
            item.seek(to: CMTime(seconds: playback.resumeTime, preferredTimescale: 600), completionHandler: nil)
        }
        
        self.playerItem = item
        self.player = AVPlayer(playerItem: item)

        // Audio session: play in silent mode like the AliPlayer
        // path did.  `.playback` lets the audio play when the
        // silent switch is on.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .moviePlayback, options: []
        )
        try? AVAudioSession.sharedInstance().setActive(true)

        // KVO on the player.  `currentTime` is a method (not a
        // KVO-observable property) so we use a periodic time
        // observer instead, fired every 0.5s on the main queue.
        // The closure receives the current `CMTime` directly
        // and updates `self.currentTime` on the main actor.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] cm in
            let seconds = CMTimeGetSeconds(cm)
            if seconds.isFinite, seconds >= 0 {
                // The `.main` queue means we're on the main actor;
                // Task { @MainActor in } bridges from whatever queue
                // check without the Task allocation overhead of the
                // KVO observers.
                Task { @MainActor in
                    self?.currentTime = seconds
                    // Keep the lock-screen playhead in sync.  Two
                    // updates per second is cheap (the dict has no
                    // new keys after the first write) and gives
                    // Control Center a moving scrubber.
                    self?.updateNowPlaying()
                }
            }
        }

        // KVO on the item for buffer state.  AVPlayer exposes
        // these as KVO-observable Bool properties on
        // `AVPlayerItem`, not as `NSNotification`s.
        observers.insert(
            item.observe(
                \.isPlaybackBufferEmpty,
                options: [.new, .initial]
            ) { [weak self] _, change in
                let empty = change.newValue ?? false
                Task { @MainActor in
                    self?.isBuffering = empty
                }
            }
        )
        observers.insert(
            item.observe(
                \.isPlaybackLikelyToKeepUp,
                options: [.new, .initial]
            ) { [weak self] _, change in
                let likely = change.newValue ?? false
                Task { @MainActor in
                    if likely { self?.isBuffering = false }
                }
            }
        )

        // Diagnostic KVO: every new buffered range fires
        // this observer.  We log the consolidated range
        // table so we can correlate "scrubber seek landed
        // at 80%" with "buffer covers 80–82%" (or "buffer
        // is empty, hence the stall").
        observers.insert(
            item.observe(\.loadedTimeRanges, options: [.new]) {
                [weak self] _, _ in
                Task { @MainActor in
                    self?.logLoadedTimeRanges()
                }
            }
        )

        // Diagnostic KVO: AVPlayer's internal wait reason
        // (iOS 16.4+).  Fires when AVPlayer is in
        // `waitingToPlayAtSpecifiedRate`.  Values include
        // `evaluatingBuffeRedSeek`, `noItemToPlay`,
        // `toMinimizeStalls` — exactly what we need to
        // distinguish "stalled because upstream is slow"
        // from "stalled because the parser gave up on the
        // response we sent".
        if #available(iOS 16.4, *) {
            observers.insert(
                player.observe(\.reasonForWaitingToPlay, options: [.new]) {
                    _, change in
                    let reason = change.newValue
                        .map { String(describing: $0) } ?? "nil"
                    diagLog(.playback,
                            "AVPlayer reasonForWaitingToPlay",
                            details: ["reason": reason])
                }
            )
        }

        // Diagnostic KVO: `AVPlayerItem.status` transitions
        // through `.unknown → .readyToPlay (or .failed)`.
        // Logging this catches the case where the proxy
        // returns a 206 with a malformed body that AVPlayer
        // rejects at the parser level.
        observers.insert(
            item.observe(\.status, options: [.new, .initial]) {
                [weak self] _, change in
                let status = change.newValue
                    .map { String(describing: $0) } ?? "nil"
                let err = self?.player.currentItem?.error
                var details: [String: Any] = ["status": status]
                if let err {
                    details["error"] = String(describing: err)
                    Analytics.recordError(err, context: "player_item_status_failed")
                    Analytics.log("player_item_status_failed", [
                        "status": status,
                        "error": String(describing: err)
                    ])
                }
                diagLog(.playback, "AVPlayerItem status changed", details: details)
            }
        )

        // End-of-stream notification.  This one is a real
        // `NSNotification`, declared as a top-level
        // `Notification.Name` constant.
        statusObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                // End-of-stream = the user watched all the way
                // through (or AVPlayer hit the end and stopped).
                // This is the strongest "engaged" signal we have
                // without a periodic heartbeat, and feeds the
                // completion-rate denominator for the playback
                // funnel.
                let totalSeconds = self?.player.currentItem?.duration.seconds ?? 0
                Analytics.log("video_complete", [
                    "duration_seconds": totalSeconds
                ])
                Analytics.breadcrumb("PLAY", "video_complete")
            }
        }
        errorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                as? Error
            diagLog(.playback, "AVPlayerItem failed to play to end", details: [
                "error": err.map { String(describing: $0) } ?? "unknown"
            ])
            if let err {
                Analytics.recordError(err, context: "video_playback_end")
                Analytics.log("video_playback_end_error", [
                    "domain": (err as NSError).domain,
                    "code": (err as NSError).code
                ])
            }
            Task { @MainActor in
                self?.isPlaying = false
                self?.isBuffering = false
            }
        }
        // The "new error log entry" notification is what fires
        // when AVPlayer refuses to play a media format (codec
        // rejection, container rejection, network error, etc).
        // It is the difference between "video keeps buffering
        // forever" and "AVPlayer said no, with a reason".  The
        // error log keeps the *last* few entries, so we always
        // include every one of them.
        //
        // We can't read AVPlayerItemErrorLogEvent's properties
        // by name from Swift because the bridge is unstable
        // across SDK versions (the properties exist in Obj-C
        // as `errorStatusCode`, `errorDomain`, `errorComment`
        // but Swift only exposes them with an explicit
        // `value(forKey:)` lookup).  Falling back to
        // `String(describing:)` is reliable and gives us
        // enough info to diagnose the "not in correct format"
        // error.
        errorLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item, queue: .main
        ) { _ in
            let entries = item.errorLog()?.events ?? []
            let summary = entries.prefix(3).map { e -> String in
                String(describing: e)
            }.joined(separator: " | ")
            diagLog(.playback, "AVPlayerItem new error log entry", details: [
                "count": entries.count,
                "last3": summary
            ])
            if let last = entries.first {
                Analytics.recordError(
                    NSError(domain: "paladala.player", code: last.errorStatusCode, userInfo: [
                        NSLocalizedDescriptionKey: last.errorComment ?? "AVPlayer error log entry",
                        "errorDomain": last.errorDomain,
                        "errorStatusCode": last.errorStatusCode
                    ]),
                    context: "player_errorLogEntry"
                )
                Analytics.log("player_error_log_entry", [
                    "count": entries.count,
                    "domain": last.errorDomain,
                    "code": last.errorStatusCode
                ])
            }
        }

        // Periodically poll: AVPlayer does not push a
        // "rate changed" event for the `rate=0 → rate=1`
        // transition that happens on play(), so we sweep
        // `player.timeControlStatus` and `player.rate` from
        // a 2Hz timer.
        startPolling()

        if isPlaying {
            player.play()
        }

        // Hook into the iOS system transport (lock screen, Control
        // Center, CarPlay, AirPods double-tap, Bluetooth accessory
        // play/pause/skip buttons).  Without this the lock-screen
        // would not show our video, and AirPods hardware buttons
        // would only pause Music, not us.  See B4 in the polish
        // plan.
        setupRemoteCommands()
        // Subscribe to the inline-PiP lifecycle notifications
        // so `isPictureInPictureActive` flips consistently for
        // PiP sessions initiated from the inline surface.
        observeInlinePiP()
        // First Now Playing write so the lock-screen artwork +
        // title are visible immediately.  Subsequent refreshes
        // piggy-back on the periodic time observer.
        updateNowPlaying()
        // Best-effort cover image fetch.  The coverURL is from
        // B站 and we already pay the round-trip elsewhere via
        // `CoverImagePipeline`, but that pipeline is `private`
        // to `SharedViews.swift`; for the one-off Now Playing
        // artwork a direct `URLSession` round-trip is cheaper
        // than lifting the cache to internal visibility.
        // Failures are silent — the lock-screen just shows a
        // generic placeholder.
        if let coverURL = nowPlayingCoverURL {
            Task { [weak self] in
                guard let image = await Self.downloadCover(url: coverURL) else {
                    return
                }
                await MainActor.run {
                    guard let self else { return }
                    self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    self.updateNowPlaying()
                }
            }
        }
    }

    /// One-shot cover download for Now Playing artwork.  Hits
    /// `URLSession.shared` with a B站-compatible `Referer` and
    /// `User-Agent` so the CDN serves the image (B站 gates
    /// `*.hdslb.com` on the Referer for hotlink protection).
    /// Returns `nil` on any failure; the caller treats that as
    /// "no artwork".
    private static func downloadCover(url: URL) async -> UIImage? {
        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    // MARK: playback control

    /// Toggle play/pause.
    func toggle() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    /// Change the playback rate (e.g., 2.0 for 2x speed).
    func setRate(_ rate: Float) {
        player.rate = rate
    }

    func setPiPActive(_ active: Bool) {
        isPictureInPictureActive = active
    }

    /// `AVPictureInPictureController` posts no KVO on
    /// `isPictureInPictureActive`; we drive the published
    /// state from the inline PiP controller's lifecycle
    /// notifications AND the fullscreen
    /// `AVPlayerViewControllerDelegate` callbacks.  Both
    /// paths funnel through this method so any observer of
    /// `isPictureInPictureActive` sees a single consistent
    /// flip regardless of which surface initiated PiP.
    /// We also surface the new state into
    /// `MPNowPlayingInfoCenter` because Control Center
    /// shows a "playing in PiP" hint while PiP is active.
    private var pipObservers: [NSObjectProtocol] = []

    private func observeInlinePiP() {
        let center = NotificationCenter.default
        pipObservers.append(
            center.addObserver(
                forName: .paladalaPiPDidStart, object: nil, queue: .main
            ) { [weak self] _ in
                self?.isPictureInPictureActive = true
                self?.updateNowPlaying()
            }
        )
        pipObservers.append(
            center.addObserver(
                forName: .paladalaPiPDidStop, object: nil, queue: .main
            ) { [weak self] _ in
                self?.isPictureInPictureActive = false
                self?.updateNowPlaying()
            }
        )
    }

    // MARK: seeking

    /// Seek by a relative offset (positive = forward, negative =
    /// backward). The target is clamped to `[0, duration]` so
    /// double-tap-skip past the end of the playable bytes does
    /// not crash — the AVPlayer would just no-op such a seek,
    /// but the explicit clamp makes the behaviour obvious and
    /// keeps the inline seek-bar (if it ever comes back)
    /// consistent with the double-tap gesture.
    ///
    /// Uses default (approximate) tolerances so AVPlayer snaps
    /// to the nearest keyframe.  Exact-tolerance seeks
    /// (`toleranceBefore/After: .zero`) force AVPlayer to wait
    /// for the precise frame to be decoded, which makes HLS
    /// scrubbing — especially past the buffered range — feel
    /// sluggish.  The 10-second double-tap skip is a short hop
    /// that users expect to feel instant.
    func seek(by offset: Double) {
        let now = CMTimeGetSeconds(player.currentTime())
        guard now.isFinite, duration > 0 else { return }
        let target = max(0, min(duration, now + offset))
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time)
    }

    /// Seek to an absolute timestamp in seconds.  Used by the
    /// music player's lyric scroller — tapping a lyric line
    /// seeks the playhead to that line's `startTime` rather
    /// than jumping by a fixed offset.  Clamps to
    /// `[0, duration]` for the same reason `seek(by:)` does.
    func seek(to seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        let target = max(0, min(duration, seconds))
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time)
    }

    // MARK: teardown

    func tearDown() {
        stopPolling()
        player.pause()
        if let token = timeObserver {
            player.removeTimeObserver(token)
        }
        timeObserver = nil
        if let token = statusObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = errorObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = errorLogObserver {
            NotificationCenter.default.removeObserver(token)
        }
        statusObserver = nil
        errorObserver = nil
        errorLogObserver = nil
        // Drop the inline-PiP lifecycle observers so a
        // torn-down controller doesn't receive notifications
        // that fire while a successor controller is being
        // constructed (the singleton NotificationCenter
        // doesn't know about per-controller lifetimes).
        pipObservers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        pipObservers.removeAll()
        observers.removeAll()
        clearNowPlaying()
        diagLog(.playback, "AVPlayerController teardown complete")
    }

    // MARK: remote commands + Now Playing

    /// Wire `MPRemoteCommandCenter` so the lock-screen, Control
    /// Center, CarPlay, and hardware buttons (AirPods double-tap,
    /// Bluetooth accessory play/pause) can drive the player.  We
    /// disable the skip-by-30s defaults and expose ±10s instead,
    /// matching the in-app double-tap gesture.  Called once per
    /// controller lifecycle; the handlers' `[weak self]` keeps the
    /// controller from being retained past `tearDown`.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.toggle()
            return .success
        }

        // ±10s to match the inline double-tap gesture.
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.seek(by: +10)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.seek(by: -10)
            return .success
        }

        // Lock-screen scrubber drag.
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent
            else {
                return .commandFailed
            }
            let target = max(0, positionEvent.positionTime)
            let time = CMTime(seconds: target, preferredTimescale: 600)
            self.player.seek(to: time)
            // Position changed — push the new value to Now Playing
            // immediately rather than waiting for the next 0.5s
            // tick, so the lock-screen thumb tracks the drag.
            self.updateNowPlaying()
            return .success
        }
    }

    /// Write the current title / artist / duration / position /
    /// rate to `MPNowPlayingInfoCenter`.  Cheap to call — the
    /// artwork is cached in `nowPlayingArtwork` so we don't
    /// re-wrap a `UIImage` on every refresh.  Position uses
    /// `currentTime` (the published snapshot from the periodic
    /// observer) rather than calling `player.currentTime()`
    /// again, so the value matches what the UI is showing.
    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = nowPlayingTitle
        info[MPMediaItemPropertyArtist] = nowPlayingArtist
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Drop our entry from `MPNowPlayingInfoCenter`.  Called from
    /// `tearDown()` so a closed mini-player doesn't leave the
    /// lock-screen / Control Center pinned to a now-defunct
    /// player.
    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: polling

    /// Emit one diagnostic log line summarising every buffered
    /// range AVPlayer currently holds for the playable item.
    /// Rate-limited to ≤1 line per 500 ms via `lastRangesLogAt`
    /// so a buffer fill doesn't drown the diagnostic log.
    /// Used by the scrubber-seek diagnosis: when the user
    /// drags to a position past the buffer, the `ranges`
    /// array will be empty or stale.
    private func logLoadedTimeRanges() {
        guard let item = player.currentItem else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRangesLogAt) >= 0.5 else { return }
        lastRangesLogAt = now
        let ranges: [[String: Double]] = item.loadedTimeRanges.map { value in
            // `loadedTimeRanges` is `[NSValue]`; each `NSValue`
            // carries a `CMTimeRange` accessible via
            // `timeRangeValue`.  Going through `.timeRange`
            // directly doesn't work because `NSValue` is a
            // generic Obj-C box, not a typed Swift struct.
            let tr = value.timeRangeValue
            let s = CMTimeGetSeconds(tr.start)
            let d = CMTimeGetSeconds(tr.duration)
            return ["start": s, "end": s + d, "duration": d]
        }
        let current = CMTimeGetSeconds(item.currentTime())
        let duration = CMTimeGetSeconds(item.duration)
        diagLog(.playback,
                "AVPlayerItem loadedTimeRanges",
                details: [
                    "currentTime": current,
                    "duration": duration,
                    "ranges": ranges,
                    "bufferEmpty": item.isPlaybackBufferEmpty,
                    "likelyToKeepUp": item.isPlaybackLikelyToKeepUp
                ])
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
        // Current time — pulled from the AVPlayer's clock.
        let ct = CMTimeGetSeconds(player.currentTime())
        if ct.isFinite, ct >= 0 {
            currentTime = ct
        }
        // Total duration — surfaced on the item once the master
        // playlist has been parsed and the EXTINF sum is known.
        let d = CMTimeGetSeconds(playerItem.duration)
        if d.isFinite, d > 0 {
            duration = d
        }
        // `isPlaying` is driven by `timeControlStatus`; AVPlayer
        // can pause on its own when the buffer empties, and we
        // do not want to fight that — we mirror it.  `WatchSession`
        // reads this every 30 seconds.
        let playing = (player.timeControlStatus == .playing)
        if playing != isPlaying {
            isPlaying = playing
            diagLog(.playback, "AVPlayer timeControlStatus changed",
                    details: ["isPlaying": playing])
        }
        // Network speed.  For the proxy path we have a real
        // byte counter on `LocalHLSProxyServer`; for the direct
        // URL path the counter is always zero, so the loading
        // overlay reads "—".  AVPlayer's `accessLog()` exposes
        // throughput, but reading it on every poll is overkill
        // for the overlay's coarse KB/s readout.
        let now = Date()
        let dt = now.timeIntervalSince(lastBytesAt)
        if dt >= 0.5 {
            let bytes = usesProxy
                ? LocalHLSProxyServer.shared.byteCount : 0
            let delta = max(0, bytes - lastBytes)
            networkSpeed = Double(delta) / dt
            lastBytes = bytes
            lastBytesAt = now
        }
    }

    deinit {
        tearDown()
    }
}
