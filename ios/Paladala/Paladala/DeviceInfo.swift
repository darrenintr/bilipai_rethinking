//
//  DeviceInfo.swift
//  Paladala
//
//  Snapshots system + network state for the diagnostic report and
//  the in-app log viewer.  Lives next to `DiagnosticLogger` so the
//  two share a "system context" story without one reaching into
//  the other's @MainActor isolation.
//
//  Two things live here:
//   1. A `NWPathMonitor` that publishes the current network type
//      (Wi-Fi / Cellular / Ethernet / Offline) and emits a
//      `.session` diagLog event whenever it changes.
//   2. A `snapshot(activeAccount:)` that returns the system info
//      header consumed by `DiagnosticLogger.generateReport()`.
//
//  Everything that touches UIKit (`UIDevice.current.model` etc.)
//  must be on the main actor — that's why this class is
//  `@MainActor`.  The path monitor itself delivers updates on a
//  private dispatch queue; we hop to main before mutating
//  `networkType`.
//

import Foundation
import Network
import Combine
import UIKit

@MainActor
final class DeviceInfo: ObservableObject {
    // PR-C Task 5: mark the singleton `nonisolated` so
    // non-MainActor call sites (`BilibiliAPIClient.init`,
    // `WbiSigner.prewarm`, etc.) can read `userAgent`
    // without first hopping to the main actor.  The init is
    // private and the static is a `let`, so this is safe —
    // there is no other place that can write to the
    // reference.
    nonisolated static let shared = DeviceInfo()

    @Published private(set) var networkType: String = "Unknown"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "Paladala.deviceInfo.net")
    private var started = false

    // `nonisolated` lets the singleton's `static let shared`
    // initialiser run from any context.  Body is empty so
    // there is no MainActor state touched.
    nonisolated private init() {}

    /// User-Agent string for outbound HTTP requests. Composed at
    /// runtime from the live iOS version so it stays accurate
    /// across iOS upgrades (the previous hard-coded "iOS 18.0"
    /// string became inaccurate the moment the user upgraded).
    /// Uses the bilibili "bili-universal/iphone" format that the
    /// official iOS client uses — bilibili servers fingerprint
    /// non-standard UAs.
    nonisolated var userAgent: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let iosVersion = "\(version.majorVersion).\(version.minorVersion)"
        return "bili-universal/iphone (iPhone; iOS \(iosVersion); Scale/3.00)"
    }

    /// Start the path monitor.  Idempotent.  We call this from
    /// `PaladalaApp.init()` so the very first `.session`
    /// event ("network.changed") is captured even if the user
    /// never opens the log viewer.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let type: String
            switch path.status {
            case .satisfied:
                if path.usesInterfaceType(.wifi) {
                    type = "Wi-Fi"
                } else if path.usesInterfaceType(.cellular) {
                    type = "Cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    type = "Ethernet"
                } else {
                    type = "Other"
                }
            default:
                type = "Offline"
            }
            // PR-C Task 3: hop to the main actor with structured
            // concurrency instead of DispatchQueue.main.async. The
            // class is @MainActor so the mutation must run on the
            // main actor; the path monitor delivers callbacks on
            // its private dispatch queue. [weak self] keeps the
            // Task from retaining the singleton past deinit (a
            // no-op today since DeviceInfo is a singleton, but
            // cheap insurance for any future refactor that makes
            // the lifecycle shorter).
            Task { @MainActor [weak self] in
                guard let self, self.networkType != type else { return }
                self.networkType = type
                diagLog(.session, "network.changed", details: ["type": type])
            }
        }
        monitor.start(queue: queue)
    }

    /// System info snapshot, formatted as the report's "System
    /// Info" section.  The active account is passed in by the
    /// caller so this method (which is on the main actor) does
    /// not have to reach into the @MainActor `AuthStore`.
    func snapshot(activeAccount: StoredAccount? = nil) -> [(String, String)] {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        let ios = ProcessInfo.processInfo.operatingSystemVersionString
        let device = UIDevice.current.model
        let systemName = UIDevice.current.systemName
        let locale = Locale.current.identifier
        let tz = TimeZone.current.identifier
        let net = networkType
        let account: String
        if let a = activeAccount {
            account = "\(a.name) (mid=\(a.mid))"
        } else {
            account = "(not signed in)"
        }
        return [
            ("App version", "\(version) (\(build))"),
            ("iOS", ios),
            ("Device", "\(device) (\(systemName))"),
            ("Locale", locale),
            ("Network", net),
            ("Timezone", tz),
            ("Active account", account)
        ]
    }
}
