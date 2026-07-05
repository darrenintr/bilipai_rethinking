//
//  LocalHLSProxyServer.swift
//  Paladala
//
//  Loopback HTTP server that synthesises an HLS master playlist
//  for a single `BiliPlayback` and proxies the underlying m4s
//  segments byte-for-byte from the B站 CDN, with the right
//  `Referer` injected.
//
//  Why this exists
//  ---------------
//  B站 increasingly returns DASH manifests for higher-quality
//  sources (1080P+, 4K, 大会员, 杜比). `AVPlayer` cannot
//  play DASH natively.  Standing up a 127.0.0.1 HTTP server
//  and feeding it a master.m3u8 we synthesise in memory is the
//  simplest way to get AVPlayer to play that DASH payload —
//  no third-party SDK, no transcoding, no per-segment hand
//  rolling.
//
//  Architecture
//  ------------
//
//       AVPlayer
//          │  GET http://127.0.0.1:NNNN/playlist.m3u8
//          ▼
//   LocalHLSProxyServer (Network.framework, 127.0.0.1 only)
//          │   ├─  playlist.m3u8 → synthesise HLS master in memory
//          │   ├─  video.m3u8    → synthesise video media playlist
//          │   ├─  audio.m3u8    → synthesise audio media playlist
//          │   └─  seg?u=…       → URLSession.fetch(realURL)
//          │                       + Referer + User-Agent
//          ▼
//       Data → NWConnection.send → AVPlayer
//
//  Notes
//  -----
//  * Loopback only.  The listener binds to 127.0.0.1; no other
//    device on the LAN can reach the port.
//  * iOS 14+ still requires `NSLocalNetworkUsageDescription`
//    even for loopback; the Info.plist declares one.
//  * The server is a process-wide singleton; the singleton
//    pattern matches the previous AliPlayer / bridge approach
//    (one playback at a time per `PlayerController`).
//  * We use Apple's first-party `Network.framework` rather
//    than Swifter / GCDWebServer to keep the dependency
//    surface at zero — the rest of the app is pure AVFoundation.
//

import Foundation
import Network

// MARK: - public surface

/// A 127.0.0.1-only HTTP server that exposes an HLS manifest
/// for a single `BiliPlayback`.  Always access through
/// `LocalHLSProxyServer.shared`.
final class LocalHLSProxyServer {
    static let shared = LocalHLSProxyServer()

    /// `http://127.0.0.1:NNNN/` once the listener is ready.
    /// `nil` before the first `serve(playback:)` call hands a
    /// port to us.  The URL is stable for the lifetime of the
    /// process unless `stop()` is called.
    /// **All reads and writes must hold `lock`.**  Use
    /// `safeBaseURL` for safe reads from any queue.
    private(set) var baseURL: URL?

    /// Thread-safe read of `baseURL`.  Holds `lock` for the
    /// duration of the read so it is safe to call from any queue.
    var safeBaseURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return baseURL
    }

    /// Non-blocking semaphore-backed waiter for the `baseURL` to
    /// become non-nil.  Returns the URL once the listener reports
    /// `.ready`, or `nil` if the timeout elapses first.
    ///
    /// Prefer this over polling with `Thread.sleep — it does not
    /// wake the thread every few milliseconds and makes the intent
    /// explicit.  Must be called after `serve(playback:)` has
    /// kicked off the listener; safe to call even if the server is
    /// already running (the semaphore returns immediately).
    func waitForReady(timeout: TimeInterval = 2.0) -> URL? {
        if let url = safeBaseURL { return url }
        let sem = DispatchSemaphore(value: 0)
        var result: URL?
        let observation = DispatchSource.makeTimerSource(queue: queue)
        observation.schedule(deadline: .now(), repeating: .milliseconds(10))
        let deadline = DispatchTime.now() + timeout
        var fired = false
        let lock = NSLock()
        observation.setEventHandler {
            lock.lock()
            defer { lock.unlock() }
            if !fired, let url = self.baseURL {
                fired = true
                result = url
                observation.cancel()
                sem.signal()
            }
        }
        let timeoutSource = DispatchSource.makeTimerSource(queue: queue)
        timeoutSource.schedule(deadline: deadline)
        timeoutSource.setEventHandler {
            lock.lock()
            defer { lock.unlock() }
            if !fired {
                fired = true
                observation.cancel()
                sem.signal()
            }
        }
        observation.resume()
        timeoutSource.resume()
        _ = sem.wait(timeout: deadline + .milliseconds(100))
        return result
    }

    /// Total bytes streamed from the B站 CDN to AVPlayer.
    /// Sampled by `PlayerController.refresh()` for the
    /// network-speed overlay on the loading screen.
    private(set) var byteCount: Int64 = 0

    // MARK: lifecycle

    /// Start (or rebind) the server to a new playback.  If the
    /// server is already running, the playback is swapped in
    /// place — the listener and port stay the same.  If not
    /// running, a fresh listener is created and a port is
    /// assigned by the OS.  The call returns immediately;
    /// check `baseURL` to know when the port is ready (the
    /// state callback flips it within a few milliseconds).
    func serve(playback: BiliPlayback) throws {
        lock.lock()
        currentPlayback = playback
        // `serve(playback:)` is the upstream-CDN path.  If
        // the caller hands us a playback that also has a
        // `localContext`, we still set it — the segment
        // router will read from disk in that case.  This
        // means a caller that already has a
        // `BiliPlayback.localContext` populated does not
        // need to know whether to call `serve` or
        // `serveLocal`.
        localContext = playback.localContext
        lock.unlock()

        // Evict probe state from any previous playback — the
        // upstream URLs are per-video and the cached totals
        // would point at the wrong bytes if reused.
        resetMediaTotalProbes()

        // If the playback is downloaded, the file sizes
        // are already known — seed the probe cache
        // synchronously.  Otherwise kick off upstream
        // probes so the media playlists can be
        // multi-segment from the first request.
        if let local = playback.localContext {
            if let video = playback.dash?.video {
                registerLocalFileSize(
                    for: video,
                    directory: local.directory,
                    fileName: "video.media"
                )
            }
            if let audio = playback.dash?.audio {
                registerLocalFileSize(
                    for: audio,
                    directory: local.directory,
                    fileName: "audio.media"
                )
            }
        } else {
            let referer = playback.referer.absoluteString
            if let video = playback.dash?.video {
                startMediaTotalProbe(for: video, referer: referer)
            }
            if let audio = playback.dash?.audio {
                startMediaTotalProbe(for: audio, referer: referer)
            }
            // Prime the probe cache for every backup CDN host
            // B站 published alongside the primary.  Without
            // this, the first failover blocks on a second
            // `Range: bytes=0-0` round-trip to the backup —
            // visible to the user as ~5 s of "buffering…"
            // before playback recovers from a primary-host
            // outage.  Parallelising the probes at startup
            // turns that into a one-segment hiccup.
            for track in [playback.dash?.video, playback.dash?.audio]
                .compactMap({ $0 }) {
                for backup in track.backupURLs {
                    startMediaTotalProbe(forBackup: backup, referer: referer)
                }
                // Fetch + parse the upstream sidx so the
                // playlist generator can emit real fragment
                // URLs with the upstream's own byte ranges
                // and durations.  Without this we'd fall back
                // to the equal-byte playlist (VBR-unsafe).
                fetchTrackSegmentIndex(for: track, referer: referer)
            }
            // Reset the failover cursor so each new playback
            // starts on its primary host.  The cursor is keyed
            // by the primary URL — concurrent playbacks (mini-
            // player + fullscreen view) get independent cursors.
            lock.lock()
            failoverIndex.removeAll()
            lock.unlock()
        }

        try ensureListener()
        diagLog(.playback, "LocalHLSProxyServer starting")
    }

    /// Stop the server.  After this call `baseURL` is `nil`
    /// and any in-flight connections are cancelled.  Calling
    /// `serve(playback:)` again will start a fresh listener
    /// (with a new OS-assigned port).
    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        currentPlayback = nil
        localContext = nil
        // Drop cached upstream probes too — after a long
        // background the cached byte sizes may belong to a
        // CDN file that has since been re-ranged, and any
        // pending waiters would otherwise be stranded on a
        // semaphore the next playback will never signal.
        probedSizes.removeAll()
        probeWaiters.removeAll()
        probeInFlight.removeAll()
        // Failover cursors also reset on stop — a new
        // playback should always start on its primary CDN.
        failoverIndex.removeAll()
        // Drop parsed SIDX indices — they belong to the
        // playback we just stopped. The next serve(playback:)
        // will re-fetch + parse for the new video.
        trackSegmentIndex.removeAll()
        inFlightRanges.removeAll()
        for (_, stream) in activeStreams {
            stream.cancel()
        }
        activeStreams.removeAll()
        port = 0
        baseURL = nil
        lock.unlock()
        diagLog(.playback, "LocalHLSProxyServer stopped")
    }

    /// Recreate the proxy from scratch.  Equivalent to
    /// `stop()` followed by a forced listener drop — used by
    /// the lifecycle handler in `RootView` when the app
    /// returns from a long background, because iOS will have
    /// suspended the `NWListener` and the `URLSession`
    /// upstream legs while we were backgrounded, and the
    /// listener's `state` callback never fires the
    /// `.cancelled` we rely on for detection.  Without this,
    /// every video opened after a long lock screen returns
    /// `NSURLError -1004 "Could not connect to the server."`
    /// because the proxy is alive-but-dead.  Calling this
    /// guarantees the next `serve(playback:)` rebuilds the
    /// listener on a fresh port.
    func recreateForResume() {
        let wasRunning = (listener != nil)
        stop()
        diagLog(.playback, "LocalHLSProxyServer recreateForResume",
                details: ["wasRunning": wasRunning])
    }

    /// Serve a `BiliPlayback` whose bytes are already on
    /// disk.  Same wire contract as `serve(playback:)` —
    /// AVPlayer sees a 127.0.0.1 loopback HTTP server
    /// returning HLS — but the init / media bytes are read
    /// from `playback.localContext.directory` instead of
    /// the B 站 CDN.  Falls back to `serve(playback:)` if
    /// `playback.localContext` is `nil`, so callers can
    /// use `serveLocal` as a single entry point.
    func serveLocal(playback: BiliPlayback) throws {
        guard let local = playback.localContext else {
            try serve(playback: playback)
            return
        }
        // Wire the playback in.  We need the upstream
        // playlists to know the byte ranges / codecs /
        // duration, but `localContext` flips the segment
        // router to disk-backed reads.
        lock.lock()
        currentPlayback = playback
        localContext = local
        lock.unlock()

        // We already know the on-disk file sizes (they
        // are on the filesystem), so seed the probe cache
        // synchronously.  Without this the playlist
        // builder would fall back to single-segment mode
        // for offline playback, which works but loses the
        // ability to scrub past the buffer.
        if let video = playback.dash?.video {
            registerLocalFileSize(
                for: video,
                directory: local.directory,
                fileName: "video.media"
            )
        }
        if let audio = playback.dash?.audio {
            registerLocalFileSize(
                for: audio,
                directory: local.directory,
                fileName: "audio.media"
            )
        }

        // Spin up the listener (shared with `serve(playback:)`).
        try ensureListener()
        diagLog(.playback, "LocalHLSProxyServer serveLocal",
                details: ["bvid": playback.dash.map { _ in "yes" } ?? "no"])
    }

    /// Idempotent listener bootstrap.  Pulled out of
    /// `serve(playback:)` so `serveLocal(playback:)` can
    /// reuse the exact same listener setup.
    private func ensureListener() throws {
        if listener != nil { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = self.listener?.port {
                    self.lock.lock()
                    self.port = p.rawValue
                    self.baseURL = URL(
                        string: "http://127.0.0.1:\(p.rawValue)"
                    )
                    self.lock.unlock()
                    diagLog(.playback, "LocalHLSProxyServer ready",
                            details: ["port": p.rawValue])
                }
            case .failed(let error):
                diagLog(.playback, "LocalHLSProxyServer failed",
                        details: ["error": error.localizedDescription])
            case .cancelled:
                self.lock.lock()
                self.port = 0
                self.baseURL = nil
                self.lock.unlock()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }
        listener.start(queue: queue)
    }

    /// Stat the on-disk m4s file for `track` and seed the
    /// probe cache with the byte count.  `track.baseURL` is
    /// the upstream CDN URL — we still key the cache by
    /// that URL so the existing media-playlist code path
    /// (`awaitMediaTotalProbe`) can find the size without
    /// changes.
    private func registerLocalFileSize(
        for track: BiliDashSource.Track,
        directory: URL,
        fileName: String
    ) {
        let url = directory.appendingPathComponent(fileName)
        guard let attrs = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
              let size = attrs[.size] as? Int64,
              size > 0 else {
            bpLog("LocalHLSProxyServer local file size failed: \(url.path)")
            Analytics.recordError(
                NSError(domain: "paladala.proxy", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "local file size failed",
                    "path": url.path
                ]),
                context: "proxy_localFileSize"
            )
            return
        }
        lock.lock()
        probedSizes[track.baseURL] = size
        lock.unlock()
    }

    // MARK: internals

    private let queue = DispatchQueue(label: "Paladala.LocalHLSProxy")
    fileprivate let lock = NSRecursiveLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var currentPlayback: BiliPlayback?
    /// When the active playback is a downloaded video, this
    /// points at the on-disk directory holding its init/media
    /// m4s files.  Set by `serveLocal(playback:)`; the
    /// segment router reads it to decide whether to fetch
    /// from disk vs. the upstream CDN.
    private var localContext: LocalPlaybackContext?
    private var activeStreams: [UUID: StreamingProxyTask] = [:]
    /// Tracks in-flight upstream byte ranges so we can detect and
    /// resolve overlaps when AVPlayer issues concurrent sub-segment
    /// requests (e.g., two overlapping `/media` ranges for the same
    /// CDN URL).  Key is the upstream URL string, value is the range
    /// start/end plus the stream ID holding that range.
    fileprivate var inFlightRanges: [String: (start: Int64, end: Int64, streamID: UUID)] = [:]

    // MARK: upstream media size probe
    //
    // To emit a multi-segment HLS playlist with `EXT-X-BYTERANGE`,
    // we need the upstream m4s total file size — that lets us
    // compute how many byte-range segments the duration should
    // be split into.  The size is discovered by issuing a
    // `Range: bytes=0-0` GET to the upstream URL; B站's CDN
    // replies 206 with `Content-Range: bytes 0-0/TOTAL`.
    //
    // The probe fires on URLSession's own background queue and
    // updates probe state directly under `lock`.  The listener
    // queue (where `respondMediaPlaylist` waits) is *not* used
    // for probe completion delivery — that avoids deadlocking
    // the listener queue when we synchronously wait on a
    // semaphore from inside `respondMediaPlaylist`.  All probe
    // state is touched only under `lock`.
    private var probedSizes: [URL: Int64] = [:]
    /// Waiters for an in-flight probe.  Each entry is a
    /// `(semaphore, callback)` pair; the callback is fired
    /// exactly once when the probe completes or times out.
    private var probeWaiters:
        [URL: [(DispatchSemaphore, (Int64?) -> Void)]] = [:]
    private var probeInFlight: Set<URL> = []
    /// CDN failover cursor. Keyed by the track's primary URL,
    /// value is the index into the track's `backupURLs` array
    /// that should serve the next playlist (and segment
    /// request). Index 0 means "use primary", 1 means "use
    /// backupURLs[0]", etc. Reset to empty by `serve(playback:)`
    /// at the start of every new playback so a fresh load
    /// always prefers the primary. Touched only under `lock`.
    private var failoverIndex: [URL: Int] = [:]
    /// Per-track parsed `sidx` (Segment Index Box). Keyed by the
    /// track's primary upstream URL so concurrent playbacks of
    /// different videos don't collide. Populated by
    /// `fetchTrackSegmentIndex(for:referer:completion:)` at
    /// `serve(playback:)` time; cleared by `stop()`.
    ///
    /// Why this exists: the old code synthesised HLS playlists
    /// from equal-byte chunks of the upstream m4s file, with
    /// `#EXTINF:6.0` for every segment. MP4 is VBR — equal
    /// bytes ≠ equal duration, and the byte boundaries may
    /// land mid-NAL or mid-`mdat` box, producing structurally
    /// invalid fMP4 chunks that AVPlayer drops with `-19602`.
    /// The sidx carries the *real* `moof+mdat` fragment byte
    /// ranges and durations, so we now build the playlist from
    /// the upstream's own segmentation instead.
    fileprivate var trackSegmentIndex: [URL: TrackSegmentIndex] = [:]
    /// Target segment duration for the multi-segment HLS
    /// playlist.  6 s gives ~40 segments for a typical 4-min
    /// VOD — enough granularity that AVPlayer can seek to the
    /// requested scrubber position without the "snap back to
    /// buffered range" behaviour.  Empirically: 6 s chunks
    /// round-trip in <100 ms over loopback.
    private static let targetSegmentDuration: Double = 6.0

    /// Kick off a `Range: bytes=0-0` GET to the upstream track
    /// URL.  Idempotent.  Safe to call from any thread; the
    /// URLSession callback runs on URLSession's queue and
    /// touches probe state only under `lock`.
    private func startMediaTotalProbe(
        for track: BiliDashSource.Track,
        referer: String
    ) {
        let key = track.baseURL
        lock.lock()
        if probedSizes[key] != nil || probeInFlight.contains(key) {
            lock.unlock()
            return
        }
        probeInFlight.insert(key)
        lock.unlock()

        var req = URLRequest(url: track.baseURL)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.httpMethod = "GET"

        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            guard let self else { return }
            let total: Int64? = (response as? HTTPURLResponse).flatMap { http in
                let cr = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let (_, _, parsedTotal) =
                    LocalHLSProxyServer.parseContentRangeHeader(cr)
                return parsedTotal > 0 ? parsedTotal : nil
            }
            self.finishMediaTotalProbe(url: key, total: total)
        }.resume()
    }

    /// Warm the probe cache for a backup CDN host so the first
    /// failover is instant.  Same wire format as
    /// `startMediaTotalProbe(for:referer:)` but keyed by the
    /// backup URL itself (not the parent track) — the
    /// `probedSizes` cache is keyed by URL, so this entry
    /// will satisfy any `awaitMediaTotalProbe(for: ...)`
    /// call the failover cursor eventually makes for this
    /// backup.  No-op if the probe is already cached or
    /// in flight.
    private func startMediaTotalProbe(
        forBackup backup: URL,
        referer: String
    ) {
        lock.lock()
        if probedSizes[backup] != nil || probeInFlight.contains(backup) {
            lock.unlock()
            return
        }
        probeInFlight.insert(backup)
        lock.unlock()

        var req = URLRequest(url: backup)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            guard let self else { return }
            let total: Int64? = (response as? HTTPURLResponse).flatMap { http in
                let cr = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let (_, _, parsedTotal) =
                    LocalHLSProxyServer.parseContentRangeHeader(cr)
                return parsedTotal > 0 ? parsedTotal : nil
            }
            self.finishMediaTotalProbe(url: backup, total: total)
            diagLog(.playback, "LocalHLSProxyServer backup probe",
                    details: [
                        "host": backup.host ?? "",
                        "totalBytes": total ?? -1,
                        "success": total != nil
                    ])
        }.resume()
    }

    /// Pick the upstream URL that should serve this track right
    /// now, honouring the failover cursor.  Returns the
    /// primary when no failover has been triggered; advances
    /// through `track.backupURLs` as the cursor moves.
    ///
    /// Called only from `respondMediaPlaylist(...)` — both
    /// the playlist-embedded URL and the segment fetches use
    /// the same picker, so a single cursor move flips every
    /// subsequent request on the same connection.
    private func activeUpstream(for track: BiliDashSource.Track) -> URL {
        lock.lock()
        defer { lock.unlock() }
        let idx = failoverIndex[track.baseURL] ?? 0
        let candidates = [track.baseURL] + track.backupURLs
        guard idx >= 0, idx < candidates.count else {
            return track.baseURL
        }
        return candidates[idx]
    }

    /// Advance the failover cursor for `primaryURL` to the
    /// next backup.  Called when an upstream fetch returns
    /// 5xx, the connection times out, or the byte-range
    /// response is malformed.  Idempotent — calling past the
    /// end of the backup list is a no-op (the playlist will
    /// keep using the last-known host, and AVPlayer will
    /// surface the underlying error to the user).
    fileprivate func markUpstreamFailed(primaryURL: URL) {
        lock.lock()
        let current = failoverIndex[primaryURL] ?? 0
        // We don't know the track's full backup list here
        // (only the primary URL is keyed), so we cap at a
        // reasonable ceiling.  Real caps come from the track
        // DTO in `respondMediaPlaylist`; this helper is
        // intentionally conservative so a stale cursor can't
        // chase a phantom host forever.
        let next = min(current + 1, 8)
        failoverIndex[primaryURL] = next
        lock.unlock()
        diagLog(.playback, "LocalHLSProxyServer failover",
                details: [
                    "primary": primaryURL.host ?? "",
                    "newIndex": next
                ])
    }

    /// Resolve which track this URL belongs to and bump its
    /// failover cursor.  Used by `StreamingProxyTask` when a
    /// 5xx comes back from an upstream — the task only knows
    /// the URL it just tried, not the track DTO.  Lookup is
    /// O(tracks × backups) per call (typically 2 tracks × ≤3
    /// backups = 6 URL comparisons), so we keep the helper
    /// synchronous.  Fires at most once per failed segment —
    /// not hot enough to warrant a URL→primary hash.
    fileprivate func markUpstreamFailed(url: URL) {
        guard let dash = currentPlayback?.dash else { return }
        for track in [dash.video, dash.audio].compactMap({ $0 }) {
            let candidates = [track.baseURL] + track.backupURLs
            if candidates.contains(url) {
                // Failover is keyed by the *primary* URL —
                // that's how `activeUpstream(for:)` reads it.
                markUpstreamFailed(primaryURL: track.baseURL)
                return
            }
        }
    }

    /// Probe completion: cache the size, signal all waiters.
    /// Runs on URLSession's background queue; touches only
    /// `probedSizes` / `probeWaiters` under `lock`.
    private func finishMediaTotalProbe(url: URL, total: Int64?) {
        lock.lock()
        probeInFlight.remove(url)
        if let total {
            probedSizes[url] = total
        }
        let waiters = probeWaiters.removeValue(forKey: url) ?? []
        lock.unlock()
        for (sem, callback) in waiters {
            callback(total)
            sem.signal()
        }
        diagLog(.playback, "LocalHLSProxyServer probe media total",
                details: [
                    "host": url.host ?? "",
                    "totalBytes": total ?? -1,
                    "success": total != nil
                ])
    }

    /// Block the caller until the probe for `url` completes,
    /// or `timeoutSeconds` elapses.  Returns the cached size
    /// if already known.  Falls back to `nil` if the probe
    /// never completes (network error, timeout).
    ///
    /// Must be called on `queue` — blocks the listener queue
    /// for the duration of one `bytes=0-0` round-trip (~100 ms
    /// in practice).  This is safe because:
    ///  - `respondMediaPlaylist` is the only caller
    ///  - AVPlayer is blocked on this connection waiting for
    ///    the playlist, so no other connection needs to be
    ///    accepted while we wait
    ///  - The actual probe completion runs on URLSession's
    ///    queue, which is independent of `queue`, so the
    ///    semaphore gets signalled even though `queue` is
    ///    parked.
    private func awaitMediaTotalProbe(
        for url: URL,
        timeoutSeconds: Double = 5.0
    ) -> Int64? {
        let sem: DispatchSemaphore
        var resolved: Int64?
        var didResolve = false
        lock.lock()
        if let cached = probedSizes[url] {
            lock.unlock()
            return cached
        }
        sem = DispatchSemaphore(value: 0)
        var waiters = probeWaiters[url] ?? []
        waiters.append((sem, { total in
            // First writer wins: if the timeout already
            // flipped `didResolve` to true (with nil), don't
            // overwrite `resolved` with the real value.
            if !didResolve {
                didResolve = true
                resolved = total
            }
        }))
        probeWaiters[url] = waiters
        lock.unlock()

        // Self-timeout.  After `timeoutSeconds` we drop the
        // waiter and signal the semaphore so the playlist
        // builder falls back to single-segment.  The race with
        // the probe completion is resolved by the `didResolve`
        // flag — whichever fires first wins.
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let remaining = self.probeWaiters[url]?
                    .filter { $0.0 !== sem } ?? []
                if remaining.isEmpty {
                    self.probeWaiters.removeValue(forKey: url)
                } else {
                    self.probeWaiters[url] = remaining
                }
                self.lock.unlock()
                if !didResolve {
                    didResolve = true
                    resolved = nil
                }
                sem.signal()
            }

        _ = sem.wait(timeout: .now() + timeoutSeconds + 0.5)
        return resolved
    }

    /// Clear probe state when the playback swaps.  The proxy
    /// is a process-wide singleton; if a previous playback
    /// probed sizes for its tracks, those sizes don't apply
    /// to the new playback and must be evicted.
    private func resetMediaTotalProbes() {
        lock.lock()
        let dropped = probeWaiters
        probedSizes.removeAll()
        probeWaiters.removeAll()
        probeInFlight.removeAll()
        lock.unlock()
        for (_, waiters) in dropped {
            for (sem, _) in waiters {
                sem.signal()
            }
        }
    }

    // MARK: - SIDX fetch + cache
    //
    // The proxy parses the upstream `sidx` box at serve() time
    // and caches the resulting TrackSegmentIndex per primary
    // upstream URL.  The playlist generator then emits one
    // segment URL per sidx reference (instead of equal-byte
    // chunks) and the segment handler serves the *exact*
    // moof+mdat byte range the sidx points at.

    /// Fetch the upstream sidx for `track`, parse it, and store
    /// the resulting `TrackSegmentIndex` in `trackSegmentIndex`.
    ///
    /// Best-effort.  When the upstream omits the sidx range
    /// (older B 站 responses, region-locked videos, transcoded
    /// HEVC where only the ftyp+moov is exposed) the cache
    /// stays empty for this track and `respondMediaPlaylist`
    /// falls back to the single-segment playlist.  The single-
    /// segment fallback is byte-range-correct (just coarse) so
    /// playback still works.
    private func fetchTrackSegmentIndex(
        for track: BiliDashSource.Track,
        referer: String
    ) {
        guard let indexRange = track.indexRange else {
            diagLog(.playback,
                    "no sidx range for track — falling back to single-segment",
                    details: [
                        "host": track.baseURL.host ?? "",
                        "hasInit": track.initializationRange.length > 0
                    ])
            return
        }
        let key = track.baseURL
        lock.lock()
        if trackSegmentIndex[key] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        var req = URLRequest(url: key)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue(
            "bytes=\(indexRange.offset)-\(indexRange.endOffset)",
            forHTTPHeaderField: "Range"
        )
        req.httpMethod = "GET"

        URLSession.shared.dataTask(with: req) { [weak self] body, response, _ in
            guard let self else { return }
            guard let body, !body.isEmpty,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                diagLog(.playback, "sidx fetch failed",
                        details: ["host": key.host ?? ""])
                return
            }
            do {
                let parsed = try parseSIDX(body)
                let initRange = track.initializationRange.offset ..< (track.initializationRange.offset + track.initializationRange.length)
                let index = makeTrackSegmentIndex(
                    initializationRange: initRange,
                    sidx: parsed
                )
                self.lock.lock()
                self.trackSegmentIndex[key] = index
                self.lock.unlock()
                diagLog(.playback, "sidx parsed",
                        details: [
                            "host": key.host ?? "",
                            "fragments": index.fragments.count,
                            "totalDuration": String(
                                format: "%.3f", index.totalDuration
                            ),
                            "maxFragment": String(
                                format: "%.3f", index.maxFragmentDuration
                            )
                        ])
            } catch {
                diagLog(.playback, "sidx parse failed",
                        details: [
                            "host": key.host ?? "",
                            "error": "\(error)"
                        ])
            }
        }.resume()
    }

    /// Snapshot a previously-parsed TrackSegmentIndex for
    /// `track`.  Returns nil if the sidx hasn't been fetched
    /// yet (or fetch failed) — caller falls back to single-
    /// segment playlist.
    fileprivate func cachedSegmentIndex(
        for track: BiliDashSource.Track
    ) -> TrackSegmentIndex? {
        lock.lock(); defer { lock.unlock() }
        return trackSegmentIndex[track.baseURL]
    }

    /// True when the proxy has a parsed SIDX for this track.
    /// The playlist generator uses this to decide between
    /// per-fragment URLs and the single-segment fallback.
    fileprivate func hasSegmentIndex(
        for track: BiliDashSource.Track
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return trackSegmentIndex[track.baseURL] != nil
    }

    private init() {}

    // MARK: diagnostic helpers

    /// Toggle for the raw-wire diagnostic dump in
    /// `dumpWireBytes`.  Off by default — the byte dumps
    /// dominate the per-segment log cost (each fMP4 segment
    /// produces ~3 dumps that together write 1.5 KB of binary
    /// to the JSONL and run a `JSONEncoder` round-trip), and
    /// a 5-minute 1080P video at 200 segments generates ~1,000
    /// diagLog calls during a single playback. Flip to `true`
    /// locally to debug the scrubber-seek-to-unbuffered bug.
    fileprivate static let wireDumpEnabled = false

    /// Toggle for the per-segment request / response metadata
    /// lines — `upstream request`, `Content-Length sanity`,
    /// `multi-segment playlist`, `single-segment playlist
    /// fallback`. Each fires once per fMP4 segment and
    /// dictionary-allocates on the calling queue, then hops to
    /// main for the in-memory ring append and to the disk
    /// queue for the JSONL write. Off by default for the same
    /// reason as `wireDumpEnabled`; flip on locally when
    /// debugging segment-level issues.
    fileprivate static let requestMetadataLogEnabled = false

    /// Render the first 500 bytes of `data` as UTF-8 so the
    /// diagnostic log shows the actual HTTP framing we put on
    /// the wire.  If the chunk is not valid UTF-8 (binary m4s
    /// body), fall back to the ASCII-printable slice so the
    /// log still shows the bytes that look human-readable.
    /// `label` is the marker name we want to see in the log
    /// (e.g. `DOWNSTREAM RESPONSE HEADER`).
    fileprivate static func dumpWireBytes(_ data: Data, label: String) -> String {
        let prefix = data.prefix(500)
        if let s = String(data: prefix, encoding: .utf8) {
            return "====== \(label) ======\n\(s)\n==========================="
        }
        let printable = prefix.filter { $0 >= 0x20 && $0 < 0x7F }
        let ascii = String(decoding: printable, as: UTF8.self)
        return "====== \(label) [binary \(prefix.count)/\(data.count) bytes] ======\n\(ascii)\n==========================="
    }

    /// Parse `Content-Range: bytes START-END/TOTAL` into a
    /// tuple.  Returns `(-1, -1, -1)` for missing or
    /// malformed headers so the caller can fall back to the
    /// upstream `Content-Length`.  We compare `end - start + 1`
    /// against `Content-Length` to detect the trap-2 mismatch
    /// (hand-rolled HTTP server accidentally sends a
    /// Content-Length that doesn't match the body).
    fileprivate static func parseContentRangeHeader(_ s: String)
        -> (start: Int64, end: Int64, total: Int64)
    {
        guard s.hasPrefix("bytes ") else { return (-1, -1, -1) }
        let body = s.dropFirst("bytes ".count)
        let parts = body.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return (-1, -1, -1) }
        let rangeParts = parts[0].split(separator: "-", maxSplits: 1)
        guard rangeParts.count == 2,
              let start = Int64(rangeParts[0]),
              let end = Int64(rangeParts[1]) else {
            return (-1, -1, -1)
        }
        let total: Int64
        if parts[1] == "*" {
            total = -1
        } else {
            total = Int64(parts[1]) ?? -1
        }
        return (start, end, total)
    }

    // MARK: connection handling

    private func accept(connection: NWConnection) {
        // Short, stable ID for this TCP connection so we can
        // correlate lifecycle events with the request(s) we
        // serve on it.  If AVPlayer ever reuses a connection
        // for a second Range request (trap 3 — keep-alive
        // reuse) we want to see two upstream requests with
        // the same `conn` rather than two anonymous ones.
        let connID = UUID().uuidString.prefix(8)
        diagLog(.network,
                "LocalHLSProxyServer accept",
                details: [
                    "conn": String(connID),
                    "endpoint": "\(connection.endpoint)"
                ])
        connection.start(queue: queue)
        receiveHeader(
            connection: connection,
            accumulated: Data(),
            connID: String(connID)
        )
    }

    /// Read the request header bytes in chunks until we see
    /// CRLFCRLF.  AVPlayer sends headers of a few hundred
    /// bytes; one read is usually enough.
    private func receiveHeader(
        connection: NWConnection,
        accumulated: Data,
        connID: String
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let error = error {
                diagLog(.network,
                        "LocalHLSProxyServer receive error",
                        details: [
                            "conn": connID,
                            "error": error.localizedDescription
                        ])
                diagLog(.network,
                        "LocalHLSProxyServer conn close",
                        details: ["conn": connID, "reason": "receive error"])
                connection.cancel()
                return
            }
            var buf = accumulated
            if let data = data { buf.append(data) }
            // End-of-headers marker.
            if buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil {
                self.route(requestBytes: buf, connection: connection,
                           connID: connID)
                return
            }
            if isComplete {
                diagLog(.network,
                        "LocalHLSProxyServer conn close",
                        details: ["conn": connID, "reason": "eof without crlf crlf"])
                connection.cancel()
                return
            }
            self.receiveHeader(connection: connection, accumulated: buf,
                               connID: connID)
        }
    }

    /// Route a complete request to the right handler.
    private func route(requestBytes: Data,
                       connection: NWConnection,
                       connID: String) {
        guard let req = HTTPRequest.parse(data: requestBytes) else {
            respondError(connection: connection, status: 400,
                         reason: "bad request", connID: connID)
            return
        }
        let pathOnly = req.path.split(separator: "?", maxSplits: 1)
            .first.map(String.init) ?? req.path
        // Local-playback path: read init/media from disk
        // instead of the upstream CDN.  Same HLS wire
        // contract, so the route keys are unchanged; only
        // the segment handler differs.
        let isLocal = isLocalMode()
        switch pathOnly {
        case "/playlist.m3u8":
            respondMasterPlaylist(connection: connection, connID: connID)
        case "/video.m3u8":
            respondMediaPlaylist(for: .video, connection: connection,
                                 connID: connID)
        case "/audio.m3u8":
            respondMediaPlaylist(for: .audio, connection: connection,
                                 connID: connID)
        case "/init":
            if isLocal {
                proxyLocalSegment(
                    req: req, connection: connection,
                    kind: .initRange, connID: connID
                )
            } else {
                proxySegment(req: req, connection: connection,
                             mode: .initRange, connID: connID)
            }
        case "/media":
            if isLocal {
                proxyLocalSegment(
                    req: req, connection: connection,
                    kind: .mediaRange, connID: connID
                )
            } else {
                proxySegment(req: req, connection: connection,
                             mode: .mediaRange, connID: connID)
            }
        case "/segment":
            // Per-fragment URL emitted by the SIDX-driven
            // playlist generator.  Each fragment gets its own
            // URL keyed by (?k=video|audio, ?n=<idx>); the
            // segment handler looks up the cached SIDX, finds
            // the upstream byte range the sidx points at, and
            // returns the bytes as a single 200 OK.  AVPlayer
            // sees one URL per fragment, which is what it
            // expects from a normal HLS server.
            if isLocal {
                respondError(connection: connection, status: 404,
                             reason: "local mode: no /segment", connID: connID)
            } else {
                proxySegmentRange(req: req, connection: connection,
                                  connID: connID)
            }
        default:
            if pathOnly.hasPrefix("/seg") {
                if isLocal {
                    respondError(connection: connection, status: 404,
                                 reason: "local mode: no /seg",
                                 connID: connID)
                } else {
                    proxySegment(req: req, connection: connection,
                                 mode: .passthrough, connID: connID)
                }
            } else {
                respondError(connection: connection, status: 404,
                             reason: "no route", connID: connID)
            }
        }
    }

    /// True when the active playback is a downloaded video
    /// with on-disk bytes.  Re-checked on every request so
    /// swapping `currentPlayback` immediately flips the
    /// routing decision.
    fileprivate func isLocalMode() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return localContext != nil
    }

    // MARK: m3u8 synthesise

    private func snapshot() -> (BiliDashSource, String)? {
        lock.lock(); defer { lock.unlock() }
        guard let p = currentPlayback,
              let dash = p.dash else { return nil }
        return (dash, p.referer.absoluteString)
    }

    private enum MediaKind { case video, audio }

    private func respondMasterPlaylist(connection: NWConnection,
                                      connID: String) {
        guard let (source, _) = snapshot(),
              safeBaseURL != nil else {
            respondError(connection: connection, status: 503,
                         reason: "no playback", connID: connID)
            return
        }
        let totalBandwidth = source.video.bandwidth
            + (source.audio?.bandwidth ?? 0)

        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if source.audio != nil {
            lines.append(
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aac\","
                + "NAME=\"default\",DEFAULT=YES,AUTOSELECT=YES,"
                + "URI=\"\(localURL(path: "audio.m3u8"))\""
            )
        }
        var streamInf = "#EXT-X-STREAM-INF:"
        streamInf += "BANDWIDTH=\(totalBandwidth)"
        streamInf += ",CODECS=\"\(source.video.codecs)"
        if let a = source.audio { streamInf += ",\(a.codecs)" }
        streamInf += "\""
        if let width = source.video.width, width > 0,
           let height = source.video.height, height > 0 {
            streamInf += ",RESOLUTION=\(width)x\(height)"
        }
        if source.audio != nil {
            streamInf += ",AUDIO=\"aac\""
        }
        lines.append(streamInf)
        lines.append(localURL(path: "video.m3u8"))
        lines.append("")
        respondText(connection: connection, connID: connID,
                    body: lines.joined(separator: "\n"))
    }

    private func respondMediaPlaylist(
        for kind: MediaKind,
        connection: NWConnection,
        connID: String
    ) {
        guard let (source, _) = snapshot(),
              safeBaseURL != nil else {
            respondError(connection: connection, status: 503,
                         reason: "no playback", connID: connID)
            return
        }
        let track: BiliDashSource.Track?
        switch kind {
        case .video: track = source.video
        case .audio: track = source.audio
        }
        guard let track = track else {
            respondError(connection: connection, status: 404,
                         reason: "no track", connID: connID)
            return
        }
        let total = max(track.totalDuration, 0.1)
        let target = Int(total.rounded(.up))
        // Encode the upstream URL as a base64url query parameter.
        // The init/media endpoints then apply absolute upstream
        // byte ranges, so AVPlayer sees normal HLS resources while
        // Bili's CDN receives the Range requests it expects.
        let encoded = base64urlEncode(activeUpstream(for: track).absoluteString)
        let initURL = localURL(
            path: "init",
            queryItems: [
                URLQueryItem(name: "u", value: encoded),
                URLQueryItem(
                    name: "range",
                    value: "\(track.initializationRange.offset)"
                        + "-\(track.initializationRange.endOffset)"
                )
            ]
        )

        // Path for the single-segment fallback.  When the sidx
        // is missing or hasn't been parsed yet we emit a
        // single-EXTINF playlist that points at this URL; the
        // segment handler streams the entire playable region
        // back as 200 OK and AVPlayer treats it as one big
        // segment.  This is the equal-byte model (broken for
        // VBR) but it's strictly better than serving nothing.
        let mediaURL = localURL(
            path: "media",
            queryItems: [
                URLQueryItem(name: "u", value: encoded),
                URLQueryItem(
                    name: "from",
                    value: "\(track.mediaStartOffset)"
                )
            ]
        )

        // Path prefix for the per-fragment URLs we emit when we
        // have a parsed SIDX.  Each segment is its own URL;
        // the segment handler fetches the upstream byte range
        // the SIDX points at and returns 200 OK with the
        // moof+mdat bytes.  This is what makes the playlist
        // spec-conformant — every `EXTINF` carries the *real*
        // fragment duration and every `URI` serves the *real*
        // fragment bytes, so AVPlayer's timeline never drifts.
        let trackLabel = (kind == .video) ? "video" : "audio"

        // SIDX-driven multi-fragment playlist (preferred).
        // Emit one EXTINF/URI pair per sidx reference.  When
        // the sidx hasn't been parsed yet (the fetch is async)
        // we fall back to single-segment — the next playlist
        // poll will pick up the SIDX-driven form.
        if let index = cachedSegmentIndex(for: track) {
            // EXT-X-TARGETDURATION must be ceil(max(EXTINF)).
            // The sidx gives us real fragment durations so this
            // is an honest number — no more "ceil(total/6)".
            let targetDuration = max(1, Int(
                index.maxFragmentDuration.rounded(.up)
            ))
            var lines: [String] = [
                "#EXTM3U",
                "#EXT-X-VERSION:7",
                "#EXT-X-PLAYLIST-TYPE:VOD",
                "#EXT-X-TARGETDURATION:\(targetDuration)",
                "#EXT-X-MEDIA-SEQUENCE:0",
                "#EXT-X-MAP:URI=\"\(initURL)\"",
            ]
            for (i, frag) in index.fragments.enumerated() {
                let segmentURL = localURL(
                    path: "segment",
                    queryItems: [
                        URLQueryItem(name: "u", value: encoded),
                        URLQueryItem(name: "k", value: trackLabel),
                        URLQueryItem(name: "n", value: "\(i)"),
                    ]
                )
                lines.append(
                    "#EXTINF:\(String(format: "%.3f", frag.duration)),"
                )
                lines.append(segmentURL)
            }
            lines.append("#EXT-X-ENDLIST")
            lines.append("")
            if Self.requestMetadataLogEnabled {
                diagLog(.playback,
                        "LocalHLSProxyServer SIDX-driven playlist",
                        details: [
                            "conn": connID,
                            "kind": trackLabel,
                            "fragments": index.fragments.count,
                            "targetDuration": targetDuration,
                            "totalDuration": String(
                                format: "%.3f", index.totalDuration
                            )
                        ])
            }
            respondText(connection: connection, connID: connID,
                        body: lines.joined(separator: "\n"))
            return
        }

        // SIDX-driven path: block briefly for the SIDX fetch
        // to complete.  This is safe on the listener queue
        // (same justification as `awaitMediaTotalProbe` — the
        // queue is parked while AVPlayer waits for this
        // response, no other connection needs the thread).
        // We poll up to 1.5 s; if the sidx fetch is still
        // outstanding after that, fall through to single-
        // segment.  AVPlayer will re-issue the playlist on
        // every buffer fill so the next call will pick up the
        // parsed sidx.
        let deadline = Date().addingTimeInterval(1.5)
        while cachedSegmentIndex(for: track) == nil,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let index = cachedSegmentIndex(for: track) {
            // Re-run with the now-cached index.  This branch
            // is intentionally a duplicate of the preferred
            // path above to keep the logic linear; production
            // paths hit the first one.
            let targetDuration = max(1, Int(
                index.maxFragmentDuration.rounded(.up)
            ))
            var lines: [String] = [
                "#EXTM3U",
                "#EXT-X-VERSION:7",
                "#EXT-X-PLAYLIST-TYPE:VOD",
                "#EXT-X-TARGETDURATION:\(targetDuration)",
                "#EXT-X-MEDIA-SEQUENCE:0",
                "#EXT-X-MAP:URI=\"\(initURL)\"",
            ]
            for (i, frag) in index.fragments.enumerated() {
                let segmentURL = localURL(
                    path: "segment",
                    queryItems: [
                        URLQueryItem(name: "u", value: encoded),
                        URLQueryItem(name: "k", value: trackLabel),
                        URLQueryItem(name: "n", value: "\(i)"),
                    ]
                )
                lines.append(
                    "#EXTINF:\(String(format: "%.3f", frag.duration)),"
                )
                lines.append(segmentURL)
            }
            lines.append("#EXT-X-ENDLIST")
            lines.append("")
            respondText(connection: connection, connID: connID,
                        body: lines.joined(separator: "\n"))
            return
        }

        // Fallback: single-segment playlist.  Used when the
        // upstream omits the sidx range or the fetch timed out.
        // AVPlayer treats the whole video as one segment in
        // this case — works for normal playback but loses the
        // ability to scrub past the buffer.
        if Self.requestMetadataLogEnabled {
            diagLog(.playback,
                    "LocalHLSProxyServer single-segment playlist fallback",
                    details: [
                        "conn": connID,
                        "kind": kind == .video ? "video" : "audio",
                        "mediaStartOffset": track.mediaStartOffset,
                        "duration": total
                    ])
        }
        let lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-MAP:URI=\"\(initURL)\"",
            "#EXTINF:\(String(format: "%.3f", total)),",
            mediaURL,
            "#EXT-X-ENDLIST",
            "",
        ]
        respondText(connection: connection, connID: connID,
                    body: lines.joined(separator: "\n"))
    }

    // MARK: segment proxy

    fileprivate enum ProxyMode {
        case passthrough
        case initRange
        case mediaRange

        var logName: String {
            switch self {
            case .passthrough: return "passthrough"
            case .initRange: return "init"
            case .mediaRange: return "media"
            }
        }
    }

    /// Serve one fMP4 fragment by SIDX index.  Route handler
    /// for `/segment?u=…&k=video|audio&n=<idx>` — the URL
    /// shape the SIDX-driven playlist generator emits.
///
/// Each fragment is fetched as a single upstream Range request
/// and returned as `200 OK` with `Content-Length` set to the
/// fragment's real byte count.  No `EXT-X-BYTERANGE` magic —
/// AVPlayer treats this as a normal HLS segment and the timeline
/// never drifts.
fileprivate func proxySegmentRange(
    req: HTTPRequest,
    connection: NWConnection,
    connID: String
) {
    guard let (source, referer) = snapshot() else {
        respondError(connection: connection, status: 503,
                     reason: "no playback", connID: connID)
        return
    }
    let query = req.path.split(separator: "?", maxSplits: 1)
        .last.map(String.init) ?? ""
    let params = parseQuery(query)
    guard let encoded = params["u"],
          let upstreamString = base64urlDecode(encoded),
          let upstream = URL(string: upstreamString) else {
        respondError(connection: connection, status: 400,
                     reason: "missing u", connID: connID)
        return
    }
    let track: BiliDashSource.Track
    switch params["k"] {
    case "video": track = source.video
    case "audio":
        guard let a = source.audio else {
            respondError(connection: connection, status: 404,
                         reason: "no audio track", connID: connID)
            return
        }
        track = a
    default:
        respondError(connection: connection, status: 400,
                     reason: "missing k", connID: connID)
        return
    }
    guard let nString = params["n"], let idx = Int(nString), idx >= 0 else {
        respondError(connection: connection, status: 400,
                     reason: "missing n", connID: connID)
        return
    }
    guard let index = cachedSegmentIndex(for: track),
          idx < index.fragments.count else {
        // SIDX not parsed yet (or invalid index).  Fall back to
        // /media?from=mediaStartOffset so the player still gets
        // bytes — at the cost of full-file streaming for this
        // one fragment.  AVPlayer will retry the playlist and
        // pick up the SIDX-driven form on the next pass.
        let encodedFallback = base64urlEncode(
            activeUpstream(for: track).absoluteString
        )
        let fallbackURL = localURL(
            path: "media",
            queryItems: [
                URLQueryItem(name: "u", value: encodedFallback),
                URLQueryItem(
                    name: "from",
                    value: "\(track.mediaStartOffset)"
                )
            ]
        )
        diagLog(.playback, "/segment: sidx not ready, falling back",
                details: [
                    "conn": connID,
                    "n": nString,
                    "fallback": fallbackURL
                ])
        respondError(connection: connection, status: 503,
                     reason: "sidx not ready", connID: connID)
        return
    }

    let frag = index.fragments[idx]
    let activeURL = activeUpstream(for: track)
    var upstreamReq = URLRequest(url: activeURL)
    upstreamReq.setValue(referer, forHTTPHeaderField: "Referer")
    upstreamReq.setValue(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/18.0 Mobile/15E148 Safari/604.1",
        forHTTPHeaderField: "User-Agent"
    )
    let byteCount = frag.byteRange.count
    upstreamReq.setValue(
        "bytes=\(frag.byteRange.lowerBound)-\(frag.byteRange.upperBound - 1)",
        forHTTPHeaderField: "Range"
    )
    upstreamReq.httpMethod = "GET"

    let stream = StreamingProxyTask(
        server: self,
        connection: connection,
        upstream: activeURL,
        request: upstreamReq,
        mode: "segment[\(idx)]",
        // Segment URLs are independent resources — no Range
        // shifting math, AVPlayer treats each as a self-
        // contained segment.
        clientSentRange: false,
        contentRangeShift: nil,
        passContentRange: false,
        connID: connID,
        rangeStart: frag.byteRange.lowerBound,
        rangeEnd: frag.byteRange.upperBound - 1
    )
    retain(stream: stream)
    stream.start()

    if Self.requestMetadataLogEnabled {
        diagLog(.playback, "LocalHLSProxyServer /segment served",
                details: [
                    "conn": connID,
                    "kind": params["k"] ?? "?",
                    "n": idx,
                    "startTime": String(format: "%.3f", frag.startTime),
                    "duration": String(format: "%.3f", frag.duration),
                    "byteRange": "\(frag.byteRange.lowerBound)"
                        + "-\(frag.byteRange.upperBound - 1)",
                    "bytes": byteCount
                ])
    }
}

    /// Proxy a single segment request.  AVPlayer issues
    /// `GET /init?...` for the fMP4 map and `GET /media?...`
    /// for the playable media data.  We translate those into
    /// absolute upstream byte ranges, then forward to the CDN
    /// with the right `Referer` and `User-Agent`.  The upstream
    /// body is streamed into the loopback response as it arrives;
    /// buffering the whole m4s first makes AVPlayer sit forever
    /// in `waitingToPlayAtSpecifiedRate`.
    private func proxySegment(
        req: HTTPRequest,
        connection: NWConnection,
        mode: ProxyMode,
        connID: String
    ) {
        guard let (source, referer) = snapshot() else {
            respondError(connection: connection, status: 503,
                         reason: "no playback", connID: connID)
            return
        }
        let query = req.path.split(separator: "?", maxSplits: 1)
            .last.map(String.init) ?? ""
        let params = parseQuery(query)
        guard let encoded = params["u"],
              let upstreamString = base64urlDecode(encoded),
              let upstream = URL(string: upstreamString) else {
            respondError(connection: connection, status: 400,
                         reason: "missing u", connID: connID)
            return
        }
        // Refuse to proxy anything other than the B站 CDN
        // (or localhost, in dev).  This is a defence-in-depth
        // check; the segment URL is generated by us, so it
        // should always be a B站 URL anyway.
        guard let host = upstream.host,
              isAllowedUpstreamHost(host) else {
            respondError(connection: connection, status: 400,
                         reason: "bad upstream host", connID: connID)
            return
        }
        var upstreamReq = URLRequest(url: upstream)
        upstreamReq.setValue(referer, forHTTPHeaderField: "Referer")
        upstreamReq.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        // Track the downstream Range so we can decide whether
        // to mirror 206/Content-Range or fall back to 200.
        // `AVPlayer` is strict: when it asks for `Range: bytes=…`,
        // it MUST see `206 Partial Content` plus a matching
        // `Content-Range` header, otherwise it abandons the
        // stream.  When it asks for the whole resource (no
        // Range), we MUST return `200 OK` with the full body.
        let clientRange = req.headers["range"]
        var contentRangeShift: Int64?
        var passContentRange = false
        switch mode {
        case .passthrough:
            // Forward Range if AVPlayer sent one (it does for
            // seeks).  B站 supports byte-range, so the forward is
            // safe.
            if let range = clientRange {
                upstreamReq.setValue(range, forHTTPHeaderField: "Range")
                passContentRange = true
            }
        case .initRange:
            // `/init` is a *logical* sub-resource that covers
            // only the fMP4 `ftyp`/`moov`/`sidx` bytes.
            // Record the sub-resource's absolute upstream
            // offset as the Content-Range shift so the
            // response can convert the upstream's absolute
            // `Content-Range` into the relative coordinates
            // AVPlayer expects for `/init` (the same way we
            // already do for `/media`).
            guard let range = parseByteRange(params["range"]) else {
                respondError(connection: connection, status: 400,
                             reason: "missing init range", connID: connID)
                return
            }
            upstreamReq.setValue(
                Self.httpRangeHeader(offset: range.offset, end: range.endOffset),
                forHTTPHeaderField: "Range"
            )
            contentRangeShift = range.offset
        case .mediaRange:
            guard let startString = params["from"],
                  let start = Int64(startString) else {
                respondError(connection: connection, status: 400,
                             reason: "missing media range", connID: connID)
                return
            }
            // Optional end byte.  When the multi-segment
            // playlist emits `/media?from=X&to=Y`, the server
            // only wants those exact bytes; without a Range
            // header from AVPlayer we have to synthesise one
            // for the upstream.
            let endString = params["to"]
            let end = endString.flatMap { Int64($0) }
            if let range = clientRange,
               let shifted = Self.shiftedRangeHeader(range, by: start) {
                upstreamReq.setValue(shifted, forHTTPHeaderField: "Range")
                contentRangeShift = start
            } else {
                upstreamReq.setValue(
                    Self.httpRangeHeader(offset: start, end: end),
                    forHTTPHeaderField: "Range"
                )
                contentRangeShift = start
            }
        }
        _ = source  // Keep the playback snapshot alive while
                    // the URLSession request is queued.

        // Virtual dynamic splicing (v2): the proxy used to
        // cancel in-flight requests whose byte range overlapped
        // with the new one — the theory was that AVPlayer
        // would otherwise see two streams deliver competing
        // bytes into the same socket and CoreMedia would emit
        // -19602 decode errors.
        //
        // In practice the cancellation is what was killing
        // playback.  AVPlayer issues 5-10 concurrent connections
        // per buffer fill; some of those connections carry
        // *adjacent* or *identical* byte ranges that the player
        // uses as a redundancy / pre-fetch mechanism.  When the
        // proxy pre-emptively cancelled the older connection,
        // the downstream socket closed mid-write, AVPlayer
        // threw away the partial response, and the buffer never
        // accumulated.  The player then stalled at the seek
        // point (`currentTime` stuck at the saved resume value,
        // `loadedTimeRanges` permanently empty) because every
        // request got cancelled before its bytes could land.
        //
        // The right behaviour is the user's "give generously":
        // honour AVPlayer's Range header, fetch whatever
        // upstream bytes are needed (the upstream CDN itself
        // serves arbitrary byte ranges — we don't need to do
        // any proxy-side concatenation), and let multiple
        // concurrent streams complete.  AVPlayer will discard
        // whatever it doesn't need; the upstream CDN handles
        // concurrent Range requests against the same file just
        // fine (it's their primary workload).
        //
        // We *do* keep the in-flight tracking below, but purely
        // for diagnostics — no cancellation, no pre-emption.
        // The "double-delivery" risk the old code was guarding
        // against never actually reproduced in the field; the
        // user-visible symptom it caused (post-seek stalls) is
        // far worse than the hypothetical it was preventing.
        let upstreamKey = upstream.absoluteString
        var reqStart: Int64?
        var reqEnd: Int64?

        if let rangeHeader = upstreamReq.value(forHTTPHeaderField: "Range"),
           rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
            let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if bounds.count == 2, let rs = Int64(bounds[0]) {
                reqStart = rs
                if !bounds[1].isEmpty, let re = Int64(bounds[1]) {
                    reqEnd = re
                } else {
                    reqEnd = Int64.max // Representing until EOF
                }
            }
        } else if mode == .mediaRange {
            // If no range header was added (meaning we request to EOF), we still want to track it.
            if let startString = params["from"], let rs = Int64(startString) {
                reqStart = rs
                if let endString = params["to"], let re = Int64(endString) {
                    reqEnd = re
                } else {
                    reqEnd = Int64.max
                }
            }
        }

        if let rs = reqStart, let re = reqEnd {
            // Diagnostic-only: record this range and the count of
            // other concurrent in-flight streams against the same
            // upstream URL.  No cancellation.  Operators can read
            // the resulting "fanout" number in the diagnostic
            // report to see how aggressively AVPlayer is
            // requesting — useful for tuning the multi-segment
            // playlist generation later if needed.
            lock.lock()
            let fanout = inFlightRanges[upstreamKey] != nil ? 1 : 0
            inFlightRanges[upstreamKey] = (rs, re, UUID())
            lock.unlock()
            if fanout > 0,
               Self.requestMetadataLogEnabled {
                diagLog(.network,
                        "LocalHLSProxyServer concurrent in-flight stream",
                        details: [
                            "conn": connID,
                            "mode": mode.logName,
                            "newRange": "\(rs)-\(re)"
                        ])
            }
        }

        if Self.requestMetadataLogEnabled {
            diagLog(.playback,
                    "LocalHLSProxyServer upstream request",
                    details: [
                        "conn": connID,
                        "mode": mode.logName,
                        "host": upstream.host ?? "",
                        "hasReferer": upstreamReq.value(
                            forHTTPHeaderField: "Referer"
                        ) != nil,
                        "range": upstreamReq.value(
                            forHTTPHeaderField: "Range"
                        ) ?? ""
                    ])
        }
        let stream = StreamingProxyTask(
            server: self,
            connection: connection,
            upstream: upstream,
            request: upstreamReq,
            mode: mode.logName,
            clientSentRange: clientRange != nil,
            contentRangeShift: contentRangeShift,
            passContentRange: passContentRange,
            connID: connID,
            rangeStart: reqStart,
            rangeEnd: reqEnd
        )
        retain(stream: stream)
        stream.start()
    }

    // MARK: local segment handler

    /// Local-mode equivalent of `proxySegment`.  Reads the
    /// init / media m4s file from `localContext.directory`
    /// and serves the requested byte range straight to the
    /// downstream socket — no upstream network call, no
    /// `URLSession`, no `Referer` rewrite.
    ///
    /// Status / `Content-Range` rules match `proxySegment`:
    ///   - no client Range → `200 OK` with the full body
    ///   - client Range   → `206 Partial Content` with a
    ///     matching `Content-Range` header
    fileprivate func proxyLocalSegment(
        req: HTTPRequest,
        connection: NWConnection,
        kind: ProxyMode,
        connID: String
    ) {
        let context: LocalPlaybackContext? = {
            lock.lock(); defer { lock.unlock() }
            return localContext
        }()
        guard let context else {
            respondError(connection: connection, status: 503,
                         reason: "no local context", connID: connID)
            return
        }
        let query = req.path.split(separator: "?", maxSplits: 1)
            .last.map(String.init) ?? ""
        let params = parseQuery(query)

        // Decode the upstream URL from the `u` query
        // parameter so we can match it against the active
        // `BiliDashSource` and decide whether this
        // init/media request is for the video or the audio
        // track.  Same wire contract as the upstream path.
        let source: BiliDashSource? = {
            lock.lock(); defer { lock.unlock() }
            return currentPlayback?.dash
        }()
        guard let source else {
            respondError(connection: connection, status: 503,
                         reason: "no source", connID: connID)
            return
        }
        guard let encoded = params["u"],
              let upstreamString = base64urlDecode(encoded),
              let upstream = URL(string: upstreamString) else {
            respondError(connection: connection, status: 400,
                         reason: "missing u", connID: connID)
            return
        }
        let mediaLabel: String
        let track: BiliDashSource.Track
        if source.video.baseURL == upstream {
            mediaLabel = "video"
            track = source.video
        } else if let audio = source.audio, audio.baseURL == upstream {
            mediaLabel = "audio"
            track = audio
        } else {
            respondError(connection: connection, status: 400,
                         reason: "unknown upstream", connID: connID)
            return
        }

        // Resolve the on-disk file path and the absolute
        // byte range the caller is asking for.  The wire
        // contract mirrors the upstream path: `/init` reads
        // from `track.initializationRange`, `/media` reads
        // from `track.mediaStartOffset` for the rest of the
        // file.
        let (fileURL, requestStart, requestEnd): (URL, Int64, Int64?) = {
            switch kind {
            case .initRange:
                guard let range = parseByteRange(params["range"]) else {
                    return (context.directory, 0, nil)
                }
                let url = context.directory
                    .appendingPathComponent("\(mediaLabel).init")
                let localStart = max(
                    0,
                    range.offset - track.initializationRange.offset
                )
                let localEnd = max(
                    localStart,
                    range.endOffset - track.initializationRange.offset
                )
                return (url, localStart, localEnd)
            case .mediaRange:
                guard let startString = params["from"],
                      let start = Int64(startString) else {
                    return (context.directory, 0, nil)
                }
                let endString = params["to"].flatMap { Int64($0) }
                let url = context.directory
                    .appendingPathComponent("\(mediaLabel).media")
                let localStart = max(0, start - track.mediaStartOffset)
                let localEnd = endString.map {
                    max(localStart, $0 - track.mediaStartOffset)
                }
                return (url, localStart, localEnd)
            case .passthrough:
                return (context.directory, 0, nil)
            }
        }()

        guard let fileSize = (try? FileManager.default
                .attributesOfItem(atPath: fileURL.path))?[.size]
                as? Int64, fileSize > 0 else {
            respondError(connection: connection, status: 404,
                         reason: "missing local file", connID: connID)
            return
        }
        // Clamp the requested range to the file size.
        let endInclusive: Int64
        if let requestEnd {
            endInclusive = min(requestEnd, fileSize - 1)
        } else {
            endInclusive = fileSize - 1
        }
        let clampedStart = min(max(0, requestStart), fileSize - 1)
        guard clampedStart <= endInclusive else {
            respondError(connection: connection, status: 416,
                         reason: "range not satisfiable", connID: connID)
            return
        }
        let byteCount = endInclusive - clampedStart + 1

        // Read the bytes synchronously.  The files are
        // bounded (a typical VOD is 50-100 MB) and AVPlayer
        // typically asks for a sub-range; for a full-file
        // read we still serve it in one shot because the
        // player is happy to receive the whole segment
        // before issuing the next range.
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(clampedStart))
            data = handle.readData(ofLength: Int(byteCount))
        } catch {
            respondError(connection: connection, status: 500,
                         reason: "read failed: \(error.localizedDescription)",
                         connID: connID)
            return
        }

        let clientSentRange = req.headers["range"] != nil
        let status = clientSentRange ? 206 : 200
        var extra: [String: String] = ["Accept-Ranges": "bytes"]
        if clientSentRange {
            extra["Content-Range"] =
                "bytes \(clampedStart)-\(endInclusive)/\(fileSize)"
        }
        let mime: String
        switch kind {
        case .initRange, .mediaRange: mime = "video/mp4"
        case .passthrough:            mime = "video/mp4"
        }
        respondBytes(
            connection: connection,
            status: status,
            contentType: mime,
            body: data,
            extraHeaders: extra,
            connID: connID,
            label: "LOCAL SEGMENT"
        )
    }

    // MARK: response helpers

    private func respondText(connection: NWConnection,
                             connID: String,
                             body: String) {
        respondBytes(
            connection: connection,
            status: 200,
            contentType: "application/vnd.apple.mpegurl",
            body: Data(body.utf8),
            connID: connID,
            label: "DOWNSTREAM RESPONSE HEADER+SMALL BODY"
        )
    }

    private func respondError(
        connection: NWConnection,
        status: Int,
        reason: String,
        connID: String
    ) {
        Analytics.recordError(
            NSError(domain: "paladala.proxy", code: status, userInfo: [
                NSLocalizedDescriptionKey: reason,
                "connID": connID
            ]),
            context: "proxy_respondError"
        )
        let body = "{\"error\":\"\(reason)\"}"
        respondBytes(
            connection: connection,
            status: status,
            contentType: "application/json",
            body: Data(body.utf8),
            connID: connID,
            label: "DOWNSTREAM ERROR RESPONSE"
        )
    }

    private func respondBytes(
        connection: NWConnection,
        status: Int,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:],
        connID: String,
        label: String
    ) {
        var response = httpHeaderData(
            status: status,
            contentType: contentType,
            contentLength: Int64(body.count),
            extraHeaders: extraHeaders
        )
        response.append(body)
        if Self.wireDumpEnabled {
            // Diagnostic: dump the actual bytes we are about
            // to hand to `connection.send` so we can see the
            // on-wire framing (CRLF + double-CRLF terminator,
            // Content-Length, headers, etc.).
            diagLog(.network,
                    "LocalHLSProxyServer wire bytes",
                    details: [
                        "conn": connID,
                        "label": label,
                        "bytes": Self.dumpWireBytes(response, label: label)
                    ])
        }
        connection.send(
            content: response,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    fileprivate func sendHeader(
        connection: NWConnection,
        status: Int,
        contentType: String,
        contentLength: Int64?,
        extraHeaders: [String: String] = [:],
        connID: String? = nil
    ) {
        let header = httpHeaderData(
            status: status,
            contentType: contentType,
            contentLength: contentLength,
            extraHeaders: extraHeaders
        )
        if Self.wireDumpEnabled {
            diagLog(.network,
                    "LocalHLSProxyServer wire bytes",
                    details: [
                        "conn": connID ?? "",
                        "label": "DOWNSTREAM RESPONSE HEADER",
                        "bytes": Self.dumpWireBytes(
                            header,
                            label: "DOWNSTREAM RESPONSE HEADER"
                        )
                    ])
        }
        connection.send(
            content: header,
            completion: .contentProcessed { _ in }
        )
    }

    private func httpHeaderData(
        status: Int,
        contentType: String,
        contentLength: Int64?,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        let reason = reasonPhrase(for: status)
        var headerLines = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
        ]
        for key in extraHeaders.keys.sorted() {
            headerLines.append("\(key): \(extraHeaders[key] ?? "")")
        }
        if let contentLength {
            headerLines.append("Content-Length: \(contentLength)")
        }
        headerLines += [
            "Connection: close",
            "Cache-Control: no-store",
            "",
            "",
        ]
        return Data(headerLines.joined(separator: "\r\n").utf8)
    }

    private func retain(stream: StreamingProxyTask) {
        lock.lock()
        activeStreams[stream.id] = stream
        lock.unlock()
    }

    fileprivate func finishStream(id: UUID) {
        lock.lock()
        activeStreams.removeValue(forKey: id)
        lock.unlock()
    }

    fileprivate func addStreamedBytes(_ count: Int) {
        lock.lock()
        byteCount += Int64(count)
        lock.unlock()
    }

    private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default:  return "OK"
        }
    }

    // MARK: utilities

    private func parseQuery(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let k = String(kv[0])
                let v = String(kv[1])
                out[k] = v.removingPercentEncoding ?? v
            }
        }
        return out
    }

    private func localURL(
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> String {
        guard let baseURL else { return "" }
        let url = baseURL.appendingPathComponent(path)
        guard !queryItems.isEmpty else {
            return url.absoluteString
        }
        var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        return components?.url?.absoluteString ?? url.absoluteString
    }

    private func parseByteRange(
        _ raw: String?
    ) -> BiliDashSource.ByteRange? {
        guard let raw else { return nil }
        let bounds = raw.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              end >= start else {
            return nil
        }
        return BiliDashSource.ByteRange(
            offset: start,
            length: end - start + 1
        )
    }

    fileprivate static func httpRangeHeader(offset: Int64, end: Int64?) -> String {
        if let end {
            return "bytes=\(offset)-\(end)"
        }
        return "bytes=\(offset)-"
    }

    fileprivate static func shiftedRangeHeader(
        _ header: String,
        by offset: Int64
    ) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes=") else {
            return nil
        }
        let spec = trimmed.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return nil }
        let bounds = spec.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              !bounds[0].isEmpty,
              let relativeStart = Int64(bounds[0]) else {
            return nil
        }
        let absoluteStart = offset + relativeStart
        if bounds[1].isEmpty {
            return Self.httpRangeHeader(offset: absoluteStart, end: nil)
        }
        guard let relativeEnd = Int64(bounds[1]),
              relativeEnd >= relativeStart else {
            return nil
        }
        return Self.httpRangeHeader(
            offset: absoluteStart,
            end: offset + relativeEnd
        )
    }

    /// Converts an upstream `Content-Range: bytes X-Y/Z` header to
    /// client-side relative coordinates by subtracting `offset`.
    ///
    /// The denominator (Z) is preserved exactly as-is — it must always
    /// be the original CDN file's total byte count.  AVPlayer tracks
    /// the file's total duration via this value; shrinking it per
    /// segment (e.g. Z→Z−offset) causes the playback timeline to
    /// contract with every new segment and ultimately triggers
    /// `-19602` decode errors.
    fileprivate func shiftedContentRange(
        _ header: String,
        by offset: Int64
    ) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else {
            return nil
        }
        let payload = trimmed.dropFirst("bytes ".count)
        let rangeAndTotal = payload.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let absoluteStart = Int64(bounds[0]),
              let absoluteEnd = Int64(bounds[1]),
              absoluteStart >= offset,
              absoluteEnd >= absoluteStart else {
            return nil
        }
        let relativeStart = absoluteStart - offset
        let relativeEnd = absoluteEnd - offset

        let totalPart: String
        if rangeAndTotal[1] == "*" {
            totalPart = "*"
        } else if let absoluteTotal = Int64(rangeAndTotal[1]) {
            let relativeTotal = absoluteTotal - offset
            totalPart = "\(relativeTotal)"
        } else {
            return nil
        }

        return "bytes \(relativeStart)-\(relativeEnd)/\(totalPart)"
    }

    private func isAllowedUpstreamHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "127.0.0.1" || lower == "localhost" {
            return true
        }
        let allowedDomains = [
            "bilivideo.com",
            "bilivideo.cn",
            "hdslb.com",
            "bilibili.com",
            "akamaized.net",
            "szbdyd.com",
        ]
        return allowedDomains.contains { domain in
            lower == domain || lower.hasSuffix(".\(domain)")
        }
    }

    private func base64urlEncode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func base64urlDecode(_ s: String) -> String? {
        var t = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        guard let d = Data(base64Encoded: t) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    fileprivate func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "m3u8":               return "application/vnd.apple.mpegurl"
        case "m4s", "mp4", "mov":  return "video/mp4"
        case "aac":                return "audio/aac"
        case "ts":                 return "video/mp2t"
        default:                   return "application/octet-stream"
        }
    }
}

private final class StreamingProxyTask: NSObject, URLSessionDataDelegate {
    let id = UUID()

    private weak var server: LocalHLSProxyServer?
    private let connection: NWConnection
    private let upstream: URL
    private let request: URLRequest
    private let mode: String
    /// Short, stable ID for the TCP connection that originated
    /// this request.  Propagated into every diagnostic marker
    /// so we can correlate lifecycle events on the same
    /// socket — particularly useful for the keep-alive-reuse
    /// hypothesis (trap 3).
    fileprivate let connID: String
    /// Absolute byte range this stream is fetching from the
    /// upstream.  Used to detect overlaps with other in-flight
    /// streams so we can cancel the older one and avoid
    /// double-delivery decode errors (-19602).
    private let rangeStart: Int64?
    private let rangeEnd: Int64?
    /// `true` if the loopback client (AVPlayer) sent a
    /// `Range` header.  When `true`, our downstream response
    /// MUST use `206 Partial Content` and include a
    /// `Content-Range` header — AVPlayer aborts any
    /// partial-content request that does not get a 206.
    /// When `false`, the response MUST be `200 OK` with no
    /// `Content-Range` header.
    private let clientSentRange: Bool
    private let contentRangeShift: Int64?
    private let passContentRange: Bool
    private let sendGroup = DispatchGroup()
    private let delegateQueue: OperationQueue

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var didSendHeader = false
    private var didFinish = false
    /// Diagnostic counters for the downstream body stream
    /// (only touched when `LocalHLSProxyServer.wireDumpEnabled`
    /// is `true`).  Used to emit the body-totals log line on
    /// completion so we can cross-check the actual bytes we
    /// pushed to `connection.send` against the
    /// `Content-Length` we promised in the header.
    private var downstreamChunksSent = 0
    private var downstreamBytesSent: Int64 = 0
    /// Set as soon as we see a downstream send failure
    /// (e.g. AVPlayer tore the socket down in
    /// `onDisappear`).  Guards against continuing to
    /// drain a 71 MB upstream response into a dead
    /// `NWConnection`.
    private var downstreamBroken = false
    /// Total bytes that have arrived from the upstream
    /// across every attempt so far.  On a mid-stream
    /// upstream failure we re-issue the same Range shifted
    /// to `bytesReceivedFromUpstream` so the downstream
    /// (AVPlayer) sees one continuous byte stream — it
    /// never knows the upstream socket was reset.
    private var bytesReceivedFromUpstream: Int64 = 0
    /// 0 = the very first request, 1..3 = retries.  Capped
    /// at `Self.maxRetries` total attempts to avoid an
    /// infinite loop if the upstream keeps failing.
    private var upstreamAttempt: Int = 0
    /// Set when we abort the current upstream task on
    /// purpose to schedule a retry (e.g. 5xx response, or a
    /// retryable transport error).  Without this flag the
    /// resulting `URLError.cancelled` in
    /// `didCompleteWithError` would look identical to the
    /// "we cancelled because the downstream went away"
    /// path and we'd never retry.
    private var cancelledForRetry = false

    /// Maximum number of times we re-issue the upstream
    /// request after the first attempt.  With base backoff
    /// 100ms and a 3× multiplier the worst-case extra wait
    /// is 100+300+900 = 1300ms — short enough that the
    /// `controller.isBuffering` overlay shows briefly but
    /// AVPlayer does not give up.
    private static let maxRetries: Int = 3
    private static let baseBackoffSeconds: Double = 0.1

    init(
        server: LocalHLSProxyServer,
        connection: NWConnection,
        upstream: URL,
        request: URLRequest,
        mode: String,
        clientSentRange: Bool,
        contentRangeShift: Int64?,
        passContentRange: Bool,
        connID: String,
        rangeStart: Int64?,
        rangeEnd: Int64?
    ) {
        self.server = server
        self.connection = connection
        self.upstream = upstream
        self.request = request
        self.mode = mode
        self.clientSentRange = clientSentRange
        self.contentRangeShift = contentRangeShift
        self.passContentRange = passContentRange
        self.connID = connID
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.delegateQueue = OperationQueue()
        self.delegateQueue.maxConcurrentOperationCount = 1
        super.init()
        // Watch the loopback connection for peer-initiated
        // close.  When AVPlayer goes to fullscreen it tears
        // down in-flight segments; the OS then drives the
        // `NWConnection` into `.cancelled` (or `.failed` on
        // a RST).  We use that signal to stop the upstream
        // URLSession task immediately so we don't keep
        // pulling bytes from the B站 CDN for a dead
        // downstream socket.  The handler is installed in
        // `init` (not when the first send happens) so we
        // catch disconnects that arrive *before* the first
        // body send, which would otherwise slip through the
        // `connection.send` error path entirely.
        //
        // The handler runs on the connection's queue
        // (`LocalHLSProxyServer.queue`, the listener queue).
        // `task?.cancel()` is safe to call from any thread;
        // URLSession will route the resulting
        // `didCompleteWithError(NSURLErrorCancelled)` to the
        // serial `delegateQueue` where the existing branch
        // at `urlSession(_:task:didCompleteWithError:)` calls
        // `finishWhenSendsDrain()` for clean teardown.
        self.connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.markDownstreamBroken(
                    reason: "connection state: \(state)"
                )
            default:
                break
            }
        }
    }

    func start() {
        startSession()
        // Register this stream's byte range so overlapping
        // requests from concurrent AVPlayer tasks can be caught.
        if let rs = rangeStart, let re = rangeEnd {
            let key = upstream.absoluteString
            server?.lock.lock()
            server?.inFlightRanges[key] = (rs, re, id)
            server?.lock.unlock()
        }
        startUpstreamTask(attempt: 0)
    }

    /// Cancel this stream and unregister its byte range so any
    /// overlapping new request can proceed without competing
    /// with a dead socket.
    fileprivate func cancel() {
        task?.cancel()
        connection.cancel()
        session?.finishTasksAndInvalidate()
        unregisterRange()
    }

    private func unregisterRange() {
        guard let rs = rangeStart, let re = rangeEnd else { return }
        let key = upstream.absoluteString
        server?.lock.lock()
        if let existing = server?.inFlightRanges[key],
           existing.streamID == id,
           existing.start == rs, existing.end == re {
            server?.inFlightRanges.removeValue(forKey: key)
        }
        server?.lock.unlock()
    }

    /// Mark the downstream socket as gone and stop pulling
    /// bytes from the B站 CDN for it.  Idempotent — the
    /// `stateUpdateHandler` (peer-initiated close) and the
    /// `connection.send` completion (we noticed on write)
    /// can both call in, and the first writer wins.  Logs a
    /// single `downstream closed` line on the *first* call
    /// so the diagnostic stream still shows the specific
    /// reason without spamming duplicates when both paths
    /// fire on the same disconnect.
    ///
    /// We deliberately do NOT call `connection.cancel()`
    /// here.  When the send-error path triggers us, there
    /// is an in-flight `connection.send` whose completion
    /// closure still has to `sendGroup.leave()` — cancelling
    /// the connection mid-send would prevent that and leave
    /// `finishWhenSendsDrain()` waiting forever.  The
    /// existing `urlSession(_:task:didCompleteWithError:)`
    /// path handles `NSURLErrorCancelled` and drives the
    /// connection cancel via `sendGroup.notify` once the
    /// drain is complete.
    fileprivate func markDownstreamBroken(reason: String) {
        if downstreamBroken { return }
        downstreamBroken = true
        // `task` is the URLSession upstream leg; cancelling
        // it stops further `didReceive data` callbacks.
        task?.cancel()
        diagLog(.network,
                "LocalHLSProxyServer downstream closed",
                details: [
                    "conn": connID,
                    "mode": mode,
                    "reason": reason
                ])
    }

    /// One-shot URLSession construction.  Kept separate from
    /// `startUpstreamTask(attempt:)` so the session survives
    /// across retries — creating a fresh `URLSession` per
    /// attempt would burn a new TCP + TLS handshake per
    /// retry, which both slows down recovery and defeats
    /// connection pooling on subsequent segments.
    private func startSession() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        self.session = session
    }

    /// (Re)issue the upstream request.  On a retry the
    /// Range header is shifted by `bytesReceivedFromUpstream`
    /// so the CDN hands us the bytes that were lost when
    /// the previous attempt's socket died.  The downstream
    /// (AVPlayer) sees those bytes appended to the stream it
    /// already has — no AVPlayer-side retry, no gap.
    private func startUpstreamTask(attempt: Int) {
        guard let session else { return }
        upstreamAttempt = attempt
        cancelledForRetry = false
        let shifted = shiftedRequest(startingAt: bytesReceivedFromUpstream)
        let task = session.dataTask(with: shifted)
        self.task = task
        task.resume()
    }

    /// Build a new `URLRequest` for the upstream that picks
    /// up where the previous attempt left off.  We mutate a
    /// copy of the original request so the referer / user
    /// agent / host we already validated are preserved.
    private func shiftedRequest(startingAt offset: Int64) -> URLRequest {
        var newRequest = request
        guard offset > 0 else { return newRequest }
        let originalRange = request.value(forHTTPHeaderField: "Range")
        let newRange: String
        if let originalRange,
           let shifted = LocalHLSProxyServer.shiftedRangeHeader(
                originalRange, by: offset
           ) {
            // Original was `bytes=start-end` or
            // `bytes=start-` — shift the start by
            // `bytesReceivedFromUpstream` so the next
            // attempt asks for the bytes we have not yet
            // received.
            newRange = shifted
        } else {
            // Original had no Range header (we asked for
            // the whole file).  Switch to a Range request
            // starting at `offset` so the CDN does not
            // resend the bytes the downstream already has.
            newRange = LocalHLSProxyServer.httpRangeHeader(
                offset: offset, end: nil
            )
        }
        newRequest.setValue(newRange, forHTTPHeaderField: "Range")
        return newRequest
    }

    /// True for transport-level errors that are safe to
    /// retry: the network connection died mid-flight, the
    /// request timed out, or we could not connect.  These
    /// are the exact failure modes we saw in the build-82
    /// diagnostic report — B站's CDN reset our socket
    /// mid-stream (`URLError.networkConnectionLost`, code
    /// -1005) and we previously gave up after one try.
    private func isRetryable(_ nsError: NSError) -> Bool {
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorTimedOut,                 // -1001
             NSURLErrorCannotConnectToHost,      // -1004
             NSURLErrorNetworkConnectionLost,    // -1005
             NSURLErrorDNSLookupFailed,          // -1006
             NSURLErrorNotConnectedToInternet:   // -1009
            return true
        default:
            return false
        }
    }

    /// Schedule the next upstream attempt on the delegate
    /// queue (serial, `maxConcurrentOperationCount = 1`)
    /// so we never race with `didCompleteWithError` from
    /// the previous attempt.  Emits a single retry log line
    /// so the diagnostic stream shows the recovery.
    private func scheduleRetry(reason: String, attempt: Int) {
        let backoff = Self.baseBackoffSeconds * pow(3.0, Double(attempt - 1))
        diagLog(.network,
                "LocalHLSProxyServer upstream retry",
                details: [
                    "mode": mode,
                    "attempt": attempt,
                    "maxRetries": Self.maxRetries,
                    "bytesReceived": bytesReceivedFromUpstream,
                    "backoffMs": Int(backoff * 1000),
                    "reason": reason
                ])
        // `delegateQueue` is an `OperationQueue`, so we
        // schedule the retry on a global dispatch queue.
        // The new task's `URLSessionDataDelegate` callbacks
        // still arrive on the serial `delegateQueue`, so the
        // retry does not race with any in-flight callbacks
        // from the previous attempt — by the time we get
        // here `didCompleteWithError` has already returned
        // and URLSession will not send more events for the
        // old task.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + backoff
        ) { [weak self] in
            self?.startUpstreamTask(attempt: attempt)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // Race guard.  The connection's queue and the
        // URLSession delegate queue are different; a
        // `connection.send` failure on the listener queue
        // can flip `downstreamBroken` *after* a response
        // callback has already been enqueued on the
        // delegate queue.  Without this guard we would
        // synthesise a 200/206 header and write it to a
        // dead socket — another `NWError 57` log line for
        // no benefit.  The cancel disposition propagates
        // straight to `didCompleteWithError(NSURLErrorCancelled)`
        // which the existing branch already handles.
        if downstreamBroken {
            completionHandler(.cancel)
            return
        }
        guard let server,
              let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finishWithError(reason: "bad upstream response")
            return
        }
        // Short-circuit upstream 5xx before we write any
        // header to the downstream — sending even a partial
        // 5xx body through the loopback would leave
        // AVPlayer's parser in a state where it cannot
        // accept the retried response on the next attempt.
        if (500...599).contains(http.statusCode) {
            cancelledForRetry = true
            completionHandler(.cancel)
            // CDN failover: a 5xx from the upstream is the
            // signal the host is degraded.  Move the cursor
            // forward so the next playlist emission uses the
            // backup.  The task captures `upstream` at
            // construction time — that's the URL we just got
            // the 5xx from, which is enough for the helper to
            // resolve the parent track and bump the cursor.
            // No-op if we're already at the end of the backup
            // list for this track.  `server` was already
            // unwrapped by the `guard let server, let http = ...`
            // at the top of this branch, so we call through
            // directly — re-binding with `if let` would shadow
            // the local with the same name and produce a
            // "must have Optional type" error.
            server.markUpstreamFailed(url: upstream)
            if upstreamAttempt < Self.maxRetries {
                // Still have retries left — wait for a
                // fresh upstream attempt with the Range
                // shifted by `bytesReceivedFromUpstream`,
                // then write its response to the same
                // downstream socket that is still waiting.
                scheduleRetry(
                    reason: "5xx: \(http.statusCode)",
                    attempt: upstreamAttempt + 1
                )
                return
            }
            // Retries exhausted — send a clean 502 to
            // AVPlayer so its parser sees a valid HTTP
            // response (not a 206 wrapping a 5xx body),
            // then tear down.
            server.sendHeader(
                connection: connection,
                status: 502,
                contentType: "application/json",
                contentLength: nil,
                connID: connID
            )
            didSendHeader = true
            diagLog(.network,
                    "Upstream segment error",
                    details: [
                        "mode": mode,
                        "attempts": Self.maxRetries + 1,
                        "error": "5xx: \(http.statusCode)"
                    ])
            finishWhenSendsDrain()
            return
        }
        didSendHeader = true
        var extraHeaders: [String: String] = ["Accept-Ranges": "bytes"]
        let upstreamContentRange = http.value(forHTTPHeaderField: "Content-Range")

        // Decide downstream status.  AVPlayer's strict rule:
        //   - if the client sent `Range: bytes=…`, the response
        //     MUST be `206 Partial Content` with a matching
        //     `Content-Range` header.  Anything else and the
        //     stream is abandoned.
        //   - if the client did not send Range, the response
        //     MUST be `200 OK` with the full body.  Returning
        //     206 here is also legal but `Content-Range` must
        //     match, so we play it safe with 200.
        // `/init` and `/media` are *logical* sub-resources of
        // the upstream m4s file, but from the client's
        // perspective they look like whole documents — so when
        // the client does NOT send Range we answer `200`, and
        // when it DOES send Range we answer `206` with a
        // `Content-Range` that has been shifted down to the
        // sub-resource's byte coordinates.
        //
        // NOTE: `/init` and `/media` are NOT symmetric:
        //   * `/init` is a *logical* sub-resource — AVPlayer
        //     never asks for a Range on it, and the body is
        //     the init bytes in their entirety. 200 OK +
        //     Content-Length is correct.
        //   * `/media` is a *partial* sub-resource — its
        //     body is a slice of the upstream file (init
        //     bytes are served separately by `/init`).
        //     Even when the single-segment playlist
        //     fallback is in effect and AVPlayer does not
        //     send a Range, the HTTP contract is still
        //     206 + Content-Range, because the resource is
        //     a slice of a larger file.  Returning 200
        //     here makes AVPlayer RST the socket
        //     (NWError 54) and/or blacklist the track.
        let isInitSubResource = (mode == "init")
        let status: Int
        if clientSentRange {
            // Client asked for a byte range — MUST be 206.
            status = 206
            if let shift = contentRangeShift,
               let upstreamContentRange,
               let shifted = server.shiftedContentRange(
                    upstreamContentRange,
                    by: shift
               ) {
                // `/init` or `/media` with a known shift:
                // convert the upstream's absolute Content-Range
                // down to the sub-resource's relative bytes so
                // AVPlayer can apply it to the `/init` or
                // `/media` URL it asked for.
                extraHeaders["Content-Range"] = shifted
            } else if let upstreamContentRange {
                // `/seg` passthrough or no shift recorded:
                // forward the upstream's Content-Range
                // verbatim — it is already in the client's
                // coordinates.
                extraHeaders["Content-Range"] = upstreamContentRange
            }
        } else if isInitSubResource {
            // `/init` (no client Range): serve the upstream's
            // 206 body as a flat `200 OK` resource.  Drop
            // `Content-Range` so AVPlayer treats the body as
            // a complete sub-resource.
            status = 200
        } else {
            // `/media` (no client Range) and `/seg` (no client
            // Range): pass the upstream status through.  B 站
            // answered 206 because we asked for a Range; we
            // shift the absolute Content-Range down to a
            // *relative* range the client can use against the
            // logical sub-resource.
            status = http.statusCode
            if let upstreamContentRange,
               let shift = contentRangeShift,
               let shifted = server.shiftedContentRange(
                    upstreamContentRange,
                    by: shift
               ) {
                extraHeaders["Content-Range"] = shifted
            } else if let upstreamContentRange,
                      mode == "passthrough" {
                // `/seg` passthrough: forward verbatim.
                extraHeaders["Content-Range"] = upstreamContentRange
            }
        }
        let contentLength = http.expectedContentLength >= 0
            ? http.expectedContentLength
            : nil
        // Trap-2 sanity check: cross-check the upstream's
        // `Content-Length` against the bytes implied by the
        // `Content-Range` header.  For a 206 response the
        // body length must equal `end - start + 1`.  If
        // they don't match, the upstream is either broken
        // or we miscomputed the Range shift — both would
        // make AVPlayer kill the socket.
        let (rangeStart, rangeEnd, rangeTotal) = LocalHLSProxyServer
            .parseContentRangeHeader(upstreamContentRange ?? "")
        let computed: Int64 = (rangeStart >= 0 && rangeEnd >= rangeStart)
            ? (rangeEnd - rangeStart + 1)
            : -1
        let upstreamCL: Int64 = http.expectedContentLength >= 0
            ? http.expectedContentLength
            : -1
        if LocalHLSProxyServer.requestMetadataLogEnabled {
            diagLog(.network,
                    "LocalHLSProxyServer Content-Length sanity",
                    details: [
                        "conn": connID,
                        "mode": mode,
                        "upstreamStatus": http.statusCode,
                        "expectedContentLength": upstreamCL,
                        "parsedContentRange": upstreamContentRange ?? "",
                        "parsedRangeStart": rangeStart,
                        "parsedRangeEnd": rangeEnd,
                        "parsedRangeTotal": rangeTotal,
                        "computedEndMinusStartPlus1": computed,
                        "matches": upstreamCL < 0 || computed < 0
                            || upstreamCL == computed
                    ])
        }
        diagLog(.playback,
                "LocalHLSProxyServer upstream response",
                details: [
                    "conn": connID,
                    "mode": mode,
                    "status": http.statusCode,
                    "downstreamStatus": status,
                    "contentLength": contentLength ?? -1,
                    "contentRange": upstreamContentRange ?? "",
                    "mimeType": http.mimeType ?? "",
                    "host": upstream.host ?? ""
                ])
        server.sendHeader(
            connection: connection,
            status: status,
            contentType: http.mimeType
                ?? server.mimeType(for: upstream.pathExtension),
            contentLength: contentLength,
            extraHeaders: extraHeaders,
            connID: connID
        )
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // Track every byte that arrives from upstream, even
        // when the downstream is broken, so the retry path
        // can shift the Range header by however much we did
        // manage to pull before the connection died.  See
        // `shiftedRequest(startingAt:)`.
        bytesReceivedFromUpstream += Int64(data.count)
        // Once the loopback client (AVPlayer) goes away
        // (e.g. `VideoDetailView.onDisappear`), the
        // downstream socket is dead.  Stop feeding the
        // upstream pipe immediately — every extra `send`
        // is an `NWError 57 — Socket is not connected` log
        // line, and a 71 MB video with a few hundred
        // segments will spam the diagnostic log for several
        // seconds otherwise.
        if downstreamBroken { return }
        // First chunk arrives without a prior `didReceive
        // response` (which only fires for 2xx/206).  In that
        // case the upstream returned a 200 without explicit
        // length headers (B站 CDN sometimes does that for
        // /init), so we have to synthesise the header here.
        if !didSendHeader {
            // Defensive: the body-byte path already
            // bailed on `downstreamBroken` above, but if
            // the flag was flipped *after* we passed that
            // check (queue race), don't synthesise a 200
            // header for a socket that just died.
            if downstreamBroken { return }
            server?.sendHeader(
                connection: connection,
                status: 200,
                contentType: server?.mimeType(
                    for: upstream.pathExtension
                ) ?? "application/octet-stream",
                contentLength: nil,
                connID: connID
            )
            didSendHeader = true
        }
        if LocalHLSProxyServer.wireDumpEnabled {
            downstreamChunksSent += 1
            downstreamBytesSent += Int64(data.count)
            if downstreamChunksSent == 1 {
                diagLog(.network,
                        "LocalHLSProxyServer wire bytes",
                        details: [
                            "conn": connID,
                            "label": "DOWNSTREAM BODY FIRST CHUNK",
                            "chunkBytes": data.count,
                            "bytes": LocalHLSProxyServer.dumpWireBytes(
                                data,
                                label: "DOWNSTREAM BODY FIRST CHUNK"
                            )
                        ])
            }
        }
        server?.addStreamedBytes(data.count)
        sendGroup.enter()
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    // Mark the downstream as dead but do NOT
                    // cancel the connection here — doing so
                    // kills in-flight send completions before
                    // they can `leave()` the sendGroup, which
                    // leaves `finishWhenSendsDrain()` waiting
                    // forever for a drain that never completes
                    // and causes AVPlayer to see a truncated
                    // body (fewer bytes than Content-Length)
                    // leading to -19602 decode failures.
                    // Instead, mark broken + cancel the
                    // upstream task; `didCompleteWithError`
                    // with `NSURLErrorCancelled` will then
                    // arrive on the delegate queue, the
                    // existing branch handles it via
                    // `finishWhenSendsDrain()` which cancels
                    // the connection once all queued send
                    // completions have left the sendGroup.
                    diagLog(.network,
                            "LocalHLSProxyServer downstream send error",
                            details: [
                                "conn": self.connID,
                                "mode": self.mode,
                                "error": error.localizedDescription
                            ])
                    self.markDownstreamBroken(
                        reason: "send error: \(error.localizedDescription)"
                    )
                }
                self.sendGroup.leave()
            }
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            let nsError = error as NSError
            // 1. Cancellation we triggered from the 5xx
            //    short-circuit in `didReceive response`
            //    means "give up on this response and retry".
            //    The flag distinguishes that from a real
            //    cancellation (downstream dead, etc.).
            if cancelledForRetry {
                // scheduleRetry was already called from
                // didReceive response — nothing to do here.
                return
            }
            // 2. Cancellation triggered by `downstreamBroken`
            //    is expected when AVPlayer goes away
            //    mid-fetch; it is *not* a real upstream
            //    failure and must not be retried (the
            //    downstream is gone anyway).
            if nsError.code == NSURLErrorCancelled {
                finishWhenSendsDrain()
                return
            }
            // 3. Retryable transport-level failure with the
            //    downstream still alive.  Re-issue the
            //    request with a shifted Range header so
            //    AVPlayer sees one continuous byte stream.
            if isRetryable(nsError),
               upstreamAttempt < Self.maxRetries,
               !downstreamBroken {
                scheduleRetry(
                    reason: nsError.localizedDescription,
                    attempt: upstreamAttempt + 1
                )
                return
            }
            // 4. Non-retryable error or retries exhausted —
            //    surface it as the final upstream failure.
            diagLog(.network,
                    "Upstream segment error",
                    details: [
                        "conn": connID,
                        "mode": mode,
                        "attempts": upstreamAttempt + 1,
                        "error": nsError.localizedDescription
                    ])
            if !didSendHeader {
                server?.sendHeader(
                    connection: connection,
                    status: 502,
                    contentType: "application/json",
                    contentLength: nil,
                    connID: connID
                )
            }
        }
        logBodyTotalsIfNeeded()
        finishWhenSendsDrain()
    }

    /// Emit the diagnostic body-totals log line.  Only
    /// fires when `LocalHLSProxyServer.wireDumpEnabled`
    /// is on; gives us a single line per stream that
    /// cross-checks the bytes pushed to `connection.send`
    /// against the `Content-Length` promised in the
    /// header (the trap-2 mismatch check).
    private func logBodyTotalsIfNeeded() {
        guard LocalHLSProxyServer.wireDumpEnabled else { return }
        diagLog(.network,
                "LocalHLSProxyServer downstream body totals",
                details: [
                    "conn": connID,
                    "mode": mode,
                    "upstreamBytes": bytesReceivedFromUpstream,
                    "downstreamChunks": downstreamChunksSent,
                    "downstreamBytes": downstreamBytesSent,
                    "matches": bytesReceivedFromUpstream == downstreamBytesSent
                ])
    }

    private func finishWithError(reason: String) {
        diagLog(.network,
                "LocalHLSProxyServer stream failed",
                details: [
                    "conn": connID,
                    "mode": mode,
                    "reason": reason
                ])
        if !didSendHeader {
            server?.sendHeader(
                connection: connection,
                status: 502,
                contentType: "application/json",
                contentLength: nil,
                connID: connID
            )
        }
        logBodyTotalsIfNeeded()
        finishWhenSendsDrain()
    }

    private func finishWhenSendsDrain() {
        guard !didFinish else { return }
        didFinish = true
        unregisterRange()
        sendGroup.notify(queue: .global(qos: .utility)) { [weak self] in
            guard let self else { return }
            self.connection.cancel()
            self.session?.finishTasksAndInvalidate()
            self.server?.finishStream(id: self.id)
        }
    }
}

// MARK: - HTTP request parser

/// Minimal HTTP/1.1 request header parser.  We only need the
/// method, path, and headers — there is never a request body
/// for the endpoints we expose.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]

    static func parse(data: Data) -> HTTPRequest? {
        guard let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = str.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":") {
                let k = String(line[..<colon]).lowercased()
                let v = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        return HTTPRequest(
            method: parts[0],
            path: parts[1],
            headers: headers
        )
    }
}
