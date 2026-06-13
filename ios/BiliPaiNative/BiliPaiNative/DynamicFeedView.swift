import SwiftUI

struct DynamicFeedView: View {
    let repository: BiliPaiRepository
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = DynamicFeedViewModel()

    var body: some View {
        List {
            if let error = model.errorMessage {
                ErrorBanner(message: error)
                    .listRowSeparator(.hidden)
            }
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
                        VideoCard(video: video) {
                            router.openVideo(video)
                        }
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
        .navigationTitle("动态")
        .task { await model.load(repository: repository) }
        .refreshable { await model.load(repository: repository) }
    }

    @ViewBuilder
    private func avatar(_ post: DynamicPost) -> some View {
        if let url = post.authorAvatarURL {
            ResilientImage(url: url)
                .frame(width: 42, height: 42)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(BiliPaiTheme.biliPink.opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay(Text(String(post.author.prefix(1))).font(.headline))
        }
    }
}
