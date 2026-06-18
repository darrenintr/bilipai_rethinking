import ImageIO
import SwiftUI

struct VideoCard: View {
    let video: BiliVideo
    let action: () -> Void
    /// Optional repository reference so the long-press context menu
    /// can call `addToWatchLater` / `removeFromWatchLater`. Call
    /// sites that don't have a repository (previews, tests) pass
    /// `nil` and the context menu's watch-later action is hidden.
    let repository: BiliPaiRepository?
    /// Optional namespace used for the hero / zoom navigation
    /// transition. When the parent view provides a `Namespace.ID`,
    /// the cover image is registered as a `matchedTransitionSource`
    /// so the `VideoDetailView` destination can zoom out of the
    /// card on push and back into it on pop. Call sites that
    /// don't care about the transition (previews, in-account
    /// rows) pass `nil` and the cover renders as before.
    let heroNamespace: Namespace.ID?

    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    /// Reserved height for the title block (two lines of `.subheadline`).
    /// Pinning this so all cards in the same grid row have an identical total
    /// height — otherwise a card with a one-line title would render shorter
    /// than its two-line neighbour, knocking the next row out of alignment.
    private static let titleBlockHeight: CGFloat = 40

    /// Convenience init for call sites that don't need the
    /// context menu or hero transition. Matches the original
    /// `init(video:action:)` signature so the existing call sites
    /// in `AccountContentViews.swift` and elsewhere don't have to
    /// change.
    init(video: BiliVideo, action: @escaping () -> Void) {
        self.video = video
        self.action = action
        self.repository = nil
        self.heroNamespace = nil
    }

    init(video: BiliVideo, repository: BiliPaiRepository, heroNamespace: Namespace.ID? = nil, action: @escaping () -> Void) {
        self.video = video
        self.repository = repository
        self.heroNamespace = heroNamespace
        self.action = action
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    // Register the cover image as a matched
                    // transition source so the system can zoom
                    // out of it on push. We only attach the
                    // modifier when a namespace is provided —
                    // the transition is a no-op otherwise and
                    // would be dead weight in the view tree.
                    coverImage
                        .modifier(HeroSourceModifier(videoID: video.id, namespace: heroNamespace))
                    Text(video.duration.mmss)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle))
                        .padding(8)
                }
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: Self.titleBlockHeight, alignment: .topLeading)
                Text(video.ownerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label(video.viewCount.compactCount, systemImage: "play.fill")
                    Label(video.danmakuCount.compactCount, systemImage: "text.bubble")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
            .bilipaiCardSurface(materialDesign)
            .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
            .contentShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .buttonStyle(.plain)
        .modifier(VideoContextMenuIfAvailable(video: video, repository: repository))
    }

    /// The cover image, kept as a property so we can apply the
    /// hero-source modifier without duplicating the modifier
    /// chain in two places.
    private var coverImage: some View {
        CoverImage(url: video.coverURL)
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
    }
}

/// Applies `.matchedTransitionSource` only when a namespace is
/// available AND the runtime OS is iOS 18+ (the API was
/// introduced in iOS 18). On iOS 17 the modifier is a no-op and
/// the destination `VideoDetailView` falls back to the system
/// cross-fade.
private struct HeroSourceModifier: ViewModifier {
    let videoID: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace, #available(iOS 18, *) {
            content.matchedTransitionSource(id: videoID, in: namespace)
        } else {
            content
        }
    }
}

/// Adds the long-press context menu only when a repository is
/// available. Falls back to a no-op modifier otherwise so the
/// `init(video:action:)` path stays free of a dependency.
private struct VideoContextMenuIfAvailable: ViewModifier {
    let video: BiliVideo
    let repository: BiliPaiRepository?

    func body(content: Content) -> some View {
        if let repository {
            content.videoContextMenu(for: video, repository: repository)
        } else {
            content
        }
    }
}

struct LiveRoomCard: View {
    let room: BiliLiveRoom

    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    @EnvironmentObject private var router: AppRouter

    /// See `VideoCard.titleBlockHeight` for why this is pinned.
    private static let titleBlockHeight: CGFloat = 40

    var body: some View {
        Button {
            router.openLive(room)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    CoverImage(url: room.coverURL)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
                    Text("LIVE")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.red, in: RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle))
                        .padding(8)
                }
                Text(room.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: Self.titleBlockHeight, alignment: .topLeading)
                Text("\(room.hostName) - \(room.areaName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(room.viewerCount.compactCount) watching")
                    .font(.caption2)
                    .foregroundStyle(BiliPaiTheme.biliPink)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
            .bilipaiCardSurface(materialDesign)
            .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .buttonStyle(.plain)
    }
}

struct CoverImage: View {
    let url: URL?

    var body: some View {
        // We pull the image bytes through a small URLSession-backed loader
        // rather than the built-in `AsyncImage`. AsyncImage is notoriously
        // flaky on slow / flaky networks — once it lands in the failure
        // phase there is no way to retry, and the system image cache keeps
        // the broken placeholder around. The custom loader keeps trying
        // (with a short back-off) and refreshes when `url` changes.
        // Note: no .clipped() here — the caller applies
        // .clipShape(RoundedRectangle) to get rounded corners.
        ResilientImage(url: url)
    }
}

struct ResilientImage: View {
    let url: URL?

    @State private var image: UIImage?
    @State private var attempts = 0

    private let maxAttempts = 3

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else if attempts >= maxAttempts {
                // Permanent failure placeholder so the cell still has
                // visible affordance instead of looking like a still-
                // loading skeleton forever.
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        image = nil
        attempts = 0

        guard let url else {
            return
        }

        while attempts < maxAttempts && !Task.isCancelled {
            attempts += 1

            do {
                image = try await CoverImagePipeline.shared.image(for: url)
                return
            } catch is CancellationError {
                return
            } catch {
                guard attempts < maxAttempts else { return }
                try? await Task.sleep(for: .milliseconds(250 * attempts))
            }
        }
    }
}

private actor CoverImagePipeline {
    static let shared = CoverImagePipeline()

    private let memoryCache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        memoryCache.countLimit = 180
        memoryCache.totalCostLimit = 96 * 1_024 * 1_024

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 32 * 1_024 * 1_024,
            diskCapacity: 256 * 1_024 * 1_024
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL) async throws -> UIImage {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached
        }

        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        guard let decoded = Self.downsample(data: data, maximumPixelSize: 900) else {
            throw URLError(.cannotDecodeContentData)
        }

        let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        memoryCache.setObject(decoded, forKey: url as NSURL, cost: cost)
        return decoded
    }

    nonisolated private static func downsample(
        data: Data,
        maximumPixelSize: Int
    ) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

struct MetricPill: View {
    let systemImage: String
    let text: String
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if materialDesign == .liquidGlass {
                    RoundedRectangle(
                        cornerRadius: BiliPaiTheme.cornerRadius,
                        style: BiliPaiTheme.cornerStyle
                    )
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: BiliPaiTheme.cornerRadius,
                                style: BiliPaiTheme.cornerStyle
                            )
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.25), Color.white.opacity(0.05)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                } else {
                    Color(uiColor: .tertiarySystemGroupedBackground)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: BiliPaiTheme.cornerRadius,
                                style: BiliPaiTheme.cornerStyle
                            )
                        )
                }
            }
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Video context menu

/// Long-press actions shared by every video card surface. The
/// watch-later / share / open-in-browser actions all run in
/// fire-and-forget `Task`s; on failure the user gets a
/// `Haptics.error()` and the action silently no-ops (so a network
/// blip doesn't ruin the long-press experience). The
/// `isWatchLaterRow` / `isHistoryRow` flags surface destructive
/// removal actions on the corresponding list.
extension View {
    @ViewBuilder
    func videoContextMenu(
        for video: BiliVideo,
        repository: BiliPaiRepository,
        isWatchLaterRow: Bool = false,
        isHistoryRow: Bool = false
    ) -> some View {
        // We need `isLoggedIn` to gate the watch-later action — but
        // `videoContextMenu(for:repository:)` is a free `View`
        // extension, not a view body, so we can't use
        // `@EnvironmentObject` here. Thread the boolean in via a
        // hidden helper view that reads the environment for us.
        // This avoids adding a `static let shared` to `AuthStore`
        // (which would conflict with the existing `@StateObject` in
        // `BiliPaiNativeApp`).
        self.modifier(VideoContextMenuModifier(
            video: video,
            repository: repository,
            isWatchLaterRow: isWatchLaterRow,
            isHistoryRow: isHistoryRow
        ))
    }
}

private struct VideoContextMenuModifier: ViewModifier {
    let video: BiliVideo
    let repository: BiliPaiRepository
    let isWatchLaterRow: Bool
    let isHistoryRow: Bool

    @EnvironmentObject private var authStore: AuthStore

    func body(content: Content) -> some View {
        let url = URL(string: "https://www.bilibili.com/video/\(video.bvid.isEmpty ? "av\(video.aid)" : video.bvid)")!
        let isLoggedIn = authStore.isLoggedIn
        content.contextMenu {
            if isLoggedIn {
                if !isWatchLaterRow {
                    Button {
                        Haptics.tap()
                        Task {
                            do {
                                try await repository.addToWatchLater(video: video)
                                Haptics.success()
                            } catch {
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label("稍后再看", systemImage: "clock.badge.checkmark")
                    }
                } else {
                    Button(role: .destructive) {
                        Haptics.tap()
                        Task {
                            do {
                                try await repository.removeFromWatchLater(video: video)
                                Haptics.success()
                                NotificationCenter.default.post(
                                    name: .watchLaterDidChange,
                                    object: video
                                )
                            } catch {
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label("从稍后再看中移除", systemImage: "clock.badge.xmark")
                    }
                }
            }
            Button {
                Haptics.tap()
                UIPasteboard.general.url = url
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }
            Button {
                Haptics.tap()
                UIApplication.shared.open(url)
            } label: {
                Label("浏览器打开", systemImage: "safari")
            }
            ShareLink(item: url) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            if isHistoryRow {
                Divider()
                Button(role: .destructive) {
                    Haptics.tap()
                    // Local-only removal from the history list —
                    // the upstream "delete history" endpoint
                    // (`/x/v2/history/delete`) requires CSRF and is
                    // not currently exposed. Refresh the history
                    // list to clear it from the UI.
                    NotificationCenter.default.post(
                        name: .historyDidRemove,
                        object: video
                    )
                } label: {
                    Label("从历史记录中移除", systemImage: "trash")
                }
            }
        } preview: {
            VideoContextMenuPreview(video: video)
        }
    }
}

/// Compact preview shown when the user long-presses a card. Reuses
/// the cover image, the title, and a brief metadata row so the user
/// can confirm they're acting on the right video without committing
/// to a navigation. Width is pinned to 320pt to match the iOS
/// system context-menu preview size.
private struct VideoContextMenuPreview: View {
    let video: BiliVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(url: video.coverURL)
                .aspectRatio(16 / 10, contentMode: .fill)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cornerRadius, style: BiliPaiTheme.cornerStyle))
            Text(video.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(video.ownerName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 320)
    }
}

extension Notification.Name {
    /// Posted by the long-press "从稍后再看中移除" action. The
    /// Watch Later list view subscribes and reloads.
    static let watchLaterDidChange = Notification.Name("bilipai.watchLater.didChange")
    /// Posted by the long-press "从历史记录中移除" action. The
    /// History list view subscribes and removes the entry locally.
    static let historyDidRemove = Notification.Name("bilipai.history.didRemove")
}

// MARK: - Skeletons

/// Grid of skeleton placeholders shown while the first feed page is
/// loading. The shimmer is driven by a single `LinearGradient` overlay
/// sliding across the cover rect — we avoid `redacted(reason:
/// .placeholder)` because that interacts badly with the manual
/// animation. Use the same `bilipaiCardSurface` as `VideoCard` so the
/// skeleton and the real content share the same outline shape and the
/// cross-fade between them does not shift layout.
struct SkeletonGrid: View {
    var columns: Int = 2
    var cardCount: Int = 6

    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns),
            spacing: 12
        ) {
            ForEach(0..<cardCount, id: \.self) { _ in
                SkeletonCard()
                    .bilipaiCardSurface(materialDesign)
            }
        }
    }
}

/// Single skeleton card. Renders three `RoundedRectangle`s (cover +
/// two text bars) with a horizontal shimmer that loops forever. The
/// shimmer is wrapped in a `mask` so it only paints inside the
/// placeholder shapes.
struct SkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: BiliPaiTheme.cornerRadius, style: BiliPaiTheme.cornerStyle)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .aspectRatio(16 / 10, contentMode: .fit)
            RoundedRectangle(cornerRadius: BiliPaiTheme.cornerRadius, style: BiliPaiTheme.cornerStyle)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .frame(height: 12)
            RoundedRectangle(cornerRadius: BiliPaiTheme.cornerRadius, style: BiliPaiTheme.cornerStyle)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .frame(height: 12)
                .frame(maxWidth: 100)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .redacted(reason: .placeholder)
    }
}
