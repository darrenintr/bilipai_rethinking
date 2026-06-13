import SwiftUI

struct DynamicFeedView: View {
    let repository: BiliPaiRepository
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        List {
            ForEach(repository.dynamicPosts()) { post in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Circle()
                            .fill(BiliPaiTheme.biliPink.opacity(0.18))
                            .frame(width: 42, height: 42)
                            .overlay(Text(String(post.author.prefix(1))).font(.headline))
                        VStack(alignment: .leading) {
                            Text(post.author)
                                .font(.headline)
                            Text(post.timeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(post.text)
                    if let video = post.attachedVideo {
                        VideoCard(video: video) {
                            router.openVideo(video)
                        }
                        .frame(maxWidth: 360)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Dynamic")
    }
}
