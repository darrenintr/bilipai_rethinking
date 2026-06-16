//
//  LocalHLSProxyServer.swift
//  BiliPaiNative
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
    private(set) var baseURL: URL?

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
        lock.unlock()

        // Evict probe state from any previous playback — the
        // upstream URLs are per-video and the cached totals
        // would point at the wrong bytes if reused.
        resetMediaTotalProbes()

        // Kick off probes so the media playlists can be
        // multi-segment from the first request.  Probes run
        // on URLSession's background queue; `serve(playback:)`
        // returns immediately.
        let referer = playback.referer.absoluteString
        if let video = playback.dash?.video {
            startMediaTotalProbe(for: video, referer: referer)
        }
        if let audio = playback.dash?.audio {
            startMediaTotalProbe(for: audio, referer: referer)
        }

        if listener != nil { return }

        // Port 0 = let the OS pick.  We only have one server
        // per process, so collisions are not a concern.
        let params = NWParameters.tcp
        // `allowLocalEndpointReuse` lets the OS hand us a port
        // even if a recently-closed connection is in
        // TIME_WAIT.  Makes tear-down + restart snappy in
        // dev loops.
        params.allowLocalEndpointReuse = true
        // Bind to 127.0.0.1 only — no other device on the LAN
        // can reach this port.  iOS 14+ still asks the user
        // for `NSLocalNetworkUsageDescription` even for
        // loopback, so make sure the Info.plist declares a
        // reason.
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
                    self.port = p.rawValue
                    self.baseURL = URL(
                        string: "http://127.0.0.1:\(p.rawValue)"
                    )
                    diagLog(.playback, "LocalHLSProxyServer ready",
                            details: ["port": p.rawValue])
                }
            case .failed(let error):
                diagLog(.playback, "LocalHLSProxyServer failed",
                        details: ["error": error.localizedDescription])
            case .cancelled:
                self.port = 0
                self.baseURL = nil
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }
        listener.start(queue: queue)
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
        lock.unlock()
        diagLog(.playback, "LocalHLSProxyServer stopped")
    }

    // MARK: internals

    private let queue = DispatchQueue(label: "BiliPai.LocalHLSProxy")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var currentPlayback: BiliPlayback?
    private var activeStreams: [UUID: StreamingProxyTask] = [:]
    /// Tracks in-flight upstream byte ranges so we can detect and
    /// resolve overlaps when AVPlayer issues concurrent sub-segment
    /// requests (e.g., two overlapping `/media` ranges for the same
    /// CDN URL).  Key is the upstream URL string, value is the range
    /// start/end plus the stream ID holding that range.
    private var inFlightRanges: [String: (start: Int64, end: Int64, streamID: UUID)] = [:]

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

    /// Build a multi-segment HLS playlist with `EXT-X-BYTERANGE`.
    /// Returns `nil` if the inputs don't yield at least one
    /// segment (caller falls back to single-segment).
    ///
    /// `mediaTotalBytes` is the upstream total file size, and
    /// `mediaStartOffset` is the first byte of the playable
    /// media section (typically right after the init segment).
    /// We divide the playable range evenly in time, with the
    /// last segment absorbing any remainder.
    fileprivate static func buildMultiSegmentPlaylist(
        mediaTotalBytes: Int64,
        mediaStartOffset: Int64,
        totalDuration: Double,
        segmentURL: (Int64, Int64) -> String,
        initURL: String
    ) -> [String]? {
        guard mediaTotalBytes > mediaStartOffset,
              totalDuration > 0 else {
            return nil
        }
        let mediaBytes = mediaTotalBytes - mediaStartOffset
        let segmentCount = max(
            1,
            Int((totalDuration / targetSegmentDuration).rounded(.up))
        )
        let bytesPerSegment = max(
            1,
            Int64((Double(mediaBytes) / Double(segmentCount)).rounded())
        )
        let baseSegmentDuration = totalDuration / Double(segmentCount)
        let targetDurationSeconds = max(
            1,
            Int(baseSegmentDuration.rounded(.up))
        )
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-TARGETDURATION:\(targetDurationSeconds)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-MAP:URI=\"\(initURL)\"",
        ]
        for i in 0..<segmentCount {
            let relStart = Int64(i) * bytesPerSegment
            let isLast = (i == segmentCount - 1)
            let relEnd = isLast
                ? mediaBytes - 1
                : min(relStart + bytesPerSegment - 1, mediaBytes - 1)
            let duration = isLast
                ? totalDuration - baseSegmentDuration * Double(segmentCount - 1)
                : baseSegmentDuration
            lines.append("#EXTINF:\(String(format: "%.3f", duration)),")
            lines.append("#EXT-X-BYTERANGE:\(relEnd - relStart + 1)@\(relStart)")
            lines.append(segmentURL(relStart, relEnd))
        }
        lines.append("#EXT-X-ENDLIST")
        return lines
    }

    private init() {}

    // MARK: diagnostic helpers

    /// Toggle for the raw-wire diagnostic dump in
    /// `dumpWireBytes`.  We leave this on while diagnosing the
    /// scrubber-seek-to-unbuffered bug; once the wire-level
    /// root cause is identified and fixed, flip it to `false`
    /// so the log isn't drowned in 500-byte byte dumps on
    /// every segment.
    fileprivate static let wireDumpEnabled = true

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
            proxySegment(req: req, connection: connection, mode: .initRange,
                         connID: connID)
        case "/media":
            proxySegment(req: req, connection: connection, mode: .mediaRange,
                         connID: connID)
        default:
            if pathOnly.hasPrefix("/seg") {
                proxySegment(req: req, connection: connection, mode: .passthrough,
                             connID: connID)
            } else {
                respondError(connection: connection, status: 404,
                             reason: "no route", connID: connID)
            }
        }
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
              baseURL != nil else {
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
              baseURL != nil else {
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
        let encoded = base64urlEncode(track.baseURL.absoluteString)
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

        // Multi-segment playlist.  We block (on the listener
        // queue) for the upstream total-bytes probe; without it
        // we can't compute how many `EXT-X-BYTERANGE` chunks to
        // emit.  See `awaitMediaTotalProbe` for why this is
        // safe to block here.
        let probedTotal = awaitMediaTotalProbe(
            for: track.baseURL, timeoutSeconds: 5.0
        )
        if let probedTotal, probedTotal > track.mediaStartOffset {
            let segmentURL: (Int64, Int64) -> String = { relStart, relEnd in
                self.localURL(
                    path: "media",
                    queryItems: [
                        URLQueryItem(name: "u", value: encoded),
                        URLQueryItem(
                            name: "from",
                            value: "\(track.mediaStartOffset + relStart)"
                        ),
                        URLQueryItem(
                            name: "to",
                            value: "\(track.mediaStartOffset + relEnd)"
                        ),
                    ]
                )
            }
            if let lines = Self.buildMultiSegmentPlaylist(
                mediaTotalBytes: probedTotal,
                mediaStartOffset: track.mediaStartOffset,
                totalDuration: total,
                segmentURL: segmentURL,
                initURL: initURL
            ) {
                diagLog(.playback,
                        "LocalHLSProxyServer multi-segment playlist",
                        details: [
                            "conn": connID,
                            "kind": kind == .video ? "video" : "audio",
                            "mediaTotalBytes": probedTotal,
                            "mediaStartOffset": track.mediaStartOffset,
                            "duration": total,
                            "segmentCount": lines.filter {
                                $0.hasPrefix("#EXTINF:")
                            }.count
                        ])
                respondText(connection: connection, connID: connID,
                            body: lines.joined(separator: "\n"))
                return
            }
        }

        // Fallback: single-segment playlist.  Used when the
        // probe hasn't completed (or failed).  AVPlayer
        // treats the whole video as one segment in this case,
        // which is the legacy behaviour — works for normal
        // playback but loses the ability to scrub past the
        // buffer.
        diagLog(.playback,
                "LocalHLSProxyServer single-segment playlist fallback",
                details: [
                    "conn": connID,
                    "kind": kind == .video ? "video" : "audio",
                    "probedTotal": probedTotal ?? -1,
                    "mediaStartOffset": track.mediaStartOffset
                ])
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

    private enum ProxyMode {
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

        // Detect overlapping in-flight requests for the same
        // upstream URL.  AVPlayer can issue concurrent sub-segment
        // requests that partially overlap (e.g., one task fetching
        // bytes 0-500000 while a second fetches 200000-700000).
        // Allowing both to run results in double-delivery of the
        // overlap bytes, which causes CoreMedia to emit
        // `-19602` decode errors.  We resolve this by cancelling
        // any stream whose byte range intersects the new request.
        let upstreamKey = upstream.absoluteString
        let reqStart: Int64?
        let reqEnd: Int64?
        switch mode {
        case .mediaRange:
            // start was already parsed above; end is optional
            reqStart = params["from"].flatMap { Int64($0) }
            reqEnd = params["to"].flatMap { Int64($0) }
        case .initRange:
            if let r = parseByteRange(params["range"]) {
                reqStart = r.offset
                reqEnd = r.endOffset
            } else {
                reqStart = nil
                reqEnd = nil
            }
        case .passthrough:
            reqStart = nil
            reqEnd = nil
        }
        if let rs = reqStart, let re = reqEnd {
            lock.lock()
            if let existing = inFlightRanges[upstreamKey],
               rs <= existing.end, re >= existing.start {
                // Overlap found — cancel the older stream so it
                // does not deliver competing bytes into the same
                // socket.  The new request will pick up from where
                // the cancelled one left off (upstream handles this
                // via Range header).
                if let existingStream = activeStreams[existing.streamID] {
                    diagLog(.network,
                            "LocalHLSProxyServer cancelling overlapping stream",
                            details: [
                                "conn": connID,
                                "mode": mode.logName,
                                "overlappingConn": existing.connID,
                                "existingRange": "\(existing.start)-\(existing.end)",
                                "newRange": "\(rs)-\(re)"
                            ])
                    existingStream.cancel()
                }
                inFlightRanges.removeValue(forKey: upstreamKey)
            }
            lock.unlock()
        }

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
        if let absoluteTotal = Int64(rangeAndTotal[1]) {
            totalPart = "\(max(absoluteTotal - offset, 0))"
        } else {
            totalPart = String(rangeAndTotal[1])
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
           existing.streamID == id {
            server?.inFlightRanges.removeValue(forKey: key)
        }
        server?.lock.unlock()
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
        let isLogicalSubResource = (mode == "init" || mode == "media")
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
        } else if isLogicalSubResource {
            // No client Range, but the URL is a logical
            // sub-resource (`/init` or `/media`).  Expose it
            // as a flat document: 200 OK, `Content-Length` set
            // to the sub-resource length, no `Content-Range`.
            status = 200
        } else {
            // `/seg` passthrough with no client Range — forward
            // the upstream's status (typically 200).
            status = http.statusCode
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
                    self.downstreamBroken = true
                    diagLog(.network,
                            "LocalHLSProxyServer downstream send error",
                            details: [
                                "conn": self.connID,
                                "mode": self.mode,
                                "error": error.localizedDescription
                            ])
                    // Cancel the upstream task and the
                    // loopback connection in the same tick
                    // — do not wait for `sendGroup.notify`,
                    // because more `didReceive data` calls
                    // are already queued behind us.
                    self.task?.cancel()
                    self.connection.cancel()
                    self.session?.finishTasksAndInvalidate()
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
