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
        // Bootstrap the download manager at launch so the
        // system has time to resume any in-flight tasks
        // from a prior run before we attach the delegate.
        // `bootstrap()` is idempotent.
        Task { @MainActor in
            DownloadManager.shared.bootstrap()
            DownloadStore.shared.loadFromDisk()
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
