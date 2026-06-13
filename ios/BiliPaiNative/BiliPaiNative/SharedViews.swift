import SwiftUI

struct VideoCard: View {
    let video: BiliVideo
    let action: () -> Void

    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .material3

    /// Reserved height for the title block (two lines of `.subheadline`).
    /// Pinning this so all cards in the same grid row have an identical total
    /// height — otherwise a card with a one-line title would render shorter
    /// than its two-line neighbour, knocking the next row out of alignment.
    private static let titleBlockHeight: CGFloat = 40

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    CoverImage(url: video.coverURL)
                        .aspectRatio(16 / 10, contentMode: .fit)
                    Text(video.duration.mmss)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 5))
                        .padding(8)
                }
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: Self.titleBlockHeight, alignment: .topLeading)
                Text(video.ownerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label(video.viewCount.compactCount, systemImage: "play.fill")
                    Label(video.danmakuCount.compactCount, systemImage: "text.bubble")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
            .bilipaiCardSurface(materialDesign)
        }
        .buttonStyle(.plain)
    }
}

struct LiveRoomCard: View {
    let room: BiliLiveRoom

    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .material3

    /// See `VideoCard.titleBlockHeight` for why this is pinned.
    private static let titleBlockHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                CoverImage(url: room.coverURL)
                    .aspectRatio(16 / 10, contentMode: .fit)
                Text("LIVE")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.red, in: RoundedRectangle(cornerRadius: 5))
                    .padding(8)
            }
            Text(room.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(minHeight: Self.titleBlockHeight, alignment: .topLeading)
            Text("\(room.hostName) - \(room.areaName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(room.viewerCount.compactCount) watching")
                .font(.caption2)
                .foregroundStyle(BiliPaiTheme.biliPink)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .bilipaiCardSurface(materialDesign)
    }
}

struct CoverImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                Rectangle()
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                    .overlay(ProgressView())
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                Rectangle()
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            @unknown default:
                Rectangle()
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            }
        }
        .clipped()
    }
}

struct MetricPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
    }
}
