//
//  BiliResourceLoaderDelegate.swift
//  BiliPaiNative
//
//  Bilibili DASH → HLS bridge, served through AVAssetResourceLoaderDelegate.
//
//  Why this exists
//  ---------------
//  Bilibili increasingly returns DASH manifests (`.mpd` / `dash.video`)
//  for higher-quality sources (1080P+, 4K, 大会员, 杜比) and
//  sometimes nothing else. `AVPlayer` cannot play DASH natively, so
//  forking out a third-party SDK (Aliyun) just to reach a format the
//  CDN does not actually return is over-engineered.
//
//  This file converts Bili's DASH into an HLS m3u8 *manifest only*
//  and proxies the underlying fMP4 segments byte-for-byte from the
//  CDN.  The CDN only checks `Referer`; that is what we inject.
//
//  Architecture
//  ------------
//
//       AVPlayer
//          │  GET bili-hls://…/master.m3u8
//          ▼
//   BiliDashToHLSBridge.shouldWaitForLoadingOfRequestedResource
//          │   ├─  master.m3u8  → synthesise HLS master in memory
//          │   └─  *.m4s        → URLSession.fetch(realURL) + Referer
//          ▼
//       Data → respondWithData → AVPlayer
//
//  Notes
//  -----
//  * No local HTTP server is started. The "local" feeling is just the
//    `bili-hls://` custom scheme; the bridge is a class method on
//    AVAssetResourceLoader, not a socket.
//  * No `NSLocalNetworkUsageDescription` permission prompt is needed.
//  * `Referer` is set on a `URLSession` shared with the
//    `Referer`-aware config so every segment sub-request goes out
//    with the right header.  The synthesized m3u8 itself is built
//    from in-memory data, so it does not need any header.
//  * fMP4 segments are passed through unchanged — we never touch
//    the encoded bytes. AVPlayer consumes fMP4 as a first-class
//    HLS segment type since iOS 11, so this works for the modern
//    codec flavours Bili ships (avc1, hvc1).
//  * Audio and video are split into two HLS media playlists with a
//    shared `EXT-X-MEDIA:TYPE=AUDIO` group — the same pattern the
//    stock HLS interleave uses.
//

import AVFoundation
import Foundation

// MARK: - public descriptor

/// `BiliDashSource` is the DASH description we need to synthesise
/// an HLS master playlist.  We extract it from the playurl JSON
/// response in `BilibiliAPIClient.bestPlayback()` and hand it
/// to `AVPlayer` via `AVURLAsset.biliDash(...)`.
///
/// Important: Bilibili's `dash.video[].baseUrl` and
/// `dash.audio[].baseUrl` are each *one whole m4s file* (Bili
/// does not publish a per-segment `SegmentTemplate` here).  The
/// m3u8 generator therefore emits a media playlist with a
/// single `EXTINF` entry whose duration is the track's
/// `totalDuration`, and lets AVPlayer stream the file via
/// HTTP `Range` requests through the resource loader.
struct BiliDashSource: Hashable {
    /// A single AdaptationSet, plus its Representation.
    /// We flatten audio + video variants into this struct
    /// because BiliBili's DASH responses are simple enough
    /// that we can skip the full MPD Period/AdaptationSet
    /// tree.
    struct Track: Hashable {
        let baseURL: URL
        /// ISO BMFF `codecs` box string (e.g. `avc1.640028`,
        /// `mp4a.40.2`).  Embedded into HLS via `CODECS`.
        let codecs: String
        /// Bandwidth in bits per second (Bili's `bandwidth`
        /// field).  Used in the master playlist's
        /// `EXT-X-STREAM-INF` `BANDWIDTH` attribute.
        let bandwidth: Int
        /// `mimeType` from the Representation, e.g.
        /// `video/mp4` / `audio/mp4`.
        let mimeType: String
        /// Total presentation duration in seconds — Bili's
        /// `dash.duration` divided by 1000 (Bili publishes
        /// milliseconds here).
        let totalDuration: Double
    }

    let video: Track
    let audio: Track?
}

// MARK: - scheme bridge

private let kBiliHLSScheme = "bili-hls"

private extension URL {
    /// Reverse of `BiliURL.bili()` — translate a `bili-hls://…`
    /// URL back into the real `https://…` form.  We pack the
    /// entire `https` URL into the path of the wrapper URL so
    /// the round trip is a 1:1 substring replacement.
    func realURL() -> URL? {
        guard self.scheme == kBiliHLSScheme else { return nil }
        let raw = self.absoluteString
        let prefix = "\(kBiliHLSScheme):///"
        guard raw.hasPrefix(prefix) else { return nil }
        let httpsForm = "https://" + raw.dropFirst(prefix.count)
        return URL(string: httpsForm)
    }
}

enum BiliURL {
    /// Wrap a real `https://…` URL into the `bili-hls://…` form
    /// the resource loader recognises.  Path-only — the host
    /// stays empty.
    static func bili(_ https: URL) -> URL? {
        let raw = https.absoluteString
        let payload = raw.dropFirst("https://".count)
        return URL(string: "\(kBiliHLSScheme):///\(payload)")
    }
}

// MARK: - the bridge

/// One instance per `AVPlayerItem`.  Stays alive as long as the
/// asset it is registered against, via the `objc_setAssociatedObject`
/// in `AVURLAsset.biliDash(...)`.
final class BiliDashToHLSBridge: NSObject, AVAssetResourceLoaderDelegate {

    /// What the master `bili-hls://…/master.m3u8` URL looks like
    /// from the player's side.  Any path ending in `master.m3u8`
    /// is treated as a request for the synthesised HLS manifest.
    private static let masterPath = "/__bili_master.m3u8"
    private static let videoPath  = "/__bili_video.m3u8"
    private static let audioPath  = "/__bili_audio.m3u8"

    private let source: BiliDashSource
    private let referer: String

    /// `URLSession` shared by all segment sub-requests.  Headers
    /// are baked into the configuration so a `Referer` or
    /// `User-Agent` is never accidentally dropped.
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = [
            "Referer": referer,
            "User-Agent":
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                + "Version/18.0 Mobile/15E148 Safari/604.1"
        ]
        // Keep a single TCP/TLS session alive across the master
        // m3u8 and the segments.
        cfg.httpShouldUsePipelining = true
        return URLSession(configuration: cfg)
    }() as URLSession

    /// In-flight bookkeeping.  Cancel a `URLSessionDataTask` when
    /// AVPlayer aborts a request — skipping past a segment does
    /// not need to drain the rest of it.
    private var inFlight: [URL: URLSessionDataTask] = [:]
    private let inFlightLock = NSLock()

    /// Total bytes pulled from the CDN since this bridge was
    /// created.  Sampled by `PlayerController.refresh()` to
    /// surface a network-speed readout on the loading overlay.
    private var byteCountValue: Int64 = 0
    private let byteCountLock = NSLock()

    /// Bytes received from CDN.  Read by the controller's
    /// polling timer; reset is up to the controller (it
    /// computes deltas and never asks for a "since the
    /// beginning" reading).
    func byteCount() -> Int64 {
        byteCountLock.lock()
        defer { byteCountLock.unlock() }
        return byteCountValue
    }

    init(source: BiliDashSource, referer: String) {
        self.source = source
        self.referer = referer
    }

    deinit {
        inFlightLock.lock()
        let tasks = Array(inFlight.values)
        inFlight.removeAll()
        inFlightLock.unlock()
        tasks.forEach { $0.cancel() }
        session.invalidateAndCancel()
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest:
            AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let bridged = loadingRequest.request.url,
              bridged.scheme == kBiliHLSScheme
        else {
            loadingRequest.finishLoading(with: NSError(
                domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL
            ))
            return false
        }

        // Synthesised m3u8 paths
        if bridged.path == Self.masterPath {
            respond(withSynthesised: masterPlaylist(),
                    loadingRequest: loadingRequest,
                    contentType: "application/vnd.apple.mpegurl")
            return true
        }
        if bridged.path == Self.videoPath {
            respond(withSynthesised: mediaPlaylist(for: source.video),
                    loadingRequest: loadingRequest,
                    contentType: "application/vnd.apple.mpegurl")
            return true
        }
        if bridged.path == Self.audioPath,
           let audio = source.audio {
            respond(withSynthesised: mediaPlaylist(for: audio),
                    loadingRequest: loadingRequest,
                    contentType: "application/vnd.apple.mpegurl")
            return true
        }

        // Anything else: treat as a real CDN segment, proxy
        // through URLSession with the right headers.
        guard let real = bridged.realURL() else {
            loadingRequest.finishLoading(with: NSError(
                domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL
            ))
            return false
        }
        startSegmentRequest(real: real, loadingRequest: loadingRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let url = loadingRequest.request.url else { return }
        inFlightLock.lock()
        let task = inFlight.removeValue(forKey: url)
        inFlightLock.unlock()
        task?.cancel()
    }

    // MARK: synthesised m3u8

    private func masterPlaylist() -> Data {
        let total = max(source.duration, 0.1)
        let videoBandwidth = source.video.bandwidth
        let totalBandwidth =
            videoBandwidth + (source.audio?.bandwidth ?? 0)

        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]

        if let audio = source.audio {
            lines.append(
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aac\",NAME=\"default\","
                + "DEFAULT=YES,AUTOSELECT=YES,"
                + "URI=\"\(Self.audioPath)\""
            )
            _ = audio  // (suppress unused warning; codecs embedded
                       //   in the media playlist below)
        }

        var streamInf = "#EXT-X-STREAM-INF:"
        streamInf += "BANDWIDTH=\(totalBandwidth)"
        streamInf += ",CODECS=\"\(source.video.codecs)"
        if let audio = source.audio {
            streamInf += "," + audio.codecs
        }
        streamInf += "\",RESOLUTION=1920x1080"   // best-effort; Bili
                                                 // does not always
                                                 // expose the size in
                                                 // the playurl JSON.
                                                 // AVPlayer ignores
                                                 // an inaccurate
                                                 // RESOLUTION.
        streamInf += ",AUDIO=\"aac\""
        lines.append(streamInf)
        lines.append(Self.videoPath)
        lines.append("")

        //  `total` is informational only — the AVPlayer derives
        //  duration from the media playlist.  We just need a
        //  non-zero value for the master to be valid; AVPlayer
        //  will read the actual duration from the first media
        //  playlist's #EXTINF sum.
        _ = total

        return lines.joined(separator: "\n")
            .data(using: .utf8) ?? Data()
    }

    private func mediaPlaylist(for track: BiliDashSource.Track) -> Data {
        // Bilibili DASH convention
        // ------------------------
        // Each track's `baseURL` is a *single* m4s file hosted
        // on the upos CDN.  There is no `SegmentTemplate`
        // multi-segment publishing — `dash.video[].baseUrl`
        // and `dash.audio[].baseUrl` are each one whole file,
        // and clients stream the file using the HTTP `Range`
        // header.  We surface this as an HLS media playlist
        // with a single `EXTINF` entry whose duration is the
        // total media length in seconds.
        //
        // The duration field in `EXTINF` is what AVPlayer
        // uses to compute the total playable length of the
        // playlist, so getting this number right is what
        // makes the scrubber and the `AVPlayerItem.duration`
        // accurate.
        //
        // `EXT-X-TARGETDURATION` is the longest single
        // segment in the playlist — for a single-file
        // playlist, that is exactly the file's duration.
        // We round up because the spec requires
        // TARGETDURATION >= the largest EXTINF.
        let total = max(track.totalDuration, 0.1)
        let target = Int(total.rounded(.up))
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:0",
        ]

        let wrapped = BiliURL.bili(track.baseURL) ?? track.baseURL
        lines.append("#EXTINF:\(String(format: "%.3f", total)),")
        lines.append(wrapped.absoluteString)
        lines.append("#EXT-X-ENDLIST")
        lines.append("")
        return lines.joined(separator: "\n")
            .data(using: .utf8) ?? Data()
    }

    private func respond(
        withSynthesised data: Data,
        loadingRequest: AVAssetResourceLoadingRequest,
        contentType: String
    ) {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }

    // MARK: segment proxy

    private func startSegmentRequest(
        real: URL,
        loadingRequest: AVAssetResourceLoadingRequest
    ) {
        var request = URLRequest(url: real)
        if let data = loadingRequest.dataRequest,
           !data.requestsAllDataToEndOfResource {
            let start = data.requestedOffset
            let end = start + Int64(data.requestedLength) - 1
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(
            with: request
        ) { [weak self, weak loadingRequest] body, response, error in
            guard let self else { return }
            guard let loadingRequest else { return }
            if let error = error {
                loadingRequest.finishLoading(with: error)
                self.removeInFlight(real)
                return
            }
            guard
                let response = response as? HTTPURLResponse,
                let body = body
            else {
                loadingRequest.finishLoading(with: NSError(
                    domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse
                ))
                self.removeInFlight(real)
                return
            }

            if let info = loadingRequest.contentInformationRequest {
                info.contentType = response.mimeType
                    ?? Self.mimeType(for: real.pathExtension)
                info.isByteRangeAccessSupported = true
                if let total = response.expectedContentLength, total > 0 {
                    info.contentLength = total
                }
            }
            loadingRequest.dataRequest?.respond(with: body)
            loadingRequest.finishLoading()
            self.removeInFlight(real)

            // Track bytes for the loading-overlay's KB/s
            // readout.  The polling timer in
            // `AVPlayerController.refresh()` samples this.
            self.byteCountLock.lock()
            self.byteCountValue += Int64(body.count)
            self.byteCountLock.unlock()
        }
        addInFlight(real, task: task)
        task.resume()
    }

    private func addInFlight(_ url: URL, task: URLSessionDataTask) {
        inFlightLock.lock(); inFlight[url] = task; inFlightLock.unlock()
    }
    private func removeInFlight(_ url: URL) {
        inFlightLock.lock(); inFlight.removeValue(forKey: url); inFlightLock.unlock()
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "m3u8":               return "application/vnd.apple.mpegurl"
        case "m4s", "mp4", "mov":  return "video/mp4"
        case "aac":                return "audio/aac"
        case "ts":                 return "video/mp2t"
        default:                   return "application/octet-stream"
        }
    }
}

// MARK: - asset association

private var kBridgeKey: UInt8 = 0

extension AVURLAsset {
    /// Build an `AVURLAsset` whose root URL is the synthesised
    /// `bili-hls://…/playlist.m3u8` and pin a
    /// `BiliDashToHLSBridge` to its resource loader for the
    /// lifetime of the asset.
    ///
    /// Host choice
    /// -----------
    /// The host portion of the root URL is purely cosmetic —
    /// every sub-request (master, video, audio) goes through
    /// the custom `bili-hls` scheme and is intercepted by the
    /// resource loader.  We use a recognisable Bili CDN
    /// hostname (rather than `example.com` or empty) for two
    /// reasons:
    ///
    /// 1. Diagnostic logs and AVFoundation's own warnings
    ///    mention the host; an "example.com" reading looks
    ///    like a misconfiguration and would get eyeballed
    ///    unnecessarily on every test run.
    /// 2. AVPlayer is more lenient with custom schemes whose
    ///    host looks like a real CDN.  An empty host can
    ///    occasionally trip the parser's relative-URL
    ///    resolution when the master playlist refers to its
    ///    child playlists by path-only URI.
    static func biliDash(
        source: BiliDashSource,
        referer: String
    ) -> AVURLAsset? {
        // A representative upos hostname.  AVPlayer never
        // resolves this — every request is intercepted by the
        // bridge — but having a non-empty host keeps the URL
        // parser happy.
        let masterURL = URL(string:
            "\(kBiliHLSScheme)://upos-sz-mirrorhw.bilivideo.com"
            + BiliDashToHLSBridge.masterPath
        )!
        let asset = AVURLAsset(url: masterURL)
        let bridge = BiliDashToHLSBridge(source: source, referer: referer)
        asset.resourceLoader.setDelegate(bridge, queue: .main)
        // Strong-retain the bridge on the asset.  Without this,
        // ARC releases it when this function returns and the
        // URLSession closure dangles.
        objc_setAssociatedObject(
            asset, &kBridgeKey, bridge,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return asset
    }
}
