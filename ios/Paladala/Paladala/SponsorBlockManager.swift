import CommonCrypto
import Foundation
import AVFoundation

@MainActor
final class SponsorBlockManager: ObservableObject {
    static let shared = SponsorBlockManager()

    @Published var config: SponsorConfig {
        didSet {
            saveConfig()
        }
    }

    @Published private(set) var segments: [SponsorSegment] = []
    @Published private(set) var skippedSegments: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var activeSkippedSegment: SponsorSegment?

    private let defaults = UserDefaults.standard
    private let configKey = "paladala.sponsorBlockConfig"

    private var fetchTask: Task<Void, Never>?
    private(set) var lastVideoID: String?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "paladala.sponsorBlockConfig"),
           let saved = try? JSONDecoder().decode(SponsorConfig.self, from: data) {
            self.config = saved
        } else {
            self.config = .default
        }
    }

    // MARK: - Persistence

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: configKey)
        }
    }

    // MARK: - Public API

    var isEnabled: Bool {
        config.isEnabled
    }

    var autoSkip: Bool {
        config.autoSkip
    }

    /// Fetch segments for a video (bvid).
    func loadSegments(for videoID: String, cid: String? = nil) {
        guard config.isEnabled, !config.categories.isEmpty else { return }

        fetchTask?.cancel()
        lastVideoID = videoID

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

                let filtered = result.filter { segment in
                    segment.votes >= config.minVotes
                }
                self.segments = filtered

                diagLog(.playback, "SponsorBlock: loaded \(filtered.count) segments", details: [
                    "videoID": videoID,
                    "total": result.count
                ])
            } catch {
                guard !Task.isCancelled else { return }
                diagLog(.playback, "SponsorBlock: fetch failed", details: [
                    "error": error.localizedDescription
                ])
            }
        }
    }

    /// Check if current time is within a segment and auto-skip if needed.
    /// Returns the segment being skipped, or nil.
    func checkCurrentTime(_ time: Double, player: AVPlayer) -> SponsorSegment? {
        guard config.isEnabled, config.autoSkip else { return nil }

        for segment in segments {
            guard !skippedSegments.contains(segment.uuid) else { continue }
            guard segment.contains(time: time) else { continue }

            skippedSegments.insert(segment.uuid)
            activeSkippedSegment = segment

            let target = CMTime(seconds: segment.endTime, preferredTimescale: 600)
            player.seek(to: target)

            diagLog(.playback, "SponsorBlock: skipped segment", details: [
                "uuid": segment.uuid,
                "category": segment.category,
                "start": segment.startTime,
                "end": segment.endTime
            ])

            Task { [uuid = segment.uuid] in
                try? await SponsorBlockService.shared.recordView(uuid: uuid)
            }

            return segment
        }

        return nil
    }

    /// Submit a new segment.
    func submitSegment(videoID: String, cid: String?, category: String, startTime: Double, endTime: Double, videoDuration: Double) async throws {
        let userID = storedUserID
        try await SponsorBlockService.shared.submitSegment(
            videoID: videoID,
            cid: cid,
            category: category,
            startTime: startTime,
            endTime: endTime,
            userID: userID,
            videoDuration: videoDuration
        )
    }

    /// Vote on a segment.
    func vote(uuid: String, type: Int) async throws {
        let userID = storedUserID
        try await SponsorBlockService.shared.vote(uuid: uuid, userID: userID, type: type)
    }

    /// Clear skipped segments for a new video.
    func reset(for videoID: String) {
        segments = []
        skippedSegments = []
        activeSkippedSegment = nil
        lastVideoID = videoID
    }

    // MARK: - User ID

    var storedUserID: String {
        get {
            if let id = defaults.string(forKey: "paladala.sponsorUserID"), id.count >= 30 {
                return id
            }
            let newID = UUID().uuidString + UUID().uuidString
            defaults.set(newID, forKey: "paladala.sponsorUserID")
            return newID
        }
        set {
            defaults.set(newValue, forKey: "paladala.sponsorUserID")
        }
    }

    var publicUserID: String {
        let privateID = storedUserID
        guard let data = privateID.data(using: .utf8) else { return storedUserID }
        var hash = data.sha256
        for _ in 0..<4999 {
            hash = hash.sha256
        }
        return hash.hexEncodedString
    }

    var totalTimeSaved: TimeInterval {
        skippedSegments.reduce(0.0) { sum, uuid in
            if let segment = segments.first(where: { $0.uuid == uuid }) {
                return sum + segment.duration
            }
            return sum
        }
    }
}

private extension Data {
    var sha256: Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(count), &hash)
        }
        return Data(hash)
    }

    func hexEncodedString() -> String {
        map { String(format: "%02hhx", $0) }.joined()
    }
}
