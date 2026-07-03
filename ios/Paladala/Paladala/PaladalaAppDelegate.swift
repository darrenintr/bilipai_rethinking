import FirebaseCore
import MetricKit
import UIKit

/// App delegate wired via `@UIApplicationDelegateAdaptor` in
/// `PaladalaApp`.  The only reason the iOS app needs an
/// `AppDelegate` at all is to forward the
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
/// callback to `DownloadManager` — `URLSessionConfiguration.background`
/// is the only session type the system wakes a suspended
/// app to deliver, and the wake event arrives on the
/// `UIApplicationDelegate`, not on the `URLSessionDelegate`.
///
/// The completion handler is the system's signal that "all
/// of the background session's pending events have been
/// delivered; you can suspend again".  We MUST call it
/// exactly once per wake, otherwise the system assumes we
/// are still doing work and keeps the app foregrounded,
/// burning battery.
///
/// Also conforms to `MXMetricManagerSubscriber` so the system
/// delivers `MXAppLaunchMetric` payloads (real-user cold-start
/// times) at next foreground after a 24 h collection window.
/// See `didReceive(_:completionHandler:)` below.
final class PaladalaAppDelegate: NSObject, UIApplicationDelegate, MXMetricManagerSubscriber {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        LaunchMetrics.shared.mark(.appDelegateStart)
        // Boot Firebase first so the very first analytics event
        // (`app_launch` from `PaladalaApp.init`) finds a
        // configured SDK. We deliberately do NOT read the opt-in
        // toggle here — `Analytics.log` reads it per call and
        // silently no-ops when the toggle is off, so Firebase can
        // safely initialise regardless of the user's preference.
        FirebaseApp.configure()
        // Force `DownloadStore.shared` to initialise here so
        // its `records` array is hydrated before SwiftUI body
        // renders.  Hydration runs synchronously inside
        // `init()` (the manifest is ~200 bytes per record,
        // well under 5 ms for hundreds of entries).  Without
        // this touch, the `VideoDetailViewModel.load()`
        // local-first branch could race a still-empty
        // `records` when the user tapped a Home-feed video
        // before the old async hydration completed — the
        // symptom was "offline launch, AVPlayer never starts,
        // cascade of -999 cancelled errors" in the
        // diagnostic log.
        _ = DownloadStore.shared
        // Subscribe to MetricKit payloads (cold-start histograms,
        // hang rates, etc.).  The system delivers aggregated
        // payloads from the previous 24 h at the next app
        // foreground, so this captures real-user launch times
        // without us having to ship our own analytics for that.
        MXMetricManager.shared.add(self)
        // Bootstrap the download manager at launch so the
        // system has time to resume any in-flight tasks
        // from a prior run before we attach the delegate.
        // `bootstrap()` is idempotent.
        Task { @MainActor in
            DownloadManager.shared.bootstrap()
        }
        LaunchMetrics.shared.mark(.appDelegateComplete)
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // The system wakes us with this callback when one
        // of our background sessions has finished its work
        // (or the system has new events for it).  We do not
        // need to inspect `identifier` — the app only has
        // one background session, and `DownloadManager` is
        // the only consumer.  Forward the completion
        // handler; `DownloadManager.urlSessionDidFinishEvents`
        // fires it once all delegate events have been
        // drained.
        guard identifier == DownloadManager.sessionIdentifier else {
            // Unknown session — fire the handler so the
            // system can suspend us anyway.
            completionHandler()
            return
        }
        Task { @MainActor in
            DownloadManager.shared.attachBackgroundCompletionHandler(
                completionHandler
            )
        }
    }

    // MARK: - MXMetricManagerSubscriber

    /// Called by `MXMetricManager` once per day with aggregated
    /// metrics from the previous 24 h.  We forward any
    /// `MXAppLaunchMetric` payloads to `DiagnosticLogger` so the
    /// in-app log viewer / `cold-start.jsonl` can show real-user
    /// cold-start distributions, not just our own milestones.
    func didReceive(
        _ payloads: [MXMetricPayload],
        completionHandler: @escaping () -> Void
    ) {
        for payload in payloads {
            let launches = payload.applicationLaunchMetrics
            guard !launches.isEmpty else { continue }
            // Log one summary row per launch metric.  Buckets
            // are aggregated server-side; we report the bucket
            // count and total sample count so the log is
            // scannable, and the full histogram is recoverable
            // from `payload.jsonRepresentation()` if needed.
            //
            // Only `histogrammedTimeToFirstDraw` is reported
            // here — it is the canonical "cold start" histogram
            // and the one that maps to the milestones
            // `LaunchMetrics` emits.  Other histograms
            // (`histogrammedTimeToFirstDrawOptimized` on
            // iOS 16+, `histogrammedApplicationResumeTime`
            // for background → foreground) are still accessible
            // via the full payload if needed.
            for (i, launch) in launches.enumerated() {
                let ttfd = launch.histogrammedTimeToFirstDraw
                DiagnosticLogger.shared.log(
                    .app,
                    "metric_kit.app_launch",
                    details: [
                        "index": i,
                        "payloadTimeBegin": ISO8601DateFormatter().string(from: payload.timeStampBegin),
                        "payloadTimeEnd": ISO8601DateFormatter().string(from: payload.timeStampEnd),
                        "ttfdBuckets": ttfd.totalBucketCount.description
                    ]
                )
            }
        }
        completionHandler()
    }
}
