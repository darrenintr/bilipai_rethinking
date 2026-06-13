import SwiftUI

struct ReplyListView: View {
    let video: BiliVideo
    let rootComment: BiliComment
    let repository: BiliPaiRepository

    @StateObject private var model: ReplyListViewModel

    init(video: BiliVideo, rootComment: BiliComment, repository: BiliPaiRepository) {
        self.video = video
        self.rootComment = rootComment
        self.repository = repository
        _model = StateObject(wrappedValue: ReplyListViewModel(video: video, rootComment: rootComment))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Root comment as a header
                    VStack(alignment: .leading, spacing: 12) {
                        CommentHeader(comment: rootComment)
                            .environmentObject(model)
                            .environmentObject(repository)
                        Divider()
                        Text("全部回复 (\(model.totalCount))")
                            .font(.headline)
                            .padding(.top, 4)
                    }
                    .padding(16)
                    .background(BiliPaiTheme.cardBackground)

                    // Replies list
                    LazyVStack(spacing: 0) {
                        if model.isLoading && model.replies.isEmpty {
                            ProgressView()
                                .padding()
                        } else {
                            ForEach(Array(model.replies.enumerated()), id: \.element.id) { index, reply in
                                ReplyItemRow(comment: reply, repository: repository, model: model)
                                    .onAppear {
                                        if index >= max(0, model.replies.count - 5) {
                                            Task { await model.loadMore(repository: repository) }
                                        }
                                    }
                                Divider()
                                    .padding(.leading, 62)
                            }
                        }

                        if model.isLoadingMore {
                            ProgressView()
                                .padding()
                        }
                    }
                    .background(BiliPaiTheme.cardBackground)
                }
            }
            
            commentInputField
                .padding()
                .background(BiliPaiTheme.cardBackground)
                .overlay(Divider(), alignment: .top)
        }
        .background(BiliPaiTheme.pageBackground)
        .navigationTitle("回复详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load(repository: repository)
        }
    }

    @State private var newReplyText = ""
    @State private var isSubmitting = false

    private var commentInputField: some View {
        HStack(spacing: 12) {
            TextField("发表你的回复…", text: $newReplyText)
                .textFieldStyle(.roundedBorder)
                .disabled(isSubmitting)

            Button {
                isSubmitting = true
                Task {
                    if await model.submitReply(repository: repository, message: newReplyText) {
                        newReplyText = ""
                    }
                    isSubmitting = false
                }
            } label: {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("回复")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(newReplyText.isEmpty || isSubmitting)
        }
    }
}

private struct CommentHeader: View {
    let comment: BiliComment
    @EnvironmentObject var model: ReplyListViewModel
    @EnvironmentObject var repository: BiliPaiRepository

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarImage(url: comment.avatarURL)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(comment.authorName)
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Button {
                        Task { await model.performCommentAction(repository: repository, rpid: comment.id, actionType: "like") }
                    } label: {
                        Label(comment.likeCount.compactCount, systemImage: "hand.thumbsup")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(comment.message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ReplyItemRow: View {
    let comment: BiliComment
    let repository: BiliPaiRepository
    let model: ReplyListViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarImage(url: comment.avatarURL)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(comment.authorName)
                        .font(.caption.weight(.bold))
                    Spacer()
                    Button {
                        Task { await model.performCommentAction(repository: repository, rpid: comment.id, actionType: "like") }
                    } label: {
                        Label(comment.likeCount.compactCount, systemImage: "hand.thumbsup")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(comment.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct AvatarImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
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
        .clipShape(Circle())
    }
}
