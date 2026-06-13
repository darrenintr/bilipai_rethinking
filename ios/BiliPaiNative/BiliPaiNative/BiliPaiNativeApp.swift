import AVFoundation
import SwiftUI

@main
struct BiliPaiNativeApp: App {
    @StateObject private var router = AppRouter()
    @AppStorage("bilipai.themeMode") private var themeMode: ThemeMode = .system

    init() {
        PlayerAudioSession.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView(repository: BiliPaiRepository(apiClient: BilibiliAPIClient()))
                .environmentObject(router)
                .tint(BiliPaiTheme.biliPink)
                .preferredColorScheme(themeMode.colorScheme)
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
            NSLog("BiliPai: failed to activate audio session: \(error)")
        }
    }
}
