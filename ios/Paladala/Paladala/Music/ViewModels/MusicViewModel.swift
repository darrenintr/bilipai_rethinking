import Foundation

// MARK: - Music view model
//
// Moved from MusicService.swift as part of the music section
// reintroduction (Phase 0b — directory regrouping). Behaviour is
// byte-for-byte identical to the original; only the file location
// and the file-level documentation header changed.
//
// Loads the music region feed and (lazily) the lyric track for
// the currently-playing video. The lyric is fetched on demand by
// `MusicPlayerView` so the list view never has to pay the cost of
// a second round-trip per row.
@MainActor
final class MusicViewModel: ObservableObject {
    @Published private(set) var videos: [BiliVideo] = []
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?
    /// PR-A Task 9: gates the .task bootstrap block. See
    /// HomeViewModel.didBootstrap for the same rationale.
    @Published private(set) var didBootstrap = false

    /// PR-A Task 9: paint the first frame from the on-disk feed
    /// snapshot if one is present. Caller is expected to gate
    /// this on `!didBootstrap`.
    func seedFromCache(_ cards: [BiliVideo]) {
        self.videos = cards
        self.didBootstrap = true
    }

    /// PR-A Task 9: see HomeViewModel.markBootstrapped for rationale.
    func markBootstrapped() {
        didBootstrap = true
    }

    func load(repository: PaladalaRepository) async {
        isLoading = true
        errorMessage = nil
        diagLog(.music, "MusicViewModel.load start", details: [
            "existingCount": videos.count
        ])
        defer { isLoading = false }
        do {
            let next = try await repository.musicVideos(page: 1)
            videos = next
            diagLog(.music, "MusicViewModel.load success", details: [
                "count": next.count
            ])
        } catch {
            errorMessage = "\(L10n.music.networkError)：\(error.localizedDescription)"
            videos = []
            diagLog(.music, "MusicViewModel.load failed", details: [
                "error": "\(error)",
                "localized": error.localizedDescription
            ])
        }
    }

    func refresh(repository: PaladalaRepository) async {
        diagLog(.music, "MusicViewModel.refresh start")
        await load(repository: repository)
    }
}