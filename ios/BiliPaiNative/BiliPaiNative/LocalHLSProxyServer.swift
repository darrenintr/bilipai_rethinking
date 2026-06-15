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

    private init() {}

    // MARK: connection handling

    private func accept(connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection: connection, accumulated: Data())
    }

    /// Read the request header bytes in chunks until we see
    /// CRLFCRLF.  AVPlayer sends headers of a few hundred
    /// bytes; one read is usually enough.
    private func receiveHeader(
        connection: NWConnection,
        accumulated: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let error = error {
                diagLog(.network,
                        "LocalHLSProxyServer receive error",
                        details: ["error": error.localizedDescription])
                connection.cancel()
                return
            }
            var buf = accumulated
            if let data = data { buf.append(data) }
            // End-of-headers marker.
            if buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil {
                self.route(requestBytes: buf, connection: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receiveHeader(connection: connection, accumulated: buf)
        }
    }

    /// Route a complete request to the right handler.
    private func route(requestBytes: Data, connection: NWConnection) {
        guard let req = HTTPRequest.parse(data: requestBytes) else {
            respondError(connection: connection, status: 400,
                         reason: "bad request")
            return
        }
        let pathOnly = req.path.split(separator: "?", maxSplits: 1)
            .first.map(String.init) ?? req.path
        switch pathOnly {
        case "/playlist.m3u8":
            respondMasterPlaylist(connection: connection)
        case "/video.m3u8":
            respondMediaPlaylist(for: .video, connection: connection)
        case "/audio.m3u8":
            respondMediaPlaylist(for: .audio, connection: connection)
        case "/init":
            proxySegment(req: req, connection: connection, mode: .initRange)
        case "/media":
            proxySegment(req: req, connection: connection, mode: .mediaRange)
        default:
            if pathOnly.hasPrefix("/seg") {
                proxySegment(req: req, connection: connection, mode: .passthrough)
            } else {
                respondError(connection: connection, status: 404,
                             reason: "no route")
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

    private func respondMasterPlaylist(connection: NWConnection) {
        guard let (source, _) = snapshot(),
              baseURL != nil else {
            respondError(connection: connection, status: 503,
                         reason: "no playback")
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
        respondText(connection: connection,
                    body: lines.joined(separator: "\n"))
    }

    private func respondMediaPlaylist(
        for kind: MediaKind,
        connection: NWConnection
    ) {
        guard let (source, _) = snapshot(),
              baseURL != nil else {
            respondError(connection: connection, status: 503,
                         reason: "no playback")
            return
        }
        let track: BiliDashSource.Track?
        switch kind {
        case .video: track = source.video
        case .audio: track = source.audio
        }
        guard let track = track else {
            respondError(connection: connection, status: 404,
                         reason: "no track")
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
        respondText(connection: connection,
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
        mode: ProxyMode
    ) {
        guard let (source, referer) = snapshot() else {
            respondError(connection: connection, status: 503,
                         reason: "no playback")
            return
        }
        let query = req.path.split(separator: "?", maxSplits: 1)
            .last.map(String.init) ?? ""
        let params = parseQuery(query)
        guard let encoded = params["u"],
              let upstreamString = base64urlDecode(encoded),
              let upstream = URL(string: upstreamString) else {
            respondError(connection: connection, status: 400,
                         reason: "missing u")
            return
        }
        // Refuse to proxy anything other than the B站 CDN
        // (or localhost, in dev).  This is a defence-in-depth
        // check; the segment URL is generated by us, so it
        // should always be a B站 URL anyway.
        guard let host = upstream.host,
              isAllowedUpstreamHost(host) else {
            respondError(connection: connection, status: 400,
                         reason: "bad upstream host")
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
        var responseStatusOverride: Int?
        var contentRangeShift: Int64?
        var passContentRange = false
        switch mode {
        case .passthrough:
            // Forward Range if AVPlayer sent one (it does for
            // seeks).  B站 supports byte-range, so the forward is
            // safe.
            if let range = req.headers["range"] {
                upstreamReq.setValue(range, forHTTPHeaderField: "Range")
                passContentRange = true
            }
        case .initRange:
            guard let range = parseByteRange(params["range"]) else {
                respondError(connection: connection, status: 400,
                             reason: "missing init range")
                return
            }
            upstreamReq.setValue(
                httpRangeHeader(offset: range.offset, end: range.endOffset),
                forHTTPHeaderField: "Range"
            )
            // `/init` is a logical resource representing only
            // the init section, so the downstream response is a
            // normal 200 even though the upstream fetch uses
            // Range.
            responseStatusOverride = 200
        case .mediaRange:
            guard let startString = params["from"],
                  let start = Int64(startString) else {
                respondError(connection: connection, status: 400,
                             reason: "missing media range")
                return
            }
            if let range = req.headers["range"],
               let shifted = shiftedRangeHeader(range, by: start) {
                upstreamReq.setValue(shifted, forHTTPHeaderField: "Range")
                contentRangeShift = start
            } else {
                upstreamReq.setValue(
                    httpRangeHeader(offset: start, end: nil),
                    forHTTPHeaderField: "Range"
                )
                // `/media` is a logical resource beginning at
                // `start`; when AVPlayer asks for the whole
                // resource, return 200 with the shifted body.
                responseStatusOverride = 200
            }
        }
        _ = source  // Keep the playback snapshot alive while
                    // the URLSession request is queued.

        diagLog(.playback,
                "LocalHLSProxyServer upstream request",
                details: [
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
            statusOverride: responseStatusOverride,
            contentRangeShift: contentRangeShift,
            passContentRange: passContentRange
        )
        retain(stream: stream)
        stream.start()
    }

    // MARK: response helpers

    private func respondText(connection: NWConnection, body: String) {
        respondBytes(
            connection: connection,
            status: 200,
            contentType: "application/vnd.apple.mpegurl",
            body: Data(body.utf8)
        )
    }

    private func respondError(
        connection: NWConnection,
        status: Int,
        reason: String
    ) {
        let body = "{\"error\":\"\(reason)\"}"
        respondBytes(
            connection: connection,
            status: status,
            contentType: "application/json",
            body: Data(body.utf8)
        )
    }

    private func respondBytes(
        connection: NWConnection,
        status: Int,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) {
        var response = httpHeaderData(
            status: status,
            contentType: contentType,
            contentLength: Int64(body.count),
            extraHeaders: extraHeaders
        )
        response.append(body)
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
        extraHeaders: [String: String] = [:]
    ) {
        connection.send(
            content: httpHeaderData(
                status: status,
                contentType: contentType,
                contentLength: contentLength,
                extraHeaders: extraHeaders
            ),
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

    private func httpRangeHeader(offset: Int64, end: Int64?) -> String {
        if let end {
            return "bytes=\(offset)-\(end)"
        }
        return "bytes=\(offset)-"
    }

    private func shiftedRangeHeader(
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
            return httpRangeHeader(offset: absoluteStart, end: nil)
        }
        guard let relativeEnd = Int64(bounds[1]),
              relativeEnd >= relativeStart else {
            return nil
        }
        return httpRangeHeader(
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
    private let statusOverride: Int?
    private let contentRangeShift: Int64?
    private let passContentRange: Bool
    private let sendGroup = DispatchGroup()
    private let delegateQueue: OperationQueue

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var didSendHeader = false
    private var didFinish = false

    init(
        server: LocalHLSProxyServer,
        connection: NWConnection,
        upstream: URL,
        request: URLRequest,
        mode: String,
        statusOverride: Int?,
        contentRangeShift: Int64?,
        passContentRange: Bool
    ) {
        self.server = server
        self.connection = connection
        self.upstream = upstream
        self.request = request
        self.mode = mode
        self.statusOverride = statusOverride
        self.contentRangeShift = contentRangeShift
        self.passContentRange = passContentRange
        self.delegateQueue = OperationQueue()
        self.delegateQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
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
        didSendHeader = true
        var extraHeaders: [String: String] = [:]
        let upstreamContentRange = http.value(forHTTPHeaderField: "Content-Range")
        if let shift = contentRangeShift,
           let upstreamContentRange,
           let shifted = server.shiftedContentRange(
                upstreamContentRange,
                by: shift
           ) {
            extraHeaders["Content-Range"] = shifted
            extraHeaders["Accept-Ranges"] = "bytes"
        } else if passContentRange,
                  let upstreamContentRange {
            extraHeaders["Content-Range"] = upstreamContentRange
            extraHeaders["Accept-Ranges"] = "bytes"
        }
        let status = statusOverride ?? http.statusCode
        let contentLength = http.expectedContentLength >= 0
            ? http.expectedContentLength
            : nil
        diagLog(.playback,
                "LocalHLSProxyServer upstream response",
                details: [
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
            extraHeaders: extraHeaders
        )
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        if !didSendHeader {
            server?.sendHeader(
                connection: connection,
                status: 200,
                contentType: server?.mimeType(
                    for: upstream.pathExtension
                ) ?? "application/octet-stream",
                contentLength: nil
            )
            didSendHeader = true
        }
        server?.addStreamedBytes(data.count)
        sendGroup.enter()
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    diagLog(.network,
                            "LocalHLSProxyServer downstream send error",
                            details: [
                                "mode": self?.mode ?? "",
                                "error": error.localizedDescription
                            ])
                }
                self?.sendGroup.leave()
            }
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            diagLog(.network,
                    "Upstream segment error",
                    details: [
                        "mode": mode,
                        "error": error.localizedDescription
                    ])
            if !didSendHeader {
                server?.sendHeader(
                    connection: connection,
                    status: 502,
                    contentType: "application/json",
                    contentLength: nil
                )
            }
        }
        finishWhenSendsDrain()
    }

    private func finishWithError(reason: String) {
        diagLog(.network,
                "LocalHLSProxyServer stream failed",
                details: ["mode": mode, "reason": reason])
        if !didSendHeader {
            server?.sendHeader(
                connection: connection,
                status: 502,
                contentType: "application/json",
                contentLength: nil
            )
        }
        finishWhenSendsDrain()
    }

    private func finishWhenSendsDrain() {
        guard !didFinish else { return }
        didFinish = true
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
