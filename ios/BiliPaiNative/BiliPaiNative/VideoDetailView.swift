import AVKit
import SwiftUI

struct VideoDetailView: View {
    let video: BiliVideo
    let repository: BiliPaiRepository

    @StateObject private var model: VideoDetailViewModel

    init(video: BiliVideo, repository: BiliPaiRepository) {
        self.video = video
        self.repository = repository
        _model = StateObject(wrappedValue: VideoDetailViewModel(video: video))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                playerSurface
                titleBlock
                controlPanel
                commentPreview
            }
            .padding(16)
        }
        .background(BiliPaiTheme.pageBackground)
        .navigationTitle(model.detail.ownerName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load(repository: repository)
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        ZStack {
            if let player = model.player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                CoverImage(url: model.detail.coverURL)
                    .overlay {
                        LinearGradient(
                            colors: [.black.opacity(0.15), .black.opacity(0.62)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .overlay {
                        if model.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 58))
                                .foregroundStyle(.white)
                        }
                    }
            }

            if model.danmakuEnabled {
                Text("Danmaku preview layer")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.38), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.detail.title)
                .font(.title2.weight(.bold))
            HStack(spacing: 8) {
                MetricPill(systemImage: "play.fill", text: model.detail.viewCount.compactCount)
                MetricPill(systemImage: "text.bubble.fill", text: model.detail.danmakuCount.compactCount)
                MetricPill(systemImage: "hand.thumbsup.fill", text: model.detail.likeCount.compactCount)
                MetricPill(systemImage: "clock.fill", text: model.detail.duration.mmss)
            }
            if let error = model.errorMessage {
                ErrorBanner(message: error)
            }
            if !model.detail.description.isEmpty {
                Text(model.detail.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controlPanel: some View {
        HStack {
            Toggle("Danmaku", isOn: $model.danmakuEnabled)
                .toggleStyle(.button)
            Toggle("Audio", isOn: $model.audioModeEnabled)
                .toggleStyle(.button)
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button("\(speed, specifier: "%.2g")x") {
                        model.playbackSpeed = Float(speed)
                        model.player?.rate = model.player?.timeControlStatus == .playing ? Float(speed) : 0
                    }
                }
            } label: {
                Label("\(Double(model.playbackSpeed), specifier: "%.2g")x", systemImage: "speedometer")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
    }

    private var commentPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Comments")
                    .font(.headline)
                Spacer()
                if model.commentsLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if !model.comments.isEmpty {
                    Text("\(model.comments.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if let error = model.commentsErrorMessage {
                ErrorBanner(message: error)
            } else if model.commentsLoading && model.comments.isEmpty {
                CommentSkeletonRows()
            } else if model.comments.isEmpty {
                ContentUnavailableView(
                    "No public comments",
                    systemImage: "text.bubble",
                    description: Text("This video has no anonymous comments available right now.")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(model.comments) { comment in
                    CommentRow(comment: comment)
                    if comment.id != model.comments.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
    }
}

private struct CommentRow: View {
    let comment: BiliComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: comment.avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Circle()
                        .fill(BiliPaiTheme.biliPink.opacity(0.18))
                        .overlay(Image(systemName: "person.fill").foregroundStyle(BiliPaiTheme.biliPink))
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(comment.authorName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if comment.likeCount > 0 {
                        Label(comment.likeCount.compactCount, systemImage: "hand.thumbsup")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(comment.message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if comment.replyCount > 0 {
                    Text("\(comment.replyCount) replies")
                        .font(.caption)
                        .foregroundStyle(BiliPaiTheme.biliPink)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CommentSkeletonRows: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            .frame(width: 120, height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            .frame(height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            .frame(width: 210, height: 12)
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
    }
}
