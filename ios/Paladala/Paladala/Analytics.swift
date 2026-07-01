// Firebase imports removed — Firebase is not in the Podfile.
// All functions are stubbed to bpLog until Firebase is added.
// To re-enable Firebase analytics, add back the imports and
// restore the original function bodies.
import Foundation

/// Thin facade mirroring the existing `bpLog` / `diagLog` style.
///
/// Every analytics / crashlytics call in the app goes through this
/// enum so we can later swap the backend (Firebase → Sentry →
/// self-hosted) without touching call sites.
///
/// Stub implementation: all calls log locally via `bpLog` until
/// Firebase is restored.
enum Analytics {
    private static let optInKey = "analytics.optIn"

    /// Stub: logs the event to the local diagnostic log.
    static func log(_ name: String, _ params: [String: Any] = [:]) {
        guard UserDefaults.standard.bool(forKey: optInKey) else { return }
        bpLog("[Analytics] \(name) \(params)")
    }

    /// Stub: logs the error to the local diagnostic log.
    static func recordError(_ error: Error, context: String) {
        guard UserDefaults.standard.bool(forKey: optInKey) else { return }
        bpLog("[Analytics] error (\(context)): \(error)")
    }

    /// Stub: logs the breadcrumb to the local diagnostic log.
    static func breadcrumb(_ category: String, _ message: String) {
        guard UserDefaults.standard.bool(forKey: optInKey) else { return }
        bpLog("[Analytics] [\(category)] \(message)")
    }
}
