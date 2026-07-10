import SwiftUI
import UIKit

// MARK: - 追番 home
//
// First-pass surface for the 追番 feature.  Renders the
// weekly PGC timeline (七天: 周一 … 周日) with one strip
// per day and a horizontal scroll of season cards inside
// the selected day.  Tapping a card opens the season's
// canonical share URL in the system handler so the user
// lands on Bilibili's official web surface (or the official
// app via Universal Links) — we don't ship an in-app
// detail or player for PGC content in this first pass.
//
// Wired via the existing `RootView.navigationDestination(for:)`
// machinery: the profile screen's "追番追剧" quick action
// pushes a `BangumiRoute.timeline` onto the root nav stack
// and the destination resolves to this view.
//
// See `BilibiliAPIClient.bangumiTimeline(...)` for the
// network half and `Models.swift` for the `BangumiCard` /
// `BangumiDay` shapes.

struct BangumiHomeView: View {
    let repository: PaladalaRepository
    /// Optional namespace for any future hero / matched-
    /// transition animation. Currently unused but kept on
    /// the signature so the destination can be added
    /// without churning every call site.
    let heroNamespace: Namespace.ID?

    @State private var days: [BangumiDay] = []
    @State private var selectedWeekday: Int = Calendar.current.component(.weekday, from: Date())
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        Group {
            if isLoading && days.isEmpty {
                loadingView
            } else if let loadError, days.isEmpty {
                errorView(message: loadError)
            } else if days.isEmpty {
                emptyView
            } else {
                contentView
            }
        }
        .navigationTitle("追番")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PaladalaTheme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await load()
        }
        .refreshable {
            await load(force: true)
        }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            weekdayStrip
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.vertical, PaladalaTheme.Spacing.s)
                .background(PaladalaTheme.paper)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.hairlineWidth
                        )
                }
            ScrollView {
                if let day = days.first(where: { $0.weekday == selectedWeekday }) {
                    if day.cards.isEmpty {
                        emptyDayView(for: day)
                            .padding(.top, 48)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(day.cards) { card in
                                BangumiCardRow(card: card)
                                if card.id != day.cards.last?.id {
                                    Rectangle()
                                        .fill(PaladalaTheme.ink.opacity(0.12))
                                        .frame(height: PaladalaTheme.hairlineWidth)
                                }
                            }
                        }
                    }
                } else {
                    Text("该日无更新")
                        .font(PaladalaTheme.FontRole.body)
                        .foregroundStyle(PaladalaTheme.mutedInk)
                        .padding(.top, 48)
                }
            }
            .background(PaladalaTheme.canvas)
        }
    }

    private var weekdayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(days) { day in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedWeekday = day.weekday
                        }
                        Haptics.tap()
                    } label: {
                        weekdayTab(day: day)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func weekdayTab(day: BangumiDay) -> some View {
        let isSelected = day.weekday == selectedWeekday
        return VStack(spacing: 2) {
            Text(day.weekdayLabel)
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(isSelected ? PaladalaTheme.ink : PaladalaTheme.mutedInk)
            if let date = day.date {
                Text(date)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
            Rectangle()
                .fill(isSelected ? PaladalaTheme.ink : Color.clear)
                .frame(height: 2)
                .padding(.top, 2)
        }
        .padding(.horizontal, PaladalaTheme.Spacing.m)
        .padding(.vertical, PaladalaTheme.Spacing.s)
    }

    private func emptyDayView(for day: BangumiDay) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(PaladalaTheme.mutedInk)
            Text("\(day.weekdayLabel)暂无番剧更新")
                .font(PaladalaTheme.FontRole.body)
                .foregroundStyle(PaladalaTheme.mutedInk)
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(PaladalaTheme.ink)
            Text("加载中…")
                .font(PaladalaTheme.FontRole.bodySmall)
                .foregroundStyle(PaladalaTheme.mutedInk)
                .padding(.top, PaladalaTheme.Spacing.s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaladalaTheme.canvas)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(PaladalaTheme.biliPink)
            Text("加载失败")
                .font(PaladalaTheme.FontRole.sectionHeader)
                .foregroundStyle(PaladalaTheme.ink)
            Text(message)
                .font(PaladalaTheme.FontRole.bodySmall)
                .foregroundStyle(PaladalaTheme.mutedInk)
                .multilineTextAlignment(.center)
            Button {
                Task { await load(force: true) }
            } label: {
                Text("重试")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                    .padding(.horizontal, PaladalaTheme.Spacing.l)
                    .padding(.vertical, PaladalaTheme.Spacing.s)
                    .background(PaladalaTheme.paper)
                    .overlay {
                        Rectangle()
                            .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(PaladalaTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaladalaTheme.canvas)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(PaladalaTheme.mutedInk)
            Text("暂无番剧时间表")
                .font(PaladalaTheme.FontRole.sectionHeader)
                .foregroundStyle(PaladalaTheme.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaladalaTheme.canvas)
    }

    private func load(force: Bool = false) async {
        if !force && !days.isEmpty { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let fetched = try await repository.bangumiTimeline()
            // If today is a weekday the upstream has data for,
            // keep the user's selection; otherwise default to
            // the first day the upstream actually returned.
            if !days.contains(where: { $0.weekday == selectedWeekday }) {
                selectedWeekday = fetched.first?.weekday ?? selectedWeekday
            }
            days = fetched
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

/// One row in the bangumi day's card list.  Street Minimal
/// chrome: cover thumbnail, title, update description, and
/// a hairline divider between rows.  Tapping the row opens
/// the card's `shareURL` in the system handler so the user
/// lands on Bilibili's official PGC surface (or the official
/// app via Universal Links).
private struct BangumiCardRow: View {
    let card: BangumiCard

    var body: some View {
        Button {
            Haptics.tap()
            openShare()
        } label: {
            HStack(alignment: .top, spacing: PaladalaTheme.Spacing.m) {
                cover
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(card.title)
                            .font(PaladalaTheme.FontRole.cardTitle)
                            .foregroundStyle(PaladalaTheme.ink)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if let badge = card.badgeText {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(PaladalaTheme.biliPink)
                        }
                    }
                    Text(card.updateDescription)
                        .font(PaladalaTheme.FontRole.bodySmall)
                        .foregroundStyle(PaladalaTheme.mutedInk)
                    Spacer(minLength: 0)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .padding(.top, 4)
            }
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.vertical, PaladalaTheme.Spacing.m)
            .background(PaladalaTheme.paper)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cover: some View {
        if let url = card.coverURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(PaladalaTheme.coolGray)
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(PaladalaTheme.coolGray)
                @unknown default:
                    Rectangle()
                        .fill(PaladalaTheme.coolGray)
                }
            }
            .frame(width: 88, height: 60)
            .clipped()
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.hairlineWidth)
            }
        } else {
            Rectangle()
                .fill(PaladalaTheme.coolGray)
                .frame(width: 88, height: 60)
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.hairlineWidth)
                }
        }
    }

    private func openShare() {
        guard let url = card.shareURL else { return }
        UIApplication.shared.open(url)
    }
}
