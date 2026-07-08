import Foundation
import Combine

/// DiagnosticLogger for iOS — specialised for tracing complex issues.
///
/// Two stores, one shared source of truth
/// --------------------------------------
/// The legacy `Logger` (in `PaladalaApp.swift`) holds raw `bpLog`
/// output as plain strings, capped at 1000 entries, in memory only.
/// `DiagnosticLogger` is the structured counterpart: typed `Event`s
/// with categories, a smaller in-memory ring buffer, and a richer
/// `generateReport()` that includes a system-info header and a tail
/// of the bpLog buffer.
///
/// Every call to `diagLog(...)` also forwards to `bpLog(...)` (see
/// `log(_:_:details:)` below), so the two stores stay correlated —
/// the in-app log viewer (and the deep diagnostic report) show both
/// in chronological order.
///
/// Disk persistence
/// ----------------
/// On `init()` we rehydrate the in-memory ring from
/// `Application Support/Paladala/log.jsonl`.  Each line is a JSON
/// object — see the private `LogEntry` below.  On every `log()` we
/// append the new entry to the same file via a serial dispatch
/// queue, so the file survives app restarts and force-quits.  At
/// every rehydrate we prune entries older than 24 h (user-decided
/// retention).
final class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()

    enum Category: String, CaseIterable {
        // 5 original categories.  Existing call sites in
        // AVPlayerController, BilibiliAPIClient, ViewModels,
        // LocalHLSProxyServer, and VideoDetailView keep using
        // these — do NOT rename, do NOT reorder.
        case recommendation = "RECO"
        case playback = "PLAY"
        case fullscreen = "FULL"
        case auth = "AUTH"
        case network = "NETW"
        // New categories for the v2 log viewer.
        case app = "APP"        // launch / cold start
        case system = "SYS"     // one-shot device info snapshots
        case lifecycle = "LC"   // scenePhase transitions
        case session = "SES"    // network-type transitions, AuthStore.refresh
        case download = "DOWN"  // DownloadManager + DownloadStore lifecycle
        case music = "MUSIC"    // MusicHomeView / MusicPlayerView
        case notification = "NOTI"  // FollowNotificationService / BG-task lifecycle
        case feed = "FEED"      // FeedCacheWarmer seed-cache lifecycle
        case proxy = "PROXY"    // LocalHLSProxyServer — stop logs, range
                                // requests, Content-Range responses,
                                // 5xx cleanup, lifecycle.
                                // (PR-B Commit 6 build fix — Commit 1
                                // added diagLog(.proxy, ...) in 8 sites
                                // without declaring the category)
        case audio = "AUDIO"    // AVAudioSession setCategory / setActive
                                // failures (PR-B Commit 5 build fix —
                                // B15 added diagLog(.audio, ...) without
                                // declaring the category)
    }

    struct Event: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: Category
        let message: String
        let details: [String: Any]?

        func format() -> String {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            let timeStr = df.string(from: timestamp)
            var detailStr = ""
            if let details = details, !details.isEmpty {
                detailStr = " | \(details)"
            }
            return "[\(timeStr)] [\(category.rawValue)] \(message)\(detailStr)"
        }
    }

    @Published private(set) var events: [Event] = []
    /// In-memory ring buffer cap.  The on-disk JSONL keeps 24 h
    /// of history regardless of this number; the cap is just to
    /// stop the SwiftUI list from being scrolled through
    /// thousands of rows.
    private let maxEvents = 500
    private let lock = NSLock()
    /// Serial queue for disk writes.  Keeps the in-memory
    /// @Published update on the main thread (cheap) and the
    /// file append off it (file I/O can stall).
    private let diskQueue = DispatchQueue(
        label: "Paladala.diaglog.disk", qos: .utility
    )
    private static let logFilePath: String = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        // Keep the storage directory stable so existing diagnostic history
        // survives the user-facing Paladala rename.
        let dir = support.appendingPathComponent("Paladala", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("log.jsonl").path
    }()
    private static let retentionInterval: TimeInterval = 24 * 3600

    private init() {
        // Defer disk read to avoid blocking init (which may be on the
        // main thread).  Events start empty; the background read
        // populates them once it finishes.
        diskQueue.async { [weak self] in
            let rehydrated = self?.loadEventsFromDisk() ?? []
            DispatchQueue.main.async {
                self?.events = rehydrated
            }
        }
    }

    /// Load events from the on-disk JSONL.  Runs on `diskQueue`.
    private func loadEventsFromDisk() -> [Event] {
        guard FileManager.default.fileExists(atPath: Self.logFilePath) else { return [] }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.logFilePath)),
              let str = String(data: data, encoding: .utf8) else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.retentionInterval)
        var rehydrated: [Event] = []
        for line in str.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(LogEntry.self, from: lineData),
                  entry.timestamp >= cutoff else { continue }
            guard let category = Category(rawValue: entry.category) else { continue }
            let details = entry.details?.mapValues { $0 as Any }
            rehydrated.append(Event(
                timestamp: entry.timestamp,
                category: category,
                message: entry.message,
                details: details
            ))
        }
        if rehydrated.count > maxEvents {
            rehydrated.removeFirst(rehydrated.count - maxEvents)
        }
        return rehydrated
    }

    // MARK: - public API

    func log(_ category: Category, _ message: String, details: [String: Any]? = nil) {
        let event = Event(timestamp: Date(), category: category, message: message, details: details)

        // Always forward to bpLog so the simple log buffer
        // (which is exported via the existing "运行日志"
        // path) gets a copy of every diag event.
        bpLog("[\(category.rawValue)] \(message) \(details ?? [:])")

        // All @Published mutations must happen on main.  Many
        // existing call sites (URLSession callbacks, AVPlayer
        // notifications) run on background queues, so we
        // dispatch the array mutation to main rather than
        // touching the @Published var directly.  The
        // `objectWillChange` fire is automatic when the
        // setter runs.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.events.append(event)
            if self.events.count > self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents)
            }
            self.lock.unlock()
        }

        appendToDisk(event: event)
    }

    /// Build the deep diagnostic report.  MUST be called from the
    /// main actor (the bpLog tail read in particular requires
    /// main-queue affinity because `Logger.shared.logs` is
    /// mutated on main without a lock).
    @MainActor
    func generateReport(activeAccount: StoredAccount? = nil) -> String {
        lock.lock()
        let currentEvents = events
        lock.unlock()

        let info = DeviceInfo.shared.snapshot(activeAccount: activeAccount)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let reportTime = df.string(from: Date())

        var report = ""
        report += "========================================\n"
        report += "Paladala iOS Deep Diagnostic Report\n"
        report += "Generated at: \(reportTime)\n"
        report += "========================================\n\n"

        report += "----- System Info -----\n"
        for (k, v) in info {
            report += "\(k): \(v)\n"
        }
        report += "\n"

        let lifecycle = currentEvents.filter {
            $0.category == .lifecycle || $0.category == .app
        }
        report += "----- Lifecycle (\(lifecycle.count)) -----\n"
        for e in lifecycle {
            report += e.format() + "\n"
        }
        report += "\n"

        let network = currentEvents.filter { $0.category == .session }
        report += "----- Network / session (\(network.count)) -----\n"
        for e in network {
            report += e.format() + "\n"
        }
        report += "\n"

        let diagOnly = currentEvents.filter {
            $0.category != .lifecycle && $0.category != .app
                && $0.category != .session && $0.category != .download
        }
        report += "----- Diagnostic events (\(diagOnly.count)) -----\n"
        for e in diagOnly {
            report += e.format() + "\n"
        }
        report += "\n"

        // Downloads — surface both the live in-memory state
        // (so a "stuck at 75%" report can show exactly
        // which segments landed) and the on-disk layout
        // (so the user can tell whether the staging dir
        // has the bytes the manifest claims it does).
        let downloadEvents = currentEvents.filter { $0.category == .download }
        report += "----- Downloads -----\n"
        report += "Diagnostic events (download): \(downloadEvents.count)\n"
        for e in downloadEvents.suffix(60) {
            report += e.format() + "\n"
        }
        report += "\n"
        let storeSnapshot = DownloadStore.shared.records
        report += "DownloadStore records: \(storeSnapshot.count)\n"
        for record in storeSnapshot {
            report += "  • \(record.bvid) — \"\(record.title)\""
            report += " — \(record.sizeBytes) bytes"
            report += " — downloaded \(record.downloadedAt)\n"
        }
        let inFlight = Array(DownloadManager.shared.stateByBvid.keys)
        report += "In-flight bvids: \(inFlight)\n"
        for bvid in inFlight {
            let state = DownloadManager.shared.stateByBvid[bvid]
            let progress = DownloadManager.shared.progress[bvid] ?? 0
            switch state {
            case .downloading:
                report += "  • \(bvid) — downloading \(Int(progress * 100))%\n"
            case .failed(let msg):
                report += "  • \(bvid) — failed: \(msg)\n"
            case .downloaded:
                report += "  • \(bvid) — downloaded\n"
            case .notDownloaded:
                report += "  • \(bvid) — notDownloaded\n"
            case .none:
                break
            }
        }
        // On-disk layout — the user-visible Downloads list
        // depends on `manifest.json` matching the bytes on
        // disk.  Dump both so we can spot drift.
        let manifestExists = FileManager.default.fileExists(
            atPath: DownloadStore.manifestURL.path
        )
        report += "Manifest at \(DownloadStore.manifestURL.path): "
        report += manifestExists ? "present" : "absent"
        report += "\n"
        let fm = FileManager.default
        func dirSize(_ url: URL) -> Int64 {
            guard let enumerator = fm.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey]
            ) else { return 0 }
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                if let size = (try? fileURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ))?.totalFileAllocatedSize {
                    total += Int64(size)
                }
            }
            return total
        }
        let inProgressSize = dirSize(DownloadStore.inProgressURL)
        let readySize = dirSize(DownloadStore.readyURL)
        report += "in_progress/ total bytes: \(inProgressSize)\n"
        report += "ready/ total bytes: \(readySize)\n"
        // Enumerate the in_progress dir so we can see what
        // half-finished downloads have on disk even if they
        // never reached the manifest.
        if let contents = try? fm.contentsOfDirectory(
            at: DownloadStore.inProgressURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for bvDir in contents {
                let size = dirSize(bvDir)
                report += "  staging \(bvDir.lastPathComponent): \(size) bytes\n"
            }
        }
        report += "\n"

        // bpLog tail — read the simple log buffer.  We slice
        // the last 100 lines so the report stays bounded.
        let bpTail = Array(Logger.shared.logs.suffix(100))
        report += "----- bpLog tail (last \(bpTail.count)) -----\n"
        for line in bpTail {
            report += line + "\n"
        }
        report += "\n"

        report += "========================================\n"
        report += "END OF REPORT\n"
        report += "========================================\n"
        return report
    }

    @MainActor
    func export(activeAccount: StoredAccount? = nil) -> URL? {
        // generateReport is @MainActor; called from a button on the
        // main thread — direct call is safe (implicitly on MainActor).
        let report = generateReport(activeAccount: activeAccount)
        let fileName = "Paladala_Diagnostic_\(Int(Date().timeIntervalSince1970)).txt"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        do {
            try report.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            // PR-B D10: route the export failure through
            // bpLog so it appears in the in-app log viewer
            // (and survives into the next diagnostic dump)
            // instead of being a one-shot stderr line that
            // gets lost the moment the OSLog buffer rolls.
            bpLog("Failed to export diagnostic report: \(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    func clearHistory() {
        lock.lock()
        events.removeAll()
        lock.unlock()
        diskQueue.async { [path = Self.logFilePath] in
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - disk persistence

    private func appendToDisk(event: Event) {
        let entry = LogEntry(
            timestamp: event.timestamp,
            category: event.category.rawValue,
            message: event.message,
            details: event.details?.mapValues { String(describing: $0) }
        )
        guard let lineData = try? JSONEncoder().encode(entry) else { return }
        var line = lineData
        line.append(0x0A)  // '\n'
        diskQueue.async { [path = Self.logFilePath] in
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                // File does not exist — create it.
                try? line.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

// MARK: - on-disk shape

/// Codable mirror of `DiagnosticLogger.Event` for JSONL persistence.
/// `details: [String: String]?` is the [String: Any] cast through
/// `String(describing:)` so we can round-trip through JSON.
private struct LogEntry: Codable {
    let timestamp: Date
    let category: String
    let message: String
    let details: [String: String]?
}

// Global helper for quick logging
func diagLog(_ category: DiagnosticLogger.Category, _ message: String, details: [String: Any]? = nil) {
    DiagnosticLogger.shared.log(category, message, details: details)
}
