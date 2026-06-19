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
            return "首頁"
        case .dynamic:
            return "動態"
        case .live:
            return "直播"
        case .profile:
            return "我的"
        }
    }

    /// SF Symbols used in the iPad sidebar (`PadRootView`). The
    /// phone tab bar still uses `tabBarItem-symbol` via
    /// `Label(... systemImage:)` so we keep `rectangle.stack` /
    /// `play.tv` for `PhoneRootView` and only customise the
    /// sidebar render through `sidebarSymbolName`.
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

    /// Filled/high-contrast variants that match the new sidebar
    /// design: a solid pink house for the active 首頁 pill, a
    /// compass/scope for 動態, a radiating-wave glyph for 直播,
    /// and a circle-person badge for the 我的 card.
    var sidebarSymbolName: String {
        switch self {
        case .home:
            return "house.fill"
        case .dynamic:
            return "safari"
        case .live:
            return "dot.radiowaves.left.and.right"
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

/// Live playback navigation. The associated `BiliLiveRoom` carries the
/// room identity (id/title) that `LivePlayerView` needs while it
/// resolves the playable stream URLs. We push the room — not a
/// pre-resolved `BiliLivePlayback` — because resolving the playback
/// requires a network call and the route value type should be a
/// small, cheap-to-`Hashable` snapshot.
enum LiveRoute: Hashable {
    case room(BiliLiveRoom)
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: MainTab = .home
    @Published var path = NavigationPath()
    @Published var pendingSearchQuery = ""
    /// One-shot: when the iPad sidebar taps "Trends" we don't add
    /// a new `MainTab` case (that would pollute the iPhone tab bar)
    /// — instead we hop to `.home` and stash a category hint that
    /// `HomeView.task` reads on the next reload. The field is then
    /// cleared so a later tab swap doesn't surprise the user.
    @Published var pendingHomeCategory: HomeCategory?
    /// Tracks which ProfileRoute (if any) the iPad sidebar last
    /// pushed onto the profile tab. Used to light up the right
    /// sidebar item (Collections / History / Settings) when the
    /// user is parked on the profile tab. Cleared on `open(_ tab:)`
    /// when leaving the profile tab.
    @Published var activeProfileSection: ProfileRoute?
    /// Drives the red dot on the iPad top-bar bell. Hard-coded to
    /// `1` so the badge is always visible; swap to a real count
    /// when the notification pipeline lands.
    @Published var notificationCount: Int = 1
    /// Set to `true` to present the login sheet. The sheet sets it back
    /// to `false` when it dismisses itself.
    @Published var isLoginSheetPresented = false

    func open(_ tab: MainTab) {
        selectedTab = tab
        path.removeLast(path.count)
        // Leaving the profile tab — clear the sub-section marker
        // so the sidebar reverts to lighting up the Settings row
        // when the user comes back via the main tap.
        if tab != .profile {
            activeProfileSection = nil
        }
    }

    func openVideo(_ video: BiliVideo) {
        IntentRecentVideoStore.record(video)
        path.append(video)
    }

    func openReplies(video: BiliVideo, root: BiliComment) {
        path.append(ReplyRoute(video: video, rootComment: root))
    }

    func open(_ route: ProfileRoute) {
        path.append(route)
    }

    /// Open the live player for `room`. Switches to the 直播 tab and
    /// pushes `LiveRoute.room(room)` onto the navigation stack so the
    /// existing `LiveRoomsView` `.navigationDestination(for:)` resolves
    /// and presents the new `LivePlayerView`.
    func openLive(_ room: BiliLiveRoom) {
        selectedTab = .live
        path.append(LiveRoute.room(room))
    }

    func openSearch(_ query: String) {
        pendingSearchQuery = query
        selectedTab = .home
        path.removeLast(path.count)
    }

    /// Sidebar "Trends" tap. Switches to the home tab and leaves a
    /// hint for `HomeView.task` to swap `model.category` to `.popular`
    /// on the next refresh. Does nothing on top of the current state
    /// if the user is already parked on Home.
    func openHomeTrending() {
        pendingHomeCategory = .popular
        selectedTab = .home
        path.removeLast(path.count)
    }

    /// Sidebar "Collections" tap. Routes to the user's favorite
    /// folders; requires a logged-in account with a non-zero `mid`.
    func openCollections(mid: Int64) {
        guard mid > 0 else {
            // Not signed in — fall through to the profile tab so
            // the user sees the login prompt instead of an empty
            // folder list.
            openLogin()
            return
        }
        selectedTab = .profile
        path.removeLast(path.count)
        path.append(ProfileRoute.favorites(mid: mid))
        activeProfileSection = .favorites(mid: mid)
    }

    /// Sidebar "History" tap. The History endpoint reads the active
    /// session cookie, so no `mid` is required; we just push the
    /// route onto the profile tab.
    func openHistory() {
        selectedTab = .profile
        path.removeLast(path.count)
        path.append(ProfileRoute.history)
        activeProfileSection = .history
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
