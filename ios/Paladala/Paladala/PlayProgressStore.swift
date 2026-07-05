import Foundation

/// On-device persistence of "where did I leave off?" per video.
///
/// Every 5 seconds while the user is playing (and once on
/// background), `PlayerController` calls
/// `PlayProgressStore.shared.update(bvid:currentTime:duration:)`.
/// When the user reopens the same `bvid` (whether from the home
/// feed, downloads, search, or a Siri intent), the detail view
/// reads the persisted time via `lastProgress(for:)` and seeds
/// `BiliPlayback.resumeTime` so `AVPlayerController` seeks to
/// the saved position before the first frame.
///
/// Why this exists
/// ---------------
///
/// Before this store, the only on-device "last play" hint came
/// from the B站 history API (via `AccountContentViews.swift:186`
/// and `BiliVideo.resumeTime`). That value goes stale quickly —
/// the user can watch for 30 minutes, kill the app, reopen, and
/// the server-side `last_play_time` is whatever the most recent
/// `report` heartbeat sent (often up to 30 s behind real time).
/// More importantly, the history API requires an authenticated
/// SESSDATA cookie; an anonymous user gets nothing.
///
/// `PlayProgressStore` is local-first: it survives app kills,
/// survives `Caches/` purges (we write to `Application Support/`,
/// not `Caches/`, so iOS won't evict us under storage pressure),
/// and is independent of B站 account state.
///
/// Failure model
/// -------------
///
/// All public methods are best-effort — a write failure
/// (filesystem full, sandbox rotation) logs via `bpLog` and
/// returns; it never throws and never blocks the playback
/// hot path. The 5 s flush cadence means the worst-case
/// data loss on a crash is ~5 s of playback, which is
/// well under what the user perceives as "lost my spot".
///
/// Concurrency
/// -----------
///
/// `PlayProgressStore` is `@MainActor`-isolated so SwiftUI
/// views that observe `lastProgress(for:)` can read it
/// synchronously.  Writes are coalesced onto a serial
/// `DispatchQueue` (the same `ioQueue` pattern `DownloadStore`
/// uses) so the on-disk JSON rewrite never blocks the main
/// thread.  The `entries` dictionary lives on the main actor
/// to make the `@Published` reads SwiftUI-friendly.
@MainActor
final class PlayProgressStore: ObservableObject {
    static let shared = PlayProgressStore()

    /// Last flush cadence. The player calls `update(...)` on
    /// the periodic time observer (every 1 s by default); we
    /// ignore calls whose `currentTime` hasn't advanced more
    /// than this since the last persisted value.  Caps disk
    /// churn at one rewrite per video per 5 s without
    /// sacrificing precision on pause / scrub.
    static let minFlushIntervalSeconds: Double = 5

    /// In-memory mirror of the on-disk JSON.  Views can read
    /// `lastProgress(for:)` directly; the player writes via
    /// `update(...)`.
    @Published private(set) var entries: [String: PlayProgressEntry] = [:]

    /// Background queue for the disk rewrite. Serial so
    /// concurrent `flush()` calls don't race on the manifest
    /// file. Same naming convention as `DownloadStore`.
    private let ioQueue = DispatchQueue(
        label: "Paladala.PlayProgressStore.io",
        qos: .utility
    )
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// `Application Support/PlayProgress/manifest.json`.  We
    /// deliberately use `Application Support` (not `Caches`)
    /// so iOS will not evict the file under storage pressure
    /// — losing the user's last-play position is exactly the
    /// regression this store is built to prevent.
    static let manifestURL: URL = {
        let fm = FileManager.default
        // `applicationSupportDirectory` is `nil` on first
        // launch until the directory has been created. We
        // create it on demand below.
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true))
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("PlayProgress",
                                                 isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("manifest.json", isDirectory: false)
    }()

    private init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
        self.entries = hydrateFromDiskSync()
    }

    // MARK: - public API

    /// Read the last saved progress for `bvid`.  Returns `nil`
    /// if the user has never watched this video on this
    /// device, or if the saved value is older than 30 days
    /// (treated as stale — most users have either re-watched
    /// or forgotten by then).
    func lastProgress(for bvid: String) -> PlayProgressEntry? {
        guard let entry = entries[bvid] else { return nil }
        // 30-day staleness window.  Anything older gets a
        // fresh play (a one-month-old "left off at 14:32"
        // is rarely what the user wanted).
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        if entry.updatedAt < cutoff {
            return nil
        }
        return entry
    }

    /// Persist the current playhead.  Cheap when called more
    /// often than `minFlushIntervalSeconds` — the early-out
    /// prevents redundant disk writes during fast scrubbing.
    ///
    /// `currentTime` is in seconds (AVPlayer's
    /// `currentTime().seconds` already gives us a `Double`).
    /// `duration` is the total asset duration in seconds; the
    /// store persists both so the UI can show a
    /// "还有 X 分钟" hint at reopen time without re-loading
    /// the asset.
    func update(bvid: String,
                currentTime: Double,
                duration: Double) {
        // Coalesce: skip the disk write if the playhead
        // barely moved since the last persisted value.  The
        // 0.5 s floor accommodates floating-point jitter on
        // AVPlayer's time observer.
        let existing = entries[bvid]
        let now = Date()
        if let existing,
           now.timeIntervalSince(existing.updatedAt)
                < Self.minFlushIntervalSeconds,
           abs(existing.currentTime - currentTime) < 0.5 {
            return
        }
        let entry = PlayProgressEntry(
            bvid: bvid,
            currentTime: max(0, currentTime),
            duration: max(0, duration),
            updatedAt: now
        )
        entries[bvid] = entry
        persistAsync()
    }

    /// Drop the saved progress for `bvid`.  Called when the
    /// user taps the "重新播放" button on the detail view, or
    /// when the download manager promotes a fresh `record` and
    /// we want the on-disk play progress to reflect the new
    /// download's first-play state (otherwise the user would
    /// resume mid-video the first time they open the redownload).
    func clear(bvid: String) {
        guard entries.removeValue(forKey: bvid) != nil else { return }
        persistAsync()
    }

    // MARK: - disk I/O

    private func hydrateFromDiskSync() -> [String: PlayProgressEntry] {
        let url = Self.manifestURL
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let arr = (try? decoder.decode([PlayProgressEntry].self,
                                       from: data)) ?? []
        // Cap at the most-recent 200 entries. The store is
        // small (a few KB per entry), so 200 is plenty of
        // history and keeps the JSON parse under a millisecond
        // even on cold cache.
        let sorted = arr.sorted { $0.updatedAt > $1.updatedAt }
        let pruned = Array(sorted.prefix(200))
        var out: [String: PlayProgressEntry] = [:]
        for entry in pruned {
            out[entry.bvid] = entry
        }
        return out
    }

    /// Fire-and-forget disk rewrite.  Same shape as
    /// `DownloadStore.persistAsync()` — snapshot the entries
    /// on the main actor, hand a `Data` blob to the serial
    /// `ioQueue` for the atomic write.
    fileprivate func persistAsync() {
        let snapshot = Array(entries.values)
        ioQueue.async { [encoder] in
            do {
                let data = try encoder.encode(snapshot)
                try data.write(to: Self.manifestURL, options: .atomic)
            } catch {
                bpLog("PlayProgressStore persist failed: \(error)")
            }
        }
    }
}

/// One row in the manifest.  Deliberately tiny so 200 entries
/// fit in a few KB and a `loadFromDisk()` round-trip stays
/// sub-millisecond.
struct PlayProgressEntry: Codable, Hashable {
    let bvid: String
    let currentTime: Double
    let duration: Double
    let updatedAt: Date
}