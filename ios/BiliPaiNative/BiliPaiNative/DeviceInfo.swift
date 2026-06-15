//
//  DeviceInfo.swift
//  BiliPaiNative
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
    static let shared = DeviceInfo()

    @Published private(set) var networkType: String = "Unknown"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "BiliPai.deviceInfo.net")
    private var started = false

    private init() {}

    /// Start the path monitor.  Idempotent.  We call this from
    /// `BiliPaiNativeApp.init()` so the very first `.session`
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
            DispatchQueue.main.async {
                guard let self = self, self.networkType != type else { return }
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
