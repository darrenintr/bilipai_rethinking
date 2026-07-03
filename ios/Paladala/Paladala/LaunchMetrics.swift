import Foundation
import os.signpost

/// Public milestones emitted during the cold-start path.
///
/// Each value is the raw event name (also used as the signpost suffix
/// and the diagnostic-log message key). Adding a new case here is the
/// only edit needed to wire a new milestone — `mark(_:)` handles the
/// rest (signpost emit, diagnostic log, in-memory buffer, dump).
enum LaunchEvent: String, CaseIterable {
    case appInitStart             = "app_init_start"
    case appInitComplete          = "app_init_complete"
    case appDelegateStart         = "app_delegate_start"
    case appDelegateComplete      = "app_delegate_complete"
    case firstRootViewAppeared    = "first_root_view_appeared"
    case firstFeedNetworkStart    = "first_feed_network_start"
    case firstFeedNetworkComplete = "first_feed_network_complete"
}

/// One row in the cold-start JSONL dump. `elapsedMS` is measured from
/// the first `mark(_:)` call (anchored to `Mach_absolute_time()`) so
/// every milestone is a self-contained wall-clock value.
struct LaunchMilestone: Codable {
    let event: String
    let elapsedMS: Double
    let thread: String
}

/// Singleton, allocation-light launcher for cold-start instrumentation.
///
/// Why one sink for everything?
/// -----------------------------
/// The launch path is the only time we cannot afford to add
/// dependencies or `await` calls. `LaunchMetrics` is a struct-free,
/// lock-protected singleton whose `mark(_:)` does at most one
/// `mach_absolute_time` read, one allocation (`LaunchMilestone`),
/// one `OSSignposter.event`, and one `DiagnosticLogger.log` —
/// all O(1) and safe to call from any thread.
///
/// Three sinks:
/// 1. `OSSignposter` (subsystem `app.paladala.ios`, category
///    `ColdStart`) — visible in Instruments → Time Profiler
///    (Signposts template) and `xcrun xctrace record`.
/// 2. `DiagnosticLogger.shared.log(.app, …)` — visible in the
///    in-app `LogViewerView` / `DeepDiagnosticReportView`, filter
///    by category `APP`.
/// 3. In-memory `[LaunchMilestone]` buffer + `dumpColdStartReport()`
///    — writes JSONL to `Application Support/Paladala/cold-start.jsonl`
///    when the `PALADALA_COLD_START_DUMP=1` env var is set, so the
///    diagnostic dump is opt-in and never grows on devices that
///    haven't asked for it.
///
/// Subsystem string
/// ----------------
/// We use the literal `app.paladala.ios` rather than the bundle
/// identifier so the signpost is filterable in Instruments even
/// before `Bundle.main` is fully resolved (the signposter is a
/// `static let` initialised lazily on first access). The subsystem
/// has to be a compile-time constant.
final class LaunchMetrics {
    static let shared = LaunchMetrics()

    private let signposter = OSSignposter(
        subsystem: "app.paladala.ios",
        category: "ColdStart"
    )
    private var startMachTime: UInt64 = 0
    private let lock = NSLock()
    private var milestones: [LaunchMilestone] = []

    private init() {}

    /// Record a milestone. Safe to call from any thread. The first
    /// call anchors `startMachTime` to "now"; every subsequent call
    /// is a delta from that anchor in milliseconds.
    func mark(_ event: LaunchEvent) {
        let now = mach_absolute_time()
        let elapsedMS: Double
        let thread: String
        let milestone: LaunchMilestone

        lock.lock()
        if startMachTime == 0 { startMachTime = now }
        elapsedMS = Self.machTimeToMS(now - startMachTime)
        thread = Thread.isMainThread ? "main" : "bg"
        milestone = LaunchMilestone(
            event: event.rawValue,
            elapsedMS: elapsedMS,
            thread: thread
        )
        milestones.append(milestone)
        lock.unlock()

        // Sink 1: Instruments signpost.
        // `event(_:)` is the iOS 15+ point-event API — cheap,
        // no begin/end pairing required. Filter in Instruments
        // by subsystem `app.paladala.ios`, category `ColdStart`.
        //
        // `event(_:)` takes a `StaticString`, not a `String`,
        // so the name has to be a string literal — no
        // interpolation.  A switch is the cheapest way to
        // map each case to a literal without losing the
        // human-readable suffix in Instruments.
        switch event {
        case .appInitStart:
            signposter.event("ColdStart.app_init_start")
        case .appInitComplete:
            signposter.event("ColdStart.app_init_complete")
        case .appDelegateStart:
            signposter.event("ColdStart.app_delegate_start")
        case .appDelegateComplete:
            signposter.event("ColdStart.app_delegate_complete")
        case .firstRootViewAppeared:
            signposter.event("ColdStart.first_root_view_appeared")
        case .firstFeedNetworkStart:
            signposter.event("ColdStart.first_feed_network_start")
        case .firstFeedNetworkComplete:
            signposter.event("ColdStart.first_feed_network_complete")
        }

        // Sink 2: in-app log viewer. The `.app` category is
        // already documented as "launch / cold start" — no new
        // category needed. `elapsedMS` is the first detail so
        // it's easy to filter / sort.
        DiagnosticLogger.shared.log(
            .app,
            "launch.\(event.rawValue)",
            details: [
                "elapsedMS": String(format: "%.1f", elapsedMS),
                "thread": thread
            ]
        )
    }

    /// Write the milestone log to
    /// `Application Support/Paladala/cold-start.jsonl`.
    ///
    /// Called from `PaladalaApp.init` at the very end of the cold
    /// path, but only if the `PALADALA_COLD_START_DUMP=1` env var
    /// is set — so the file does not accumulate on devices that
    /// don't need it. The function is idempotent and safe to call
    /// from any thread.
    func dumpColdStartReport() {
        lock.lock()
        let snapshot = milestones
        lock.unlock()
        guard !snapshot.isEmpty else { return }

        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("Paladala", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent("cold-start.jsonl")

        // Pretty keys so a `cat` of the file is human-readable.
        // The file is small (<1 KB even with all 7 milestones) so
        // the byte overhead is irrelevant.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var lines: [String] = []
        for m in snapshot {
            guard let data = try? encoder.encode(m),
                  let s = String(data: data, encoding: .utf8) else { continue }
            lines.append(s)
        }
        let body = lines.joined(separator: "\n") + "\n"
        try? body.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - mach time → milliseconds

    /// Standard iOS pattern. `mach_timebase_info` returns the
    /// numerator/denominator pair that converts mach ticks to
    /// nanoseconds; dividing by 1_000_000 yields milliseconds.
    /// Computed once on first access and cached.
    private static let machTimeToMSFactor: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000
    }()

    private static func machTimeToMS(_ mach: UInt64) -> Double {
        Double(mach) * machTimeToMSFactor
    }
}
