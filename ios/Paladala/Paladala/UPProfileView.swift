import SwiftUI

/// View model for `UPProfileView`. Drives the three independent
/// loads (card, stats, videos page 1) with `async let` so the
/// header, stats row, and video list all populate in parallel.
/// Pagination uses the same `loadMore(repository:)` shape as
/// `HistoryListViewModel` / `FavoriteFolderVideosViewModel` so
/// the future "merge into the existing account-list" refactor
/// is a copy-paste away.
@MainActor
final class UPProfileViewModel: ObservableObject {
    @Published var card: BiliUserCard?
    @Published var followingCount: String = "--"
    @Published var followerCount: String = "--"
    @Published var dynamicCount: String = "--"
    @Published var videos: [BiliVideo] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMore = true
    @Published var errorMessage: String?

    private var nextPage = 1
    private let mid: Int64

    init(mid: Int64) {
        self.mid = mid
    }

    func load(repository: PaladalaRepository) async {
        guard mid > 0 else {
            errorMessage = "无效的 UP ID"
            return
        }
        isLoading = true
        errorMessage = nil
        nextPage = 1
        // Fire the three independent reads in parallel. The
        // card fetch is the slowest (WBI-signed); the stats
        // fan-out is fast; the videos page is medium. We
        // `try?` the card so a 403/-101 on a banned or
        // shadow-banned user still renders the video list.
        async let cardResult = try? await repository.userCardInfo(mid: mid)
        async let statsResult = try? await repository.userStats(mid: mid)
        async let videosResult = (try? await repository.userVideos(mid: mid, page: 1)) ?? (videos: [], hasMore: false)

        let (loadedCard, loadedStats, loadedVideos) = await (cardResult, statsResult, videosResult)
        card = loadedCard
        if let loadedStats {
            followingCount = loadedStats.following
            followerCount = loadedStats.follower
            dynamicCount = loadedStats.dynamic
        }
        videos = loadedVideos.videos
        hasMore = loadedVideos.hasMore
        nextPage = 2
        isLoading = false
    }

    func loadMore(repository: PaladalaRepository) async {
        guard !isLoading, !isLoadingMore, hasMore, mid > 0 else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await repository.userVideos(mid: mid, page: nextPage)
            // Dedupe by `bvid` so a server-side re-order between
            // pages does not produce duplicate rows. The
            // home-feed / favorites lists use the same guard.
            let seen = Set(videos.map(\.id))
            videos.append(contentsOf: page.videos.filter { !seen.contains($0.id) })
            hasMore = page.hasMore
            nextPage += 1
        } catch {
            errorMessage = "加载更多失败"
        }
    }
}

/// Public profile screen for a UP (content creator). Pushed onto
/// the navigation stack by `AppRouter.openUP(mid:)` when the
/// user taps the owner name in `VideoDetailView`'s nav bar.
/// Three sections, top to bottom: header, stats, published
/// videos. Tapping a row in the videos list pushes another
/// `VideoDetailView` for that video via the existing
/// `BiliVideo` navigation destination registered in
/// `RootView.swift`.
struct UPProfileView: View {
    let mid: Int64
    let repository: PaladalaRepository

    @StateObject private var model: UPProfileViewModel
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    init(mid: Int64, repository: PaladalaRepository) {
        self.mid = mid
        self.repository = repository
        _model = StateObject(wrappedValue: UPProfileViewModel(mid: mid))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statsRow
                videosSection
            }
            .padding(16)
        }
        .navigationTitle(model.card?.name ?? "UP 主")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load(repository: repository)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let card = model.card {
            HStack(alignment: .top, spacing: 14) {
                avatar(for: card)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(card.name)
                            .font(.title2.weight(.bold))
                        if card.vipType > 0 {
                            Image(systemName: "crown.fill")
                                .foregroundStyle(PaladalaTheme.biliPink)
                                .accessibilityLabel("大会员")
                        }
                    }
                    Text("UID: \(card.mid)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if card.level > 0 {
                        // Render the level as a small capsule so
                        // it's easy to scan. Bilibili's level is
                        // 0-6; we map it to LV1..LV6 verbatim.
                        Text("LV\(card.level)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(PaladalaTheme.biliPink, in: Capsule())
                    }
                }
                Spacer()
            }
            if !card.sign.isEmpty {
                Text(card.sign)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        } else if model.isLoading {
            HStack(spacing: 14) {
                Circle()
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        .frame(width: 120, height: 16)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        .frame(width: 80, height: 12)
                }
                Spacer()
            }
            .redacted(reason: .placeholder)
        } else if let error = model.errorMessage {
            // The card fetch failed but the videos might still
            // load. Show a small inline banner rather than
            // swallowing the error.
            Text(error)
                .font(.subheadline)
                .foregroundStyle(PaladalaTheme.biliPink)
        }
    }

    @ViewBuilder
    private func avatar(for card: BiliUserCard) -> some View {
        if let url = card.faceURL {
            ResilientImage(url: url)
                .frame(width: 64, height: 64)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(PaladalaTheme.biliPink.opacity(0.18))
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.title)
                        .foregroundStyle(PaladalaTheme.biliPink)
                )
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 16) {
            statPill(label: "粉丝", value: model.followerCount)
            statPill(label: "关注", value: model.followingCount)
            statPill(label: "动态", value: model.dynamicCount)
            Spacer()
        }
        .padding(14)
        .paladalaCardSurface(materialDesign)
    }

    private func statPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Videos

    @ViewBuilder
    private var videosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("投稿")
                    .font(.headline)
                Spacer()
                if model.isLoadingMore {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = model.errorMessage, model.videos.isEmpty {
                ErrorBanner(message: error)
            } else if model.videos.isEmpty && model.isLoading {
                ForEach(0..<3, id: \.self) { _ in
                    rowSkeleton
                }
            } else if model.videos.isEmpty {
                ContentUnavailableView(
                    "暂无投稿",
                    systemImage: "film.stack",
                    description: Text("该 UP 暂未发布视频，或数据加载失败。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                    NavigationLink(value: video) {
                        UPVideoListRow(video: video)
                    }
                    .buttonStyle(.plain)
                    if index == model.videos.count - 1 && model.hasMore {
                        // Last-row onAppear trigger for pagination.
                        // Lives inside the `if index == count-1` so
                        // the load fires once per page rather than
                        // on every scroll tick.
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await model.loadMore(repository: repository) }
                            }
                    }
                    if video.id != model.videos.last?.id {
                        Divider()
                    }
                }
                if !model.hasMore && !model.videos.isEmpty {
                    Text("— 没有更多了 —")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
        .padding(14)
        .paladalaCardSurface(materialDesign)
    }

    private var rowSkeleton: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .frame(width: 112, height: 70)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                    .frame(height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                    .frame(width: 180, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                    .frame(width: 90, height: 10)
            }
        }
        .redacted(reason: .placeholder)
    }
}

/// One row in the published-videos list. Mirrors
/// `AccountContentViews.VideoListRow` but is local to this file
/// because the latter is `private` to its enclosing file and
/// the two will diverge (this one drops the subtitle because
/// we already know the owner — every row here is by the same UP).
private struct UPVideoListRow: View {
    let video: BiliVideo

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: video.coverURL)
                .frame(width: 112, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
            VStack(alignment: .leading, spacing: 6) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Label(video.viewCount.compactCount, systemImage: "play.fill")
                    Label(video.danmakuCount.compactCount, systemImage: "text.bubble")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if video.duration > 0 {
                    Text(video.duration.mmss)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
