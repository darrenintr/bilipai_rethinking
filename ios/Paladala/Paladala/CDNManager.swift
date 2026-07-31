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
    private static let fallbackNodes: [Node] = [
        Node(host: "upos-sz-mirrorali.bilivideo.com", region: "默认"),
        Node(host: "upos-sz-mirrorcosov.bilivideo.com", region: "华南 cosov"),
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

    /// Tests the CDN host itself with a small range request. This intentionally
    /// measures latency/availability, not throughput, avoiding a batch download
    /// of Bilibili media as recommended by CCB.
    func test(_ node: Node) async -> SpeedResult {
        let started = ContinuousClock.now
        let url = URL(string: "https://\(node.host)/")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        do {
            let (_, response) = try await session.data(for: request)
            let elapsed = ContinuousClock.now - started
            let ms = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            return SpeedResult(node: node, latencyMs: max(ms, 1), statusCode: (response as? HTTPURLResponse)?.statusCode, error: nil)
        } catch {
            return SpeedResult(node: node, latencyMs: nil, statusCode: nil, error: error.localizedDescription)
        }
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
