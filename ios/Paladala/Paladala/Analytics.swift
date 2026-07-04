// Firebase has been fully removed from the project.  The
// `Analytics` facade below is a thin `bpLog` wrapper that
// preserves the call-site signature so any future analytics
// backend can be slotted in without touching the call sites.
import Foundation

/// Thin facade mirroring the existing `bpLog` / `diagLog` style.
///
/// Every analytics call in the app goes through this enum so a
/// future backend (Sentry, self-hosted, etc.) can be slotted in
/// without touching call sites.
///
/// No-op implementation: all calls log locally via `bpLog` when
/// the `analytics.optIn` toggle is on.  When the toggle is off,
/// they return immediately — this is the production default.
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
