import CryptoKit
import Foundation
import AVFoundation

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
        if let data = UserDefaults.standard.data(forKey: "paladala.sponsorBlockConfig"),
           let saved = try? JSONDecoder().decode(SponsorConfig.self, from: data) {
            self.config = saved
        } else {
            self.config = .default
        }
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: configKey)
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
                self.segments = filtered
                self.sortedSegments = filtered.sorted { $0.startTime < $1.startTime }
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

    /// Optimized check: only scans from the current index forward.
    func checkCurrentTime(_ time: Double, player: AVPlayer) -> Bool {
        guard config.isEnabled, config.autoSkip, !sortedSegments.isEmpty else { return false }

        while segmentIndex < sortedSegments.count {
            let segment = sortedSegments[segmentIndex]
            if segment.endTime < time {
                segmentIndex += 1
                continue
            }
            if segment.contains(time: time) {
                segmentIndex += 1
                lastSkippedSegment = segment

                let target = CMTime(seconds: segment.endTime, preferredTimescale: 600)
                player.seek(to: target)

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
                    try? await SponsorBlockService.shared.recordView(uuid: uuid)
                }
                return true
            }
            break
        }
        return false
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
