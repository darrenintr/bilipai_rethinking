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
enum PlayerPlaybackError: Equatable, Error {
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
    /// **PR-B D8**: `BiliPlayback` had no DASH source AND no
    /// fallback URL (server schema drift, region block, CDN
    /// reset).  Previously this path hit `fatalError` and
    /// crashed the app — it now surfaces through the existing
    /// playbackErrorOverlay as a graceful error.  `detail`
    /// carries a diagnostic line for the diagnostic dump.
    case playbackSourceUnavailable(detail: String?)

    var title: String {
        switch self {
        case .itemFailed:                   return "无法播放此视频"
        case .stoppedMidStream:             return "播放中断"
        case .proxyFailed:                  return "服务器连接失败"
        case .prolongedStall:               return "加载缓慢"
        case .playbackSourceUnavailable:    return "视频源不可用"
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
            // Bilibili's live CDN returns 403 when the cookie
            // is rejected, when the room is region-restricted,
            // or when the upstream session has expired.  Spell
            // that out for the user so the recovery action
            // (re-login) makes sense.
            if code == 403 {
                return "视频源拒绝请求（HTTP 403）。可能是登录已过期或地区受限。"
            }
            return "视频代理服务器返回错误（HTTP \(code)），请稍后重试。"
        case .prolongedStall:
            return "加载时间过长，可能是网络问题。"
        case .playbackSourceUnavailable(let detail):
            if let d = detail, !d.isEmpty {
                return d
            }
            return "该视频当前无法播放，可能已下架或地区受限。"
        }
    }

    var recoveryAction: RecoveryAction {
        switch self {
        case .itemFailed:                     return .retryPlayback
        case .stoppedMidStream:               return .retryPlayback
        case .proxyFailed(let code) where code == 403:
            return .signInAgain
        case .proxyFailed:                    return .retryPlayback
        case .prolongedStall:                 return .retrySeek
        // PR-B D8: a schema-drift / region-block situation
        // doesn't recover via retry (the same BiliPlayback
        // would fail identically), but the recovery surface
        // needs a button — falling back to retryPlayback
        // gives the user something to tap while we surface
        // the diagnostic detail to the developer.
        case .playbackSourceUnavailable:      return .retryPlayback
        }
    }
}

enum RecoveryAction {
    case retryPlayback   // full playback re-init (DASH re-fetch)
    case retrySeek       // seek to current time (buffer refetch)
    /// Live CDN returned 403 — SESSDATA is invalid or the
    /// room is region-restricted.  The surface should pop
    /// `AppRouter.openLogin()` instead of re-issuing the
    /// playback request.
    case signInAgain

    var buttonLabel: String {
        switch self {
        case .retryPlayback: return "重新播放"
        case .retrySeek:     return "重新加载"
        case .signInAgain:   return "重新登录"
        }
    }
}

@MainActor
final class PlayerController: ObservableObject {
    // MARK: playback state machine

    /// **Build 182 state machine.**  Replaces the implicit
    /// `playerError`-only state model with an explicit
    /// lifecycle.  AVPlayer binding (`replaceCurrentItem`)
    /// only happens in `.ready`; `retryPlayback()` only
    /// runs from `.ready`; the loadTask can be cancelled
    /// safely while in `.preparing`.
    ///
    /// `playerError` (the existing `@Published`) is still
    /// the rich-error payload shown by the overlay — it's
    /// set when `playbackState` becomes `.failed(...)` and
    /// cleared when `playbackState` becomes `.preparing`.
    enum PlaybackState: Equatable {
        case idle
        case preparing
        case ready
        case failed(PlayerPlaybackError)

        static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.preparing, .preparing), (.ready, .ready):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: published state

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying: Bool = true
    @Published private(set) var isBuffering: Bool = false
    @Published private(set) var isPictureInPictureActive: Bool = false
    @Published var isNativeFullscreenActive: Bool = false
    @Published var isLongPressingSpeed: Bool = false
    @Published private(set) var playerError: PlayerPlaybackError?
    /// **Build 182**: explicit playback lifecycle.  Use
    /// this (not `playerError`) for state-machine guards
    /// in `retryPlayback()` and similar.
    @Published private(set) var playbackState: PlaybackState = .idle
    @Published private(set) var networkSpeed: Double = 0

    // MARK: seek state machine (PR-A Group 1)

    /// `true` while an `AVPlayer.seek(to:)` is in flight.  Used
    /// by the prolonged-stall watchdog (`stallTimerTask`) and
    /// by `armStallWatchdog()` to suppress the 10-second stall
    /// error while AVPlayer is still finishing the seek —
    /// without this guard, scrubbing past the buffered range
    /// would race the watchdog and surface a spurious
    /// `prolongedStall` error.  Cleared in the seek completion
    /// handler after the generation check passes.
    @Published private(set) var isSeeking: Bool = false

    /// Monotonic counter incremented at the start of every
    /// seek.  The completion handler captures the value at
    /// dispatch time and compares it against the live counter
    /// before clearing `isSeeking` — if a newer seek has
    /// started, the older completion is treated as stale and
    /// ignored (logged as `seek_stale`).  Lets the user mash
    /// the scrubber without older completions clobbering a
    /// newer in-flight seek.
    internal private(set) var seekGeneration: UInt64 = 0

    /// Snapshot of the user's playhead at the moment
    /// `retryPlayback()` was called, consumed by
    /// `startPlaybackSession(item:)` to seek back after the
    /// proxy re-init completes.  Populated only on the VOD
    /// DASH (proxy) path per PR-A architectural decision D4 —
    /// live / legacy MP4 playback restarts from 0.  Declared
    /// here for proximity to the other seek state; the actual
    /// snapshot/restore logic lands in Group 4.
    internal private(set) var retryRestoreTime: Double?

    /// **PR-A Group 5**: test-only setter for `retryRestoreTime`.
    /// Production code only writes this field from
    /// `retryPlayback()` (proxy branch); tests need to seed a
    /// pending restore target without firing the proxy load
    /// sequence, so we expose a tiny hook behind a `_ForTest`
    /// suffix that greps cleanly.
    internal func setRetryRestoreTimeForTest(_ value: Double?) {
        retryRestoreTime = value
    }

    /// **PR-B Commit 4 (A8 test)**: test-only access to the
    /// in-flight loadTask handle.  Production code mutates
    /// `loadTask` from `loadPlayback(_:)` / `runLoadPlayback(_:)`
    /// / `tearDown()`.  The `A8` test needs to assert that
    /// `loadPlayback(_:)` cleared a pre-seeded
    /// `retryRestoreTime` BEFORE the new loadTask got a chance
    /// to run; reading the handle here lets the test confirm
    /// exactly one loadTask was scheduled.
    internal var hasInFlightLoadTaskForTest: Bool {
        loadTask != nil
    }

    /// **PR-B Commit 4 (A8 test)**: test-only wrapper around
    /// `loadPlayback(_:)` that skips the proxy listener bind.
    /// In production `loadPlayback(_:)` kicks off
    /// `LocalHLSProxyServer.shared.serve(playback:)` which
    /// tries to bind a loopback listener; tests don't want to
    /// pay that cost (and would race other tests' listeners).
    /// We delegate to the same orchestration but route through
    /// the direct asset path so the test exercises the
    /// retryRestoreTime-clearing branch without a listener.
    ///
    /// Mirrors what the proxy branch's catch blocks (D6) do
    /// when they observe the cancellation — the test then
    /// asserts the field was cleared.
    internal func loadPlaybackForTest(_ playback: BiliPlayback) {
        // Reuse the production method but capture
        // retryRestoreTime BEFORE loadPlayback zeroes it (it
        // doesn't actually zero it; D6 only clears in catch
        // branches).  The test inspects after the call.
        loadPlayback(playback)
    }

    /// Tolerance applied to every seek path (user scrub,
    /// ±10 s double-tap, SponsorBlock auto-skip).  Half a
    /// second lets AVPlayer snap to the nearest keyframe
    /// instead of decoding the precise frame — past the
    /// buffered range this difference is the gap between
    /// "snaps immediately" and "buffer wheel for a second".
    /// Pinned so future refactors can't drift the value.
    private static let seekTolerance = CMTime(seconds: 0.5, preferredTimescale: 600)

    /// Test-accessible mirror of `seekTolerance`.  Group 5
    /// asserts that all seek paths use the same tolerance —
    /// the wrapper exposes the half-second pair as an
    /// `Equatable` value type so XCTest can read both halves
    /// without touching `CMTime` internals.
    internal struct SeekToleranceForTesting: Equatable {
        let toleranceBefore: CMTime
        let toleranceAfter: CMTime
    }
    internal static let seekToleranceForTesting = SeekToleranceForTesting(
        toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
        toleranceAfter:  CMTime(seconds: 0.5, preferredTimescale: 600)
    )

    // MARK: underlying AVPlayer

    /// The single `AVPlayer` instance the view layer binds to
    /// (`VideoPlayer(player: controller.player)` and the
    /// `AVPlayerViewController` in fullscreen both use this).
    /// Owned for the lifetime of the controller; `tearDown` calls
    /// `pause()` and removes the observers but does not
    /// deallocate the player (it lives as long as the controller
    /// does).
    let player: AVPlayer
    private var playerItem: AVPlayerItem
    /// Backing media for the player item.  Typed as the broad
    /// `AVAsset` so the composition path (an
    /// `AVMutableComposition` of two local mp4 tracks) and the
    /// upstream paths (`AVURLAsset` for live HLS, legacy MP4,
    /// or proxy m3u8) can both stash their asset here without
    /// casts.  The reference is retained for symmetry with the
    /// previous `let asset` shape and so future error-recovery
    /// hooks (e.g. reloading the asset on a stale-manifest
    /// diagnostic) have somewhere to reach the live object.
    private let asset: AVAsset
    /// Original `BiliPlayback` for retry.  Kept so
    /// `retryPlayback()` can re-stand the local proxy and
    /// hand AVPlayer a fresh manifest without the caller
    /// having to re-supply the DASH source.  Direct-asset
    /// (live / legacy MP4) paths reuse `asset` directly and
    /// don't read this.
    private let originalPlayback: BiliPlayback
    /// `true` if this controller is fed by the local HLS proxy
    /// (the VOD DASH path).  When `false`, the asset is a direct
    /// `AVURLAsset` (live HLS or legacy MP4) or an
    /// `AVMutableComposition` of merged local mp4 tracks; the
    /// proxy is not involved.
    ///
    /// `internal private(set) var` so Group 5 tests can read
    /// the proxy-vs-direct routing without exposing mutation.
    /// The init-time assignment `self.usesProxy = usesProxy`
    /// works identically for `let` and `var`.
    internal private(set) var usesProxy: Bool

    // MARK: observers / timer

    private var pollTimer: Timer?
    private var observers: Set<NSKeyValueObservation> = []
    private var statusObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    /// Prolonged-stall watchdog — see `init()` for the
    /// rationale.  Held so `tearDown()` can cancel it before
    /// the controller is dropped; otherwise a discarded
    /// controller would still fire a `.prolongedStall` write
    /// against the next one's state.
    private var stallTimerTask: Task<Void, Never>?
    /// **Build 182**: the orchestration task that drives
    /// `LocalHLSProxyServer.serve(playback:) async throws ->
    /// URL` → endpoint self-test → `replaceCurrentItem` →
    /// `playbackState = .ready`.  Held so `retryPlayback()`
    /// and video-switch can cancel an in-flight load before
    /// the next one starts (otherwise an old loadTask
    /// completing in the background would write `playbackState
    /// = .ready` after a newer loadTask had already started).
    private var loadTask: Task<Void, Never>?
    /// Token returned by `addPeriodicTimeObserver`.  We hold it
    /// to keep the observer alive and to remove it on
    /// `tearDown`.  `AVPlayer.currentTime` is a method, not a
    /// KVO-observable property, so the per-frame time updates
    /// come from a periodic time observer instead.
    private var timeObserver: Any?

    /// One-shot guard for `AVAudioSession.setActive`.
    /// Previously called from `PaladalaApp.init()` on every
    /// cold start; deferred to the first `PlayerController`
    /// construction so a launch that never plays audio
    /// (e.g. user only browses the Downloads tab) skips the
    /// audio HAL priming entirely.  Read+write are not
    /// atomic in isolation, but `PlayerController` is
    /// `@MainActor`-isolated so all callsites are.
    private static var didActivateAudioSession = false

    private static func activateAudioSessionOnce() {
        guard !didActivateAudioSession else { return }
        didActivateAudioSession = true
        // `.playback` lets the audio play when the silent
        // switch is on (the AliPlayer path did the same).
        // PR-B B15: previously both `try?` calls silently
        // swallowed AVAudioSession errors — category set
        // failure (audio HAL conflict) and `setActive`
        // failure (interrupted by another app's session)
        // both produced identical no-op behaviour with no
        // diagnostic.  Each is now logged so an
        // audio-output anomaly in the field can be
        // attributed to a session-setup failure vs. a
        // post-setup interruption.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .moviePlayback, options: []
            )
        } catch {
            diagLog(.audio, "AVAudioSession.setCategory failed",
                    details: ["error": error.localizedDescription])
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            diagLog(.audio, "AVAudioSession.setActive failed",
                    details: ["error": error.localizedDescription])
        }
    }

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
    /// `bvid` of the currently-playing video.  Set in `init`
    /// so the periodic time observer can persist play progress
    /// to `PlayProgressStore` keyed by `bvid`.  `nil` for live
    /// rooms (their streams have no resumable state).
    let nowPlayingBvid: String?
    /// Cached artwork.  Built once when the coverURL resolves,
    /// then handed to `MPMediaItemArtwork` on every Now Playing
    /// refresh so we don't re-wrap a `UIImage` twice a second.
    private var nowPlayingArtwork: MPMediaItemArtwork?

    // MARK: lifecycle

    init(playback: BiliPlayback, video: BiliVideo? = nil) {
        diagLog(.playback, "Initialising AVPlayerController", details: [
            "isDASH": playback.isDASH,
            "referer": playback.referer.absoluteString,
            "hasMergedLocal": playback.localContext?.mergedVideo != nil
        ])

        // Activate the shared audio session on the first
        // controller that comes up.  Deferred from
        // `PaladalaApp.init()` so a cold start that never
        // opens a video never touches the audio HAL (saves
        // 100–400 ms per the cold-start audit).  Re-entrant
        // safe — `setActive` is idempotent.
        Self.activateAudioSessionOnce()

        self.nowPlayingTitle = video?.title ?? "直播"
        self.nowPlayingArtist = video?.ownerName ?? "Paladala"
        self.nowPlayingCoverURL = video?.coverURL
        self.nowPlayingBvid = video?.id

        let referer = playback.referer.absoluteString
        var asset: AVAsset
        let usesProxy: Bool
        var initialPlayerError: PlayerPlaybackError?

        // Fast path: a downloaded video with the merged
        // mp4 files on disk.  We play both tracks through
        // an `AVMutableComposition` and skip the local HLS
        // proxy entirely.  This eliminates the upstream-
        // offset byte-range math that broke every time
        // B 站 shifted `track.initializationRange.offset` /
        // `track.mediaStartOffset`, and removes the
        // proxy as a single point of failure for offline
        // playback.  The composition reuses the same
        // underlying media data the proxy would have read,
        // so there is no extra disk cost.
        if let merged = playback.localContext?.mergedVideo,
           FileManager.default.fileExists(atPath: merged.path) {
            let videoURL = merged
            let audioURL = playback.localContext?.mergedAudio
            // Build the composition synchronously — the
            // assets are on local disk so track discovery
            // does not need the network.  If audio is
            // missing or unreadable we fall back to
            // video-only (the user still sees the picture
            // and gets a clear diagnostic line rather than
            // a black screen).
            let videoAsset = AVURLAsset(url: videoURL)
            var insertDuration: CMTime = .positiveInfinity
            if let videoTrack = videoAsset.tracks(withMediaType: .video).first {
                insertDuration = videoTrack.timeRange.duration
            }
            let composition = AVMutableComposition()
            if let compVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ), let sourceVideoTrack = videoAsset
                .tracks(withMediaType: .video).first {
                do {
                    try compVideoTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: insertDuration),
                        of: sourceVideoTrack,
                        at: .zero
                    )
                } catch {
                    diagLog(.playback,
                            "merge video insert failed",
                            details: ["error": error.localizedDescription])
                }
            }
            var audioAttached = false
            if let audioURL,
               FileManager.default.fileExists(atPath: audioURL.path) {
                let audioAsset = AVURLAsset(url: audioURL)
                if let compAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ), let sourceAudioTrack = audioAsset
                    .tracks(withMediaType: .audio).first {
                    let audioDuration = sourceAudioTrack.timeRange.duration
                    // `CMTime` doesn't conform to `Comparable`,
                    // so we use the C interop helper
                    // `CMTimeMinimum(...)` rather than Swift's
                    // `min(_:_:)`.  Clamping the audio slice to
                    // the video length keeps the two tracks
                    // aligned even when the upstream audio
                    // track runs a fraction of a second
                    // longer (a known quirk of B站 DASH audio
                    // tracks where the publisher pads the
                    // tail with silence).
                    let slice = CMTimeRange(
                        start: .zero,
                        duration: CMTimeMinimum(audioDuration,
                                                insertDuration)
                    )
                    do {
                        try compAudioTrack.insertTimeRange(
                            slice, of: sourceAudioTrack, at: .zero
                        )
                        audioAttached = true
                    } catch {
                        diagLog(.playback,
                                "merge audio insert failed",
                                details: ["error": error.localizedDescription])
                    }
                }
            }
            asset = composition
            usesProxy = false
            diagLog(.playback,
                    "AVPlayerController bound to merged local mp4",
                    details: [
                        "video": videoURL.lastPathComponent,
                        "audio": audioURL?.lastPathComponent ?? "none",
                        "audioAttached": audioAttached,
                        "durationSec":
                            CMTimeGetSeconds(insertDuration)
                    ])
        } else if playback.dash != nil {
            // VOD DASH path: stand up the local HLS proxy
            // and point AVPlayer at the synthesised master
            // playlist.  **Build 182**: replaces the old
            // fire-and-forget `serve` + `waitForReady` +
            // `AVURLAsset` path with the async `loadPlayback`
            // orchestration below.  `init` only sets a
            // placeholder `AVMutableComposition` and lets
            // `loadPlayback` swap in the real `AVPlayerItem`
            // once the proxy's manifest is ready (and only
            // after a local 200 endpoint self-test).
            asset = AVMutableComposition()
            usesProxy = true
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
            // PR-B D8: previously this path crashed the app
            // with `fatalError` when a BiliPlayback had neither
            // a DASH source nor a fallback URL — schema drift
            // from the B站 server, region block, or a stale
            // cached playback payload.  Surface through the
            // existing playbackErrorOverlay so the user sees
            // a graceful "视频源不可用" message and the developer
            // gets a diagnostic dump instead of a process abort.
            let detail = "BiliPlayback has no DASH source and no fallback URL"
            diagLog(.playback,
                    "AVPlayerController: no DASH source and no fallback",
                    details: [
                        "isDASH": playback.isDASH,
                        "hasMergedLocal": playback.localContext?.mergedVideo != nil,
                        "fallback": playback.fallbackURL?.absoluteString ?? "nil"
                    ])
            initialPlayerError = .playbackSourceUnavailable(detail: detail)
            // Bind an `about:blank` URL asset so AVPlayer
            // has a valid item to attach observers to; the
            // overlay will surface the error and the user
            // can tap "重新播放" without a process crash.
            asset = AVURLAsset(url: URL(string: "about:blank")!)
            usesProxy = false
        }

        self.asset = asset
        self.usesProxy = usesProxy
        self.originalPlayback = playback
        self.playerError = initialPlayerError

        let item = AVPlayerItem(asset: asset)

        // Build 182: the seek-to-resume-time call moved
        // into `startPlaybackSession(item:)`.  See the
        // proxy-path branch below — the placeholder item
        // used in the proxy path has no duration, so
        // seeking on it is wasted; `startPlaybackSession`
        // runs after the real item is bound.
        self.playerItem = item
        self.player = AVPlayer(playerItem: item)

        // Audio session activation lives in
        // `activateAudioSessionOnce()` below — invoked at the
        // top of `init()`.  Re-activating on every controller
        // is unnecessary; the first one primes the HAL.

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
                    guard let self else { return }
                    // PR-5 (M5): throttle `currentTime`
                    // publication to the integer-second boundary.
                    // The 2 Hz observer drove every observing view
                    // (MusicProgressBar, LyricScrollView,
                    // MusicPlayerView, PlayerView, mini-player) to
                    // repaint twice per second indefinitely.  At
                    // 1 Hz the slider / progress bar still moves
                    // smoothly (one pixel per refresh on Retina),
                    // downstream observers update less, and
                    // PlayProgressStore still gets enough samples
                    // to persist the right resume time.
                    let wholeSecond = Int(seconds)
                    let previousWholeSecond = Int(self.currentTime)
                    if wholeSecond != previousWholeSecond {
                        self.currentTime = seconds
                    }
                    // Persist to disk so the user can resume after
                    // a kill / crash / `Caches` purge.  The store
                    // coalesces internally (won't rewrite the JSON
                    // more than once every 5 s, or when the
                    // playhead barely moves), so this 2 Hz loop
                    // does not churn disk I/O.
                    let duration = CMTimeGetSeconds(self.player.currentItem?.duration ?? .zero)
                    PlayProgressStore.shared.update(
                        bvid: self.nowPlayingBvid ?? "",
                        currentTime: seconds,
                        duration: duration
                    )
                    // Keep the lock-screen playhead in sync.  Two
                    // updates per second is cheap (the dict has no
                    // new keys after the first write) and gives
                    // Control Center a moving scrubber.
                    self.updateNowPlaying()
                    // PR-A Group 1: SponsorBlock check no longer
                    // takes an AVPlayer and seeks from inside.
                    // The check now returns the seek target (or
                    // nil); the controller routes the seek through
                    // `performSeek(_:)` so it participates in the
                    // generation guard + tolerance + log pipeline.
                    if let sponsorTarget = SponsorBlockManager.shared.checkCurrentTime(seconds) {
                        self.seekToSponsorSegmentEnd(sponsorTarget)
                    }
                }
            }
        }

        // **Build 182**: KVO observers are installed via
        // `installObservers(on:)` so both `init` (placeholder
        // item) and `loadPlayback` (real item) use the same
        // observer wiring with the `[weak self, weak item] +
        // currentItem === item` guard (item #10).
        installObservers(on: item)

        // **Build 182**: NotificationCenter observers are
        // installed via `installNotificationObservers(on:)`
        // so both `init` (placeholder item) and `loadPlayback`
        // (real item) re-attach them on the new item with
        // the same `[weak self]` + `currentItem === item`
        // guard pattern (item #10).
        installNotificationObservers(on: item)

        // Periodically poll: AVPlayer does not push a
        // "rate changed" event for the `rate=0 → rate=1`
        // transition that happens on play(), so we sweep
        // `player.timeControlStatus` and `player.rate` from
        // a 2Hz timer.
        startPolling()

        // Prolonged-stall watchdog. AVPlayer reports buffer
        // state via `isPlaybackBufferEmpty` (line 312-321) but
        // a brief hiccup is normal — only surface an error if
        // the buffer has been empty for ≥ 10 s.  The task is
        // cancelled in `tearDown()` so a player that's been
        // paused and discarded doesn't fire a phantom error.
        //
        // **PR-A Group 1**: gated on `!isSeeking` so a seek
        // in flight doesn't race the watchdog.  Without this
        // guard, scrubbing past the buffered range would let
        // the 10 s timer fire while AVPlayer was still
        // settling on the new keyframe, surfacing a phantom
        // `prolongedStall` error.  Seek completion re-arms
        // the watchdog via `armStallWatchdog()` if AVPlayer
        // is still buffering after the seek lands.
        stallTimerTask = Task { @MainActor [weak self] in
            let startedAt = Date()
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            if self.isBuffering && !self.isSeeking && self.playerError == nil {
                self.playerError = .prolongedStall
                diagLog(.playback, "PlayerController.playerError assigned", details: [
                    "case": "prolongedStall",
                    "isSeeking": self.isSeeking,
                    "isBuffering": self.isBuffering,
                    "seekGeneration": self.seekGeneration,
                    "stalledFor": Date().timeIntervalSince(startedAt)
                ])
            }
        }

        // **Build 182**: for the proxy path, do NOT call
        // `startPlaybackSession(item:)` here — the proxy
        // item doesn't exist yet (it will be constructed
        // inside `loadPlayback(_:)` once the proxy's
        // manifest is ready).  Instead, kick off the
        // loadTask; it will call `startPlaybackSession`
        // after binding the real item.
        if !usesProxy {
            startPlaybackSession(item: item)
        } else {
            // **Build 182 orchestration.**  Start the
            // async loadTask.  `init` returns immediately;
            // the task will await `serve(playback:) async`,
            // run the endpoint self-test, swap in a fresh
            // `AVPlayerItem`, and call
            // `startPlaybackSession(item:)` itself.
            loadPlayback(playback)
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
        // PR-B B1: previously `try?` swallowed both the
        // network failure and the decode failure into a
        // single `nil` return with no diagnostic.  Now each
        // path emits a distinct diagLog so the operator can
        // tell whether the failure was network (cover fetch
        // rejected by the CDN) or decode (CDN served a
        // non-image response or a corrupt payload).
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let image = UIImage(data: data) else {
                diagLog(.playback,
                        "cover download failed",
                        details: [
                            "url": url.absoluteString,
                            "reason": "decode",
                            "bytes": data.count
                        ])
                return nil
            }
            return image
        } catch {
            diagLog(.playback,
                    "cover download failed",
                    details: [
                        "url": url.absoluteString,
                        "reason": "fetch",
                        "error": error.localizedDescription
                    ])
            return nil
        }
    }

    // MARK: playback orchestration

    /// Build 182: do the playback-side wiring (seek to
    /// resume time, load SponsorBlock segments, call
    /// `player.play()`) for `item`.  Pulled out of `init`
    /// so the proxy-path `loadPlayback(_:)` can call it
    /// after `replaceCurrentItem(with:)` — identical work,
    /// different caller.
    private func startPlaybackSession(item: AVPlayerItem) {
        // PR-4 (premium-UX plan, Milestone 3): previously we
        // silently auto-seek to `resumeTime` if it was > 0.  That
        // was the single most-cited "where was I?" friction
        // shape in App Store reviews for similar apps — the user
        // never sees confirmation and can't choose to restart.
        // Resume-confirmation is now owned by the SwiftUI sheet
        // (`VideoDetailView.resumePromptSheet`) — we just play
        // from 0 here and let the user pick.
        _ = originalPlayback.resumeTime
        if let sbBvid = nowPlayingBvid {
            SponsorBlockManager.shared.reset(for: sbBvid)
            SponsorBlockManager.shared.loadSegments(for: sbBvid)
        }
        if isPlaying {
            player.play()
        }
        // **PR-A Group 4 (item 9, D4)**: if a retry on the proxy
        // path captured the previous playhead, restore it now
        // (after `play()` so AVPlayer's seek target is honoured).
        // Goes through the Group-1 instrumented performSeek so it
        // participates in seekGeneration + tolerance + logging.
        if let restore = retryRestoreTime {
            retryRestoreTime = nil
            diagLog(.playback, "retry_restore", details: [
                "restoreTo": restore
            ])
            // PR-B D5: `fromRestore: true` skips the
            // upper-bound clamp in performSeek because
            // `self.duration` is still 0 here (the periodic
            // observer hasn't published the real duration
            // yet).  AVPlayer clamps internally.
            performSeek(restore, fromRestore: true)
        }
    }

    /// **Build 182 orchestration entry point.**  Drives the
    /// full VOD-DASH proxy load sequence:
    ///
    /// 1. `LocalHLSProxyServer.shared.serve(playback:) async`
    ///    waits for both listener bind AND SIDX manifest
    ///    publish.
    /// 2. Local 200 endpoint self-test on `/playlist.m3u8`,
    ///    `/video.m3u8`, `/audio.m3u8` so a 503 from the
    ///    playlist handler can never reach AVPlayer.
    /// 3. `AVPlayerItem(url:)` + `replaceCurrentItem(with:)`.
    /// 4. Re-install KVO observers on the new item with the
    ///    `[weak self, weak item]` + `currentItem === item`
    ///    guard (item #10 — old item's KVO can't poison the
    ///    new state).
    /// 5. `startPlaybackSession(item:)` for seek +
    ///    SponsorBlock + play.
    /// 6. `playbackState = .ready`.
    ///
    /// Cancellation: `loadTask?.cancel()` from `retryPlayback()`
    /// or a future video-switch cancels mid-flight; the
    /// `Task.checkCancellation()` calls in the chain throw
    /// `CancellationError`, which is mapped to
    /// `.playbackState = .idle` (preserving the previous
    /// observable state if the task finished already).
    func loadPlayback(_ playback: BiliPlayback) {
        // PR-B B8: log before the cancel so the operator
        // can tell whether a slow old loadTask was
        // superseded (`hadTask=true`) or whether no prior
        // load was running (`hadTask=false`).  Without
        // this distinction, a slow-then-fast load pair is
        // indistinguishable from a single cold load in
        // the diagnostic dump.
        let hadTask = loadTask != nil
        if hadTask {
            diagLog(.playback, "loadTask.cancel",
                    details: ["hadTask": true])
        }
        loadTask?.cancel()
        playbackState = .preparing
        playerError = nil
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runLoadPlayback(playback)
        }
    }

    /// Internal async body of `loadPlayback(_:)`.  Split
    /// out so the public method reads cleanly.
    private func runLoadPlayback(_ playback: BiliPlayback) async {
        do {
            let url = try await LocalHLSProxyServer.shared.serve(playback: playback)
            try Task.checkCancellation()
            diagLog(.playback,
                    "AVPlayerController manifest ready, self-testing endpoints",
                    details: ["url": url.absoluteString])
            try await validateLocalEndpoints(url: url)
            try Task.checkCancellation()

            let item = AVPlayerItem(url: url)
            // Detach observers attached to the previous
            // (placeholder) item, swap the item in, then
            // re-attach observers on the new item.  Order
            // matters: `replaceCurrentItem` must run before
            // `installObservers` so the new observers' guard
            // (`self.player.currentItem === item`) sees the
            // new item as current.
            observers.forEach { $0.invalidate() }
            observers.removeAll()
            if let token = statusObserver {
                NotificationCenter.default.removeObserver(token)
                statusObserver = nil
            }
            if let token = errorObserver {
                NotificationCenter.default.removeObserver(token)
                errorObserver = nil
            }
            if let token = errorLogObserver {
                NotificationCenter.default.removeObserver(token)
                errorLogObserver = nil
            }
            player.replaceCurrentItem(with: item)
            self.playerItem = item
            installObservers(on: item)
            installNotificationObservers(on: item)
            startPlaybackSession(item: item)

            playbackState = .ready
            diagLog(.playback,
                    "AVPlayerController bound to local HLS proxy",
                    details: [
                        "url": url.absoluteString,
                        "manifestReady": true
                    ])
        } catch is CancellationError {
            // PR-B D6: clear the pending restore snapshot
            // even on the cancellation path.  Without this,
            // a load cancelled between `retryPlayback()`
            // and `startPlaybackSession(item:)` would leave
            // `retryRestoreTime` set; a future successful
            // `loadPlayback(_:)` (e.g. from a video switch)
            // would then seek the user back to the old
            // playhead.  `tearDown()` already clears it, but
            // teardown isn't reached when the load is just
            // cancelled and the controller is reused.
            retryRestoreTime = nil
            if playbackState == .preparing {
                playbackState = .idle
            }
            diagLog(.playback, "AVPlayerController loadPlayback cancelled",
                    details: ["state": "\(playbackState)"])
        } catch {
            // PR-B D6: same rationale as the cancellation
            // path above — a failed load shouldn't leak the
            // restore snapshot to a future playback session.
            retryRestoreTime = nil
            let pbError: PlayerPlaybackError
            if let proxy = error as? PlayerPlaybackError {
                pbError = proxy
            } else {
                pbError = .itemFailed(detail: "\(error)")
            }
            playerError = pbError
            playbackState = .failed(pbError)
            diagLog(.playback,
                    "AVPlayerController loadPlayback failed",
                    details: ["error": "\(error)"])
        }
    }

    /// **Build 182**: extract KVO observer wiring into a
    /// method so `loadPlayback(_:)` can call it on the
    /// newly constructed item.  All observers capture
    /// `[weak self, weak item]` and short-circuit when
    /// `self.player.currentItem !== item` — prevents the
    /// old item's KVO from poisoning the new state (item
    /// #10).  Mirrors the original wiring 1:1 otherwise.
    private func installObservers(on item: AVPlayerItem) {
        observers.insert(
            item.observe(\.isPlaybackBufferEmpty, options: [.new, .initial]) {
                [weak self, weak item] _, change in
                Task { @MainActor in
                    guard let self, let item else { return }
                    guard self.player.currentItem === item else { return }
                    self.isBuffering = change.newValue ?? false
                }
            }
        )
        observers.insert(
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.new, .initial]) {
                [weak self, weak item] _, change in
                Task { @MainActor in
                    guard let self, let item else { return }
                    guard self.player.currentItem === item else { return }
                    if change.newValue == true { self.isBuffering = false }
                }
            }
        )
        observers.insert(
            item.observe(\.loadedTimeRanges, options: [.new]) {
                [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item else { return }
                    guard self.player.currentItem === item else { return }
                    self.logLoadedTimeRanges()
                }
            }
        )
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
        observers.insert(
            item.observe(\.status, options: [.new, .initial]) {
                [weak self, weak item] _, _ in
                guard let item else { return }
                let currentStatus = item.status
                let status = Self.describe(itemStatus: currentStatus)
                let err = item.error
                Task { @MainActor in
                    guard let self else { return }
                    guard self.player.currentItem === item else { return }
                    var details: [String: Any] = ["status": status]
                    if let err {
                        details["error"] = String(describing: err)
                        if let events = item.errorLog()?.events, !events.isEmpty {
                            details["errorLogEvents"] = events.suffix(5).map { event in
                                [
                                    "statusCode": event.errorStatusCode,
                                    "domain": event.errorDomain,
                                    "comment": event.errorComment ?? "",
                                    "uri": event.uri ?? "",
                                    "server": event.serverAddress ?? "",
                                    "session": event.playbackSessionID ?? ""
                                ] as [String: Any]
                            }
                        }
                        Analytics.recordError(err, context: "player_item_status_failed")
                        Analytics.log("player_item_status_failed", [
                            "status": status,
                            "error": String(describing: err)
                        ])
                    }
                    diagLog(.playback, "AVPlayerItem status changed", details: details)
                    if currentStatus == .failed {
                        let detail = err.map { String(describing: $0) }
                        self.playerError = .itemFailed(detail: detail)
                        diagLog(.playback,
                                "PlayerController.playerError assigned",
                                details: [
                                    "case": "itemFailed",
                                    "detail": detail ?? ""
                                ])
                    }
                }
            }
        )
    }

    /// **Build 182**: NotificationCenter observer wiring
    /// extracted from `init` so `loadPlayback(_:)` can
    /// re-attach them on the real item.  Each closure
    /// captures `[weak self, weak item]` and short-circuits
    /// when `self.player.currentItem !== item` — prevents
    /// the old placeholder's notifications from poisoning
    /// the new state (item #10).
    private func installNotificationObservers(on item: AVPlayerItem) {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item else { return }
                guard self.player.currentItem === item else { return }
                self.isPlaying = false
                let totalSeconds = self.player.currentItem?.duration.seconds ?? 0
                Analytics.log("video_complete", [
                    "duration_seconds": totalSeconds
                ])
                Analytics.breadcrumb("PLAY", "video_complete")
                NotificationCenter.default.post(
                    name: .paladalaVideoDidPlayToEnd,
                    object: self.player.currentItem
                )
            }
        }
        errorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main
        ) { [weak self, weak item] note in
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
                guard let self, let item else { return }
                guard self.player.currentItem === item else { return }
                self.isPlaying = false
                self.isBuffering = false
                let detail = err.map { String(describing: $0) }
                self.playerError = .stoppedMidStream(detail: detail)
                diagLog(.playback, "PlayerController.playerError assigned", details: [
                    "case": "stoppedMidStream",
                    "detail": detail ?? ""
                ])
            }
        }
        errorLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item, queue: .main
        ) { [weak self, weak item] _ in
            guard let item else { return }
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
                let code = last.errorStatusCode
                if (400..<500).contains(code) {
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.player.currentItem === item else { return }
                        self.playerError = .proxyFailed(code: code)
                        diagLog(.playback, "PlayerController.playerError assigned", details: [
                            "case": "proxyFailed",
                            "code": code
                        ])
                    }
                }
            }
        }
    }

    /// **Build 182**: probe `/playlist.m3u8`, `/video.m3u8`,
    /// `/audio.m3u8` against the local proxy and verify all
    /// three return 200 within a 2-second budget.  Catches a
    /// race between `publishAndStart` and the first AVPlayer
    /// request — without this guard, AVPlayer could see a 503
    /// from `respondMediaPlaylist` and permanently mark the
    /// item as failed.
    ///
    /// Throws `PlayerPlaybackError.proxyFailed(code: -1)` on
    /// any non-200 or transport failure; the caller
    /// (`loadPlayback`) translates this to
    /// `playbackState = .failed(...)`.
    private func validateLocalEndpoints(url: URL) async throws {
        // Build the probe URLs via `URLComponents` relative
        // resolution instead of string concatenation.
        //
        // **Build 183 fix**: the previous code did
        // `url.deletingLastPathComponent().absoluteString + path`,
        // which produced `"http://127.0.0.1:52461/" +
        // "/playlist.m3u8"` → `"http://127.0.0.1:52461//playlist.m3u8"`
        // (double slash).  The route table only matches
        // `"/playlist.m3u8"` so the request fell into the
        // default branch and returned 404.  Resolving
        // `path` against the base URL via URLComponents
        // produces the correct single-slash form.
        let paths = ["/playlist.m3u8", "/video.m3u8", "/audio.m3u8"]
        let deadline = Date().addingTimeInterval(2.0)
        let session = URLSession.shared
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw PlayerPlaybackError.proxyFailed(code: -1)
        }
        for path in paths {
            try Task.checkCancellation()
            guard Date() < deadline else {
                diagLog(.playback,
                        "endpoint self-test timeout",
                        details: ["path": path])
                throw PlayerPlaybackError.proxyFailed(code: -1)
            }
            components.path = path
            components.query = nil
            guard let probe = components.url else { continue }
            var req = URLRequest(url: probe, timeoutInterval: 1.5)
            req.httpMethod = "GET"
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard code == 200 else {
                    let bodyText = String(
                        data: data,
                        encoding: .utf8
                    ) ?? "<non-utf8 body \(data.count) bytes>"
                    diagLog(.playback,
                            "endpoint self-test non-200",
                            details: [
                                "path": path,
                                "statusCode": code,
                                "body": bodyText
                            ])
                    throw PlayerPlaybackError.proxyFailed(code: code)
                }
                diagLog(.playback,
                        "endpoint self-test 200",
                        details: ["path": path])
            } catch let error as PlayerPlaybackError {
                throw error
            } catch {
                diagLog(.playback,
                        "endpoint self-test transport failed",
                        details: [
                            "path": path,
                            "error": "\(error)"
                        ])
                throw PlayerPlaybackError.proxyFailed(code: -1)
            }
        }
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
                // `queue: .main` guarantees this closure
                // runs on the main thread, and the closure
                // body touches `@MainActor`-isolated state
                // (`isPictureInPictureActive` /
                // `updateNowPlaying()`).  `MainActor.
                // assumeIsolated` lets us bridge the
                // non-Sendable closure boundary to the
                // MainActor isolation domain without an
                // `await` hop (the hop would force a
                // Task, which in turn is fire-and-forget —
                // we want a synchronous state flip so the
                // MPNowPlayingInfoCenter update lands in
                // the same runloop turn as the PiP
                // notification).
                MainActor.assumeIsolated {
                    self?.isPictureInPictureActive = true
                    self?.updateNowPlaying()
                }
            }
        )
        pipObservers.append(
            center.addObserver(
                forName: .paladalaPiPDidStop, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isPictureInPictureActive = false
                    self?.updateNowPlaying()
                }
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
    /// **PR-A Group 1**: routes through `performSeek(_:)` so
    /// the seek-in-flight guard (`isSeeking` +
    /// `seekGeneration`) and the uniform 0.5 s tolerance
    /// apply.  Direct `player.seek(to:)` is no longer used by
    /// any caller — `performSeek` is the single entry point.
    func seek(by offset: Double) {
        let now = CMTimeGetSeconds(player.currentTime())
        guard now.isFinite, duration > 0 else { return }
        let target = max(0, min(duration, now + offset))
        performSeek(target)
    }

    /// Seek to an absolute timestamp in seconds.  Used by the
    /// music player's lyric scroller — tapping a lyric line
    /// seeks the playhead to that line's `startTime` rather
    /// than jumping by a fixed offset.  Clamps to
    /// `[0, duration]` for the same reason `seek(by:)` does.
    ///
    /// **PR-A Group 1**: routes through `performSeek(_:)`.
    func seek(to seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        let target = max(0, min(duration, seconds))
        performSeek(target)
    }

    /// SponsorBlock auto-skip entry point.  Called from the
    /// periodic time observer when
    /// `SponsorBlockManager.shared.checkCurrentTime(_:)` returns
    /// a non-nil target (i.e. the playhead has entered a
    /// sponsored segment and should jump to its end).
    ///
    /// **PR-A Group 1**: previously the manager called
    /// `player.seek(to:)` directly with the default
    /// (zero-tolerance) seek.  That bypassed the controller's
    /// `seekGeneration` + `isSeeking` + `seekTolerance`
    /// machinery — a SponsorBlock skip during a user scrub
    /// could clobber `isSeeking = false` when its completion
    /// fired.  Routing through `performSeek(_:)` makes the
    /// skip first-class: it participates in the same
    /// generation-guarded completion handler as user seeks.
    func seekToSponsorSegmentEnd(_ time: Double) {
        performSeek(time)
    }

    /// The single AVPlayer.seek entry point.  Every public seek
    /// (`seek(by:)`, `seek(to:)`, `seekToSponsorSegmentEnd(_:)`)
    /// and the `retryPlayback()` restore path (Group 4) calls
    /// through here so the generation guard, the tolerance,
    /// and the seek log lines are applied uniformly.
    ///
    /// Bumps `seekGeneration` BEFORE the AVPlayer.seek call so
    /// any older in-flight completion sees a stale generation
    /// and bails out.  Clears `isSeeking` in the completion
    /// handler ONLY if the generation still matches — older
    /// completions are ignored as `seek_stale`.
    ///
    /// If AVPlayer is still buffering after the seek lands,
    /// the prolonged-stall watchdog is re-armed so the
    /// post-seek buffering has its own 10 s budget separate
    /// from the pre-seek one.
    ///
    /// `fromRestore` is `true` only for the seek-to-resume-time
    /// path invoked from `startPlaybackSession(item:)` after a
    /// proxy retry (PR-B D5).  When `true` we skip the upper
    /// bound on the clamp because `self.duration` is published
    /// by the periodic-time observer ~250 ms after item binding
    /// and is still 0 here; AVPlayer's own `seek(to:)` will
    /// clamp to the real duration internally.  Without this
    /// guard the user is bounced to 0:00 every retry.
    private func performSeek(_ target: Double, fromRestore: Bool = false) {
        let liveDuration: Double = {
            let d = duration
            if d > 0 { return d }
            // PR-B D5: AVPlayer publishes `duration` via the
            // periodic-time observer ~250 ms after item binding,
            // so `self.duration` is still 0 on the restore path.
            // Read the AVAsset duration synchronously — it
            // returns `.nan` when unknown rather than 0.
            let assetDuration = player.currentItem?.asset.duration.seconds ?? .nan
            return assetDuration.isFinite ? assetDuration : d
        }()
        let clamped = fromRestore
            ? max(0, target)         // PR-B D5: AVPlayer clamps the
                                     // upper bound internally.
            : max(0, min(liveDuration, target))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        seekGeneration &+= 1
        let generation = seekGeneration
        isSeeking = true
        // PR-B D7: arm the prolonged-stall watchdog BEFORE the
        // seek lands so any buffering that starts immediately
        // after `player.seek` returns (the typical case when
        // scrubbing past the buffered range) is covered from
        // the moment the seek fires — not just from the moment
        // its completion handler runs (which can be tens of ms
        // later when AVPlayer is still settling on a keyframe).
        // The post-seek re-arm at the end of the completion
        // handler stays — together they guarantee the
        // 10 s stall budget applies to *post-seek* buffering
        // from time-zero.
        if isBuffering && playerError == nil {
            armStallWatchdog()
        }
        diagLog(.playback, "seek_begin", details: [
            "generation": generation,
            "from": String(format: "%.3f", CMTimeGetSeconds(player.currentTime())),
            "to": String(format: "%.3f", clamped),
            "duration": String(format: "%.3f", duration),
            "fromRestore": fromRestore
        ])
        player.seek(
            to: time,
            toleranceBefore: Self.seekTolerance,
            toleranceAfter: Self.seekTolerance
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.seekGeneration == generation else {
                    diagLog(.playback, "seek_stale", details: [
                        "generation": generation,
                        "current": self.seekGeneration
                    ])
                    return
                }
                self.isSeeking = false
                diagLog(.playback, "seek_complete", details: [
                    "generation": generation,
                    "finished": finished,
                    "landedAt": String(format: "%.3f", CMTimeGetSeconds(self.player.currentTime()))
                ])
                if self.isBuffering && self.playerError == nil {
                    self.armStallWatchdog()
                }
            }
        }
    }

    /// Re-arm the prolonged-stall watchdog with a fresh 10 s
    /// timer.  Called from two sites:
    ///
    ///  1. The end of the buffering-detection branch in the
    ///     `isPlaybackBufferEmpty` KVO observer (initial arm
    ///     on entering `.buffering`).
    ///  2. The end of `performSeek`'s completion handler, when
    ///     the seek lands but AVPlayer is still buffering
    ///     (e.g. the user scrubbed past the buffered range).
    ///
    /// Cancels any in-flight watchdog first so we never have
    /// two timers racing.  The `!isSeeking` guard inside the
    /// task is what makes the post-seek re-arm safe: a
    /// second seek started during the gap can't accidentally
    /// cancel this watchdog before the timer fires.
    private func armStallWatchdog() {
        stallTimerTask?.cancel()
        stallTimerTask = Task { @MainActor [weak self] in
            let startedAt = Date()
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            if self.isBuffering && !self.isSeeking && self.playerError == nil {
                self.playerError = .prolongedStall
                diagLog(.playback, "PlayerController.playerError assigned", details: [
                    "case": "prolongedStall",
                    "isSeeking": self.isSeeking,
                    "isBuffering": self.isBuffering,
                    "seekGeneration": self.seekGeneration,
                    "stalledFor": Date().timeIntervalSince(startedAt)
                ])
            }
        }
    }

    // MARK: recovery

    /// Clear `playerError` and re-issue the playback request
    /// the recovery button is bound to.  Two paths:
    ///
    ///  - **VOD DASH** (`usesProxy == true`): re-stand the
    ///    local proxy with the original `BiliPlayback` via
    ///    `loadPlayback(_:)`.  The previous loadTask is
    ///    cancelled first so a slow old prep can't race a
    ///    fast new one.  `playbackState` becomes `.preparing`
    ///    immediately.
    ///  - **Live / legacy MP4** (`usesProxy == false`):
    ///    replace the current item with a fresh
    ///    `AVPlayerItem(asset:)`.  We don't re-fetch the
    ///    HLS manifest — Bilibili's CDN rotates the live
    ///    manifest anyway, so the existing `asset` URLs are
    ///    still valid; only the AVPlayer-level state needed
    ///    a reset.
    ///
    /// **Build 182 guard**: only runs from
    /// `playbackState == .ready`.  Critically, never runs
    /// while `playbackState == .preparing` — that was the
    /// Build 181 bug where the AVPlayerItem's transient 503
    /// triggered a retry that wiped the freshly-completed
    /// preparation.
    func retryPlayback() {
        // Build 182: only retry from `.ready`.  During
        // `.preparing` the loadTask is the source of truth
        // and a retry would race it; during `.idle` or
        // `.failed` the recovery button shouldn't trigger
        // a duplicate load.
        guard case .ready = playbackState else {
            diagLog(.playback, "PlayerController.retryPlayback ignored",
                    details: ["state": "\(playbackState)"])
            return
        }
        diagLog(.playback, "PlayerController.retryPlayback", details: [
            "usesProxy": usesProxy
        ])

        if usesProxy {
            // **PR-A Group 4 (item 9, D4)**: on the proxy
            // path, snapshot the playhead before reloading so
            // `startPlaybackSession(item:)` can restore it
            // once the new item is bound.  This avoids
            // bouncing the user back to 0:00 every time the
            // proxy recovers from a transient upstream
            // failure mid-video.
            let snapshot = CMTimeGetSeconds(player.currentTime())
            retryRestoreTime = (snapshot.isFinite && snapshot > 0) ? snapshot : nil
            diagLog(.playback, "retry_begin", details: [
                "path": "proxy", "restoreTo": retryRestoreTime ?? "nil"
            ])
            // VOD DASH: kick the async loadTask.  It will
            // bump `currentPrepGeneration` inside the
            // proxy via `beginServing()`, run prepare +
            // publish, swap the item, and only then flip
            // `playbackState = .ready` again.
            loadPlayback(originalPlayback)
        } else {
            // **PR-A Group 4 (item 9, D4)**: non-proxy path
            // (live / legacy MP4).  The asset is the same;
            // only the error + buffering flags need clearing.
            // Snapshotting here would be misleading because
            // the same player item keeps playing — so we
            // explicitly do NOT seek on restore.
            retryRestoreTime = nil
            diagLog(.playback, "retry_begin", details: ["path": "direct"])
            playerError = nil
            isBuffering = false
            isPlaying = true
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            player.play()
        }
    }

    // MARK: teardown

    func tearDown() {
        stopPolling()
        // PR-B B9: log whether a stall watchdog was
        // actually running at teardown.  Distinguishes a
        // controller torn down during a real buffering
        // pause (hadTask=true) from a controller torn down
        // while the player was playing smoothly
        // (hadTask=false).  Without this signal, a
        // user-reported "pause stuck on loading" complaint
        // is hard to disambiguate from a "tap to dismiss,
        // playback was fine all along" complaint.
        if stallTimerTask != nil {
            diagLog(.playback, "stallTimer.cancel",
                    details: ["hadTask": true])
        }
        stallTimerTask?.cancel()
        stallTimerTask = nil
        // **PR-A Group 4 (item 9)**: clear any pending retry
        // snapshot so a teardown mid-recovery doesn't leak
        // the restore target into a future playback.
        retryRestoreTime = nil
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

    /// `nonisolated` because the body is a pure switch over
    /// an `AVPlayerItem.Status` — no @MainActor state
    /// touched.  The KVO observer (`observe(\.status, ...)`)
    /// is a non-Sendable closure that fires on the KVO
    /// thread, so calling the @MainActor default would
    /// require a Task hop just to read the status name.
    nonisolated private static func describe(itemStatus status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .readyToPlay:
            return "readyToPlay"
        case .failed:
            return "failed"
        @unknown default:
            return "future(\(status.rawValue))"
        }
    }

    deinit {
        // Inline the critical cleanup that must run at deallocation.
        // KVO observers (in `observers` Set) auto-release when self
        // deallocates — no action needed.  The time observer and
        // NotificationCenter observers must be removed explicitly
        // because they hold a strong reference to self.
        if let token = timeObserver {
            player.removeTimeObserver(token)
        }
        pollTimer?.invalidate()
        if let token = statusObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = errorObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = errorLogObserver {
            NotificationCenter.default.removeObserver(token)
        }
        pipObservers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }
}
