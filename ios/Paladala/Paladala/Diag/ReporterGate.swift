//
//  ReporterGate.swift
//  Paladala
//
//  Decides whether a `DiagnosticLogger.log(...)` call is
//  reportable to the Paladala Portal.  Conservative filter —
//  only fires for categories the user cares about AND when
//  the details dict carries a recognisable error signal.
//
//  Categories covered:
//    .network, .auth, .playback, .download, .proxy, .audio
//
//  Categories deliberately excluded:
//    .app         (logs include routine events, would flood)
//    .system      (one-shot device info, not an error)
//    .lifecycle   (scenePhase transitions)
//    .session     (network-type changes)
//    .reco, .full (legacy UI categories; not errors)
//    .music, .noti, .feed, .bgmi  (not error streams)
//
//  AppErrorCenter goes through its own gate (effectively
//  always-fire when called) — see ErrorSink.swift.
//

import Foundation

enum ReporterGate {
    /// True when a DiagnosticLogger.log call should produce a
    /// Portal report.  Used by `ErrorSink.maybeReport(...)`.
    static func shouldReport(category: DiagnosticLogger.Category,
                             details: [String: Any]?) -> Bool {
        // Only categories in the reportable set.
        switch category {
        case .network, .auth, .playback, .download, .proxy, .audio:
            break
        default:
            return false
        }
        // Only when the details dict actually carries an error
        // signal — otherwise we'd fire on every routine
        // `diagLog(.network, "DNS cache cleared")` etc.
        let errorKeys: Set<String> = ["error", "err", "status", "exception", "fatal"]
        let keys = (details?.keys ?? []).map { $0.lowercased() }
        return keys.contains { errorKeys.contains($0) }
    }
}