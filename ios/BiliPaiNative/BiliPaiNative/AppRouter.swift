import Foundation
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable, Codable {
    case home
    case dynamic
    case live
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "首页"
        case .dynamic:
            return "动态"
        case .live:
            return "直播"
        case .profile:
            return "我的"
        }
    }

    var symbolName: String {
        switch self {
        case .home:
            return "house"
        case .dynamic:
            return "rectangle.stack"
        case .live:
            return "play.tv"
        case .profile:
            return "person.crop.circle"
        }
    }
}

enum ProfileRoute: Hashable {
    case history
    case favorites(mid: Int64)
    case watchLater
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: MainTab = .home
    @Published var path = NavigationPath()
    @Published var pendingSearchQuery = ""
    /// Set to `true` to present the login sheet. The sheet sets it back
    /// to `false` when it dismisses itself.
    @Published var isLoginSheetPresented = false

    func open(_ tab: MainTab) {
        selectedTab = tab
        path.removeLast(path.count)
    }

    func openVideo(_ video: BiliVideo) {
        IntentRecentVideoStore.record(video)
        path.append(video)
    }

    func open(_ route: ProfileRoute) {
        path.append(route)
    }

    func openSearch(_ query: String) {
        pendingSearchQuery = query
        selectedTab = .home
        path.removeLast(path.count)
    }

    func openLogin() {
        selectedTab = .profile
        isLoginSheetPresented = true
    }

    func consumePendingIntentRoute() {
        guard let route = IntentRouteStore.consumeRoute() else { return }
        switch route {
        case .tab(let tab):
            open(tab)
        case .search(let query):
            openSearch(query)
        case .video(let entity):
            selectedTab = .home
            path.removeLast(path.count)
            path.append(BiliVideo(
                bvid: entity.id,
                aid: 0,
                cid: 0,
                title: entity.title,
                ownerName: entity.ownerName,
                coverURL: nil,
                duration: 0,
                viewCount: 0,
                danmakuCount: 0,
                likeCount: 0,
                description: ""
            ))
        case .login:
            openLogin()
        }
    }
}
