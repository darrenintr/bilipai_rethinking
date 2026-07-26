import CryptoKit
import Foundation

extension Notification.Name {
    static let paladalaSponsorSegmentSkipped = Notification.Name("app.paladala.ios.sponsorSegmentSkipped")
}

@MainActor
final class SponsorBlockManager: ObservableObject {
    static let shared = SponsorBlockManager()

    @Published var config: SponsorConfig {
        didSet { saveConfig() }
    }

    @Published private(set) var segments: [SponsorSegment] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastSkippedSegment: SponsorSegment?

    private let defaults = UserDefaults.standard
    private let configKey = "paladala.sponsorBlockConfig"

    private var fetchTask: Task<Void, Never>?
    private(set) var lastVideoID: String?

    private var sortedSegments: [SponsorSegment] = []
    private var segmentIndex = 0
    private var _cachedUserID: String?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "paladala.sponsorBlockConfig") {
            // PR-B B13: previously a corrupt JSON in
            // UserDefaults silently fell back to
            // `.default` with no diagnostic — operators
            // couldn't tell whether the user's config was
            // intentionally default or whether a bad write
            // had nuked it.  Now we log the decode error
            // so the diagnostic dump carries the
            // distinction.
            do {
                let saved = try JSONDecoder().decode(SponsorConfig.self, from: data)
                self.config = saved
            } catch {
                diagLog(.playback,
                        "SponsorBlock: config decode failed, falling back to default",
                        details: [
                            "error": error.localizedDescription,
                            "bytes": data.count
                        ])
                self.config = .default
            }
        } else {
            self.config = .default
        }
    }

    private func saveConfig() {
        // PR-B B13: same rationale — encode failures used
        // to silently drop the user's config change.  Log
        // so a UserDefaults write failure (disk full,
        // permissions) is observable.
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: configKey)
        } catch {
            diagLog(.playback,
                    "SponsorBlock: config encode failed",
                    details: ["error": error.localizedDescription])
        }
    }

    // MARK: - Public API

    var isEnabled: Bool { config.isEnabled }
    var autoSkip: Bool { config.autoSkip }

    func loadSegments(for videoID: String, cid: String? = nil) {
        guard config.isEnabled, !config.categories.isEmpty else {
            segments = []
            sortedSegments = []
            segmentIndex = 0
            return
        }

        fetchTask?.cancel()
        lastVideoID = videoID
        segmentIndex = 0

        fetchTask = Task { [weak self] in
            guard let self else { return }
            isLoading = true
            defer { isLoading = false }

            do {
                let result = try await SponsorBlockService.shared.fetchSegments(
                    videoID: videoID,
                    categories: config.categories
                )
                guard !Task.isCancelled else { return }

                let filtered = result.filter { ($0.votes ?? 0) >= config.minVotes }
                // Layer plugin-supplied skip segments on top of
                // the network result before sorting. Plugin
                // extras bypass `minVotes` because they're
                // locally authored and trust-implicit — see
                // `PluginManager.sponsorExtras(for:)`.
                let combined = filtered + PluginManager.shared.sponsorExtras(for: videoID)
                self.segments = combined
                self.sortedSegments = combined.sorted { $0.startTime < $1.startTime }
                self.segmentIndex = 0

                diagLog(.playback, "SponsorBlock: loaded \(filtered.count) segments", details: [
                    "videoID": videoID, "total": result.count
                ])
            } catch {
                guard !Task.isCancelled else { return }
                diagLog(.playback, "SponsorBlock: fetch failed", details: [
                    "error": error.localizedDescription
                ])
            }
        }
    }

    /// Optimized check: only scans from the current index
    /// forward.  Returns the timestamp to seek to if the
    /// playhead has entered a sponsored segment, or `nil` if
    /// no skip is needed.
    ///
    /// **PR-A Group 1**: previously this method took an
    /// `AVPlayer` and called `player.seek(to:)` directly with
    /// the default (zero-tolerance) seek.  That bypassed the
    /// controller's `seekGeneration` + `isSeeking` +
    /// `seekTolerance` machinery — a SponsorBlock skip during
    /// a user scrub could clobber the user's in-flight
    /// `isSeeking = false` when its completion fired.  The
    /// seek side-effect is now the caller's responsibility:
    /// the controller's periodic time observer calls
    /// `seekToSponsorSegmentEnd(_:)` if this returns a non-nil
    /// target.
    func checkCurrentTime(_ time: Double) -> Double? {
        guard config.isEnabled, config.autoSkip, !sortedSegments.isEmpty else { return nil }

        while segmentIndex < sortedSegments.count {
            let segment = sortedSegments[segmentIndex]
            if segment.endTime < time {
                segmentIndex += 1
                continue
            }
            if segment.contains(time: time) {
                segmentIndex += 1
                lastSkippedSegment = segment

                diagLog(.playback, "SponsorBlock: skipped segment", details: [
                    "uuid": segment.uuid, "category": segment.category,
                    "start": segment.startTime, "end": segment.endTime
                ])

                NotificationCenter.default.post(
                    name: .paladalaSponsorSegmentSkipped,
                    object: segment,
                    userInfo: ["category": segment.category]
                )

                Task { [uuid = segment.uuid] in
                    // PR-B B13: a SponsorBlock view-record
                    // failure (network down at skip time,
                    // sponsorblock.pe API down) used to
                    // vanish silently.  Logged so operators
                    // can correlate a high skip count in
                    // metrics with low recordView count
                    // (network failures) vs. successful
                    // skips that all recorded normally.
                    do {
                        try await SponsorBlockService.shared.recordView(uuid: uuid)
                    } catch {
                        diagLog(.playback,
                                "SponsorBlock: recordView failed",
                                details: [
                                    "uuid": uuid,
                                    "error": error.localizedDescription
                                ])
                    }
                }
                return segment.endTime
            }
            break
        }
        return nil
    }

    func submitSegment(videoID: String, cid: String?, category: String, startTime: Double, endTime: Double, videoDuration: Double) async throws {
        try await SponsorBlockService.shared.submitSegment(
            videoID: videoID, cid: cid, category: category,
            startTime: startTime, endTime: endTime,
            userID: storedUserID, videoDuration: videoDuration
        )
    }

    func vote(uuid: String, type: Int) async throws {
        try await SponsorBlockService.shared.vote(uuid: uuid, userID: storedUserID, type: type)
    }

    func clearLastSkipped() {
        lastSkippedSegment = nil
    }

    func reset(for videoID: String) {
        segments = []
        sortedSegments = []
        segmentIndex = 0
        lastSkippedSegment = nil
        lastVideoID = videoID
    }

    // MARK: - User ID

    var storedUserID: String {
        get {
            if let cached = _cachedUserID { return cached }
            if let id = defaults.string(forKey: "paladala.sponsorUserID"), id.count >= 30 {
                _cachedUserID = id
                return id
            }
            let newID = UUID().uuidString + UUID().uuidString
            defaults.set(newID, forKey: "paladala.sponsorUserID")
            _cachedUserID = newID
            return newID
        }
        set {
            _cachedUserID = newValue
            defaults.set(newValue, forKey: "paladala.sponsorUserID")
        }
    }

    var totalTimeSaved: TimeInterval {
        segments.reduce(0.0) { sum, seg in
            guard seg.endTime < .infinity else { return sum }
            return sum + seg.duration
        }
    }

    var skippedCount: Int {
        segments.count { $0.endTime < .infinity }
    }
}
