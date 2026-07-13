import SwiftUI

// MARK: - Music home
//
// Moved from MusicHomeView.swift as part of the music section
// reintroduction (Phase 0b — directory regrouping). Behaviour is
// byte-for-byte identical to the original; only the file location
// and the file-level documentation header changed.
//
// The Music tab is split across two screens:
//   * `MusicHomeView` — grid of music videos, same visual
//     language as `HomeView`/`LiveRoomsView`.
//   * `MusicPlayerView` — fullscreen audio-only player with
//     Apple-Music-style scrolling lyrics on the bottom half and
//     the cover art / title on the top half.
//
// Both share the `PaladalaRepository` for the network calls and
// `PlayerController` (the same one `VideoDetailView` uses) for
// playback. The Music view never instantiates its own
// `AVPlayer` — it goes through the same controller so the audio
// session, the Lock Screen now-playing info, and the
// `WatchSession` reporting all stay consistent across the
// regular video player and the music player.

struct MusicHomeView: View {
    let repository: PaladalaRepository

    @StateObject private var model = MusicViewModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    private var columns: [GridItem] {
        if horizontalSizeClass == .regular {
            return Array(
                repeating: GridItem(.flexible(), spacing: 32, alignment: .top),
                count: 2
            )
        }
        return [GridItem(.flexible(), alignment: .top)]
    }

    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let error = model.errorMessage {
                    ErrorBanner(message: error)
                }
                if model.isLoading && model.videos.isEmpty {
                    SkeletonGrid(
                        columns: horizontalSizeClass == .regular ? 2 : 1,
                        columnSpacing: 32,
                        rowSpacing: 32
                    )
                        .padding(.top, 4)
                } else if model.videos.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 32) {
                        ForEach(model.videos) { video in
                            Button {
                                Haptics.tap()
                                diagLog(.music, "MusicCard tap", details: [
                                    "bvid": video.bvid,
                                    "title": video.title
                                ])
                                router.openMusic(video)
                            } label: {
                                MusicCard(video: video)
                            }
                            .buttonStyle(PaladalaPressBounceButtonStyle())
                        }
                    }
                }
            }
            .padding(PaladalaTheme.contentPadding)
        }
        .background(Color.clear)
        .scrollIndicators(.hidden)
        .navigationTitle(L10n.music.title)
        .task {
            diagLog(.music, "MusicHomeView appeared")
        }
        .onDisappear {
            diagLog(.music, "MusicHomeView disappeared")
        }
        .task(id: "music-load") {
            // PR-A Task 9: see HomeView.task for the same
            // seed-then-load pattern. The id makes this re-fire
            // on explicit user actions, but the didBootstrap gate
            // makes it a no-op for re-appearances with cached data.
            if !model.didBootstrap {
                if let cached = await FeedCacheWarmer.shared.seedFromCache(key: "music") {
                    model.seedFromCache(cached)
                }
                model.markBootstrapped()
                LaunchMetrics.shared.mark(.firstFeedCached)
                await Task.yield()
                LaunchMetrics.shared.mark(.firstFeedNetworkStart)
                await model.load(repository: repository)
                LaunchMetrics.shared.mark(.firstFeedNetworkComplete)
            }
        }
        .refreshable {
            Haptics.medium()
            await model.refresh(repository: repository)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    Task { await model.refresh(repository: repository) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
            }
        }
        .modifier(LiquidGlassNavBarModifier(materialDesign: materialDesign))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            model.errorMessage == nil ? L10n.music.empty : L10n.music.networkError,
            systemImage: "music.note.list",
            description: Text(L10n.music.emptyHint)
        )
        .frame(maxWidth: .infinity, minHeight: 260)
        .overlay(alignment: .bottom) {
            Button {
                Haptics.tap()
                Task { await model.refresh(repository: repository) }
            } label: {
                Label(L10n.common.retry, systemImage: "arrow.clockwise")
            }
            .buttonStyle(PaladalaGlassButtonStyle(materialDesign: materialDesign))
            .padding(.bottom, 24)
        }
    }
}