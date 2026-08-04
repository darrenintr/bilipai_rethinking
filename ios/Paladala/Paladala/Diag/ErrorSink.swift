//
//  ErrorSink.swift
//  Paladala
//
//  Single chokepoint for "should I report this error to the
//  Paladala Portal?".  Called from two existing private log
//  methods after their existing `bpLog` / `diagLog` calls —
//  the only additive change to AppErrorCenter.swift and
//  DiagnosticLogger.swift in Phase 2.
//
//  Always fire-and-forget: never blocks the caller.  The
//  LogReporter actor handles batching, signing, and retry.
//

import Foundation
import UIKit

enum ErrorSink {
    /// From `AppErrorCenter.log(descriptor:source:context:presented:)`.
    /// AppErrorCenter only fires for normalised user-facing
    /// errors (BilibiliAPIError / URLError / DecodingError /
    /// CocoaError), so we always report.
    ///
    /// `@MainActor` is required because we read
    /// `UIDevice.current.systemVersion` / `UIDevice.current.model`,
    /// which Swift 6 marks as main-actor-isolated. Both callers
    /// (`AppErrorCenter.log` and `DiagnosticLogger.log`) already
    /// run on the main thread in practice (see DiagnosticLogger's
    /// "@Published mutations must happen on main" comment), so
    /// promoting the requirement from implicit to explicit is
    /// just a compile-time annotation, not a behaviour change.
    @MainActor
    static func maybeReport(descriptor: AppErrorDescriptor,
                            context: String,
                            source: Error) {
        guard LogReporterConfig.enabled,
              !LogReporterConfig.sharedSecret.isEmpty
        else { return }
        let details: [String: Any] = [
            "kind": descriptor.kind.rawValue,
            "context": context,
            "retryable": descriptor.isRetryable,
            "error": String(describing: source)
        ]
        // Worker zod schema requires `app_build` to match
        // X.Y.Z.N (e.g. "0.5.1.301").  `AppVersion.current
        // .versionLine` returns "0.5.1 (2)" for the About
        // page — wrong shape.  Construct the dotted form
        // ourselves.
        let marketing = AppVersion.current.marketingVersion
        let build = AppVersion.current.buildNumber
        let appBuild = "\(marketing).\(build)"
        let payload = ReportPayload(
            app_build: appBuild,
            app_version: marketing,
            os_version: "iOS \(UIDevice.current.systemVersion)",
            error_class: String(describing: type(of: source)),
            message: descriptor.message,
            device_model: UIDevice.current.model,
            locale: Locale.current.identifier,
            session_id: LogReporter.shared.currentSessionID,
            stacktrace: nil,
            raw: ReportRaw.from(details: details)
        )
        Task.detached(priority: .utility) {
            await LogReporter.shared.ingest(payload)
        }
    }

    /// From `DiagnosticLogger.log(_:_:details:)`.  Filtered
    /// by `ReporterGate.shouldReport(...)`.
    /// See the first overload for why this is `@MainActor`.
    @MainActor
    static func maybeReport(category: DiagnosticLogger.Category,
                            message: String,
                            details: [String: Any]?) {
        guard LogReporterConfig.enabled,
              !LogReporterConfig.sharedSecret.isEmpty
        else { return }
        guard ReporterGate.shouldReport(category: category, details: details)
        else { return }
        // Worker zod requires `app_build` to match X.Y.Z.N.
        // `AppVersion.current.versionLine` returns "0.5.1 (2)"
        // for the About page — construct the dotted form.
        let marketing = AppVersion.current.marketingVersion
        let build = AppVersion.current.buildNumber
        let appBuild = "\(marketing).\(build)"
        let payload = ReportPayload(
            app_build: appBuild,
            app_version: marketing,
            os_version: "iOS \(UIDevice.current.systemVersion)",
            error_class: category.rawValue,
            message: message,
            device_model: UIDevice.current.model,
            locale: Locale.current.identifier,
            session_id: LogReporter.shared.currentSessionID,
            stacktrace: nil,
            raw: details.map { ReportRaw.from(details: $0) } ?? nil
        )
        Task.detached(priority: .utility) {
            await LogReporter.shared.ingest(payload)
        }
    }
}