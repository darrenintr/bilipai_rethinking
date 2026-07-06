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
    let repository: PaladalaRepository
    /// Optional namespace for the hero / zoom navigation
    /// transition. When the parent `NavigationStack` provides
    /// a `Namespace.ID`, the body is wrapped in
    /// `.navigationTransition(.zoom(sourceID:in:))` and the
    /// system zooms out of the source `VideoCard`'s cover on
    /// push and back into it on pop. `nil` is a no-op — the
    /// standard cross-fade transition is used.
    let heroNamespace: Namespace.ID?
    /// When set, the view is opening an *offline* video
    /// downloaded via `DownloadManager`.  The model uses
    /// `record.dash` to construct a `BiliPlayback` with a
    /// `localContext` pointing at the on-disk bytes, so the
    /// player reads from disk instead of the upstream CDN.
    /// `nil` is the regular network path.
    let localRecord: DownloadRecord?

    @StateObject private var model: VideoDetailViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var miniPlayerStore: MiniPlayerStore
    @State private var isFullscreenPresented = false
    @State private var fullscreenTransitionUntil: Date = .distantPast
    @State private var lastFullscreenDismissedAt: Date = .distantPast
    /// Player height as a fraction of the available height. 1.0
    /// means the player takes its full rest size (~55% of the
    /// screen, preserving the 16:9 letterbox). 0.5 means the
    /// player is shrunken to exactly 50% of the screen, giving
    /// the comments the other half. We interpolate between the
    /// two based on the inner `ScrollView`'s content offset —
    /// scrolling down shrinks the player, scrolling back up
    /// grows it.
    @State private var playerScale: CGFloat = 1.0
    /// User's preferred comment sort, persisted across launches. The
    /// view writes through to the model and to the underlying fetch
    /// whenever the user toggles the picker.
    @AppStorage("paladala.commentSort") private var storedCommentSort: String = CommentSort.hot.rawValue
    /// User's preferred playback quality, persisted across
    /// launches. Mirrors `model.preferredQn` so a fresh open of
    /// the detail view picks up the user's last pick without a
    /// flash of 1080P → 720P.
    @AppStorage("paladala.preferredQn") private var storedPreferredQn: Int = 80
    /// Material design preference — drives glass vs M3 surfaces
    /// on the control panel and comment card.
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass
    /// User's preferred subtitle visibility. The timed-text track
    /// still loads in the background so enabling subtitles during
    /// playback is instant when the upstream publishes one.
    @AppStorage("paladala.subtitleEnabled") private var storedSubtitleEnabled = true
    /// When true the player takes 80% of the screen and comments
    /// take 20%, giving a more immersive video-watching experience.
    /// Toggled by the "immersive" button in the nav bar.
    @State private var isImmersiveMode = false
    /// YouTube-style next-up overlay state. Shown briefly
    /// when the current item reaches its end (we listen for
    /// `.paladalaVideoDidPlayToEnd`). The overlay either
    /// auto-plays the next related video (when the user has
    /// enabled `paladala.autoPlayNext`) or stays on screen
    /// as a manual countdown the user can dismiss.
    @State private var isShowingNextUp: Bool = false
    @State private var isCountingDownToNext: Bool = false
    @State private var nextUpCountdown: Int = 5
    @State private var nextUpCountdownTask: Task<Void, Never>?
    /// PR-4 (M3): the saved-time-confirmation sheet.  Nil until
    /// the user has progress > 30 s for this bvid.  When set,
    /// a sheet offers "继续观看 MM:SS" or "重新播放".  Auto-dismisses
    /// to nil after the user picks (or taps outside).
    @State private var resumePromptSeconds: Double?
    /// Default countdown duration. YouTube uses 5 s; matches
    /// the HIG-recommended transition window for video
    /// chrome.
    private static let nextUpCountdownDuration: Int = 5

    init(video: BiliVideo, repository: PaladalaRepository, heroNamespace: Namespace.ID? = nil, localRecord: DownloadRecord? = nil) {
        self.video = video
        self.repository = repository
        self.heroNamespace = heroNamespace
        self.localRecord = localRecord
        _model = StateObject(wrappedValue: VideoDetailViewModel(video: video, localRecord: localRecord))
    }

    /// The active player controller — owned by the `MiniPlayerStore`
    /// now, not by this view. Both the inline `PlayerView` and the
    /// `FullscreenPlayerView` read from the store so the playhead
    /// stays continuous across the inline ↔ fullscreen transition
    /// AND across the mini-player transition.
    private var playerController: PlayerController? {
        miniPlayerStore.controller
    }

    var body: some View {
        GeometryReader { geo in
            let totalH = geo.size.height
            // Immersive mode: fixed at 80% height (at rest), 90% when scrolled.
            // Regular mode: 55% height (at rest), 50% when scrolled.
            let maxPlayerHeight = totalH * (isImmersiveMode ? 0.8 : 0.55)
            let minPlayerHeight = totalH * (isImmersiveMode ? 0.9 : 0.5)
            let playerHeight = maxPlayerHeight
                + (minPlayerHeight - maxPlayerHeight) * (1.0 - playerScale)

            VStack(spacing: 0) {
                playerSurface
                    .frame(height: playerHeight)
                    .frame(width: isImmersiveMode ? geo.size.width * 0.9 : nil, alignment: .center)
                    .clipped()
                    // YouTube-style "next up" overlay sits over
                    // the player surface only — never over the
                    // comments. The overlay is empty by default
                    // and renders only while `isShowingNextUp` is
                    // true. Tap targets on the overlay
                    // ("立即播放" / "取消") take priority; the
                    // surface's tap-to-wake gestures below the
                    // overlay do not fire.
                    .overlay {
                        if isShowingNextUp {
                            nextUpOverlay
                        }
                    }

                // Prominent UP entry point. Lives between the
                // player surface and the comments scroll so it
                // stays pinned in view as the user scrolls the
                // comments — the toolbar principal slot is too
                // small to be discoverable on its own. Uses
                // Apple's `NavigationLink(value:)` idiom so the
                // navigation is registered with the parent
                // `NavigationStack` (state-restorable, deep-
                // linkable, previewable). Hidden when
                // `ownerMid == 0` because many `BiliVideo`s
                // (history rows, search hits, dynamic-feed
                // archive) are synthesised with `ownerMid = 0`.
                if video.ownerMid > 0 {
                    upEntryCard
                        .transition(
                            .move(edge: .top)
                                .combined(with: .opacity)
                        )
                }

                commentsScrollView
            }
        }
        .background(Color.clear)
        .navigationTitle(model.detail.ownerName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Tappable owner-name button in the nav-bar centre.
            // Uses `NavigationLink(value:)` — Apple's official
            // idiom — so the destination is registered with the
            // parent `NavigationStack` rather than mutating the
            // router directly. The plain button style suppresses
            // the default link tint so the title keeps the
            // system chrome. Hidden when `ownerMid == 0` so
            // synthesised `BiliVideo`s (history rows, search
            // hits) fall back to plain title text.
            ToolbarItem(placement: .principal) {
                if video.ownerMid > 0 {
                    NavigationLink(value: UPProfileRoute.up(mid: video.ownerMid)) {
                        HStack(spacing: 4) {
                            Text(model.detail.ownerName)
                                .font(.headline)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看 UP 主 \(model.detail.ownerName) 的个人主页")
                    .accessibilityHint("打开 UP 主个人主页")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // ShareLink with the canonical Bilibili URL. The
                // `subject:` populates the Mail subject line and
                // Twitter/X title; the URL itself is what gets
                // handed to the system share sheet. The button
                // is hidden when `bvid` is empty (legacy `aid`-only
                // entries) so we never produce a malformed URL.
                if let shareURL = model.detail.shareURL {
                    ShareLink(
                        item: shareURL,
                        subject: Text(model.detail.title),
                        label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.medium))
                        }
                    )
                    .accessibilityLabel(L10n.common.share)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.selection()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isImmersiveMode.toggle()
                    }
                } label: {
                    Image(systemName: isImmersiveMode ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        .font(.body.weight(.medium))
                        .foregroundStyle(isImmersiveMode ? PaladalaTheme.biliPink : .primary)
                }
                .accessibilityLabel(isImmersiveMode ? "Exit immersive mode" : "Enter immersive mode")
            }
        }
        .modifier(VideoDetailToolbarGlassModifier(materialDesign: materialDesign))
        .task {
            // Hydrate the model from the persisted sort before the
            // first fetch — otherwise the in-memory `commentSort`
            // would always be `.hot` on a fresh mount and the user
            // would have to re-toggle the picker.
            let persisted = CommentSort(rawValue: storedCommentSort) ?? .hot
            if model.commentSort != persisted {
                model.commentSort = persisted
            }
            // Same pattern for preferred quality: hydrate from
            // `@AppStorage` so the playurl fetch honours the user's
            // last pick without a visible "load 1080P → refetch as
            // 720P" round-trip.
            if model.preferredQn != storedPreferredQn {
                model.preferredQn = storedPreferredQn
            }
            if model.subtitleEnabled != storedSubtitleEnabled {
                model.subtitleEnabled = storedSubtitleEnabled
            }
            await model.load(repository: repository)
            // PR-4 (M3): after load, surface the saved-time
            // confirmation sheet so the user can either continue
            // from where they left off or restart.  Gated > 30 s
            // of progress so trivial re-opens (skipped a tab,
            // came back) don't pepper the user.
            if let saved = PlayProgressStore.shared.lastProgress(for: model.detail.bvid),
               saved.currentTime > 30,
               let duration = playerController?.duration, duration > 0,
               saved.currentTime < duration - 30 {
                resumePromptSeconds = saved.currentTime
            }
        }
        .modifier(ResumePromptSheetModifier(
            seconds: $resumePromptSeconds,
            bvid: model.detail.bvid,
            continueAction: {
                Haptics.tap()
                playerController?.seek(to: resumePromptSeconds ?? 0)
                playerController?.play()
                resumePromptSeconds = nil
            },
            restartAction: {
                Haptics.tap()
                PlayProgressStore.shared.clear(bvid: model.detail.bvid)
                playerController?.seek(to: 0)
                playerController?.play()
                resumePromptSeconds = nil
            }
        ))
        // `initial: true` is REQUIRED for the offline (cached
        // video) path.  When `localRecord` is set, the model
        // already has a non-nil `playback` at construction time
        // (set in `VideoDetailViewModel.init` from the saved
        // `DownloadRecord.dash`); `model.load(...)` then
        // short-circuits because the local context already
        // covers playback.  In that case `model.playback`
        // transitions *zero times* after the view first appears,
        // so the plain `.onChange` would never fire and
        // `miniPlayerStore.bind(...)` would never run — leaving
        // `controller == nil`, the `PlayerView` branch never
        // entered, and the user staring at the CoverImage
        // fallback.  `initial: true` (iOS 17+) fires once on
        // first appear so the offline case is wired the same as
        // the online case.
        .onChange(of: model.playback, initial: true) { _, playback in
            // Hand the new playback off to the store. The store's
            // `bind(...)` is idempotent — if the same video is
            // already playing in the mini-player, the call is a
            // no-op and the player keeps running across the
            // mini-player → inline re-mount.
            guard let playback else { return }
            miniPlayerStore.bind(video: model.detail, playback: playback, repository: repository)
        }
        // Re-bind on every appearance so that returning from a
        // navigation-push sub-page (UP profile, replies) hides the
        // mini-player that `onDisappear` surfaced during the push.
        // `bind` is idempotent for the same video — it won't
        // restart playback or re-report `progress=0`.
        .onAppear {
            guard let playback = model.playback else { return }
            miniPlayerStore.bind(video: model.detail, playback: playback, repository: repository)
        }
        .onDisappear {
            // Suppress teardown during the iPad fullscreen quirk
            // (entering/leaving `.fullScreenCover` fires
            // `onDisappear` on the parent view). The grace window
            // also suppresses `detachInline` so the player does not
            // get re-bound mid-cover-dismissal.
            let now = Date()
            let isInsideFullscreenDismissGrace = now.timeIntervalSince(lastFullscreenDismissedAt) < 3
            let isNativeFullscreen = playerController?.isNativeFullscreenActive ?? false
            guard !isFullscreenPresented, !isNativeFullscreen, now >= fullscreenTransitionUntil, !isInsideFullscreenDismissGrace else {
                diagLog(.fullscreen, "onDisappear suppressed during fullscreen transition", details: [
                    "isPresented": isFullscreenPresented,
                    "nativeFullscreen": isNativeFullscreen,
                    "until": fullscreenTransitionUntil.timeIntervalSince1970,
                    "lastDismissedAt": lastFullscreenDismissedAt.timeIntervalSince1970,
                    "insideDismissGrace": isInsideFullscreenDismissGrace
                ])
                return
            }

            // Switch the inline player off; the store keeps the
            // AVPlayer running and flips `isShowingMiniPlayer` to
            // true so the overlay surfaces.
            diagLog(.playback, "VideoDetailView.onDisappear: detachInline")
            miniPlayerStore.detachInline()
            model.teardown()
        }
        .fullScreenCover(isPresented: $isFullscreenPresented) {
            if let playback = model.playback, let controller = playerController {
                FullscreenPlayerView(
                    video: model.detail,
                    playback: playback,
                    repository: repository,
                    subtitleTrack: model.subtitleEnabled ? model.subtitleTrack : nil,
                    danmakuItems: model.danmakuEnabled ? model.danmakuItems : [],
                    controller: controller
                )
            }
        }
        .onChange(of: isFullscreenPresented) { _, newValue in
            // The grace-window timestamps defend against the
            // iPad quirk where `.fullScreenCover` fires
            // `onDisappear` on the parent view.  AVKit now
            // owns the player layer (no manual layer swap), so
            // this is the only remaining piece of the
            // transition dance.  When fullscreen dismisses we
            // suppress teardown for ~1s so the parent view's
            // `onDisappear` does not kill the controller while
            // the cover is animating away.
            fullscreenTransitionUntil = Date().addingTimeInterval(1)
            if !newValue {
                lastFullscreenDismissedAt = Date()
            }
            diagLog(.fullscreen, "Fullscreen presentation changed", details: ["isPresented": newValue])
        }
        // Hero / zoom transition — only attached when a
        // namespace is available. The system looks up the
        // source view by `video.id` (the same string the
        // `VideoCard` used for `matchedTransitionSource`) and
        // animates a zoom between the card's cover image and
        // this view's body. Without a namespace the
        // transition falls back to the standard
        // cross-fade.
        .modifier(HeroDestinationModifier(videoID: video.id, namespace: heroNamespace))
        // YouTube-style "next up" + auto-play. Listens for
        // the `.paladalaVideoDidPlayToEnd` notification that
        // `AVPlayerController` posts when the current item
        // reaches its end. Branches on the user's auto-play
        // preference:
        //   - `autoPlayNext` on  → countdown overlay
        //     (5 s) then auto-advance via `advanceToNextUp()`.
        //   - `autoPlayNext` off → still surface the overlay
        //     but no countdown; the user has to tap "立即播放"
        //     or "取消" to dismiss.
        .onReceive(NotificationCenter.default.publisher(for: .paladalaVideoDidPlayToEnd)) { _ in
            handleVideoDidEnd()
        }
        // Reset the auto-play cursor on first appear so a
        // fresh VideoDetailView always starts from the top
        // of the recommendation queue.
        .task {
            model.resetNextUpCursor()
        }
    }

    /// Inner `ScrollView` containing the title, controls, and
    /// comments. Two geometry listeners run on it:
    ///
    /// 1. **Comment pagination** — fires `loadMoreComments` when
    ///    the user is within 200pt of the bottom of the comment
    ///    list. The `hasScrolled` guard (contentOffset > 1pt)
    ///    prevents the very first render from auto-loading.
    /// 2. **Player scale** — maps content offset 0..240pt to
    ///    `playerScale` 1.0..0.5. Scrolling down shrinks the
    ///    player; scrolling back up grows it back to its rest
    ///    size. Animated with a spring for a smooth feel.
    /// Prominent UP entry card. Renders between the player
    /// surface and the comments scroll so it stays pinned in
    /// view while the user scrolls the comments — the
    /// toolbar-principal button is too small to be
    /// discoverable on its own. The whole row is wrapped in a
    /// `NavigationLink(value:)` so the push is registered
    /// with the parent `NavigationStack` (state-restorable,
    /// deep-linkable, previewable). We do not surface an
    /// avatar here because `BiliVideo` does not carry one
    /// (the upstream `/x/web-interface/view` endpoint
    /// returns a `pic` cover but not an owner face URL) —
    /// keeping the row text-only avoids a placeholder gap.
    private var upEntryCard: some View {
        NavigationLink(value: UPProfileRoute.up(mid: video.ownerMid)) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(PaladalaTheme.biliPink)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.detail.ownerName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("查看 UP 主个人主页")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius,
                                 style: PaladalaTheme.cornerStyle)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius,
                                           style: PaladalaTheme.cornerStyle))
        }
        .buttonStyle(PaladalaPressBounceButtonStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开 UP 主个人主页")
    }

    private var commentsScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleBlock
                if aiSummaryShouldRender {
                    aiSummarySection
                }
                controlPanel
                commentPreview
                if !model.relatedVideos.isEmpty {
                    relatedVideosSection
                        // Force a fresh transition when the rail
                        // first populates — the parent VStack
                        // doesn't re-key on `model.relatedVideos`
                        // (we use `.id(...)` on the section group
                        // for the tab-switch animation in
                        // UPProfileView but here the same
                        // behaviour is implicit).
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(16)
        }
        .modifier(CommentScrollGeometryModifier(
            model: model,
            repository: repository,
            playerScale: $playerScale
        ))
    }

    /// Three states collapse to one boolean so the
    /// `commentsScrollView` VStack stays scannable:
    ///   - loading + no data: show shimmer placeholder
    ///   - has data: show expandable card
    ///   - unavailable / no data: hide entirely (graceful absence)
    private var aiSummaryShouldRender: Bool {
        if model.aiSummary != nil { return true }
        if model.aiSummaryLoading { return true }
        return false
    }

    @ViewBuilder
    private var playerSurface: some View {
        ZStack(alignment: .topLeading) {
            if let playback = model.playback, let controller = playerController {
                // Keep the inline player in the hierarchy while
                // fullscreen is presented. Removing it causes AVKit
                // to briefly detach the player during the transition,
                // leading to connection resets and black screens.
                // The `.fullScreenCover` naturally hides it anyway.
                PlayerView(
                    playback: playback,
                    video: model.detail,
                    repository: repository,
                    subtitleTrack: model.subtitleEnabled ? model.subtitleTrack : nil,
                    danmakuItems: model.danmakuEnabled ? model.danmakuItems : [],
                    controller: controller
                )
                    .onAppear { model.isPlaying = true }
                    .onDisappear { model.isPlaying = false }

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
            // The inline surface no longer draws custom fullscreen chrome;
            // AVKit's native controls already provide that button. Timed
            // text now lives inside PlayerView so it follows inline and
            // fullscreen playback surfaces consistently.
        }
        // No aspectRatio here — the parent `body`'s GeometryReader
        // gives the surface a fixed `height` from the
        // `playerScale` interpolation. The 16:9 video letterboxes
        // inside whatever frame we give it. We `.clipped()` so
        // when the player shrinks to 50% the cover and chrome
        // don't bleed past the new height. The `.clipShape`
        // rounds the outer corners — the custom player controls
        // (play/pause, skip) sit in the centre of the view and
        // are not clipped by the rounded rectangle.
        .clipShape(RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
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
        // Five chips: subtitle, danmaku, quality, download, coin.
        // The previous iteration also exposed a 倍速 menu, but
        // AVPlayerViewController already surfaces the same set
        // natively (long-press the play button → speed picker)
        // so keeping a duplicate here caused the two surfaces to
        // drift — clearing it lets the AVKit path own speed.
        HStack(spacing: 8) {
            subtitleChip
            danmakuChip
            qualityMenu
            downloadButton
            coinButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .paladalaCardSurface(materialDesign)
        // Coin-banner overlay anchored to the bottom of the
        // card.  Renders only while `model.coinToast` is set,
        // auto-dismisses via `Task.sleep` in the model so the
        // view stays declarative.
        .overlay(alignment: .bottom) {
            if let toast = model.coinToast {
                CoinToastBanner(text: toast)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86),
                   value: model.coinToast)
    }

    /// Subtitle toggle.  Disabled when the upstream didn't
    /// publish a timed-text track for the active video — the
    /// button dims and ignores taps in that case.
    private var subtitleChip: some View {
        Toggle(isOn: $model.subtitleEnabled) {
            // Animated icon swap: outlined glyph when off, filled
            // when on, with a 220 ms crossfade + slight scale
            // so toggling feels deliberate rather than binary.
            Image(systemName: model.subtitleEnabled
                  ? "captions.bubble.fill"
                  : "captions.bubble")
                .contentTransition(.symbolEffect(.replace.downUp))
        }
        .toggleStyle(.button)
        .disabled(model.subtitleTrack == nil)
        .buttonStyle(PaladalaActionPillStyle(accent: .blue))
        .onChange(of: model.subtitleEnabled) { _, newValue in
            storedSubtitleEnabled = newValue
        }
    }

    /// Danmaku toggle.  Same animation contract as
    /// `subtitleChip` so the two toggles feel like a pair.
    private var danmakuChip: some View {
        Toggle(isOn: $model.danmakuEnabled) {
            Image(systemName: model.danmakuEnabled
                  ? "text.bubble.fill"
                  : "text.bubble")
                .contentTransition(.symbolEffect(.replace.downUp))
        }
        .toggleStyle(.button)
        .buttonStyle(PaladalaActionPillStyle(accent: PaladalaTheme.biliPink))
    }

    /// Download button.  Renders one of four labels
    /// depending on `model.downloadState`:
    ///   - `.notDownloaded`     → "下载" + down arrow
    ///   - `.downloading(p)`    → "\(p*100)%" + stop icon,
    ///     second tap cancels
    ///   - `.downloaded`        → "已下载" + checkmark
    ///   - `.failed(message)`   → "重试下载" + retry icon
    ///
    /// Disabled (and dimmed) when the device is offline or
    /// the playback has not yet loaded — the network is
    /// required to fetch the DASH manifest that backs a
    /// download, and the user is not yet looking at a video
    /// they could want to keep.
    private var downloadButton: some View {
        let canStart = model.playback != nil
        return Button {
            Haptics.tap()
            model.onDownloadTap()
        } label: {
            downloadButtonLabel
        }
        .buttonStyle(PaladalaActionPillStyle(accent: PaladalaTheme.biliPink))
        .disabled(!canStart)
        .opacity(canStart ? 1 : 0.5)
    }

    /// Pure value builder for the download button label.
    /// Pulled out of `downloadButton` so the parent can stay
    /// a regular `some View` (no `@ViewBuilder` gymnastics
    /// around a `let` + `switch`).  Uses `.contentTransition`
    /// so the icon swaps with a 220 ms crossfade when the
    /// download state flips — the user gets a clear "the
    /// button did something" cue without us adding an extra
    /// spinner overlay.
    @ViewBuilder
    private var downloadButtonLabel: some View {
        switch model.downloadState {
        case .notDownloaded:
            Label {
                Text("下载")
            } icon: {
                Image(systemName: "arrow.down.circle")
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
        case .downloading(let p):
            Label {
                Text("\(Int(p * 100))%")
            } icon: {
                Image(systemName: "stop.fill")
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
        case .downloaded:
            Label {
                Text("已下载")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
        case .failed:
            Label {
                Text("重试下载")
            } icon: {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
        }
    }

    /// 投币 (B-coin) button.  The label flips to a filled
    /// glyph + count chip once the user has given at least one
    /// coin, so the action bar surfaces both the action and its
    /// current state in a single tap target.  The 1x / 2x
    /// choice lives in the menu so the chip itself stays a
    /// single tap ("give one more"); long-press / chevron pick
    /// for "give two at once" is exposed for power users.
    private var coinButton: some View {
        Menu {
            Button {
                Haptics.tap()
                Task {
                    await model.giveCoins(multiply: 1, repository: repository)
                    scheduleCoinToastDismiss()
                }
            } label: {
                Label("投 1 枚硬币", systemImage: "bitcoinsign.circle")
            }
            Button {
                Haptics.tap()
                Task {
                    await model.giveCoins(multiply: 2, repository: repository)
                    scheduleCoinToastDismiss()
                }
            } label: {
                Label("投 2 枚硬币", systemImage: "bitcoinsign.circle.fill")
            }
            if model.coinGiven > 0 {
                Divider()
                Text("已投 \(model.coinGiven) 枚")
            }
        } label: {
            // The label crosses between three visual states:
            //   idle / dimmed        — outline glyph + "投币"
            //   pending              — outline + progressView
            //   given (≥ 1)          — filled glyph + count chip
            // `.contentTransition` crossfades the icon swap so
            // the state change reads as motion, not a blink.
            HStack(spacing: 4) {
                if model.coinInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: model.coinGiven > 0
                          ? "bitcoinsign.circle.fill"
                          : "bitcoinsign.circle")
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
                Text(model.coinGiven > 0 ? "已投 \(model.coinGiven)" : "投币")
                    .contentTransition(.numericText(value: Double(model.coinGiven)))
            }
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(PaladalaActionPillStyle(accent: .orange))
        .disabled(model.coinInFlight)
    }

    /// Auto-dismiss the coin-success toast after ~1.6 s.
    /// Lives on the view so the timer survives re-renders of
    /// `controlPanel` (a `Task` captured inside `model` would
    /// get cancelled when the view disappears and re-appears).
    private func scheduleCoinToastDismiss() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            model.clearCoinToast()
        }
    }

    /// Bilibili official "AI 视频总结" card. Header row is
    /// always visible (while data exists or is loading); the
    /// prose + chapter outline render only when expanded.
    /// Tapping a chapter seeks the player to that timestamp
    /// via `VideoDetailViewModel.seekAIOutline(...)`.
    private var aiSummarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.aiSummaryExpanded.toggle()
                }
                Haptics.selection()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(PaladalaTheme.biliPink)
                    Text(L10n.aiSummary.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if model.aiSummaryLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else if let summary = model.aiSummary {
                        Text("\(summary.outline.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Image(systemName: model.aiSummaryExpanded
                              ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(model.aiSummaryExpanded
                               ? "Tap to collapse"
                               : "Tap to expand")

            if model.aiSummaryExpanded, let summary = model.aiSummary {
                aiSummaryExpandedBody(summary)
            }
        }
        .padding(14)
        .paladalaCardSurface(materialDesign)
    }

    /// Body of the AI summary card (rendered only when expanded).
    /// Renders the Markdown prose via `Text(.init(...))` so
    /// `**bold**`, `_italic_`, and `[link](url)` survive without
    /// pulling in a Markdown parser; the outline is a chapter
    /// header row plus a list of bullet rows under it, each of
    /// which seeks the player to its own timestamp.
    @ViewBuilder
    private func aiSummaryExpandedBody(_ summary: BiliAISummary) -> some View {
        if !summary.summary.isEmpty {
            Text(.init(summary.summary))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if !summary.outline.isEmpty {
            Divider().padding(.vertical, 4)
            Text(L10n.aiSummary.chapters)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(summary.outline) { chapter in
                    chapterHeader(chapter)
                    if !chapter.partOutline.isEmpty {
                        ForEach(chapter.partOutline) { bullet in
                            bulletRow(bullet)
                        }
                    }
                    if chapter.id != summary.outline.last?.id {
                        Divider().padding(.vertical, 6)
                    }
                }
            }
        }
    }

    /// Chapter header row in the AI outline. Tapping it seeks
    /// to the chapter's start timestamp and provides the chapter
    /// title + bullet count.
    @ViewBuilder
    private func chapterHeader(_ chapter: BiliAISummaryChapter) -> some View {
        Button {
            model.seekAIOutline(
                toSeconds: Double(chapter.timestamp),
                controller: playerController
            )
            Haptics.tap()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(chapter.timestampLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PaladalaTheme.biliPink)
                    .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                    if !chapter.partOutline.isEmpty {
                        Text("\(chapter.partOutline.count) 个要点")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle")
                    .font(.callout)
                    .foregroundStyle(PaladalaTheme.biliPink.opacity(0.85))
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chapter.timestampLabel) \(chapter.title)")
        .accessibilityHint(L10n.aiSummary.seekHint)
    }

    /// One bullet row nested inside a chapter. The wire shape
    /// (`outline[].part_outline[]`) gives every bullet its own
    /// timestamp the player can seek to, so bullets are their
    /// own tap targets rather than passive text.
    @ViewBuilder
    private func bulletRow(_ bullet: BiliAISummaryBullet) -> some View {
        Button {
            model.seekAIOutline(
                toSeconds: Double(bullet.timestamp),
                controller: playerController
            )
            Haptics.tap()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(bullet.timestampLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PaladalaTheme.biliPink.opacity(0.85))
                    .frame(width: 52, alignment: .leading)
                Text(bullet.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(bullet.timestampLabel) \(bullet.content)")
        .accessibilityHint(L10n.aiSummary.seekHint)
    }

    /// Quality menu lifted out of `controlPanel` so the helper that
    /// maps qn code → label stays scoped to this file. The menu
    /// itself is a standard SwiftUI `Menu` — no custom chrome — so
    /// it inherits the same Liquid Glass background the rest of the
    /// toolbar uses.
    private var qualityMenu: some View {
        Menu {
            ForEach([80, 64, 32, 16], id: \.self) { qn in
                Button {
                    guard model.preferredQn != qn else { return }
                    storedPreferredQn = qn
                    Task { await model.setPreferredQn(qn, repository: repository) }
                } label: {
                    if model.preferredQn == qn {
                        Label(qnLabel(qn), systemImage: "checkmark")
                    } else {
                        Text(qnLabel(qn))
                    }
                }
            }
        } label: {
            Label(qnLabel(model.preferredQn), systemImage: "rectangle.stack.badge.play")
        }
        .accessibilityLabel(L10n.player.quality)
    }

    /// Map a Bilibili `accept_quality` ladder code to the
    /// user-facing label. Anything outside the modelled ladder
    /// (e.g. an unknown `qn` slipped in by an upstream change)
    /// falls back to a plain "<qn>P" string so the menu never
    /// renders empty.
    private func qnLabel(_ qn: Int) -> String {
        switch qn {
        case 80: return L10n.player.quality1080
        case 64: return L10n.player.quality720
        case 32: return L10n.player.quality480
        case 16: return L10n.player.quality360
        default: return "\(qn)P"
        }
    }

    private var commentPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
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
                        // The count flips from "—" (loading) to a
                        // real number on first paint. The
                        // spring-in transition makes the badge
                        // feel "discovered" rather than
                        // appearing flat.
                        .transition(.scale.combined(with: .opacity))
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: model.comments.count)
                }
                commentSortPicker
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
        .paladalaCardSurface(materialDesign)
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
    private var commentSortPicker: some View {
        Picker("Comment sort", selection: Binding(
            get: { CommentSort(rawValue: storedCommentSort) ?? .hot },
            set: { newValue in
                storedCommentSort = newValue.rawValue
                Task { await model.setCommentSort(newValue, repository: repository) }
            }
        )) {
            ForEach(CommentSort.allCases) { sort in
                Text(sort.title).tag(sort)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityLabel("Comment sort order")
    }

    private var loadMoreFooter: some View {
        Group {
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
                        Haptics.success()
                    } else {
                        Haptics.error()
                    }
                    isSubmittingComment = false
                }
            } label: {
                if isSubmittingComment {
                    ProgressView().controlSize(.small)
                } else {
                    // Mixed-script bug fix from A11y honourable
                    // mentions — the rest of the app is 简体 so
                    // the comment-publish button was reading
                    // 繁體 against the rest.  Use the localized key.
                    Text(L10n.video.publish)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(newCommentText.isEmpty || isSubmittingComment)
        }
    }

    /// YouTube-style "推荐" rail. Horizontal scroll of
    /// `model.relatedVideos` cards; tapping one pushes a new
    /// `VideoDetailView` for that bvid (the parent
    /// `NavigationStack` already handles the push via
    /// `BiliVideo` as the navigation value).
    private var relatedVideosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("相关推荐")
                    .font(.headline)
                Spacer()
                if UserDefaults.standard.bool(forKey: "paladala.autoPlayNext") {
                    Label("自动播放下一集", systemImage: "play.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(PaladalaTheme.biliPink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            PaladalaTheme.biliPink.opacity(0.12),
                            in: Capsule()
                        )
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(model.relatedVideos.enumerated()), id: \.element.id) { index, video in
                        NavigationLink(value: video) {
                            RelatedVideoCard(video: video, isNextUp: model.nextUpIndex == index)
                                .frame(width: 200)
                        }
                        .buttonStyle(PaladalaPressBounceButtonStyle())
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(14)
        .paladalaCardSurface(materialDesign)
    }

    /// YouTube-style "next up" overlay shown briefly when the
    /// current video reaches its end and the user has the
    /// auto-play queue populated. Shows the next-up cover +
    /// title with a 5-second countdown; tapping the overlay
    /// jumps to it immediately. Auto-dismisses when the
    /// countdown hits zero — the parent view then either
    /// navigates to the next-up (when `autoPlayNext` is on)
    /// or hides the overlay.
    @ViewBuilder
    private var nextUpOverlay: some View {
        if isShowingNextUp {
            // PR-6 (M4): the overlay is now always rendered when
            // the video ends.  When the related-queue is empty
            // (`nextUpIndex == nil` or out of range) we still
            // surface a "replay / back to feed" card so the user
            // has somewhere to go from the end-of-video state
            // instead of being stuck on the last frame.
            let hasQueue: Bool = {
                guard let next = model.nextUpIndex else { return false }
                return next < model.relatedVideos.count
            }()
            VStack(spacing: 12) {
                if hasQueue, let next = model.nextUpIndex,
                   next < model.relatedVideos.count {
                    let video = model.relatedVideos[next]
                    Text("下一个视频")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    CoverImage(url: video.coverURL)
                        .frame(width: 200, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                } else {
                    Text("已经看完了")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                HStack(spacing: 12) {
                    if hasQueue {
                        Button {
                            Haptics.tap()
                            advanceToNextUp()
                        } label: {
                            Label("立即播放", systemImage: "play.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                    } else {
                        // PR-6 (M4) end-of-video replay path.  The
                        // original code rendered the overlay only
                        // when there was a queue; empty-queue
                        // videos (very common — most older clips
                        // have no related list) left the user
                        // stranded.  Always offer replay + back.
                        Button {
                            Haptics.tap()
                            controller?.seek(to: 0)
                            controller?.play()
                            withAnimation(.easeInOut(duration: 0.22)) {
                                isShowingNextUp = false
                            }
                        } label: {
                            Label("重新播放", systemImage: "arrow.counterclockwise")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                        Button {
                            Haptics.tap()
                            withAnimation(.easeInOut(duration: 0.22)) {
                                isShowingNextUp = false
                            }
                            router.open(.home)
                        } label: {
                            Label("回到首页", systemImage: "house.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }
                if isCountingDownToNext && hasQueue {
                    Text("\(nextUpCountdown) 秒后自动播放")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .transition(.opacity)
                }
            }
            .padding(20)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    /// Helper invoked from both the "立即播放" button and the
    /// countdown-timer expiry. Pops the next-up entry off the
    /// queue, navigates to it, and resets the cursor.
    private func advanceToNextUp() {
        guard let video = model.consumeNextUp() else { return }
        nextUpCountdownTask?.cancel()
        withAnimation(.easeInOut(duration: 0.22)) {
            isShowingNextUp = false
            isCountingDownToNext = false
        }
        router.openVideo(video)
    }

    /// End-of-stream handler. Subscribed to
    /// `.paladalaVideoDidPlayToEnd`. Branches on the user's
    /// `paladala.autoPlayNext` preference:
    ///   - off: surface the overlay with no countdown; user
    ///     must tap "立即播放" or "取消".
    ///   - on: start a 5 s countdown that auto-advances.
    ///
    /// Skipped entirely when the recommendation queue is
    /// empty (Bilibili returned no related videos) so the
    /// user doesn't see an overlay with no actionable
    /// content.
    private func handleVideoDidEnd() {
        nextUpCountdownTask?.cancel()
        nextUpCountdown = Self.nextUpCountdownDuration
        // PR-6 (M4): always render the end-overlay, even when the
        // related-queue is empty.  Previously the early-return
        // left the player frozen on the last frame with no CTA.
        // The conditional inside the overlay (`hasQueue`) flips the
        // body between "Replay + Back-to-feed" and the normal
        // "立即播放 next" countdown.
        let hasQueue = (model.nextUpIndex != nil)
            && (model.nextUpIndex ?? 0) < model.relatedVideos.count
        if !hasQueue {
            // No queue → show the static "replay + return" card.
            isCountingDownToNext = false
            withAnimation(.easeInOut(duration: 0.22)) {
                isShowingNextUp = true
            }
            return
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            isShowingNextUp = true
            isCountingDownToNext = UserDefaults.standard.bool(forKey: "paladala.autoPlayNext")
        }
        guard isCountingDownToNext else { return }
        nextUpCountdownTask = Task { @MainActor in
            while nextUpCountdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                nextUpCountdown -= 1
            }
            advanceToNextUp()
        }
    }
}

private struct CommentRow: View {
    let comment: BiliComment
    let video: BiliVideo
    let repository: PaladalaRepository
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
                        .fill(PaladalaTheme.biliPink.opacity(0.18))
                        .overlay(Image(systemName: "person.fill").foregroundStyle(PaladalaTheme.biliPink))
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
                        Haptics.tap()
                        Task {
                            await model.performCommentAction(repository: repository, rpid: comment.id, actionType: "like")
                            Haptics.success()
                        }
                    } label: {
                        Label(comment.likeCount.compactCount, systemImage: "hand.thumbsup")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(PaladalaPressBounceButtonStyle())
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
                                        .foregroundStyle(PaladalaTheme.biliPink)
                                        .padding(.top, 2)
                                }
                            }
                            .padding(.top, 2)
                        } else if comment.replyCount > 0 {
                            Text("查看全部 \(comment.replyCount) 条回复 >")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PaladalaTheme.biliPink)
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
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: PaladalaTheme.cornerRadius, style: PaladalaTheme.cornerStyle)
        )
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
                        RoundedRectangle(cornerRadius: PaladalaTheme.pillRadius, style: PaladalaTheme.cornerStyle)
                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            .frame(width: 120, height: 12)
                        RoundedRectangle(cornerRadius: PaladalaTheme.pillRadius, style: PaladalaTheme.cornerStyle)
                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            .frame(height: 12)
                        RoundedRectangle(cornerRadius: PaladalaTheme.pillRadius, style: PaladalaTheme.cornerStyle)
                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            .frame(width: 210, height: 12)
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
    }
}

/// Applies `.navigationTransition(.zoom(sourceID:in:))` only
/// when a namespace is available AND the runtime OS is iOS 18+
/// (the API was introduced in iOS 18). On iOS 17 the modifier is
/// a no-op and the system cross-fade is used.
private struct HeroDestinationModifier: ViewModifier {
    let videoID: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace, #available(iOS 18, *) {
            content.navigationTransition(.zoom(sourceID: videoID, in: namespace))
        } else {
            content
        }
    }
}

/// Attaches the two `onScrollGeometryChange` modifiers that drive
/// the comment-pagination auto-load and the player-scale
/// interpolation. Extracted so we can gate the whole modifier
/// behind `if #available(iOS 18, *)` (the API was introduced in
/// iOS 18) and keep `commentsScrollView` itself a simple
/// `some View`. The iOS 17 build gets the scroll view without
/// any of the geometry listeners — pagination falls back to the
/// manual "加载更多评论" button in `loadMoreFooter`, and the
/// player stays at its rest size.
private struct CommentScrollGeometryModifier: ViewModifier {
    let model: VideoDetailViewModel
    let repository: PaladalaRepository
    @Binding var playerScale: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
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
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    // Map offset 0..240pt to scale 1.0..0.5. The wider
                    // the range, the gentler the shrink. We anchor at
                    // 0.5 (not 0.0) so even at maximum scroll the
                    // player is never smaller than 50% of the screen.
                    let normalized = min(1.0, max(0.0, geometry.contentOffset.y / 240))
                    return 1.0 - normalized * 0.5
                } action: { _, newScale in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        playerScale = newScale
                    }
                }
        } else {
            content
        }
    }
}

/// Applies Liquid Glass background to the video detail toolbar.
private struct VideoDetailToolbarGlassModifier: ViewModifier {
    let materialDesign: MaterialDesign

    func body(content: Content) -> some View {
        if materialDesign == .liquidGlass {
            content.paladalaNavBarGlass(.liquidGlass)
        } else {
            content
        }
    }
}

/// One card in the "相关推荐" rail. Mirrors the
/// `VideoCard` chrome but in a horizontal-card aspect —
/// 16:9 cover + two-line title + meta line. When
/// `isNextUp` is true the card gets a pink "下一个" pill
/// so the user can see which video is queued for
/// auto-play without expanding the overlay.
private struct RelatedVideoCard: View {
    let video: BiliVideo
    let isNextUp: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                // See `VideoCard.coverImage` for the sizing story.
                // Same Rectangle() + .aspectRatio(16/10, .fit) +
                // overlay pattern — applying `.fill` directly to
                // CoverImage was the pre-2d1105d1 bug that collapsed
                // the cell height in the "下一个" rail.
                Rectangle()
                    .fill(.clear)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        CoverImage(url: video.coverURL)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: PaladalaTheme.cardRadius, style: PaladalaTheme.cornerStyle))
                if video.duration > 0 {
                    Text(video.duration.mmss)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: PaladalaTheme.pillRadius, style: PaladalaTheme.cornerStyle))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                if isNextUp {
                    Text("下一个")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(PaladalaTheme.biliPink, in: Capsule())
                        .padding(6)
                }
            }
            Text(video.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(video.ownerName)
                    .lineLimit(1)
                Text("·")
                Label(video.viewCount.compactCount, systemImage: "play.fill")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(8)
        .paladalaCardSurface(.liquidGlass)
    }
}

/// Transient banner shown under the player action bar after a
/// 投币 attempt.  Renders the upstream reason on failure or a
/// success line on success, auto-dismisses via the
/// `scheduleCoinToastDismiss()` task on the parent view.  The
/// banner uses `.move(edge:).combined(with: .opacity)` so it
/// slides up + fades in and reverses on dismiss — the same
/// contract used elsewhere in the app for transient chrome.
private struct CoinToastBanner: View {
    let text: String
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bitcoinsign.circle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: PaladalaTheme.cardRadius,
                style: PaladalaTheme.cornerStyle
            )
            .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: PaladalaTheme.cardRadius,
                style: PaladalaTheme.cornerStyle
            )
            .strokeBorder(PaladalaTheme.biliPink.opacity(0.3), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        .paladalaCardSurface(materialDesign)
    }
}

/// Tiny value type used as the `.sheet(item:)` payload so the
/// resume-prompt sheet can present a single chunk of state.
/// `.id` is the timestamp; SwiftUI's `.sheet(item:)` requires
/// `Identifiable`.
private struct ResumePromptChoice: Identifiable, Hashable {
    let seconds: Double
    var id: Double { seconds }
}

/// PR-4 (M3) "Continue from where you left off" sheet.  Lifted
/// out of `VideoDetailView.body` so the latter stays under the
/// SwiftUI type-checker budget.  Always renders "重新播放" as the
/// secondary action — premium apps all leave that path explicit
/// rather than absorbing it into "继续观看".
private struct ResumePromptSheet: View {
    let seconds: Double
    let onContinue: () -> Void
    let onRestart: () -> Void
    let onDismiss: () -> Void

    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    private var mmss: String {
        let total = max(0, Int(seconds))
        let mm = total / 60
        let ss = total % 60
        return String(format: "%02d:%02d", mm, ss)
    }

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
            Text("继续观看 \(mmss)？")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("上次你看到这里了，要不要接着看？")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                Button {
                    onDismiss()
                } label: {
                    Text("重新播放")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    onContinue()
                } label: {
                    Text("继续观看")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(PaladalaTheme.biliPink)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .padding(.vertical, 4)
        .paladalaCardSurface(materialDesign)
    }
}

/// PR-4 (M3) wrapper that keeps the resume-prompt sheet
/// decoupled from the parent body so `VideoDetailView.body`
/// stays under the SwiftUI type-checker budget.  See the
/// companion `HomeSearchModifier` from PR-2 for the same
/// pattern applied to the home search field.
private struct ResumePromptSheetModifier: ViewModifier {
    @Binding var seconds: Double?
    let bvid: String
    let continueAction: () -> Void
    let restartAction: () -> Void

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { seconds.map { ResumePromptChoice(seconds: $0) } },
            set: { seconds = $0?.seconds }
        )) { choice in
            ResumePromptSheet(
                seconds: choice.seconds,
                onContinue: continueAction,
                onRestart: restartAction,
                onDismiss: { seconds = nil }
            )
            .presentationDetents([.height(220)])
            .presentationDragIndicator(.visible)
        }
    }
}
