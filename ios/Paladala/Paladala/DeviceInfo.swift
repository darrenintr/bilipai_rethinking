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

    /// B 站 device-fingerprint cookie (`buvid3`). Persisted in
    /// `UserDefaults` because the value must survive across
    /// reinstalls on iOS 26 (whose Keychain retains unsigned-IPA
    /// entries across uninstall — a behavior change from iOS 18
    /// and earlier). `UserDefaults` is wiped with the app bundle,
    /// so the first launch after a reinstall will refresh the
    /// value via `BilibiliAuthAPI.fetchDeviceID()`.
    ///
    /// The previous implementation in `BilibiliAPIClient
    /// .generateMobileBuvid()` used a hard-coded
    /// `"Paladala-iOS-Device-Seed"` shared by every install; B
    /// 站 server fingerprints that seed and silently gates
    /// comment content for anonymous users. The Mac browser,
    /// iPhone official app, and iPad Safari all use a unique
    /// per-install buvid3 fetched from
    /// `/x/frontend/finger/spi` on first launch; Paladala
    /// needs to do the same to escape the silent-gate.
    nonisolated static let buvid3DefaultsKey = "paladala.device.buvid3"
    nonisolated static let buvid4DefaultsKey = "paladala.device.buvid4"

    /// Thread-safe read of the persisted buvid3. Callers in
    /// non-MainActor contexts (e.g. `BilibiliAPIClient.get`)
    /// can use this without hopping to the main actor. Returns
    /// `nil` on first launch / after a fresh install.
    nonisolated var persistedBuvid3: String? {
        UserDefaults.standard.string(forKey: Self.buvid3DefaultsKey)
    }

    /// Persist a freshly-fetched SPI device-fingerprint pair.
    /// `MainActor` because the underlying `UserDefaults` write
    /// should be serialised with the rest of the @MainActor
    /// state mutations during the launch sequence.
    @MainActor
    func setBuvids(buvid3: String, buvid4: String) {
        UserDefaults.standard.set(buvid3, forKey: Self.buvid3DefaultsKey)
        UserDefaults.standard.set(buvid4, forKey: Self.buvid4DefaultsKey)
        bpLog("DeviceInfo: buvid3 captured, length=\(buvid3.count)")
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "Paladala.deviceInfo.net")
    private var started = false

    // `nonisolated` lets the singleton's `static let shared`
    // initialiser run from any context.  Body is empty so
    // there is no MainActor state touched.
    nonisolated private init() {}

    /// User-Agent string for outbound HTTP requests. Switched
    /// from the bilibili-specific `bili-universal/iphone` shape
    /// to an iOS-Safari Mobile shape on 2026-08-03 after
    /// diagnostic evidence: B站 server fingerprints
    /// `bili-universal/iphone` as a third-party client and
    /// silently gates comment content (200 OK with a valid
    /// cursor but `replies: null`). The cross-reference
    /// open-source client `guozhigq/pilipala` (Flutter, also
    /// unsigned, also running on URLSession) reaches the same
    /// comments endpoint with this iOS-Safari Mobile UA and
    /// gets the real reply list. Same network stack, different
    /// UA — that's the only meaningful delta. The web client
    /// and the official iOS app use the same iOS-Safari
    /// Mobile shape (verified 2026-08-03 from a Mac browser
    /// and an iPhone running the official app on the same IP
    /// as the failing install: both work).
    nonisolated var userAgent: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let iosVersion = "\(version.majorVersion).\(version.minorVersion)"
        // 18_0 / 18.0 / 15E148 matches the iOS-Safari Mobile
        // shape `pilipala` ships in `Request.headerUa(type:
        // 'mob')` for `Platform.isIOS`. B站's client-fingerprint
        // logic appears to use the WebKit/605 + Safari/604
        // signature to classify "real mobile browser / real
        // official iOS client" vs. third-party native clients
        // (which would normally ship `bili-universal/...` or
        // a custom UA).
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(iosVersion.replace(".", "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(iosVersion) Mobile/15E148 Safari/604.1"
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
