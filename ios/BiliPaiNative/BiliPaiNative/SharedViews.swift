import SwiftUI

struct VideoCard: View {
    let video: BiliVideo
    let action: () -> Void

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
                    .fixedSize(horizontal: false, vertical: true)
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
            .padding(10)
            .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
        }
        .buttonStyle(.plain)
    }
}

struct LiveRoomCard: View {
    let room: BiliLiveRoom

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
            Text("\(room.hostName) - \(room.areaName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(room.viewerCount.compactCount) watching")
                .font(.caption2)
                .foregroundStyle(BiliPaiTheme.biliPink)
        }
        .padding(10)
        .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
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
