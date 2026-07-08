import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum PaladalaDestination: String, AppEnum {
    case home
    case dynamic
    case live
    case settings

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Paladala Destination")
    static var caseDisplayRepresentations: [PaladalaDestination: DisplayRepresentation] = [
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

struct OpenPaladalaDestinationIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Paladala"
    static var description = IntentDescription("Open Paladala to a useful destination.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Destination")
    var destination: PaladalaDestination

    init() {
        destination = .home
    }

    init(destination: PaladalaDestination) {
        self.destination = destination
    }

    func perform() async throws -> some IntentResult {
        IntentRouteStore.store(.tab(destination.tab))
        return .result()
    }
}

struct SearchPaladalaIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Paladala"
    static var description = IntentDescription("Search public Bilibili videos inside Paladala.")
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

struct OpenPaladalaSearchIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Paladala Search"
    static var description = IntentDescription("Open Paladala to the video search field.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        IntentRouteStore.store(.search(""))
        return .result()
    }
}

struct ContinueWatchingIntent: AppIntent {
    static var title: LocalizedStringResource = "Continue Watching"
    static var description = IntentDescription("Open the most recent Paladala video.")
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
    static var title: LocalizedStringResource = "Add to Paladala Watch Later"
    static var description = IntentDescription("Save a recent Paladala video to the local Watch Later list.")

    @Parameter(title: "Video")
    var video: PaladalaVideoEntity

    init() {
        video = PaladalaVideoEntity(id: "", title: "Recent Video", ownerName: "")
    }

    init(video: PaladalaVideoEntity) {
        self.video = video
    }

    func perform() async throws -> some IntentResult {
        IntentRecentVideoStore.addWatchLater(video)
        return .result()
    }
}

struct PaladalaVideoEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Paladala Video")
    static var defaultQuery = PaladalaVideoQuery()

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
            description: "",
            ownerMid: 0
        )
    }
}

struct PaladalaVideoQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PaladalaVideoEntity] {
        let all = IntentRecentVideoStore.recentVideos() + IntentRecentVideoStore.watchLaterVideos()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PaladalaVideoEntity] {
        IntentRecentVideoStore.recentVideos()
    }
}

struct PaladalaShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .pink

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenPaladalaDestinationIntent(destination: .home),
            phrases: [
                "Open \(.applicationName)",
                "Open home in \(.applicationName)"
            ],
            shortTitle: "Open Paladala",
            systemImageName: "play.rectangle"
        )
        AppShortcut(
            intent: OpenPaladalaSearchIntent(),
            phrases: [
                "Search in \(.applicationName)"
            ],
            shortTitle: "Search Paladala",
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
    case video(PaladalaVideoEntity)
    case login
}

enum IntentRouteStore {
    private static let pendingRouteKey = "paladala.intent.pendingRoute"

    static func store(_ route: IntentRoute) {
        let payload: IntentRoutePayload
        switch route {
        case .tab(let tab):
            payload = IntentRoutePayload(kind: "tab", tab: tab, query: nil, video: nil)
        case .search(let query):
            payload = IntentRoutePayload(kind: "search", tab: nil, query: query, video: nil)
        case .video(let entity):
            payload = IntentRoutePayload(kind: "video", tab: nil, query: nil, video: PaladalaVideoRecord(entity: entity))
        case .login:
            payload = IntentRoutePayload(kind: "login", tab: nil, query: nil, video: nil)
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
        case "login":
            return .login
        default:
            return nil
        }
    }
}

private struct IntentRoutePayload: Codable, Sendable {
    let kind: String
    let tab: MainTab?
    let query: String?
    let video: PaladalaVideoRecord?
}

private struct PaladalaVideoRecord: Codable, Sendable {
    let id: String
    let title: String
    let ownerName: String

    init(entity: PaladalaVideoEntity) {
        id = entity.id
        title = entity.title
        ownerName = entity.ownerName
    }

    var entity: PaladalaVideoEntity {
        PaladalaVideoEntity(id: id, title: title, ownerName: ownerName)
    }
}

enum IntentRecentVideoStore {
    private static let recentKey = "paladala.intent.recentVideos"
    private static let watchLaterKey = "paladala.intent.watchLaterVideos"
    /// Spotlight index domain identifier for the recently
    /// watched list. Kept distinct from the watch-later
    /// domain so a future "clear watch history" action
    /// only wipes one bucket at a time.
    private static let recentSpotlightDomain = "paladala.recent"
    /// Spotlight index domain identifier for the watch
    /// later list. Mirrors the URL-Scheme / App-Group
    /// convention used elsewhere in the app.
    private static let watchLaterSpotlightDomain = "paladala.watchlater"

    static func record(_ video: BiliVideo) {
        guard !video.bvid.isEmpty else { return }
        let entity = PaladalaVideoEntity(id: video.bvid, title: video.title, ownerName: video.ownerName)
        let prior = recentVideos()
        var videos = prior.filter { $0.id != entity.id }
        videos.insert(entity, at: 0)
        let next = Array(videos.prefix(10))
        save(next, key: recentKey)
        // Spotlight — index the new entry, deindex any that
        // were evicted by the FIFO truncation so the iOS
        // search results don't show stale bvid pointers.
        indexInSpotlight(
            entity: entity,
            domain: recentSpotlightDomain,
            thumbnail: video.coverURL,
            description: video.description
        )
        let evicted = prior.prefix(10).filter { entity in
            !next.contains(where: { $0.id == entity.id })
        }
        for stale in evicted {
            removeFromSpotlight(bvid: stale.id, domain: recentSpotlightDomain)
        }
    }

    static func recentVideos() -> [PaladalaVideoEntity] {
        load(key: recentKey)
    }

    static func addWatchLater(_ video: PaladalaVideoEntity) {
        guard !video.id.isEmpty else { return }
        var videos = watchLaterVideos().filter { $0.id != video.id }
        videos.insert(video, at: 0)
        save(videos, key: watchLaterKey)
        // Spotlight — watch later never carries a
        // thumbnail or description at the entity layer
        // (the upstream intent strips them) so we pass
        // nil and let the OS fall back to a generic
        // movie icon.
        indexInSpotlight(
            entity: video,
            domain: watchLaterSpotlightDomain,
            thumbnail: nil,
            description: ""
        )
    }

    static func removeFromWatchLater(_ video: PaladalaVideoEntity) {
        guard !video.id.isEmpty else { return }
        let videos = watchLaterVideos().filter { $0.id != video.id }
        save(videos, key: watchLaterKey)
        removeFromSpotlight(bvid: video.id, domain: watchLaterSpotlightDomain)
    }

    static func watchLaterVideos() -> [PaladalaVideoEntity] {
        load(key: watchLaterKey)
    }

    /// Hand a `PaladalaVideoEntity` to CoreSpotlight so
    /// the system search / "Continue Watching" suggestion
    /// surfaces it. The indexing call is fire-and-forget
    /// — failures only land in the diagnostic log so a
    /// transient Spotlight service outage cannot wedge the
    /// playback path that called `record(_:)`.
    private static func indexInSpotlight(
        entity: PaladalaVideoEntity,
        domain: String,
        thumbnail: URL?,
        description: String
    ) {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.movie)
        attributes.title = entity.title
        // `contentDescription` is what Spotlight shows under
        // the title. Prefer the upstream video description
        // when present, fall back to the UP master name so
        // the row never renders as an empty string.
        attributes.contentDescription = description.isEmpty ? entity.ownerName : description
        attributes.keywords = ["Paladala", "Bilibili", entity.ownerName]
        if let thumbnail {
            attributes.thumbnailURL = thumbnail
        }
        let item = CSSearchableItem(
            uniqueIdentifier: entity.id,
            domainIdentifier: domain,
            attributeSet: attributes
        )
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error {
                bpLog("Spotlight index failed for \(entity.id) (domain: \(domain)): \(error)")
            }
        }
    }

    /// Remove a single bvid from one Spotlight bucket.
    /// `CSSearchableIndex.deleteSearchableItems(withIdentifiers:)`
    /// is silent about missing entries so calling it for
    /// an already-evicted id is a no-op.
    private static func removeFromSpotlight(bvid: String, domain: String) {
        // Per-id delete is enough: the FIFO eviction in
        // `record(_:)` only ever needs to drop a single
        // row at a time, and `deleteSearchableItems(withIdentifiers:)`
        // is a no-op when the id isn't indexed so calling it
        // for an id that was never written is safe.
        CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: [bvid]
        ) { error in
            if let error {
                bpLog("Spotlight deindex failed for \(bvid) (domain: \(domain)): \(error)")
            }
        }
    }

    private static func load(key: String) -> [PaladalaVideoEntity] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return ((try? JSONDecoder().decode([PaladalaVideoRecord].self, from: data)) ?? []).map(\.entity)
    }

    private static func save(_ videos: [PaladalaVideoEntity], key: String) {
        let data = try? JSONEncoder().encode(videos.map(PaladalaVideoRecord.init(entity:)))
        UserDefaults.standard.set(data, forKey: key)
    }
}
