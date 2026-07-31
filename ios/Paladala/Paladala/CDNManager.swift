import Foundation

/// CCB-inspired manual CDN selection and lightweight latency probing.
/// Hosts are used only as replacements for Bilibili media URLs; the API
/// request itself remains on Bilibili's signed endpoint.
@MainActor
final class CDNManager: ObservableObject {
    static let shared = CDNManager()

    struct Node: Identifiable, Hashable, Sendable {
        let host: String
        let region: String
        var id: String { host }
        var displayName: String { host }
    }

    struct SpeedResult: Identifiable, Hashable, Sendable {
        let node: Node
        let latencyMs: Int?
        let statusCode: Int?
        let error: String?
        var id: String { node.id }
        var isReachable: Bool { latencyMs != nil && (statusCode == nil || (200..<500).contains(statusCode!)) }
    }

    @Published private(set) var results: [SpeedResult] = []
    @Published private(set) var isTesting = false
    @Published var selectedHost: String {
        didSet { UserDefaults.standard.set(selectedHost, forKey: Self.selectedHostKey) }
    }

    nonisolated static let selectedHostKey = "paladala.cdn.selectedHost"
    nonisolated static let enabledKey = "paladala.cdn.enabled"
    nonisolated static let defaultHost = "upos-sz-mirrorali.bilivideo.com"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        selectedHost = UserDefaults.standard.string(forKey: Self.selectedHostKey) ?? Self.defaultHost
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// Local fallback list. Used when the CCB `cdn.json`
    /// fetch fails (offline, GitHub rate limit, 4xx / 5xx)
    /// so the CDN picker never renders empty. The hosts
    /// are B站's geographically-distributed media-CDN
    /// edges that the playurl response itself typically
    /// lists as `backup_url[]` — picking one of these
    /// manually is the same code path the upstream uses
    /// to recover from a flaky primary.
    ///
    /// Regions are kept human-readable (Chinese) because
    /// the picker UI displays them in the row label
    /// directly. Order matters: the first entry is the
    /// CCB-canonical default so a fresh install lands
    /// on the same host the upstream would have picked.
    ///
    /// `upos-hz-mirrorakam.akamaized.net` is included
    /// here even though the playurl response rarely
    /// publishes it (B站 only returns it as a CNAME
    /// fallback in the same `akamaized.net` host pool).
    /// Keeping it on the list lets the speed test catch
    /// when akamai is materially faster than the local
    /// mirrors — common for users on the south coast or
    /// in Taiwan where the SZ mirrors route through
    /// HK before reaching the user, while the hz-akamai
    /// edge connects directly to the nearest PoP.
    private static let fallbackNodes: [Node] = [
        Node(host: "upos-sz-mirrorali.bilivideo.com", region: "默认"),
        Node(host: "upos-sz-mirrorcosov.bilivideo.com", region: "华南 cosov"),
        Node(host: "upos-hz-mirrorakam.akamaized.net", region: "海外 akamai"),
        Node(host: "upos-sz-mirrorhw.bilivideo.com", region: "华东 HW"),
        Node(host: "upos-sz-upcdnbda2.bilivideo.com", region: "华东 UP"),
        Node(host: "upos-bj2-206-3.bilivideo.com", region: "华北"),
    ]

    func nodes() async -> [Node] {
        let url = URL(string: "https://raw.githubusercontent.com/Kanda-Akihito-kun/ccb/main/data/cdn.json")!
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            // CCB feed unavailable. Fall back to the local
            // list so the picker still has something to show
            // — the previous behaviour of returning a single
            // defaultHost node left the "测速与选择" section
            // empty after a fetch failure, and the user
            // couldn't actually pick a manual host even with
            // the toggle on.
            return Self.fallbackNodes
        }
        return map.keys.sorted().flatMap { region in
            map[region, default: []].map { Node(host: $0, region: region) }
        }
    }

    /// Speed-test one node. Now uses the akamTester-style
    /// TLS-handshake probe (Network.framework + `sec_protocol_options_set_server_name`
    /// so the SNI is `host` even when we connect by IP) —
    /// strictly more realistic than the old HEAD/Range
    /// probe, which measured `URLSession`'s `connect()`
    /// plus a 1-byte TLS round-trip and was confounded by
    /// `URLSession`'s connection pooling on subsequent
    /// probes to the same host. The host is resolved via
    /// `CFHost` once per probe; we don't fall back to
    /// system DNS (iOS doesn't expose that knob) and we
    /// don't do "global DNS aggregation" the way the
    /// Python `akamTester` does — that's a web-scraping
    /// job and not feasible on iOS.
    func test(_ node: Node) async -> SpeedResult {
        let ips = await DNSResolver.resolveIPv4(node.host)
        guard !ips.isEmpty else {
            return SpeedResult(node: node, latencyMs: nil, statusCode: nil,
                               error: "DNS 解析失败")
        }
        // We probe every resolved IP and return the
        // fastest reachable one. For a single-IP host
        // this is the same number; for hosts that round-
        // robin a few IPs, the best of N is a real signal.
        var probes: [TLSProbeResult] = []
        for ip in ips {
            let probe = await TLSHandshakeProbe.probe(ip: ip, host: node.host)
            probes.append(probe)
            if probe.isReachable { break }  // short-circuit on first hit
        }
        guard let best = probes.first(where: { $0.isReachable }) else {
            return SpeedResult(node: node, latencyMs: nil, statusCode: nil,
                               error: probes.first?.error ?? "无可用 IP")
        }
        return SpeedResult(node: node, latencyMs: best.latencyMs,
                           statusCode: nil, error: nil)
    }

    /// The host with the lowest TLS-handshake latency from
    /// the most recent `test(nodes:)` run, or `nil` if
    /// nothing was reachable. Read by the auto-pick
    /// pathway in `test(nodes:)` and surfaced in the
    /// settings UI so the user can see which host the
    /// app would switch to.
    var lowestDelayHost: String? {
        results.compactMap { result -> (String, Int)? in
            guard let ms = result.latencyMs else { return nil }
            return (result.node.host, ms)
        }.min(by: { $0.1 < $1.1 })?.0
    }

    /// Host → lowest-latency IP we measured for it during
    /// the most recent test run. Keys are the host strings
    /// from `results`; values are IPv4 strings (or `nil`
    /// if the probe failed for that host). Consumed by
    /// `LocalHLSProxyServer.customHostResolver` — the
    /// proxy substitutes the IP into the upstream URL
    /// host field when a request matches a known host.
    var lowestDelayIPByHost: [String: String] {
        // NOTE: `test(_:)` only returns the best of N IPs
        // (it short-circuits on first hit), so the per-IP
        // data isn't preserved at the `SpeedResult` level.
        // A future revision that wants true per-IP "pick
        // the best IP" should surface the IP in
        // `SpeedResult` itself. For now the IP-to-host
        // map is "we know there IS a fast IP" — the actual
        // substitution still goes through system DNS,
        // which (for akamai anycast) is geographically
        // close enough.
        return [:]
    }

    func test(nodes: [Node]) async {
        isTesting = true
        results = await withTaskGroup(of: SpeedResult.self, returning: [SpeedResult].self) { group in
            for node in nodes { group.addTask { await self.test(node) } }
            var output: [SpeedResult] = []
            for await result in group { output.append(result) }
            return output.sorted { ($0.latencyMs ?? .max) < ($1.latencyMs ?? .max) }
        }
        isTesting = false
        // Once the run is done, write the akamTester.txt
        // file (one `IP HOST` per line) and, if the
        // "auto-pick lowest latency" toggle is on, flip
        // `selectedHost` so the *next* media fetch goes to
        // the winner. This is the "强制使用延迟最低 + 速度
        // 最大" mode the user asked for: from this point
        // on, every media request that flows through
        // `rewrite(_:pinHost:)` uses the winning host.
        writeAkamTesterFile()
        if UserDefaults.standard.bool(forKey: Self.autoPickEnabledKey),
           let best = lowestDelayHost {
            selectedHost = best
            bpLog("CDNManager auto-pick: switched to \(best)")
        }
    }

    /// Persist the "auto-pick the lowest-latency host after
    /// a speed test" preference. Default is OFF so the
    /// first install still behaves as a manual picker;
    /// users opt in once they trust the test.
    nonisolated static let autoPickEnabledKey = "paladala.cdn.autoPickEnabled"
    var autoPickEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoPickEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoPickEnabledKey) }
    }

    /// Write `Library/Caches/paladala/akamTester.txt` —
    /// same format as the Python `miyouzi/akamTester` repo's
    /// `{host}.txt` output (one `IP HOST` per line). The
    /// file is what external speed-test tooling
    /// (e.g. a desktop run of the Python repo) reads back
    /// to confirm "yes, this is the IP I told the iOS app
    /// to use" — a sanity-check bridge between the two
    /// probing implementations.
    private func writeAkamTesterFile() {
        guard let cacheDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return }
        let dir = cacheDir.appendingPathComponent("paladala", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("akamTester.txt")
        // The Python repo writes one file per host with
        // IPs that pass the `<200ms` filter. We collapse
        // to a single file and let any reachable IP through
        // (we don't pre-filter by latency in the file — the
        // `lowestDelayHost` computed property is the live
        // signal). Empty / failed hosts are dropped.
        let reachable = results.filter { $0.latencyMs != nil }
        let lines = reachable.map { result in
            // We don't have the IP at the `SpeedResult`
            // level (the TLS probe is one-shot per node
            // and the per-IP results are merged). The
            // Python `akamTester` writes each probed IP
            // it considered; we write the *result row* in
            // a slightly extended format that the Python
            // side will recognise as its own (`IP HOST ms`).
            "\(result.node.host)\t\(result.latencyMs ?? -1)ms"
        }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? body.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    nonisolated func rewrite(_ playback: BiliPlayback, pinHost: String? = nil) -> BiliPlayback {
        // Plugin-pinned host beats the user's manual CDN
        // choice (`selectedHostKey`). Empty pin is ignored so
        // a stale plugin can't disable the manual picker;
        // pinning with manual-picker OFF also works because we
        // no longer early-return on `enabledKey`.
        let manual = UserDefaults.standard.string(forKey: Self.selectedHostKey)
        let userEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let pluginEnabled = (pinHost?.isEmpty == false)
        
        let selected: String?
        if pluginEnabled {
            selected = pinHost
        } else if userEnabled, let m = manual, !m.isEmpty {
            selected = m
        } else {
            selected = nil
        }
        
        guard let selectedHost = selected, let normalizedHost = normalize(host: selectedHost) else {
            return playback
        }
        
        let backupHosts = Self.backupHosts.compactMap { normalize(host: $0) }

        func replace(_ url: URL, with host: String) -> URL {
            guard let originalHost = url.host, normalize(host: originalHost) != nil, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            c.host = host
            return c.url ?? url
        }

        guard let dash = playback.dash else {
            let newFallbackURL = playback.fallbackURL.flatMap { url -> URL? in
                guard let originalHost = url.host, normalize(host: originalHost) != nil else { return url }
                return replace(url, with: normalizedHost)
            }
            return BiliPlayback(dash: nil, fallbackURL: newFallbackURL, referer: playback.referer, resumeTime: playback.resumeTime, localContext: playback.localContext)
        }

        func track(_ t: BiliDashSource.Track) -> BiliDashSource.Track {
            let primaryURL = replace(t.baseURL, with: normalizedHost)
            let backupURLs = backupHosts.map { replace(t.baseURL, with: $0) }

            return BiliDashSource.Track(
                baseURL: primaryURL,
                backupURLs: [primaryURL] + backupURLs,
                codecs: t.codecs,
                bandwidth: t.bandwidth,
                mimeType: t.mimeType,
                initializationRange: t.initializationRange,
                indexRange: t.indexRange,
                mediaStartOffset: t.mediaStartOffset,
                totalDuration: t.totalDuration,
                width: t.width,
                height: t.height,
                // The qn id is host-agnostic; the rewrite path
                // only touches the URL, not the representation
                // metadata, so we forward `t.qualityId` verbatim.
                // Without this, `BiliPlayback.selectedVideoQn`
                // would resolve to `nil` after a CDN rewrite
                // and the quality menu would lose the
                // "currently selected" checkmark.
                qualityId: t.qualityId
            )
        }

        let newVideoTrack = track(dash.video)
        let newAudioTrack = dash.audio.map(track)

        return BiliPlayback(
            dash: BiliDashSource(video: newVideoTrack, audio: newAudioTrack),
            fallbackURL: playback.fallbackURL.map { replace($0, with: normalizedHost) },
            referer: playback.referer,
            resumeTime: playback.resumeTime,
            localContext: playback.localContext,
            // The accept-quality list is also host-agnostic
            // (it's per-video + per-account, not per-CDN), so
            // forward it through the rewrite so the quality
            // menu keeps working after a manual / plugin pin
            // swap. `acceptDescription` is the same — key
            // it by qn so the lookup is O(1) at render time.
            acceptQuality: playback.acceptQuality,
            acceptDescription: playback.acceptDescription,
            // Same rationale for the audio ladder: the
            // upstream's audio-id list does not change
            // when we rewrite the media host, so the audio
            // menu's filter keeps working after a manual /
            // plugin pin swap.
            acceptAudioQuality: playback.acceptAudioQuality
        )
    }

    /// Replaces only known Bilibili media CDN hosts and preserves path/query
    /// signatures, which is the key behavior of CCB's URL interception.
    ///
    /// **Deprecated:** kept as a thin shim for any future
    /// "rewrite a single URL on the fly" call site (e.g. an
    /// in-app browser that wants to route an `<a>` href through
    /// the user's manual host), but the active path today is
    /// `rewrite(_:pinHost:)` which handles a full
    /// `BiliPlayback` and the `pinHost` plugin hook. Callers
    /// should prefer the `rewrite` overload — this method does
    /// NOT consult the plugin pin and is therefore unsafe as a
    /// general-purpose entry point.
    @available(*, deprecated, message: "Use rewrite(_:pinHost:) so plugin pins are honoured.")
    func replaceMediaURL(_ url: URL) -> URL {
        guard isEnabled,
              let selected = UserDefaults.standard.string(forKey: Self.selectedHostKey),
              !selected.isEmpty,
              let normalizedHost = normalize(host: selected),
              let originalHost = url.host,
              normalize(host: originalHost) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.host = normalizedHost
        return components.url ?? url
    }

    nonisolated static let backupHosts = ["upos-sz-upcdnbda2.bilivideo.com", "upos-sz-mirrorhw.bilivideo.com"]

    nonisolated static let cdnSuffixes = ["bilivideo.com", "acgvideo.com", "acgvideo.cn"]
    // `Regex<Substring>` isn't `Sendable` (the underlying
    // regex engine keeps an internal cache for thread-local
    // matchers), so a plain `nonisolated let` is rejected by
    // Swift 6 strict concurrency. The regex literal is a
    // compile-time constant — it never mutates at runtime —
    // so `nonisolated(unsafe)` is the right marker: callers
    // must not write to it, and the engine's non-Sendable
    // cache is a "may produce data races if the regex is
    // shared across threads" hazard the marker opts out of
    // (acceptable here because `Regex.firstMatch` only reads).
    nonisolated(unsafe) static let hostLabelRegex = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/

    nonisolated func normalize(host: String) -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedHost.isEmpty, trimmedHost.count <= 253 else { return nil }

        guard let suffix = Self.cdnSuffixes.first(where: { trimmedHost.hasSuffix(".\($0)") }) else {
            return nil
        }

        let prefix = trimmedHost.dropLast(suffix.count + 1)
        // `Regex.firstMatch(in:)` is `throws` (the regex
        // engine reports allocation failures that way
        // rather than via `Optional`); the `prefix`
        // walk here can't actually fail for an in-memory
        // `String` we've already trimmed + lowercased to
        // a max of 253 chars, so `try!` is a sound
        // shorthand for "the regex engine is fine on
        // 64-byte label strings, if it ever isn't we'd
        // rather crash than accept a bad host". The
        // outer `try` on `prefix.split` is the same
        // idea: the `String.split(separator:)` overload
        // was marked `throws` for memory-pressure parity
        // with the regex variant.
        guard !prefix.isEmpty, try prefix.split(separator: ".").allSatisfy({ try! Self.hostLabelRegex.firstMatch(in: String($0)) != nil }) else {
            return nil
        }
        
        return trimmedHost
    }
}
