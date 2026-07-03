import SwiftUI

struct DynamicFeedView: View {
    let repository: PaladalaRepository
    /// Optional namespace for the hero / zoom navigation
    /// transition. Threaded down to attached `VideoCard`s
    /// inside dynamic posts.
    let heroNamespace: Namespace.ID?
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = DynamicFeedViewModel()
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    init(repository: PaladalaRepository, heroNamespace: Namespace.ID? = nil) {
        self.repository = repository
        self.heroNamespace = heroNamespace
    }

    var body: some View {
        List {
            if model.isLoading && model.posts.isEmpty {
                // Skeleton list rows on the *first* load only.
                ForEach(0..<5, id: \.self) { _ in
                    DynamicFeedSkeletonRow()
                        .listRowSeparator(.hidden)
                }
            } else if let error = model.errorMessage {
                ErrorBanner(message: error)
                    .listRowSeparator(.hidden)
            } else if model.posts.isEmpty {
                ContentUnavailableView(
                    "暂无动态",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("关注 UP 主后，他们的视频、专栏、番剧和开播提醒会出现在这里。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowSeparator(.hidden)
                .overlay(alignment: .bottom) {
                    Button {
                        Haptics.tap()
                        Task { await model.load(repository: repository) }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 24)
                }
            } else {
                ForEach(Array(model.posts.enumerated()), id: \.element.id) { index, post in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            avatar(post)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(post.author)
                                    .font(.headline)
                                Text(post.timeLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !post.text.isEmpty {
                            Text(post.text)
                                .font(.subheadline)
                        }
                        if let video = post.attachedVideo {
                            VideoCard(
                                video: video,
                                repository: repository,
                                heroNamespace: heroNamespace,
                                action: { router.openVideo(video) }
                            )
                            .frame(maxWidth: 360)
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowSeparator(index == model.posts.count - 1 ? .hidden : .visible)
                    .onAppear {
                        if index >= max(0, model.posts.count - 5) {
                            Task { await model.loadMore(repository: repository) }
                        }
                    }
                }
                if model.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("动态")
        .task { await model.load(repository: repository) }
        .refreshable {
            Haptics.medium()
            await model.load(repository: repository)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    Task { await model.load(repository: repository) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
            }
        }
        .modifier(DynamicToolbarGlassModifier(materialDesign: materialDesign))
    }

    @ViewBuilder
    private func avatar(_ post: DynamicPost) -> some View {
        if let url = post.authorAvatarURL {
            ResilientImage(url: url)
                .frame(width: 42, height: 42)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(PaladalaTheme.biliPink.opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay(Text(String(post.author.prefix(1))).font(.headline))
        }
    }
}

/// Single-row skeleton for the dynamic feed. Avatar + 2 text bars.
private struct DynamicFeedSkeletonRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: PaladalaTheme.cornerRadius, style: PaladalaTheme.cornerStyle)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                    .frame(width: 120, height: 12)
                RoundedRectangle(cornerRadius: PaladalaTheme.cornerRadius, style: PaladalaTheme.cornerStyle)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
            }
        }
        .padding(.vertical, 8)
        .redacted(reason: .placeholder)
    }
}

/// Applies Liquid Glass background to the dynamic feed toolbar.
private struct DynamicToolbarGlassModifier: ViewModifier {
    let materialDesign: MaterialDesign

    func body(content: Content) -> some View {
        if materialDesign == .liquidGlass {
            content.paladalaNavBarGlass(.liquidGlass)
        } else {
            content
        }
    }
}
