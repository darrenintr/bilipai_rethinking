import Foundation

/// Result of attempting to read a cached feed snapshot. Never throws —
/// the warmer is best-effort and logs every failure path so the cold-start
/// trace shows whether a seed attempt succeeded, was missing, or hit a
/// schema/IO problem.
enum FeedCacheResult {
    case success([BiliVideo])
    case missing
    case corrupt(reason: String)
}

/// Reads the on-disk seed snapshot for a named feed
/// (`Application Support/Paladala/<key>.json`) so the home / music tabs
/// can paint the first frame from cache while the network request is
/// still in flight. PR-A, audit items #6 and #14.
///
/// The file format is versioned (`FeedSnapshotEnvelope`); a schema
/// mismatch returns `.corrupt` rather than crashing so a future
/// migration can replace the on-disk data without taking the app down.
/// All IO is off-main; the public surface is `@MainActor` so callers can
/// drop the result straight into an `@StateObject` view-model.
@MainActor
final class FeedCacheWarmer {
    /// Shared instance pointed at the default `Application Support`
    /// directory. Most callers want this; tests inject their own
    /// `directory:`.
    static let shared = FeedCacheWarmer(directory: FeedCacheWarmer.defaultDirectory)

    private let directory: URL

    /// `nonisolated` so the `static let shared` initializer (which runs
    /// on first access from any context) can construct the instance.
    /// The body only stores a URL — no main-actor state mutation — so
    /// non-isolated construction is safe. The class itself stays
    /// `@MainActor`, so all instance methods remain main-actor-isolated.
    nonisolated init(directory: URL) {
        self.directory = directory
    }

    /// Returns the cached cards for `key`, or `nil` on any failure
    /// path (missing / corrupt / IO). Each failure path emits one
    /// `DiagnosticLogger` row tagged `.feed` so the cold-start trace
    /// records the outcome.
    func seedFromCache(key: String) async -> [BiliVideo]? {
        let result = await Task.detached(priority: .userInitiated) { [directory] in
            FeedCacheWarmer.read(directory: directory, key: key)
        }.value
        return result.toOptionalCards()
    }

    /// Synchronous file read — runs on a detached task. Kept private so
    /// callers can't accidentally do disk IO on the main actor.
    private static func read(directory: URL, key: String) -> FeedCacheResult {
        let url = directory.appendingPathComponent("\(key).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .corrupt(reason: "io") }
        // version: 1 — the first envelope format; bump on breaking changes
        // and the existing files will be rejected as `.corrupt(reason: "schema")`
        // until a migration runs.
        guard let envelope = try? JSONDecoder().decode(FeedSnapshotEnvelope.self, from: data),
              envelope.version == 1 else {
            return .corrupt(reason: "schema")
        }
        return .success(envelope.cards)
    }

    /// `Application Support/Paladala/`. Created on first access. Uses
    /// `try!` because the OS guarantees this directory is writable;
    /// failing here is unrecoverable.
    static var defaultDirectory: URL {
        let fm = FileManager.default
        let dir = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("Paladala", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// On-disk format for cached feed snapshots. `version` lets us evolve
/// the shape later without breaking older installs (the warmer rejects
/// mismatches as `.corrupt` so the view still boots into a network
/// state).
struct FeedSnapshotEnvelope: Codable {
    let version: Int
    let cards: [BiliVideo]
}

/// Bridge from the synchronous read result to the public async API.
/// Each non-success path emits a `DiagnosticLogger` row so the
/// cold-start log shows *why* the seed was skipped — important for
/// triaging why a cached first frame isn't appearing on a real device.
private extension FeedCacheResult {
    func toOptionalCards() -> [BiliVideo]? {
        switch self {
        case .success(let cards):
            return cards
        case .missing:
            DiagnosticLogger.shared.log(.feed, "seed_cache_unavailable",
                                        details: ["reason": "missing"])
            return nil
        case .corrupt(let reason):
            DiagnosticLogger.shared.log(.feed, "seed_cache_unavailable",
                                        details: ["reason": reason])
            return nil
        }
    }
}