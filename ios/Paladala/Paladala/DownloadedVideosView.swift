import SwiftUI

/// List of every video the user has downloaded.  Reached
/// from the profile screen's "离线缓存" quick action
/// (`ProfileRoute.downloads` in `AppRouter`).
///
/// Each row shows the cover, title, duration, on-disk size
/// and the date the download completed.  Tap a row to play
/// (offline-capable — the playback path is `BiliPlayback
/// .localContext` → `LocalHLSProxyServer.serveLocal(...)`).
/// Swipe-to-delete removes both the manifest entry and the
/// on-disk bytes.
///
/// The toolbar exposes a single share-log action: when a
/// download is stuck or the list looks empty, the user can
/// one-tap share the diagnostic report (which now includes a
/// downloads section) so the developer has everything
/// needed to debug — manifest state, in-flight
/// `DownloadManager` state, on-disk byte counts, and the
/// tail of the in-memory event log.
struct DownloadedVideosView: View {
    let repository: PaladalaRepository
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authStore: AuthStore
    @ObservedObject private var store = DownloadStore.shared
    @State private var shareURL: URL? = nil
    @State private var showShareSheet = false

    var body: some View {
        Group {
            if store.records.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.records) { record in
                        Button {
                            Haptics.tap()
                            router.openLocalVideo(record)
                        } label: {
                            DownloadedVideoRow(record: record)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Haptics.tap()
                                DownloadStore.shared.remove(bvid: record.bvid)
                            } label: {
                                Label("删除下载", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("离线缓存")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    shareDiagnosticReport()
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .accessibilityLabel("导出诊断日志")
                .accessibilityHint("导出诊断日志可发送给开发者排查下载问题")
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    /// Shown when the user has never successfully completed a
    /// download.  Calls out the most common reason (a download
    /// got "stuck at 75%") and offers the export-log action
    /// right next to the empty illustration.
    private var emptyState: some View {
        VStack(spacing: 18) {
            ContentUnavailableView(
                "暂无下载视频",
                systemImage: "arrow.down.circle",
                description: Text("在视频页点击下载按钮保存到本地")
            )
            Button {
                Haptics.tap()
                shareDiagnosticReport()
            } label: {
                Label("导出诊断日志", systemImage: "square.and.arrow.up")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(
                            cornerRadius: PaladalaTheme.cardRadius,
                            style: PaladalaTheme.cornerStyle
                        )
                        .fill(PaladalaTheme.biliPink.opacity(0.14))
                    )
                    .foregroundStyle(PaladalaTheme.biliPink)
            }
            .buttonStyle(.plain)
            .accessibilityHint("下载卡住时把日志发给开发者")
        }
        .padding(.bottom, 24)
    }

    /// Build the diagnostic report (which now includes a
    /// "Downloads" section with manifest + on-disk byte
    /// counts + in-flight state) and pop the iOS share sheet.
    /// Falls back to clipboard if the temp-file write fails
    /// (rare on iOS but the share sheet cannot survive a nil
    /// `shareURL`).
    private func shareDiagnosticReport() {
        let url = DiagnosticLogger.shared.export(
            activeAccount: authStore.activeAccount
        )
        guard let url else {
            let report = DiagnosticLogger.shared.generateReport(
                activeAccount: authStore.activeAccount
            )
            UIPasteboard.general.string = report
            return
        }
        shareURL = url
        showShareSheet = true
    }
}

/// One row in `DownloadedVideosView`.  Mirrors the chrome
/// of `VideoListRow` so the two lists feel like siblings
/// (cover on the left, title + meta on the right).
private struct DownloadedVideoRow: View {
    let record: DownloadRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ResilientImage(url: record.coverURL)
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(record.ownerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(durationLabel, systemImage: "clock")
                    Label(record.sizeBytes.compactFileSize,
                          systemImage: "internaldrive")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text(record.downloadedAt.formatted(
                    .dateTime
                        .year()
                        .month()
                        .day()
                        .hour()
                        .minute()
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    /// `BiliVideo.duration` is in seconds.  Format as
    /// `mm:ss` (or `h:mm:ss` for clips over an hour).
    private var durationLabel: String {
        let total = record.duration
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

private extension Int64 {
    /// Render an on-disk byte count as a compact human
    /// string (`"71.2 MB"`, `"1.4 GB"`).  We deliberately
    /// use the binary (1024-based) units so the number
    /// matches what the user sees in iOS's own storage
    /// settings.
    var compactFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}