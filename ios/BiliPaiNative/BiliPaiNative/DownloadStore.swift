import Foundation

/// Persistent, on-disk record of every video the user has
/// downloaded.  The store is the single source of truth for
/// the "下载" tab; it does *not* own the bytes themselves —
/// those live under
/// `Caches/BiliPai/Downloads/ready/{bvid}/`, and the store
/// points to them.
///
/// Concurrency model
/// -----------------
///
/// `DownloadStore` is a `@MainActor` `ObservableObject` —
/// SwiftUI views can observe `records` directly.  All disk
/// I/O hops onto a dedicated background `DispatchQueue` so
/// the main thread is never blocked by the manifest rewrite
/// (the manifest is small — order of 200 bytes per record —
/// but `Data.write(to:options: .atomic)` does an
/// `fsync`-equivalent and is unpredictable on a hot path).
///
/// The on-disk manifest is rewritten via `Data.write(to:
/// options: .atomic)` so a crash mid-write cannot leave the
/// user with a partial JSON file.  iOS replaces the file
/// atomically via a temporary + rename, and the old content
/// is recoverable from the OS-level recycle bin if the
/// rename never happens.
///
/// Storage location
/// ----------------
///
/// `Caches/` rather than `Documents/` — iOS may purge
/// `Caches/` under storage pressure, but the user's downloads
/// are re-derivable from the B 站 CDN so the trade-off is
/// correct.  `Documents/` would block iCloud backup of the
/// app, which we do not want for 70 MB video files.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    /// All currently-downloaded records, ordered by
    /// `downloadedAt` descending (newest first).  SwiftUI
    /// views observe this and re-render when it changes.
    @Published private(set) var records: [DownloadRecord] = []

    /// Root of every download-related file the store owns.
    /// `Caches/BiliPai/Downloads/` — `manifest.json` lives at
    /// the root, with two child directories:
    ///   - `in_progress/{bvid}/` — staging, never read by the
    ///     player
    ///   - `ready/{bvid}/`       — atomic-swap destination
    static let rootURL: URL = {
        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!
        return caches
            .appendingPathComponent("BiliPai", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }()

    static let inProgressURL: URL = rootURL
        .appendingPathComponent("in_progress", isDirectory: true)
    static let readyURL: URL = rootURL
        .appendingPathComponent("ready", isDirectory: true)
    static let manifestURL: URL = rootURL
        .appendingPathComponent("manifest.json")

    /// Background queue.  Serial, so two concurrent writes do
    /// not race.  All disk I/O for the manifest + on-disk
    /// layout hops here.
    private let ioQueue = DispatchQueue(
        label: "BiliPai.DownloadStore.io",
        qos: .userInitiated
    )
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: lifecycle

    /// Read the manifest from disk and rebuild the in-memory
    /// record list.  Called once from `BiliPaiNativeApp` at
    /// launch (alongside `DownloadManager.bootstrap()`).
    /// Tolerates a missing or corrupt manifest by treating it
    /// as "no records".
    func loadFromDisk() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(
                    at: Self.rootURL,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: Self.inProgressURL,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: Self.readyURL,
                    withIntermediateDirectories: true
                )
            } catch {
                bpLog("DownloadStore could not create dirs: \(error)")
            }
            let onDisk: [DownloadRecord]
            do {
                let data = try Data(contentsOf: Self.manifestURL)
                onDisk = (try? self.decoder.decode(
                    [DownloadRecord].self, from: data
                )) ?? []
            } catch {
                // File missing is the common case on first
                // launch — not an error.  Any other read
                // failure falls back to "empty" so the user
                // can still use the app; a fresh manifest is
                // written on the next mutation.
                onDisk = []
            }
            // Re-hydrate the directory URL for each record
            // (we deliberately do not persist it — see the
            // comment on `DownloadRecord.id`).
            let hydrated = onDisk
                .sorted { $0.downloadedAt > $1.downloadedAt }
            Task { @MainActor in
                self.records = hydrated
            }
        }
    }

    // MARK: directory helpers

    /// On-disk directory for a `bvid` in the ready (final)
    /// state.  Computed from `readyURL` so the URL stays
    /// valid even if iOS rotates the Caches container.
    func readyDirectory(for bvid: String) -> URL {
        Self.readyURL.appendingPathComponent(bvid, isDirectory: true)
    }

    /// On-disk directory for a `bvid` in the in-progress
    /// (staging) state.  Symmetric to `readyDirectory(for:)`.
    func inProgressDirectory(for bvid: String) -> URL {
        Self.inProgressURL.appendingPathComponent(bvid, isDirectory: true)
    }

    // MARK: mutation

    /// Promote a finished download into the ready state.  The
    /// `in_progress/{bvid}/` directory is moved to
    /// `ready/{bvid}/` (atomic on APFS), the manifest is
    /// rewritten, and the in-memory `records` is updated.
    func add(_ record: DownloadRecord) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let staging = self.inProgressDirectory(for: record.bvid)
            let destination = self.readyDirectory(for: record.bvid)
            do {
                // The destination might exist from a prior
                // download of the same `bvid` (the user
                // re-downloaded).  Remove it first so
                // `moveItem` does not fail with
                // `NSFileWriteFileExistsError`.
                if FileManager.default.fileExists(
                    atPath: destination.path
                ) {
                    try FileManager.default.removeItem(
                        at: destination
                    )
                }
                try FileManager.default.moveItem(
                    at: staging, to: destination
                )
                diagLog(.download, "DownloadStore move success",
                        details: [
                            "bvid": record.bvid,
                            "from": staging.lastPathComponent,
                            "to": destination.lastPathComponent
                        ])
            } catch {
                bpLog("DownloadStore move failed: \(error)")
                diagLog(.download, "DownloadStore move failed",
                        details: [
                            "bvid": record.bvid,
                            "from": staging.lastPathComponent,
                            "to": destination.lastPathComponent,
                            "error": "\(error)"
                        ])
                // Recover: drop the staging dir to avoid
                // growing the in_progress folder unbounded.
                try? FileManager.default.removeItem(at: staging)
                return
            }
            self.appendRecord(record)
        }
    }

    /// Remove a record (and the on-disk directory).  No-op if
    /// the record does not exist.  Used by the
    /// swipe-to-delete action in `DownloadedVideosView`.
    func remove(bvid: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let directory = self.readyDirectory(for: bvid)
            try? FileManager.default.removeItem(at: directory)
            Task { @MainActor in
                self.records.removeAll { $0.bvid == bvid }
                self.persistAsync()
            }
        }
    }

    /// Look up a record by `bvid`.  Used by
    /// `PlayerController` to wire `BiliPlayback.localContext`
    /// when the user opens a downloaded video.
    func record(for bvid: String) -> DownloadRecord? {
        records.first { $0.bvid == bvid }
    }

    // MARK: internal mutation

    /// Insert + persist a new record.  Caller has already
    /// moved the staging directory into place.
    ///
    /// Marked `nonisolated` so it is callable from the
    /// background `ioQueue` (in `add(_:)`); the actual
    /// mutation hops to the main actor via `Task { @MainActor in … }`.
    /// `records` is `@MainActor`-isolated because SwiftUI
    /// views observe it directly.
    nonisolated fileprivate func appendRecord(_ record: DownloadRecord) {
        Task { @MainActor in
            self.records.removeAll { $0.bvid == record.bvid }
            self.records.append(record)
            self.records.sort { $0.downloadedAt > $1.downloadedAt }
            self.persistAsync()
        }
    }

    /// Write the in-memory `records` to `manifest.json`.  Safe
    /// to call repeatedly — `Data.write(to:options:
    /// .atomic)` is idempotent.
    fileprivate func persistAsync() {
        let snapshot = records
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try self.encoder.encode(snapshot)
                try data.write(to: Self.manifestURL, options: .atomic)
            } catch {
                bpLog("DownloadStore persist failed: \(error)")
            }
        }
    }
}
