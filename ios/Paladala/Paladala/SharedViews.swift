import ImageIO
import SwiftUI

struct VideoCard: View {
    let video: BiliVideo
    let action: () -> Void
    /// Optional repository reference so the long-press context menu
    /// can call `addToWatchLater` / `removeFromWatchLater`. Call
    /// sites that don't have a repository (previews, tests) pass
    /// `nil` and the context menu's watch-later action is hidden.
    let repository: PaladalaRepository?
    /// Optional namespace used for the hero / zoom navigation
    /// transition. When the parent view provides a `Namespace.ID`,
    /// the cover image is registered as a `matchedTransitionSource`
    /// so the `VideoDetailView` destination can zoom out of the
    /// card on push and back into it on pop. Call sites that
    /// don't care about the transition (previews, in-account
    /// rows) pass `nil` and the cover renders as before.
    let heroNamespace: Namespace.ID?

    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    /// Reserved height for the title block (two lines of `.subheadline`).
    /// Pinning this so all cards in the same grid row have an identical total
    /// height — otherwise a card with a one-line title would render shorter
    /// than its two-line neighbour, knocking the next row out of alignment.
    private static let titleBlockHeight: CGFloat = 40

    /// Reserved height for the UP-owner line (`.caption`, 1 line).
    /// Pinned so cards don't grow / shrink based on whether the
    /// owner name happens to include a Chinese full-width
    /// character that affects line metrics.
    private static let ownerLineHeight: CGFloat = 18

    /// Reserved height for the play / danmaku count row (`.caption2`, 1 line).
    /// Pinned to remove the remaining height variation between cards.
    private static let countsLineHeight: CGFloat = 16

    /// Total card height = cover (16:10 of card width) + spacing +
    /// title + owner + counts + bottom padding.  We don't pin the
    /// cover to a fixed height because it scales with the column
    /// width; pinning the three text rows above makes the total
    /// height deterministic per column width.
    private static let textRowsVerticalPadding: CGFloat = 8

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

    init(video: BiliVideo, repository: PaladalaRepository, heroNamespace: Namespace.ID? = nil, action: @escaping () -> Void) {
        self.video = video
        self.repository = repository
        self.heroNamespace = heroNamespace
        self.action = action
    }

    var body: some View {
        Button {
            // Centralised "user tapped a card" analytics hook —
            // single point of instrumentation covers home / follow
            // / search / history / favorites / watch-later /
            // dynamic feeds because every call site uses
            // `VideoCard`. `bvid` is the only identifying param
            // we ship; everything else (duration, view count,
            // etc.) is recoverable by joining against the
            // server-side bvid table.
            Analytics.log("card_select", [
                "bvid": video.id,
                "duration": video.duration
            ])
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
                        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: PaladalaTheme.pillRadius, style: PaladalaTheme.cornerStyle))
                        .padding(8)
                }
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: Self.titleBlockHeight, alignment: .topLeading)
                Text(video.ownerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: Self.ownerLineHeight, alignment: .topLeading)
                HStack(spacing: 10) {
                    Label(video.viewCount.compactCount, systemImage: "play.fill")
                    Label(video.danmakuCount.compactCount, systemImage: "text.bubble")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: Self.countsLineHeight, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Asymmetric padding: only horizontal + bottom.  The
            // top of the cover image is flush with the card's
            // top edge so the two share their top-left and
            // top-right rounded corners.  Previously `.padding(10)`
            // inset the cover by 10pt on every side, leaving a
            // visible "frame" of card background around the
            // cover — the cover's own rounded corners then
            // nested inside the card's corners instead of
            // aligning with them, which read as overlapping
            // borders to the user.
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .paladalaCardSurface(materialDesign)
            .clipShape(RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
            .contentShape(RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .buttonStyle(PaladalaPressBounceButtonStyle())
        .modifier(VideoContextMenuIfAvailable(video: video, repository: repository))
        // Impression fires once per card every time it enters
        // the visible viewport. For long feeds this can be
        // noisy; if analytics volume becomes a concern later,
        // swap this for a debounced / sampled impression hook
        // (e.g. only fire on first appearance per session,
        // keyed by bvid in a Set).
        .onAppear {
            Analytics.log("card_impression", ["bvid": video.id])
        }
    }

    /// The cover image, kept as a property so we can apply the
    /// hero-source modifier without duplicating the modifier
    /// chain in two places.
    ///
    /// Sizing story (this is the third rewrite — see commit
    /// history): the box must report a *deterministic* height to
    /// the parent `LazyVGrid` cell so the cell's text rows
    /// (title / owner / counts, all pinned to fixed heights) get
    /// stacked below the cover instead of being painted on top
    /// of the next row's cover.
    ///
    /// - `Rectangle().fill(.clear)` is a `Shape` and proposes a
    ///   non-zero intrinsic size to its parent. `Color.clear` is
    ///   a `Color` wrapped as `View` and its intrinsic size
    ///   collapses to zero on iPad horizontal + sidebar layouts,
    ///   so `aspectRatio` has nothing to derive a height from.
    /// - `.aspectRatio(16/10, .fit)` then locks the rectangle to
    ///   a 16:10 box; the `.frame(maxWidth: .infinity)` above
    ///   gives it the column's full width, so height becomes
    ///   `width * 10/16` deterministically.
    /// - `CoverImage` (a `ZStack` of placeholder + `Image`) is
    ///   overlaid into that fixed box. We force it to fill via
    ///   `maxWidth:.infinity, maxHeight:.infinity` because
    ///   ZStacks don't fill by default. The internal
    ///   `Image(uiImage:)` already does `.scaledToFill() + .clipped()`
    ///   so every source aspect ratio (16:9, 4:3, 1:1) gets
    ///   cropped to the 16:10 box.
    /// - The outer `.clipShape(RoundedRectangle(cardRadius))`
    ///   gives the cover the same 24 pt corner radius as the
    ///   card.
    private var coverImage: some View {
        Rectangle()
            .fill(.clear)
            .aspectRatio(16 / 10, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                CoverImage(url: video.coverURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
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
    let repository: PaladalaRepository?

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

    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    @EnvironmentObject private var router: AppRouter

    /// See `VideoCard.titleBlockHeight` for why this is pinned.
    private static let titleBlockHeight: CGFloat = 40

    var body: some View {
        Button {
            router.openLive(room)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    // See `VideoCard.coverImage` for the sizing story.
                    // Same Rectangle() + .aspectRatio(16/10, .fit)
                    // pattern — without the explicit Shape container,
                    // CoverImage's ZStack of Rectangle+Image can
                    // collapse to placeholder size on first paint
                    // (before the URL image lands) and the grid cell
                    // reports a tiny height to the parent, causing
                    // the LIVE badge to be painted on top of the
                    // next row's cover.
                    Rectangle()
                        .fill(.clear)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay(
                            CoverImage(url: room.coverURL)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        )
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
                    Text("LIVE")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color(uiColor: .systemRed), in: RoundedRectangle(cornerRadius: PaladalaTheme.pillRadius, style: PaladalaTheme.cornerStyle))
                        .padding(8)
                        // Apple's recommended "live" affordance —
                        // the SF Symbol pulses on a continuous loop
                        // so the user can spot a live card at a
                        // glance during a fast scroll. We apply the
                        // effect to a hidden SF Symbol inside the
                        // same container because `.symbolEffect(.pulse)`
                        // on `Text` itself is a no-op; the visible
                        // "LIVE" label keeps its typography, the
                        // pulse animates the dot to the right.
                        .overlay(alignment: .trailing) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(.white)
                                // `.repeat(.continuous)` is iOS 18+
                                // (deployment target is 17.5). On
                                // iOS 17 the default `.symbolEffect
                                // (.pulse)` plays once and stops;
                                // the dot then sits static on a
                                // live card. That's still better
                                // than no badge at all.
                                .symbolEffect(.pulse)
                                .padding(.trailing, 3)
                                .accessibilityHidden(true)
                        }
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
                    .foregroundStyle(PaladalaTheme.biliPink)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
            .paladalaCardSurface(materialDesign)
            .clipShape(RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .buttonStyle(PaladalaPressBounceButtonStyle())
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
        // We deliberately do NOT reset `image` here.  The
        // `.task(id: url)` modifier re-fires on every view
        // appearance — including `LazyVStack` recycles that
        // hand us back the same URL identity.  Resetting the
        // `@State` causes a visible placeholder flash on
        // fast scroll even when the pipeline's actor cache
        // would have served the image instantly.  Leave the
        // previous render in place; the in-flight task will
        // overwrite it if a fresher copy arrives.

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
        memoryCache.countLimit = 360
        memoryCache.totalCostLimit = 192 * 1_024 * 1_024

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 32 * 1_024 * 1_024,
            diskCapacity: 256 * 1_024 * 1_024
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        // Bumped from 6 to 12 — the feed lists fan out across
        // many distinct `i0/i1/...` Bilibili cover hosts, and
        // a single host rarely appears in more than 4–5 cells
        // at once.  The old limit stalled covers during fast
        // scroll on the Music grid where ~30 cells mount in a
        // single runloop tick.
        configuration.httpMaximumConnectionsPerHost = 12
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
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if materialDesign == .liquidGlass {
                    RoundedRectangle(
                        cornerRadius: PaladalaTheme.cornerRadius,
                        style: PaladalaTheme.cornerStyle
                    )
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: PaladalaTheme.cornerRadius,
                                style: PaladalaTheme.cornerStyle
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
                                cornerRadius: PaladalaTheme.cornerRadius,
                                style: PaladalaTheme.cornerStyle
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
            .foregroundStyle(Color(uiColor: .systemOrange))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(uiColor: .systemOrange).opacity(0.12), in: RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
    }
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
        repository: PaladalaRepository,
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
        // `PaladalaApp`).
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
    let repository: PaladalaRepository
    let isWatchLaterRow: Bool
    let isHistoryRow: Bool

    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var router: AppRouter

    /// Build the bv / av URL on demand.  `URL(string:)` is a
    /// cheap constructor (string interpolation + Unicode
    /// normalisation; no I/O), so the per-body rebuild cost
    /// is dominated by SwiftUI's diff machinery itself — a
    /// `lazy var` here would force a mutating getter on the
    /// struct (Swift rejects it because the modifier value
    /// is immutable at the call site), so we keep the
    /// straightforward `let` in `body`.
    private var videoURL: URL {
        URL(string: "https://www.bilibili.com/video/\(video.bvid.isEmpty ? "av\(video.aid)" : video.bvid)")!
    }

    func body(content: Content) -> some View {
        let url = videoURL
        let isLoggedIn = authStore.isLoggedIn
        content.contextMenu {
            // "查看 UP 主主页" appears whenever the row carries
            // a non-zero `ownerMid`. Search results now
            // populate `ownerMid` correctly (Bilibili's web
            // search endpoint exposes flat `mid` + `author`,
            // not `owner.mid` — see `VideoDTO.init(from:)`),
            // so this entry is reachable from every row.
            if video.ownerMid > 0 {
                Button {
                    Haptics.selection()
                    router.openUP(mid: video.ownerMid)
                } label: {
                    Label("查看 UP 主主页", systemImage: "person.crop.circle")
                }
                Divider()
            }
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
                Menu {
                    Button {
                        Haptics.tap()
                        Task {
                            do {
                                try await repository.giveCoins(to: video, multiply: 1)
                                Haptics.success()
                            } catch {
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label("投 1 枚硬币", systemImage: "bitcoinsign.circle")
                    }
                    Button {
                        Haptics.tap()
                        Task {
                            do {
                                try await repository.giveCoins(to: video, multiply: 2)
                                Haptics.success()
                            } catch {
                                Haptics.error()
                            }
                        }
                    } label: {
                        Label("投 2 枚硬币", systemImage: "bitcoinsign.circle.fill")
                    }
                } label: {
                    Label("投币支持 UP 主", systemImage: "bitcoinsign.circle")
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
                .clipShape(RoundedRectangle(cornerRadius: PaladalaTheme.cornerRadius, style: PaladalaTheme.cornerStyle))
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
    static let watchLaterDidChange = Notification.Name("paladala.watchLater.didChange")
    /// Posted by the long-press "从历史记录中移除" action. The
    /// History list view subscribes and removes the entry locally.
    static let historyDidRemove = Notification.Name("paladala.history.didRemove")
}

// MARK: - Skeletons

/// Grid of skeleton placeholders shown while the first feed page is
/// loading. The shimmer is driven by a single `LinearGradient` overlay
/// sliding across the cover rect — we avoid `redacted(reason:
/// .placeholder)` because that interacts badly with the manual
/// animation. Use the same `paladalaCardSurface` as `VideoCard` so the
/// skeleton and the real content share the same outline shape and the
/// cross-fade between them does not shift layout.
struct SkeletonGrid: View {
    var columns: Int = 2
    var cardCount: Int = 6

    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns),
            spacing: 12
        ) {
            ForEach(0..<cardCount, id: \.self) { _ in
                SkeletonCard()
                    .paladalaCardSurface(materialDesign)
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
            RoundedRectangle(cornerRadius: PaladalaTheme.cornerRadius, style: PaladalaTheme.cornerStyle)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .aspectRatio(16 / 10, contentMode: .fit)
            RoundedRectangle(cornerRadius: PaladalaTheme.cornerRadius, style: PaladalaTheme.cornerStyle)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .frame(height: 12)
            RoundedRectangle(cornerRadius: PaladalaTheme.cornerRadius, style: PaladalaTheme.cornerStyle)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .frame(height: 12)
                .frame(maxWidth: 100)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .paladalaShimmer()
    }
}
