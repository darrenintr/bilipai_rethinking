import AppIntents
import Foundation

enum BiliPaiDestination: String, AppEnum {
    case home
    case dynamic
    case live
    case settings

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "BiliPai Destination")
    static var caseDisplayRepresentations: [BiliPaiDestination: DisplayRepresentation] = [
        .home: "Home",
        .dynamic: "Dynamic",
        .live: "Live",
        .settings: "Settings"
    ]

    var tab: MainTab {
        switch self {
        case .home:
            return .home
        case .dynamic:
            return .dynamic
        case .live:
            return .live
        case .settings:
            return .profile
        }
    }
}

struct OpenBiliPaiDestinationIntent: AppIntent {
    static var title: LocalizedStringResource = "Open BiliPai"
    static var description = IntentDescription("Open BiliPai to a useful destination.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Destination")
    var destination: BiliPaiDestination

    init() {
        destination = .home
    }

    init(destination: BiliPaiDestination) {
        self.destination = destination
    }

    func perform() async throws -> some IntentResult {
        IntentRouteStore.store(.tab(destination.tab))
        return .result()
    }
}

struct SearchBiliPaiIntent: AppIntent {
    static var title: LocalizedStringResource = "Search BiliPai"
    static var description = IntentDescription("Search public Bilibili videos inside BiliPai.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Keyword")
    var keyword: String

    init() {
        keyword = ""
    }

    init(keyword: String) {
        self.keyword = keyword
    }

    func perform() async throws -> some IntentResult {
        IntentRouteStore.store(.search(keyword))
        return .result()
    }
}

struct ContinueWatchingIntent: AppIntent {
    static var title: LocalizedStringResource = "Continue Watching"
    static var description = IntentDescription("Open the most recent BiliPai video.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        if let entity = IntentRecentVideoStore.recentVideos().first {
            IntentRouteStore.store(.video(entity))
        } else {
            IntentRouteStore.store(.tab(.home))
        }
        return .result()
    }
}

struct AddVideoToWatchLaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to BiliPai Watch Later"
    static var description = IntentDescription("Save a recent BiliPai video to the local Watch Later list.")

    @Parameter(title: "Video")
    var video: BiliPaiVideoEntity

    init() {
        video = BiliPaiVideoEntity(id: "", title: "Recent Video", ownerName: "")
    }

    init(video: BiliPaiVideoEntity) {
        self.video = video
    }

    func perform() async throws -> some IntentResult {
        IntentRecentVideoStore.addWatchLater(video)
        return .result()
    }
}

struct BiliPaiVideoEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "BiliPai Video")
    static var defaultQuery = BiliPaiVideoQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Uploader")
    var ownerName: String

    init(id: String, title: String, ownerName: String) {
        self.id = id
        self.title = title
        self.ownerName = ownerName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: ownerName.isEmpty ? nil : "\(ownerName)",
            image: .init(systemName: "play.rectangle")
        )
    }

    var video: BiliVideo {
        BiliVideo(
            bvid: id,
            aid: 0,
            cid: 0,
            title: title,
            ownerName: ownerName,
            coverURL: nil,
            duration: 0,
            viewCount: 0,
            danmakuCount: 0,
            likeCount: 0,
            description: ""
        )
    }
}

struct BiliPaiVideoQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [BiliPaiVideoEntity] {
        let all = IntentRecentVideoStore.recentVideos() + IntentRecentVideoStore.watchLaterVideos()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [BiliPaiVideoEntity] {
        IntentRecentVideoStore.recentVideos()
    }
}

struct BiliPaiShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .pink

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenBiliPaiDestinationIntent(destination: .home),
            phrases: [
                "Open \(.applicationName)",
                "Open home in \(.applicationName)"
            ],
            shortTitle: "Open BiliPai",
            systemImageName: "play.rectangle"
        )
        AppShortcut(
            intent: SearchBiliPaiIntent(),
            phrases: [
                "Search \(\.$keyword) in \(.applicationName)"
            ],
            shortTitle: "Search BiliPai",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: ContinueWatchingIntent(),
            phrases: [
                "Continue watching in \(.applicationName)"
            ],
            shortTitle: "Continue Watching",
            systemImageName: "play.circle"
        )
    }
}

enum IntentRoute {
    case tab(MainTab)
    case search(String)
    case video(BiliPaiVideoEntity)
}

enum IntentRouteStore {
    private static let pendingRouteKey = "bilipai.intent.pendingRoute"

    static func store(_ route: IntentRoute) {
        let payload: IntentRoutePayload
        switch route {
        case .tab(let tab):
            payload = IntentRoutePayload(kind: "tab", tab: tab, query: nil, video: nil)
        case .search(let query):
            payload = IntentRoutePayload(kind: "search", tab: nil, query: query, video: nil)
        case .video(let entity):
            payload = IntentRoutePayload(kind: "video", tab: nil, query: nil, video: BiliPaiVideoRecord(entity: entity))
        }
        let data = try? JSONEncoder().encode(payload)
        UserDefaults.standard.set(data, forKey: pendingRouteKey)
    }

    static func consumeRoute() -> IntentRoute? {
        guard let data = UserDefaults.standard.data(forKey: pendingRouteKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingRouteKey)
        guard let payload = try? JSONDecoder().decode(IntentRoutePayload.self, from: data) else { return nil }
        switch payload.kind {
        case "tab":
            return payload.tab.map(IntentRoute.tab)
        case "search":
            return payload.query.map(IntentRoute.search)
        case "video":
            return payload.video.map { .video($0.entity) }
        default:
            return nil
        }
    }
}

private struct IntentRoutePayload: Codable {
    let kind: String
    let tab: MainTab?
    let query: String?
    let video: BiliPaiVideoRecord?
}

private struct BiliPaiVideoRecord: Codable {
    let id: String
    let title: String
    let ownerName: String

    init(entity: BiliPaiVideoEntity) {
        id = entity.id
        title = entity.title
        ownerName = entity.ownerName
    }

    var entity: BiliPaiVideoEntity {
        BiliPaiVideoEntity(id: id, title: title, ownerName: ownerName)
    }
}

enum IntentRecentVideoStore {
    private static let recentKey = "bilipai.intent.recentVideos"
    private static let watchLaterKey = "bilipai.intent.watchLaterVideos"

    static func record(_ video: BiliVideo) {
        guard !video.bvid.isEmpty else { return }
        let entity = BiliPaiVideoEntity(id: video.bvid, title: video.title, ownerName: video.ownerName)
        var videos = recentVideos().filter { $0.id != entity.id }
        videos.insert(entity, at: 0)
        save(videos.prefix(10).map { $0 }, key: recentKey)
    }

    static func recentVideos() -> [BiliPaiVideoEntity] {
        load(key: recentKey)
    }

    static func addWatchLater(_ video: BiliPaiVideoEntity) {
        guard !video.id.isEmpty else { return }
        var videos = watchLaterVideos().filter { $0.id != video.id }
        videos.insert(video, at: 0)
        save(videos, key: watchLaterKey)
    }

    static func watchLaterVideos() -> [BiliPaiVideoEntity] {
        load(key: watchLaterKey)
    }

    private static func load(key: String) -> [BiliPaiVideoEntity] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return ((try? JSONDecoder().decode([BiliPaiVideoRecord].self, from: data)) ?? []).map(\.entity)
    }

    private static func save(_ videos: [BiliPaiVideoEntity], key: String) {
        let data = try? JSONEncoder().encode(videos.map(BiliPaiVideoRecord.init(entity:)))
        UserDefaults.standard.set(data, forKey: key)
    }
}
