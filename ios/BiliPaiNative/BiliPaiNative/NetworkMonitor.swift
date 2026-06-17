import Combine
import Network
import SwiftUI

/// Reachability monitor backed by `NWPathMonitor`. Exposes a single
/// `@Published var isOnline: Bool` that the rest of the app reads via
/// `@EnvironmentObject`.
///
/// The `pathUpdateHandler` is called on a background queue. We hop to
/// `@MainActor` and debounce updates by 400ms so a flapping connection
/// does not flicker the offline banner in the UI. The monitor is
/// started in `init` and cancelled in `deinit`, which is enough for
/// the lifetime of the app (`NetworkMonitor` is a `@StateObject` in
/// `BiliPaiNativeApp` and lives as long as the process does).
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.bilipai.network-monitor", qos: .utility)
    private var debounceTask: Task<Void, Never>?
    private var didStart = false

    init() {
        // `NWPathMonitor.start(queue:)` is safe to call from any
        // thread; the path update handler runs on the queue we pass
        // in. We default `isOnline` to `true` because that's the
        // typical device state on first launch — a user with no
        // network on first launch will see the banner pop in after
        // the first path update.
        start()
    }

    deinit {
        monitor.cancel()
    }

    private func start() {
        guard !didStart else { return }
        didStart = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.debounceTask?.cancel()
                self.debounceTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard let self, !Task.isCancelled else { return }
                    if self.isOnline != online {
                        self.isOnline = online
                        diagLog(.network, "isOnline changed", details: ["online": online])
                    }
                }
            }
        }
        monitor.start(queue: queue)
    }
}

/// Slim offline banner shown at the top of `RootView` when the
/// `NetworkMonitor` reports `isOnline == false`. Uses
/// `.ultraThinMaterial` so the banner reads as glass on top of the
/// content. The banner is for *display only* — tapping it is a no-op
/// for now; the user can pull-to-refresh on the feed tabs to retry.
struct OfflineBanner: View {
    @EnvironmentObject private var monitor: NetworkMonitor

    var body: some View {
        if !monitor.isOnline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                Text("当前离线 · 显示缓存内容")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前离线,显示缓存内容")
        }
    }
}
