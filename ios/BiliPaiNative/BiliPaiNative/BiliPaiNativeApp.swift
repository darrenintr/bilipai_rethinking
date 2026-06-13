import AVFoundation
import SwiftUI

@main
struct BiliPaiNativeApp: App {
    @StateObject private var router = AppRouter()
    @StateObject private var authStore = AuthStore()
    @AppStorage("bilipai.themeMode") private var themeMode: ThemeMode = .system

    private let repository: BiliPaiRepository

    init() {
        PlayerAudioSession.activate()
        // Build the API client + repository with a cookie provider that
        // reads the live `AuthStore` on every request. We can't capture
        // `self.authStore` here because it isn't constructed yet — the
        // `wireAuth(_:)` call below re-binds the closure after the
        // `StateObject` is up.
        let client = BilibiliAPIClient()
        let repo = BiliPaiRepository(apiClient: client)
        client.cookieProvider = nil // re-bound in onAppear below
        self.repository = repo
    }

    var body: some Scene {
        WindowGroup {
            RootView(repository: repository)
                .environmentObject(router)
                .environmentObject(authStore)
                .tint(BiliPaiTheme.biliPink)
                .preferredColorScheme(themeMode.colorScheme)
                .onAppear {
                    // Now that `authStore` exists as an `@StateObject`,
                    // we can read `activeAccount.cookieHeader` lazily on
                    // each API call.
                    repository.apiClient.cookieProvider = { [weak authStore] in
                        authStore?.activeAccount?.cookieHeader
                    }
                }
        }
    }
}

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
