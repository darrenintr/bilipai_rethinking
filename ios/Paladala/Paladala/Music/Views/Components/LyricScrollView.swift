import SwiftUI

// MARK: - LyricScrollView
//
// Moved from MusicHomeView.swift as part of the music section
// reintroduction (Phase 0b — directory regrouping). Behaviour is
// byte-for-byte identical to the original; only the file location
// and the file-level documentation header changed.
//
// Apple-Music-style scrolling lyrics. The active line is bold
// and tinted with the brand pink; the lines above and below
// fade out. Tapping a line seeks the player to that timestamp.
//
// The view drives its own scroll state via `ScrollViewReader` —
// when `currentTime` crosses a line boundary, we call
// `proxy.scrollTo(activeID, anchor: .center)`. The auto-scroll
// is suppressed for a few seconds after a tap so the user can
// read a line they jumped to without us yanking them back to
// the playhead.

struct LyricScrollView: View {
    let track: BiliLyricTrack?
    /// Observed directly so the view re-renders every time the
    /// player's periodic time observer publishes a new
    /// `currentTime`. Reading the value at the call site
    /// (`controller?.currentTime ?? 0`) wouldn't subscribe
    /// SwiftUI to the `@Published` change, leaving the
    /// active-line highlight stuck on whichever line was
    /// active at first render.
    @ObservedObject var controller: PlayerController
    /// PR-5 (M5): last-seen active-line index so we only call
    /// `proxy.scrollTo` when the line actually changes.  Without
    /// this cache every `currentTime` tick (now throttled to 1 Hz
    /// but still every second) re-runs `scrollTo(id, anchor: .center)`
    /// with the same target, churning the scroll view and
    /// re-animating the active-line highlight.
    @State private var lastActiveIndex: Int?
    /// Fires when the user taps a lyric line. The owner wires
    /// this to `controller.seek(to:)` — without it the tap
    /// only flips a `@State` and never moves the playhead.
    let onSeek: (Double) -> Void

    @State private var userScrolledAt: Date?
    @State private var userSelectedLineID: Int?

    /// Reuse the bottom-line index from the track so we don't
    /// recompute on every `currentTime` tick.
    private var activeIndex: Int {
        track?.index(at: controller.currentTime) ?? 0
    }

    /// `true` while the user-initiated seek window is open —
    /// the auto-scroll logic skips the scrollTo during this
    /// window so the line they tapped stays centred.
    private var isInUserSeekWindow: Bool {
        guard let userScrolledAt else { return false }
        return Date().timeIntervalSince(userScrolledAt) < 4
    }

    var body: some View {
        Group {
            if let track, !track.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            // Top spacer pushes the first line down
                            // so the active line is vertically
                            // centred.
                            Color.clear.frame(height: 80)
                            ForEach(track.lines) { line in
                                LyricLineView(
                                    line: line,
                                    isActive: line.id == track.lines[activeIndex].id,
                                    isSelected: line.id == userSelectedLineID
                                )
                                .id(line.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    userScrolledAt = Date()
                                    userSelectedLineID = line.id
                                    // The whole point of Apple-Music-style
                                    // lyrics: tap a line to jump there.
                                    // Without this the tap only flipped
                                    // the highlight and the user had to
                                    // slide back to the playhead.
                                    onSeek(line.startTime)
                                }
                            }
                            Color.clear.frame(height: 80)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                    }
                    .onChange(of: controller.currentTime) { _, newTime in
                        guard !isInUserSeekWindow, !track.lines.isEmpty else { return }
                        // Look up the active index for `newTime`
                        // explicitly — `activeIndex` reads from the
                        // *previous* `currentTime` until SwiftUI
                        // re-evaluates `body`, and the animation
                        // would otherwise target the wrong line.
                        let next = track.index(at: newTime)
                        if next == lastActiveIndex { return }
                        lastActiveIndex = next
                        let id = track.lines[next].id
                        withAnimation(.easeInOut(duration: 0.32)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onAppear {
                        guard !track.lines.isEmpty else { return }
                        let id = track.lines[activeIndex].id
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(L10n.music.noLyrics)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - LyricLineView
//
// Moved from MusicHomeView.swift as part of the music section
// reintroduction (Phase 0b — directory regrouping). Behaviour is
// byte-for-byte identical to the original.

struct LyricLineView: View {
    let line: BiliLyricLine
    let isActive: Bool
    let isSelected: Bool

    var body: some View {
        Text(line.text)
            .font(isActive ? PaladalaTheme.FontRole.sectionHeader : PaladalaTheme.FontRole.body)
            .foregroundStyle(foreground)
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            .padding(.horizontal, isActive ? 8 : 0)
            .padding(.vertical, isActive ? 6 : 2)
            .background(isActive ? PaladalaTheme.biliPink : Color.clear)
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .frame(width: 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.24), value: isActive)
    }

    private var foreground: Color {
        if isActive { return PaladalaTheme.ink }
        if isSelected { return PaladalaTheme.biliPink.opacity(0.7) }
        if line.isMetadata { return .secondary.opacity(0.5) }
        return .secondary
    }
}