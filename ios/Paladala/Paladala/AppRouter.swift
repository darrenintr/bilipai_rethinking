import Foundation
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable, Codable {
    case home
    case dynamic
    case live
    case music
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
        case .music:
            return "音樂"
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
        case .music:
            return "music.note"
        case .profile:
            return "person.crop.circle"
        }
    }

    /// Filled/high-contrast variants that match the new sidebar
    /// design: a solid pink house for the active 首頁 pill, a
    /// compass/scope for 動態, a radiating-wave glyph for 直播,
    /// a filled music-note glyph for 音樂, and a circle-person
    /// badge for the 我的 card.
    var sidebarSymbolName: String {
        switch self {
        case .home:
            return "house.fill"
        case .dynamic:
            return "safari"
        case .live:
            return "dot.radiowaves.left.and.right"
        case .music:
            return "music.note"
        case .profile:
            return "person.crop.circle"
        }
    }
}

enum ProfileRoute: Hashable {
    case history
    case favorites(mid: Int64)
    case watchLater
    /// Offline downloads list. Pushed when the user taps
    /// the "离线缓存" quick action on the profile screen.
    /// No associated value — the destination view reads
    /// `DownloadStore.shared.records` directly.
    case downloads
}

/// Local (downloaded) video playback.  The associated
/// `DownloadRecord` carries the full DASH source the proxy
/// needs to serve the on-disk bytes — no upstream network
/// call is made for this kind of playback, so the player
/// path has to know it is opening a local file before it
/// even asks the proxy to start.
enum LocalVideoRoute: Hashable {
    case local(DownloadRecord)
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
    /// Set to `true` to present the login sheet. The sheet sets it back
    /// to `false` when it dismisses itself.
    @Published var isLoginSheetPresented = false

    /// Open the music player for `video`. Switches to the 音樂
    /// tab and pushes `MusicRoute.player(video)` onto the path
    /// so the existing `.navigationDestination(for:)` machinery
    /// resolves it into a `MusicPlayerView`.
    func openMusic(_ video: BiliVideo) {
        selectedTab = .music
        path.append(MusicRoute.player(video))
    }

    func open(_ tab: MainTab) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            selectedTab = tab
            path.removeLast(path.count)
        }
        Haptics.selection()
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

    func openLogin() {
        selectedTab = .profile
        isLoginSheetPresented = true
    }

    /// Open a downloaded video for offline playback.  Switches
    /// to the home tab (so the user lands inside the same
    /// `NavigationStack` as regular videos) and pushes a
    /// `LocalVideoRoute.local(record)` onto the path.  The
    /// `RootView` resolves the route into a `VideoDetailView`
    /// whose `BiliPlayback.localContext` is set from the
    /// record.
    func openLocalVideo(_ record: DownloadRecord) {
        selectedTab = .home
        path.append(LocalVideoRoute.local(record))
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
                description: "",
                ownerMid: 0
            ))
        case .login:
            openLogin()
        }
    }
}
