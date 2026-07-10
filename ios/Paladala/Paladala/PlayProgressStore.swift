import Foundation
import UIKit

/// On-device persistence of "where did I leave off?" per video.
///
/// `PlayerController` samples the playhead every 0.5 seconds.
/// This store coalesces those samples into a write at most once
/// every 5 seconds and force-flushes pending state on background.
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

    /// Last flush cadence. The player calls `update(...)` from
    /// a 0.5 s periodic observer; samples inside this window stay
    /// in `pendingEntries` and are committed together. This caps
    /// manifest rewrites at one per video per 5 s while retaining
    /// the newest playhead for pause / background flushing.
    static let minFlushIntervalSeconds: Double = 5

    /// In-memory mirror of the on-disk JSON.  Views can read
    /// `lastProgress(for:)` directly; the player writes via
    /// `update(...)`.
    @Published private(set) var entries: [String: PlayProgressEntry] = [:]

    /// Latest high-frequency samples that have not reached the
    /// manifest yet. This dictionary is deliberately not published:
    /// a 0.5 s AVPlayer tick must not invalidate observing SwiftUI
    /// views. `lastProgress(for:)` still consults it so an in-process
    /// reopen sees the newest playhead immediately.
    private var pendingEntries: [String: PlayProgressEntry] = [:]

    /// Wall-clock time of the actual manifest commit, kept separate
    /// from `PlayProgressEntry.updatedAt` (the time of the latest
    /// sample). Using the sample timestamp as the throttle anchor can
    /// make two physical writes less than five seconds apart when a
    /// delayed flush commits a slightly older sample.
    private var lastPersistedAt: [String: Date] = [:]

    /// One delayed flush per active video. The task wakes at the next
    /// legal persistence deadline and commits the newest pending
    /// sample, even if playback paused and the periodic observer no
    /// longer produces another tick.
    private var scheduledFlushes: [String: Task<Void, Never>] = [:]

    /// Background queue for the disk rewrite. Serial so
    /// concurrent `flush()` calls don't race on the manifest
    /// file. Same naming convention as `DownloadStore`.
    private let ioQueue = DispatchQueue(
        label: "Paladala.PlayProgressStore.io",
        qos: .utility
    )
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let nowProvider: @MainActor () -> Date
    private let persistenceObserver: (@MainActor ([PlayProgressEntry]) -> Void)?
    private let schedulesDelayedFlushes: Bool
    private var lifecycleObserverTokens: [NSObjectProtocol] = []

    /// `Application Support/PlayProgress/manifest.json`.  We
    /// deliberately use `Application Support` (not `Caches`)
    /// so iOS will not evict the file under storage pressure
    /// — losing the user's last-play position is exactly the
    /// regression this store is built to prevent.
    /// `Application Support/PlayProgress/manifest.json`.  We
    /// deliberately use `Application Support` (not `Caches`)
    /// so iOS will not evict the file under storage pressure
    /// — losing the user's last-play position is exactly the
    /// regression this store is built to prevent.  Marked
    /// `nonisolated` so the ioQueue worker (background
    /// `DispatchQueue`) can read the path without an actor
    /// hop when rewriting the manifest.
    nonisolated static let manifestURL: URL = {
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

    /// Production uses the defaults. Tests inject an empty initial
    /// dictionary, a controllable clock, and a persistence observer so
    /// cadence assertions never touch the real Application Support file.
    init(
        initialEntries: [String: PlayProgressEntry]? = nil,
        nowProvider: @escaping @MainActor () -> Date = Date.init,
        persistenceObserver: (@MainActor ([PlayProgressEntry]) -> Void)? = nil,
        schedulesDelayedFlushes: Bool = true,
        observesLifecycle: Bool = true
    ) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
        self.nowProvider = nowProvider
        self.persistenceObserver = persistenceObserver
        self.schedulesDelayedFlushes = schedulesDelayedFlushes

        if let initialEntries {
            self.entries = initialEntries
        } else {
            self.entries = hydrateFromDiskSync()
        }
        self.lastPersistedAt = self.entries.mapValues(\.updatedAt)

        if observesLifecycle {
            observeLifecycleFlushes()
        }
    }

    // MARK: - public API

    /// Read the last saved progress for `bvid`.  Returns `nil`
    /// if the user has never watched this video on this
    /// device, or if the saved value is older than 30 days
    /// (treated as stale — most users have either re-watched
    /// or forgotten by then).
    func lastProgress(for bvid: String) -> PlayProgressEntry? {
        guard !bvid.isEmpty,
              let entry = pendingEntries[bvid] ?? entries[bvid]
        else { return nil }
        // 30-day staleness window.  Anything older gets a
        // fresh play (a one-month-old "left off at 14:32"
        // is rarely what the user wanted).
        let cutoff = nowProvider().addingTimeInterval(-30 * 24 * 3600)
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
                duration: Double,
                force: Bool = false) {
        // Live-room controllers have no bvid. The old path persisted
        // them under the empty-string key every 0.5 s, continuously
        // rewriting the whole JSON manifest for data that could never
        // be resumed.
        guard !bvid.isEmpty, currentTime.isFinite else { return }

        let now = nowProvider()
        let entry = PlayProgressEntry(
            bvid: bvid,
            currentTime: max(0, currentTime),
            duration: duration.isFinite ? max(0, duration) : 0,
            updatedAt: now
        )
        pendingEntries[bvid] = entry

        if force {
            flushPending(for: bvid)
            return
        }

        if let lastPersisted = lastPersistedAt[bvid] {
            let elapsed = max(0, now.timeIntervalSince(lastPersisted))
            if elapsed < Self.minFlushIntervalSeconds {
                scheduleFlush(
                    for: bvid,
                    after: Self.minFlushIntervalSeconds - elapsed
                )
                return
            }
        }

        flushPending(for: bvid)
    }

    /// Commit every pending playhead in one manifest rewrite. The app
    /// lifecycle observers call this before suspension / termination;
    /// tests and any future explicit pause/end hook can call it too.
    func flushPending() {
        guard !pendingEntries.isEmpty else { return }

        let pending = pendingEntries
        pendingEntries.removeAll(keepingCapacity: true)
        let persistedAt = nowProvider()
        for (bvid, entry) in pending {
            scheduledFlushes.removeValue(forKey: bvid)?.cancel()
            entries[bvid] = entry
            lastPersistedAt[bvid] = persistedAt
        }
        persistAsync()
    }

    /// Drop the saved progress for `bvid`.  Called when the
    /// user taps the "重新播放" button on the detail view, or
    /// when the download manager promotes a fresh `record` and
    /// we want the on-disk play progress to reflect the new
    /// download's first-play state (otherwise the user would
    /// resume mid-video the first time they open the redownload).
    func clear(bvid: String) {
        guard !bvid.isEmpty else { return }
        let removedPending = pendingEntries.removeValue(forKey: bvid) != nil
        let removedPersisted = entries.removeValue(forKey: bvid) != nil
        scheduledFlushes.removeValue(forKey: bvid)?.cancel()
        lastPersistedAt.removeValue(forKey: bvid)
        guard removedPending || removedPersisted else { return }
        persistAsync()
    }

    // MARK: - coalescing

    private func scheduleFlush(for bvid: String, after delay: TimeInterval) {
        guard schedulesDelayedFlushes,
              scheduledFlushes[bvid] == nil
        else { return }

        scheduledFlushes[bvid] = Task { @MainActor [weak self] in
            do {
                let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            self.scheduledFlushes[bvid] = nil
            self.flushPending(for: bvid, cancelScheduledTask: false)
        }
    }

    private func flushPending(
        for bvid: String,
        cancelScheduledTask: Bool = true
    ) {
        guard let entry = pendingEntries.removeValue(forKey: bvid) else {
            return
        }
        if cancelScheduledTask {
            scheduledFlushes.removeValue(forKey: bvid)?.cancel()
        }
        entries[bvid] = entry
        lastPersistedAt[bvid] = nowProvider()
        persistAsync()
    }

    private func observeLifecycleFlushes() {
        let center = NotificationCenter.default
        for name in [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification
        ] {
            let token = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.flushPending()
                }
            }
            lifecycleObserverTokens.append(token)
        }
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
        for entry in pruned where !entry.bvid.isEmpty {
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
        if let persistenceObserver {
            persistenceObserver(snapshot)
            return
        }
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
