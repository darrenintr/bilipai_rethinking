import AVKit
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var category: HomeCategory = .recommend
    @Published var popularSubCategory: PopularSubCategory = .comprehensive
    @Published var searchQuery = ""
    @Published var videos: [BiliVideo] = []
    @Published var liveRooms: [BiliLiveRoom] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load(repository: BiliPaiRepository) async {
        isLoading = true
        errorMessage = nil
        do {
            if category == .follow {
                videos = []
                liveRooms = []
                errorMessage = "登录后查看关注动态、关注直播和个人推荐。"
            } else if category == .live {
                liveRooms = try await repository.liveRooms()
                videos = []
            } else {
                videos = try await repository.feed(
                    category: category,
                    searchQuery: searchQuery,
                    popularSubCategory: popularSubCategory
                )
                liveRooms = []
            }
        } catch {
            errorMessage = "内容加载失败，下拉重试。"
        }
        isLoading = false
    }

    func applyIntentSearch(_ query: String, repository: BiliPaiRepository) async {
        guard !query.isEmpty else { return }
        category = .search
        searchQuery = query
        await load(repository: repository)
    }
}

@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published var detail: BiliVideo
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var comments: [BiliComment] = []
    @Published var commentsLoading = false
    @Published var commentsErrorMessage: String?
    @Published var danmakuEnabled = true
    @Published var audioModeEnabled = false
    @Published var playbackSpeed: Float = 1

    init(video: BiliVideo) {
        self.detail = video
    }

    func load(repository: BiliPaiRepository) async {
        isLoading = true
        errorMessage = nil
        do {
            detail = try await repository.detail(for: detail)
            let playback = try await repository.playback(for: detail)
            let asset = AVURLAsset(
                url: playback.url,
                options: [
                    "AVURLAssetHTTPHeaderFieldsKey": [
                        "Referer": playback.referer.absoluteString,
                        "User-Agent": "Mozilla/5.0 BiliPai-iOS/0.1"
                    ]
                ]
            )
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.rate = playbackSpeed
            self.player = player
            await loadComments(repository: repository)
        } catch {
            errorMessage = "Playback is unavailable for this item without a valid public play URL."
            await loadComments(repository: repository)
        }
        isLoading = false
    }

    private func loadComments(repository: BiliPaiRepository) async {
        commentsLoading = true
        commentsErrorMessage = nil
        do {
            comments = try await repository.comments(for: detail)
        } catch {
            commentsErrorMessage = "Could not load public comments."
        }
        commentsLoading = false
    }
}

@MainActor
final class LiveViewModel: ObservableObject {
    @Published var rooms: [BiliLiveRoom] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load(repository: BiliPaiRepository) async {
        isLoading = true
        errorMessage = nil
        do {
            rooms = try await repository.liveRooms()
        } catch {
            errorMessage = "Could not load live rooms."
        }
        isLoading = false
    }
}
