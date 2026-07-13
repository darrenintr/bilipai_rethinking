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
    /// Concurrency gate for `refresh(...)`. iPadOS 26.6 on
    /// `ScrollView + empty content + .refreshable` is known to
    /// re-fire the refresh closure at frame-tick rate while the
    /// pull gesture is in flight, and our network failure path
    /// (B 站 business-code "啥都木有") returns fast — so the
    /// closure can chain 5-10 times before the user even lifts
    /// their finger, each re-entering `refresh → load` and
    /// spamming the diag log. The gate makes `refresh` a
    /// single-flight: any concurrent caller (refreshable,
    /// toolbar button, emptyState retry) drops on the floor
    /// with a diagnostic trace instead of stacking requests.
    @Published private(set) var isRefreshing = false

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
        // Single-flight gate. See `isRefreshing` doc-comment for
        // the iPadOS 26.6 .refreshable quirk that motivates this.
        if isRefreshing {
            diagLog(.music, "MusicViewModel.refresh dropped (in-flight)", details: [
                "inFlight": "true"
            ])
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        diagLog(.music, "MusicViewModel.refresh start")
        await load(repository: repository)
    }
}