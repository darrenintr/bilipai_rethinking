import AVFoundation
import SwiftUI

@main
struct PaladalaApp: App {
    @UIApplicationDelegateAdaptor(PaladalaAppDelegate.self) private var appDelegate
    @StateObject private var router = AppRouter()
    @StateObject private var authStore = AuthStore()
    @StateObject private var repository: PaladalaRepository
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var miniPlayerStore = MiniPlayerStore()
    @AppStorage("paladala.themeMode") private var themeMode: ThemeMode = .system
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    @AppStorage("paladala.glassMigrationVersion") private var glassMigrationVersion = 0

    init() {
        LaunchMetrics.shared.mark(.appInitStart)
        // Audio session activation moved out of `init()` —
        // it now happens lazily inside `PlayerController.init`
        // (gated by a one-shot flag), so a cold start that
        // never opens a video never touches the audio HAL.
        let client = BilibiliAPIClient()
        // Pre-warm WbiSigner keys off the launch critical
        // path.  The first signed API request (typically the
        // home feed) used to pay a synchronous round-trip to
        // `/x/web-interface/nav`; with this fire-and-forget
        // task the keys are usually cached by the time the
        // feed view kicks off its network load.
        Task.detached(priority: .userInitiated) {
            await BilibiliAPIClient.prewarmWbiKeys()
        }
        // PR-A Task 10: pre-warm the HLS proxy listener off the
        // launch critical path. The first video tap would
        // otherwise pay the listener-startup cost synchronously
        // (audit item #8). The .proxyListenerReady mark is
        // emitted here, not inside prewarmProxyServer itself, so
        // the milestone measures the actual ready time as seen
        // by the app, not the time the call returned.
        LaunchMetrics.shared.mark(.proxyListenerRequested)
        Task.detached(priority: .userInitiated) {
            await LocalHLSProxyServer.prewarmProxyServer()
            LaunchMetrics.shared.mark(.proxyListenerReady)
        }
        let repo = PaladalaRepository(apiClient: client)
        // Do NOT clear `cookieProvider` here — the wired closure is
        // installed in `body.onAppear` below. Clearing it in `init`
        // opens a window where the first API request goes out
        // anonymously, which the user perceives as "logged out on
        // every fresh launch" until onAppear fires.
        _repository = StateObject(wrappedValue: repo)
        // Log the cold start so the diagnostic report has a
        // clear "the session started here" anchor.  Also start
        // the network monitor now so the first `.session` event
        // ("network.changed type=Wi-Fi") is captured even if the
        // user never opens the log viewer.
        diagLog(.app, "app.launch", details: [
            "marketingVersion":
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "?",
            "build":
                Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "?"
        ])
        DeviceInfo.shared.startIfNeeded()
        LaunchMetrics.shared.mark(.appInitComplete)
        // If the user opted in via the `PALADALA_COLD_START_DUMP=1`
        // env var (e.g. in the Xcode scheme for a perf run), write
        // the milestone log to `Application Support/Paladala/cold-start.jsonl`
        // on a background queue. The dump is opt-in so production
        // devices never accumulate the file.
        if ProcessInfo.processInfo.environment["PALADALA_COLD_START_DUMP"] == "1" {
            DispatchQueue.global(qos: .utility).async {
                LaunchMetrics.shared.dumpColdStartReport()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(repository: repository)
                .environmentObject(router)
                .environmentObject(authStore)
                .environmentObject(repository)
                .environmentObject(networkMonitor)
                .environmentObject(miniPlayerStore)
                .tint(PaladalaTheme.biliPink)
                .preferredColorScheme(themeMode.colorScheme)
                .onAppear {
                    if glassMigrationVersion < 1 {
                        materialDesign = .liquidGlass
                        glassMigrationVersion = 1
                    }

                    // Defensive re-hydration: in case the first render
                    // happened before `@StateObject` had a chance to
                    // run `AuthStore.bootstrap()` (e.g. when the
                    // SwiftUI view is mounted in the same runloop
                    // tick as the App init), re-read the persisted
                    // account list from the Keychain here. This is
                    // a single, cheap read and guarantees
                    // `activeAccount` is populated before the
                    // cookieProvider closure captures it.
                    authStore.bootstrap()

                    repository.apiClient.cookieProvider = { [weak authStore] in
                        authStore?.activeAccount?.cookieHeader
                    }
                    // The App API uses `buvid3` + `mid` to return a
                    // personalised feed. The closure is re-evaluated on
                    // every recommend call, so switching accounts in
                    // `ProfileSettingsView` immediately takes effect.
                    repository.apiClient.appConfigProvider = { [weak authStore] in
                        guard let account = authStore?.activeAccount else { return nil }
                        return BiliAppConfig(buvid3: account.buvid3, mid: account.mid, csrf: account.csrf)
                    }
                    // Hook the follow-notification BG-task handler.
                    // Must happen after the cookieProvider is
                    // installed so the BG poll can decide whether
                    // the user is signed in. Idempotent — calling
                    // twice just re-registers the same handler.
                    FollowNotificationService.shared.bootstrap(
                        repository: repository,
                        accountMid: authStore.activeAccount?.mid ?? 0
                    )
                    // When the upstream API returns 401 the user is
                    // effectively logged out (B站 rotates SESSDATA
                    // every ~30 days). Pop the login sheet on the
                    // first 401 of a burst — the API client latches
                    // the failure so we only show the sheet once,
                    // and `AuthStore.completeLogin` resets the latch
                    // so the *next* session-expiry can re-fire.
                    repository.onSessionExpired { [weak router] in
                        router?.openLogin()
                    }

                    // iCloud preference mirror: idempotent bootstrap
                    // that subscribes to remote-change notifications
                    // and asks the system for an initial sync. The
                    // store itself decides whether a real iCloud
                    // account is signed in and exposes
                    // `isAvailable` so the settings toggle can
                    // render a hint when the user is not signed in.
                    ICloudSync.shared.bootstrap()
                }
                // Invalidate the follow-feed's cached followings set
                // whenever the active account changes. Without this,
                // switching to a new account would still apply the
                // previous account's follow filter on the next load
                // of the 关注 tab.
                .onReceive(authStore.$activeAccount) { newAccount in
                    if newAccount != nil {
                        repository.invalidateFollowingsCache()
                    }
                }
                // Forward cross-view login requests (posted by
                // `PlayerView` when a live 403 surfaces the
                // "重新登录" recovery button) to the AppRouter.
                // Posting through NotificationCenter is the only
                // way to bubble an action out of an `AVPlayer`
                // overlay that doesn't hold the AppRouter
                // EnvironmentObject.
                .onReceive(NotificationCenter.default.publisher(
                    for: .paladalaRequestOpenLogin
                )) { _ in
                    router.openLogin()
                }
        }
    }
}

// MARK: - Logger

final class Logger: ObservableObject {
    static let shared = Logger()

    @Published private(set) var logs: [String] = []
    private let maxLogs = 1000

    private init() {}

    /// `ISO8601DateFormatter` is expensive to instantiate
    /// (CFDateFormatter + locale resolution under the hood)
    /// and `Logger.log(...)` is on the launch hot path via
    /// `bpLog`.  One per process — `DateFormatter` instances
    /// are documented as thread-safe for `string(from:)`.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let timestamp = Self.timestampFormatter.string(from: Date())
        let logEntry = "[\(timestamp)] [\(fileName):\(line)] \(message)"

        DispatchQueue.main.async {
            if self.logs.isEmpty {
                self.logs.append("[Paladala Session Start]")
            }
            self.logs.append(logEntry)
            if self.logs.count > self.maxLogs {
                self.logs.removeFirst()
            }
            print(logEntry)
        }
    }
    
    func export() -> URL? {
        let allLogs = logs.joined(separator: "\n")
        if allLogs.isEmpty { return nil }
        
        let fileName = "Paladala_Logs_\(Int(Date().timeIntervalSince1970)).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try allLogs.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            print("Failed to export logs: \(error.localizedDescription)")
            return nil
        }
    }
    
    func copyToClipboard() {
        let allLogs = logs.joined(separator: "\n")
        UIPasteboard.general.string = allLogs
    }

    func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
}

func bpLog(_ message: String, file: String = #file, line: Int = #line) {
    Logger.shared.log(message, file: file, line: line)
}

// MARK: - Audio Session

enum PlayerAudioSession {
    /// Configure the shared audio session for video playback. Must be called once
    /// at app launch so the system allocates an appropriate route and so the
    /// player can keep rendering audio after the screen locks or the app moves
    /// to the background (when background-audio capability is added).
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true, options: [])
        } catch {
            // Audio session failures are non-fatal for the UI shell — log and
            // continue. The player will still attempt playback, it just may
            // not produce sound on first run.
            bpLog("failed to activate audio session: \(error)")
        }
    }
}
