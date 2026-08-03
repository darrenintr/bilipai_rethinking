//
//  LogReporterConfig.swift
//  Paladala
//
//  xcconfig-driven configuration for the Paladala Portal reporter.
//  Reads build settings via `ProcessInfo.processInfo.environment`,
//  which Xcode populates from .xcconfig files attached to each
//  build configuration via `baseConfigurationReference`.
//
//  See `ios/Paladala/Config/Opspad.xcconfig.example` for the
//  full layout and secret-generation recipe.
//

import Foundation

enum LogReporterConfig {
    /// xcconfig-driven.  Empty string means: do not upload
    /// (toggle off OR build misconfigured — same effect).
    static var sharedSecret: String {
        ProcessInfo.processInfo.environment["OPSPAD_HMAC_SECRET"] ?? ""
    }

    /// xcconfig-driven.  Defaults to `wrangler dev`'s port.
    static var endpoint: URL {
        let raw = ProcessInfo.processInfo.environment["OPSPAD_ENDPOINT"]
            ?? "http://localhost:8787"
        return URL(string: raw)!
    }

    /// xcconfig-driven.  UserDefaults key the Settings toggle
    /// writes to.  Only override if you need to fork namespace.
    static var enabledKey: String {
        ProcessInfo.processInfo.environment["OPSPAD_ENABLED_KEY"]
            ?? "diag.ops.enabled"
    }

    /// User-facing state.  Defaults to OFF (UserDefaults.bool
    /// returns false for missing keys, which is the desired
    /// first-launch behaviour).
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static let batchSize: Int = 25
    static let flushInterval: TimeInterval = 30
    static let maxRetries: Int = 3
    static let requestTimeout: TimeInterval = 15
    static let userAgent: String = "Paladala-iOS/\(AppVersion.current.versionLine)"
}