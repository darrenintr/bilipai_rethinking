//
//  AVPlayerController.swift
//  BiliPaiNative
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

@MainActor
final class PlayerController: ObservableObject {
    // MARK: published state

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying: Bool = true
    @Published private(set) var isBuffering: Bool = false
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

    // MARK: lifecycle

    init(playback: BiliPlayback) {
        diagLog(.playback, "Initialising AVPlayerController", details: [
            "isDASH": playback.isDASH,
            "referer": playback.referer.absoluteString
        ])

        let referer = playback.referer.absoluteString
        let asset: AVURLAsset
        let usesProxy: Bool

        if let dash = playback.dash {
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
            // The listener's `ready` state arrives on the
            // server's dispatch queue.  AVPlayer can not
            // meaningfully retry a missing port, so block
            // briefly here (main thread) until the port is
            // known.  In practice this is a few milliseconds.
            let deadline = Date().addingTimeInterval(2.0)
            while LocalHLSProxyServer.shared.baseURL == nil
                    && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let baseURL = LocalHLSProxyServer.shared.baseURL else {
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
                self?.currentTime = seconds
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

        // End-of-stream notification.  This one is a real
        // `NSNotification`, declared as a top-level
        // `Notification.Name` constant.
        statusObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
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
        observers.removeAll()
        diagLog(.playback, "AVPlayerController teardown complete")
    }

    // MARK: polling

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
        pollTimer?.invalidate()
    }
}
