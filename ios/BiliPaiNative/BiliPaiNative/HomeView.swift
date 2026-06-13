import SwiftUI

struct HomeView: View {
    let repository: BiliPaiRepository

    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = HomeViewModel()

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                searchBar
                categoryStrip
                if let error = model.errorMessage {
                    ErrorBanner(message: error)
                }
                if model.isLoading && model.videos.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if model.videos.isEmpty {
                    HomeEmptyState(
                        category: model.category,
                        searchQuery: model.searchQuery,
                        hasError: model.errorMessage != nil
                    )
                } else {
                    TodayWatchCard(videos: Array(model.videos.prefix(4)))
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.videos) { video in
                            VideoCard(video: video) {
                                router.openVideo(video)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(BiliPaiTheme.pageBackground)
        .navigationTitle("BiliPai")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    router.open(.dynamic)
                } label: {
                    Image(systemName: "bell")
                }
                Button {
                    router.open(.profile)
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
        }
        .task {
            await model.load(repository: repository)
        }
        .refreshable {
            await model.load(repository: repository)
        }
        .onChange(of: model.category) { _, _ in
            Task { await model.load(repository: repository) }
        }
        .onChange(of: router.pendingSearchQuery) { _, query in
            Task { await model.applyIntentSearch(query, repository: repository) }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Bilibili videos", text: $model.searchQuery)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit {
                    model.category = .search
                    Task { await model.load(repository: repository) }
                }
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeCategory.allCases) { category in
                    Button {
                        model.category = category
                    } label: {
                        Text(category.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(
                                model.category == category ? BiliPaiTheme.biliPink.opacity(0.16) : Color(uiColor: .tertiarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct HomeEmptyState: View {
    let category: HomeCategory
    let searchQuery: String
    let hasError: Bool

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
    }

    private var title: String {
        if hasError { return "Videos unavailable" }
        if category == .search && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search Bilibili"
        }
        return "No videos found"
    }

    private var systemImage: String {
        if category == .search { return "magnifyingglass" }
        return "play.rectangle"
    }

    private var description: String {
        if hasError { return "Pull to retry the public Bilibili feed." }
        if category == .search && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a keyword above to load public Bilibili videos."
        }
        return "Try another keyword or switch to the popular feed."
    }
}

private struct TodayWatchCard: View {
    let videos: [BiliVideo]
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Today Watch", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text("Local queue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BiliPaiTheme.biliPink)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(videos) { video in
                        Button {
                            router.openVideo(video)
                        } label: {
                            HStack(spacing: 10) {
                                CoverImage(url: video.coverURL)
                                    .frame(width: 110, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(video.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(2)
                                    Text("Relax or learn based on recent viewing")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(width: 270, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
    }
}
