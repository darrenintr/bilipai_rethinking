import FirebaseCore
import UIKit

/// App delegate wired via `@UIApplicationDelegateAdaptor` in
/// `BiliPaiNativeApp`.  The only reason the iOS app needs an
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
final class BiliPaiAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Boot Firebase first so the very first analytics event
        // (`app_launch` from `BiliPaiNativeApp.init`) finds a
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
        // Bootstrap the download manager at launch so the
        // system has time to resume any in-flight tasks
        // from a prior run before we attach the delegate.
        // `bootstrap()` is idempotent.
        Task { @MainActor in
            DownloadManager.shared.bootstrap()
        }
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
}
