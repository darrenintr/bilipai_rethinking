import SwiftUI

@main
struct BiliPaiNativeApp: App {
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView(repository: BiliPaiRepository(apiClient: BilibiliAPIClient()))
                .environmentObject(router)
                .tint(BiliPaiTheme.biliPink)
        }
    }
}
