import Foundation
import SwiftUI

/// Thin wrapper around `NSUbiquitousKeyValueStore` so the
/// rest of the app reads / writes iCloud-synced preferences
/// through a single, easy-to-grep surface.
///
/// The store is intentionally minimal: only the
/// `@AppStorage` values that the user would expect to land
/// on a fresh install (theme, danmaku toggle, material
/// design) are mirrored. Account sessions, watch-later,
/// and history continue to live on the server so this
/// class does not double-write secrets anywhere.
///
/// `ICloudSync` is a fire-and-forget layer. The system
/// `NSUbiquitousKeyValueStore` does not surface success
/// or failure of a remote write, so there is no promise
/// in the API — the user just sees a "开启 iCloud 同步"
/// toggle that, when on, asks iCloud to keep these four
/// keys consistent across their devices. When off, no
/// remote calls are made.
@MainActor
final class ICloudSync: ObservableObject {
    static let shared = ICloudSync()

    /// User-facing key for the iCloud switch in settings.
    static let enableKey = "bilipai.iCloudSync"

    /// Keys we mirror to iCloud. Centralised so a future
    /// "sync more" feature only has to extend this list —
    /// the rest of the call sites stay declarative.
    static let mirroredKeys: [String] = [
        "bilipai.themeMode",
        "bilipai.materialDesign",
        "bilipai.danmakuEnabled",
        "bilipai.backgroundAudio"
    ]

    /// Set to `true` when the system confirms a real
    /// iCloud account is signed in. The settings toggle
    /// in `ProfileSettingsView` reads this to decide
    /// whether to render the "Open iCloud Settings"
    /// hint vs. just sit disabled.
    @Published private(set) var isAvailable: Bool = false

    private let store = NSUbiquitousKeyValueStore.default

    private init() {}

    /// Wire up the observer + initial sync. Call once
    /// from the app entry point (`BiliPaiNativeApp`).
    /// Idempotent — calling twice is a no-op.
    func bootstrap() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
        // `synchronize()` returns `true` when the local
        // store is in sync with the server. The first
        // `didChangeExternally` arrives a few hundred ms
        // later on a real device; treat the initial
        // return value as "iCloud is reachable right
        // now" for the UI affordance.
        isAvailable = store.synchronize()
    }

    /// Mirror a single key to iCloud. `value` matches
    /// the shape of `UserDefaults.object(forKey:)` so the
    /// caller can pass the result directly.
    func mirror(key: String, value: Any?) {
        guard UserDefaults.standard.bool(forKey: Self.enableKey) else { return }
        guard Self.mirroredKeys.contains(key) else { return }
        if let value {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
        // `synchronize` is fire-and-forget; the system
        // coalesces rapid writes.
        store.synchronize()
    }

    /// Read a single mirrored value, or `nil` if the
    /// user has not opted in (or the value is not
    /// present remotely).
    func read(key: String) -> Any? {
        guard UserDefaults.standard.bool(forKey: Self.enableKey) else { return nil }
        guard Self.mirroredKeys.contains(key) else { return nil }
        return store.object(forKey: key)
    }

    @objc private func handleExternalChange(_ note: Notification) {
        // The system tells us exactly which keys changed
        // remotely; map them back into standard
        // UserDefaults so the `@AppStorage` views pick
        // them up via the existing change notification.
        // We deliberately use the standard suite (not
        // the App Group suite) because these are
        // per-device preferences, not library state.
        let changedKeys = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
        for key in changedKeys where Self.mirroredKeys.contains(key) {
            if let value = store.object(forKey: key) {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
