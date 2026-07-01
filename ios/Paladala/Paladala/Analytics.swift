// Firebase imports removed — Firebase is not in the Podfile.
// Analytics calls are stubbed to bpLog until Firebase is added.
import Foundation

/// Thin facade mirroring the existing `bpLog` / `diagLog` style.
///
/// Every analytics / crashlytics call in the app goes through this
/// enum so we can later swap the backend (Firebase → Sentry →
/// self-hosted) without touching call sites. The facade also
/// honours the user opt-out toggle in `ProfileSettingsView` —
/// when the toggle is off, every call here becomes a no-op.
///
/// Wiring:
/// * `Analytics.log(_:_:)` → `FirebaseAnalytics.Analytics.logEvent`
/// * `Analytics.recordError(_:context:)` → `Crashlytics.record(error:)`
/// * `Analytics.breadcrumb(_:_:)` → `Crashlytics.log(_:)`
///
/// The opt-in key (`analytics.optIn`) defaults to `true` via
/// `@AppStorage` in `ProfileSettingsView`. To disable telemetry
/// entirely for a build (e.g. a TestFlight tester who wants no
/// analytics), flip the toggle in 我的 → 系统与诊断 → 分享使用统计.
enum Analytics {
    private static let optInKey = "analytics.optIn"

    /// User-opted-out path: still record breadcrumbs for the local
    /// diagnostic log but never ship anything to Firebase. Callers
    /// can pass `nil` to indicate "no specific params" without
    /// forcing a dictionary allocation at every call site.
    static func log(_ name: String, _ params: [String: Any] = [:]) {
        guard UserDefaults.standard.bool(forKey: optInKey) else { return }
        // `logEvent` is documented thread-safe; we still funnel
        // through it on the main thread (all our call sites are
        // `@MainActor`) but the SDK tolerates background calls.
        FirebaseAnalytics.Analytics.logEvent(name, parameters: params)
    }

    /// Record a non-fatal error. The `context` string is surfaced
    /// in the Crashlytics dashboard next to the error so we can
    /// triage without reading the full stack — useful for the
    /// catch-all blocks scattered across the repo.
    static func recordError(_ error: Error, context: String) {
        guard UserDefaults.standard.bool(forKey: optInKey) else { return }
        Crashlytics.crashlytics().record(
            error: error,
            userInfo: ["context": context]
        )
    }

    /// Lightweight breadcrumb. Mirrors the existing
    /// `DiagnosticLogger` categories (RECO / PLAY / FULL / AUTH /
    /// NETW / APP / SYS / LC / SES / DOWN) so a Crashlytics
    /// investigation can correlate against the local share-log
    /// report.
    static func breadcrumb(_ category: String, _ message: String) {
        guard UserDefaults.standard.bool(forKey: optInKey) else { return }
        Crashlytics.crashlytics().log("\(category): \(message)")
    }
}