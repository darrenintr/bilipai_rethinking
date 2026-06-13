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
                        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle))
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
                    .background(.red, in: RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle))
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
        // We pull the image bytes through a small URLSession-backed loader
        // rather than the built-in `AsyncImage`. AsyncImage is notoriously
        // flaky on slow / flaky networks — once it lands in the failure
        // phase there is no way to retry, and the system image cache keeps
        // the broken placeholder around. The custom loader keeps trying
        // (with a short back-off) and refreshes when `url` changes.
        ResilientImage(url: url)
            .clipped()
    }
}

private struct ResilientImage: View {
    let url: URL?

    @State private var image: UIImage?
    @State private var attempts = 0
    @State private var task: Task<Void, Never>?

    private let maxAttempts = 3

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if attempts >= maxAttempts {
                // Permanent failure placeholder so the cell still has
                // visible affordance instead of looking like a still-
                // loading skeleton forever.
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            await load()
        }
        .onDisappear {
            task?.cancel()
        }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        // Reset state for the new URL.
        image = nil
        attempts = 0
        task?.cancel()
        task = Task {
            while attempts < maxAttempts && !Task.isCancelled {
                attempts += 1
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        throw NSError(domain: "CoverImage", code: http.statusCode)
                    }
                    if let ui = UIImage(data: data) {
                        await MainActor.run { self.image = ui }
                        return
                    }
                } catch {
                    // Swallow and retry. Bilibili's `i0.hdslb.com` CDN
                    // occasionally serves a 1×1 transparent pixel that
                    // decodes to `nil`; the retry succeeds.
                }
                // Exponential-ish back-off capped at 1.5 s.
                let delay = min(1_500_000_000, 250_000_000 * attempts)
                try? await Task.sleep(nanoseconds: UInt64(delay))
            }
        }
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
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: BiliPaiTheme.pillRadius, style: BiliPaiTheme.cornerStyle))
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
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius, style: BiliPaiTheme.cornerStyle))
    }
}
