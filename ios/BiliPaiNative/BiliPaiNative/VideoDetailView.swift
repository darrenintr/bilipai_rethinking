import SwiftUI

/// Signal extracted from the comment-list `ScrollView`'s geometry.
/// The auto-load trigger cares about two facts: has the user scrolled
/// at all, and are they within a viewport-height of the bottom.
/// Encoding both into an `Equatable` value lets
/// `onScrollGeometryChange` fire the action only when the answer
/// changes, which is cheaper than reacting to every pixel of scroll.
private struct CommentScrollSignal: Equatable {
    let hasScrolled: Bool
    let isNearBottom: Bool
}

struct VideoDetailView: View {
    let video: BiliVideo
    let repository: BiliPaiRepository

    @StateObject private var model: VideoDetailViewModel
    @State private var isFullscreenPresented = false
    /// Single `PlayerController` shared by the inline `PlayerView`
    /// and the `FullscreenPlayerView`. Created lazily once
    /// `model.playback` is loaded, because the controller's
    /// initialiser needs the playback URL. Hoisting the player
    /// up to this level is what makes the playhead and
    /// play/pause state stay continuous across the inline ↔
    /// fullscreen transition — both surfaces point at the same
    /// `VLCMediaPlayer`, only the visible `UIView` (drawable) is
    /// swapped when the user enters / leaves fullscreen.
    @State private var playerController: PlayerController?
    /// The history-reporting `WatchSession` also lives at this
    /// level for the same reason. Previously each view created
    /// its own, which would double-fire on every inline ↔
    /// fullscreen transition.
    @State private var watchSession: WatchSession?

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
        .onChange(of: model.playback) { _, playback in
            // Build the shared controller + history reporter
            // exactly once, when playback first becomes available.
            // We compare against `playerController` (not just nil)
            // because a re-load on a `Retry` could fire this
            // `onChange` with a new playback object while the old
            // controller is still alive.
            guard let playback, playerController == nil else { return }
            let controller = PlayerController(
                url: playback.videoURL,
                referer: playback.referer.absoluteString
            )
            playerController = controller
            let session = WatchSession(
                repository: repository,
                aid: model.detail.aid,
                cid: model.detail.cid,
                getCurrentSeconds: { [weak controller] in controller?.currentTime ?? 0 },
                isActive: { [weak controller] in controller?.isPlaying ?? false }
            )
            watchSession = session
            session.start()
        }
        .onDisappear {
            // Free the asset and observers as soon as the screen is gone so we
            // do not hold a decoded video in memory while the user scrolls
            // around the home grid.
            isFullscreenPresented = false
            watchSession?.stop()
            watchSession = nil
            playerController?.tearDown()
            playerController = nil
            model.teardown()
        }
        .fullScreenCover(isPresented: $isFullscreenPresented) {
            if let playback = model.playback, let controller = playerController {
                FullscreenPlayerView(video: model.detail, playback: playback, controller: controller)
            }
        }
        // Auto-load the next comment batch only when the user has
        // actually scrolled the list and is within 200pt of the bottom.
        // The earlier per-row `.onAppear { if index >= count - 5 }`
        // trigger was a footgun: when the initial 20 items fit on
        // screen, the last 5 rows' onAppear all fire at once, queue up
        // loadMore calls, and the list grows to load the entire thread
        // before the user even touches the scroll view. The
        // `hasScrolled` guard (contentOffset > 1pt) makes sure the
        // very first render never auto-loads.
        .onScrollGeometryChange(for: CommentScrollSignal.self) { geometry in
            let hasScrolled = geometry.contentOffset.y > 1
            let isNearBottom = geometry.contentOffset.y + geometry.containerSize.height
                >= geometry.contentSize.height - 200
            return CommentScrollSignal(hasScrolled: hasScrolled, isNearBottom: isNearBottom)
        } action: { _, signal in
            if signal.hasScrolled && signal.isNearBottom {
                Task { await model.loadMoreComments(repository: repository) }
            }
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        ZStack(alignment: .topLeading) {
            if let playback = model.playback, let controller = playerController {
                PlayerView(playback: playback, video: model.detail, controller: controller)
                    .onAppear { model.isPlaying = true }
                    .onDisappear { model.isPlaying = false }

                fullscreenButton
                    .padding(10)
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
            // The earlier "Danmaku preview layer" overlay used to live here
            // and crowd the top-leading corner where the fullscreen button
            // sits. There is no real danmaku engine yet (the project README
            // is explicit: "full danmaku rendering are not ported yet"), so
            // we drop the placeholder entirely. The Danmaku toggle in the
            // control panel below stays as a "coming soon" hint.
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
    }

    private var fullscreenButton: some View {
        Button {
            isFullscreenPresented = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(9)
                .background(.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Enter fullscreen")
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
                VStack(alignment: .leading, spacing: 8) {
                    ErrorBanner(message: error)
                    Button {
                        Task { await model.load(repository: repository) }
                    } label: {
                        Label("重试播放", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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
            // TODO: real danmaku engine. The toggle stays in the UI as a
            // hint at the future feature but does nothing until then.
            Toggle("Danmaku", isOn: $model.danmakuEnabled)
                .toggleStyle(.button)
                .disabled(true)
                .opacity(0.5)
            Toggle("Audio", isOn: $model.audioModeEnabled)
                .toggleStyle(.button)
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button(String(format: "%.2gx", speed)) {
                        model.playbackSpeed = Float(speed)
                    }
                }
            } label: {
                Label(String(format: "%.2gx", Double(model.playbackSpeed)), systemImage: "speedometer")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
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
                    Text("\(max(model.comments.count, model.commentsTotalCount))")
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
                commentInputField
                    .padding(.bottom, 8)

                ForEach(Array(model.comments.enumerated()), id: \.element.id) { _, comment in
                    CommentRow(comment: comment, video: model.detail, repository: repository, model: model)
                    if comment.id != model.comments.last?.id {
                        Divider()
                    }
                }
                loadMoreFooter
            }
        }
        .padding(14)
        .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
    }

    @State private var newCommentText = ""
    @State private var isSubmittingComment = false

    /// Footer shown at the bottom of the comment list. When the user
    /// can scroll past the loaded items the auto-load trigger on the
    /// outer `ScrollView` handles pagination; this footer covers the
    /// case where the loaded 20 items fit entirely in the viewport
    /// (no scroll possible) so the user can still request the next
    /// batch explicitly. Also doubles as a manual retry target if the
    /// auto-load hits a network error and stops firing.
    @ViewBuilder
    private var loadMoreFooter: some View {
        if model.commentsHasMore {
            HStack {
                Spacer()
                if model.commentsLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                    Text("加载中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        Task { await model.loadMoreComments(repository: repository) }
                    } label: {
                        Label("加载更多评论", systemImage: "arrow.down.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(.vertical, 12)
        } else if !model.comments.isEmpty {
            Text("— 没有更多评论了 —")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private var commentInputField: some View {
        HStack(spacing: 12) {
            TextField("说点什么…", text: $newCommentText)
                .textFieldStyle(.roundedBorder)
                .disabled(isSubmittingComment)

            Button {
                isSubmittingComment = true
                Task {
                    if await model.submitComment(repository: repository, message: newCommentText) {
                        newCommentText = ""
                    }
                    isSubmittingComment = false
                }
            } label: {
                if isSubmittingComment {
                    ProgressView().controlSize(.small)
                } else {
                    Text("發佈")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(newCommentText.isEmpty || isSubmittingComment)
        }
    }
}

private struct CommentRow: View {
    let comment: BiliComment
    let video: BiliVideo
    let repository: BiliPaiRepository
    let model: VideoDetailViewModel
    @EnvironmentObject private var router: AppRouter

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
                    Button {
                        Task { await model.performCommentAction(repository: repository, rpid: comment.id, actionType: "like") }
                    } label: {
                        Label(comment.likeCount.compactCount, systemImage: "hand.thumbsup")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Button {
                    if comment.replyCount > 0 {
                        router.openReplies(video: video, root: comment)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(comment.message)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if !comment.replies.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(comment.replies) { reply in
                                    NestedReplyRow(comment: reply)
                                }
                                if comment.replyCount > comment.replies.count {
                                    Text("查看全部 \(comment.replyCount) 条回复 >")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(BiliPaiTheme.biliPink)
                                        .padding(.top, 2)
                                }
                            }
                            .padding(.top, 2)
                        } else if comment.replyCount > 0 {
                            Text("查看全部 \(comment.replyCount) 条回复 >")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BiliPaiTheme.biliPink)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NestedReplyRow: View {
    let comment: BiliComment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(comment.authorName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if comment.likeCount > 0 {
                    Label(comment.likeCount.compactCount, systemImage: "hand.thumbsup")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(comment.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: BiliPaiTheme.cornerStyle))
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
                        RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle)
                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            .frame(width: 120, height: 12)
                        RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle)
                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            .frame(height: 12)
                        RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle)
                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            .frame(width: 210, height: 12)
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
    }
}
