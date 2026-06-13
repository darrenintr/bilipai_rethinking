import AVFoundation
import SwiftUI

@main
struct BiliPaiNativeApp: App {
    @StateObject private var router = AppRouter()
    @StateObject private var authStore = AuthStore()
    @StateObject private var repository: BiliPaiRepository
    @AppStorage("bilipai.themeMode") private var themeMode: ThemeMode = .system

    init() {
        PlayerAudioSession.activate()
        let client = BilibiliAPIClient()
        let repo = BiliPaiRepository(apiClient: client)
        client.cookieProvider = nil
        _repository = StateObject(wrappedValue: repo)
    }

    var body: some Scene {
        WindowGroup {
            RootView(repository: repository)
                .environmentObject(router)
                .environmentObject(authStore)
                .environmentObject(repository)
                .tint(BiliPaiTheme.biliPink)
                .preferredColorScheme(themeMode.colorScheme)
                .onAppear {
                    repository.apiClient.cookieProvider = { [weak authStore] in
                        authStore?.activeAccount?.cookieHeader
                    }
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
    
    func log(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] [\(fileName):\(line)] \(message)"
        
        DispatchQueue.main.async {
            if self.logs.isEmpty {
                self.logs.append("[BiliPai Session Start]")
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
        
        let fileName = "BiliPai_Logs_\(Int(Date().timeIntervalSince1970)).txt"
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
