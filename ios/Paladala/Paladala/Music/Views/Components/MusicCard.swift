import SwiftUI

// MARK: - MusicCard
//
// Moved from MusicHomeView.swift as part of the music section
// reintroduction (Phase 0b — directory regrouping). Behaviour is
// byte-for-byte identical to the original; only the file location
// and the file-level documentation header changed.
//
// Mirrors `VideoCard`'s chrome (cover / title / owner) but is
// tuned for the music context: the title is allowed two lines,
// the bottom metadata row collapses to a single `play.fill` +
// view count, and a small "纯享" badge sits in the bottom-right
// of the cover so users immediately understand "audio only".

struct MusicCard: View {
    let video: BiliVideo

    @AppStorage("paladala.materialDesign") private var materialDesign: MaterialDesign = .liquidGlass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                cover
                Text(video.duration.mmss)
                    .font(PaladalaTheme.FontRole.labelMono)
                    // Match VideoCard's duration chip (paper on ink)
                    // so the music feed inherits the same Street
                    // Minimal chip treatment as the home feed.
                    .foregroundStyle(PaladalaTheme.paper)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(PaladalaTheme.ink)
                    .padding(12)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .frame(height: PaladalaTheme.borderWidth)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(video.title)
                    .font(PaladalaTheme.FontRole.headline)
                    .foregroundStyle(PaladalaTheme.ink)
                    // No `.textCase(.uppercase)` — VideoCard /
                    // LiveRoomCard render titles in mixed case
                    // and rely on `.font(PaladalaTheme.FontRole.headline)`
                    // for the editorial weight.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                Text(video.ownerName)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(video.viewCount.compactCount, systemImage: "play.fill")
                    Spacer(minLength: 0)
                    Text(L10n.music.audioOnly)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(PaladalaTheme.biliPink)
                        .foregroundStyle(PaladalaTheme.ink)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.hairlineWidth
                                )
                        }
                }
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.mutedInk)
            }
            .padding(PaladalaTheme.Spacing.l)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .paladalaCardSurface(materialDesign)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if let url = video.coverURL {
            // Use `.contentMode: .fit` (NOT `.fill`) so the 1:1
            // aspect ratio actually resolves to a bounded square.
            //
            // With `.fill`, SwiftUI treats the constraint as
            // "size in both dimensions ≥ the parent's proposed
            // size, possibly overflowing".  Inside a
            // `LazyVGrid` cell the proposed height is unbounded
            // (the VStack height grows with content), so the
            // aspect-ratio modifier asks for `height ≥ ∞` while
            // maintaining 1:1 — SwiftUI gives back an unbounded
            // height and the cover stretches to fill the entire
            // VStack content area, making cards visually overlap
            // each other as the user scrolls.
            //
            // With `.fit`, the constraint becomes "size in both
            // dimensions ≤ proposed".  Width is bounded (cell
            // width minus padding) so the 1:1 ratio forces
            // height = width.  This matches how `VideoCard` and
            // `LiveRoomCard` render their covers (both use
            // `.fit`).
            ResilientImage(url: url, maximumPixelSize: 720)
                .aspectRatio(1, contentMode: .fit)
                .frame(minWidth: 0, maxWidth: .infinity)
        } else {
            Rectangle()
                .fill(PaladalaTheme.coolGray)
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(PaladalaTheme.biliPink)
                )
        }
    }
}
