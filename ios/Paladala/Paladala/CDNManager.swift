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

    func nodes() async -> [Node] {
        let url = URL(string: "https://raw.githubusercontent.com/Kanda-Akihito-kun/ccb/main/data/cdn.json")!
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [Node(host: Self.defaultHost, region: "默认")]
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
        guard let selected else { return playback }
        func replace(_ url: URL) -> URL {
            guard let host = url.host, Self.isMediaHost(host), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            c.host = selected
            return c.url ?? url
        }
        guard let dash = playback.dash else {
            return BiliPlayback(dash: nil, fallbackURL: playback.fallbackURL.map(replace), referer: playback.referer, resumeTime: playback.resumeTime, localContext: playback.localContext)
        }
        func track(_ t: BiliDashSource.Track) -> BiliDashSource.Track {
            BiliDashSource.Track(baseURL: replace(t.baseURL), backupURLs: t.backupURLs.map(replace), codecs: t.codecs, bandwidth: t.bandwidth, mimeType: t.mimeType, initializationRange: t.initializationRange, indexRange: t.indexRange, mediaStartOffset: t.mediaStartOffset, totalDuration: t.totalDuration, width: t.width, height: t.height)
        }
        return BiliPlayback(dash: BiliDashSource(video: track(dash.video), audio: dash.audio.map(track)), fallbackURL: playback.fallbackURL.map(replace), referer: playback.referer, resumeTime: playback.resumeTime, localContext: playback.localContext)
    }

    /// Replaces only known Bilibili media CDN hosts and preserves path/query
    /// signatures, which is the key behavior of CCB's URL interception.
    func replaceMediaURL(_ url: URL) -> URL {
        guard isEnabled, !selectedHost.isEmpty,
              let host = url.host,
              Self.isMediaHost(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.host = selectedHost
        return components.url ?? url
    }

    nonisolated static func isMediaHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h.contains("bilivideo.com") || h.contains("bilivideo.cn") ||
            h.contains("acgvideo.com") || h.contains("acgvideo.cn") ||
            h.contains("akamaized.net") || h.contains("edge.mountaintoys.cn")
    }
}
