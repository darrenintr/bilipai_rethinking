//
//  LogViewerView.swift
//  Paladala
//
//  In-app log viewer.  Replaces the broken sheet-based export in
//  `ProfileSettingsView` (which showed a blank popup on the
//  first tap and the iOS share sheet on the second tap, because
//  the .sheet content closure re-evaluated with `logExportURL`
//  still nil).
//
//  We now push a real screen via `NavigationLink`.  Inside the
//  screen the user can:
//    * Filter by category (multi-select chips at the top)
//    * Free-text search across message + details
//    * Copy the full report to the clipboard
//    * Share the report as a file (local `.sheet`, but
//      `shareURL` is set on the same main-actor tick as
//      `showShareSheet = true`, so the content closure
//      sees both at present time — no race)
//
//  The viewer subscribes to `DiagnosticLogger.shared.events` via
//  `@StateObject` so the list updates live as new events arrive.
//  Events are sorted latest-first; we do not auto-scroll (per
//  user decision: less intrusive).
//

import SwiftUI
import UIKit

struct LogViewerView: View {
    @StateObject private var logger = DiagnosticLogger.shared
    @EnvironmentObject private var authStore: AuthStore

    @State private var searchText: String = ""
    @State private var enabledCategories: Set<DiagnosticLogger.Category> = Set(
        DiagnosticLogger.Category.allCases
    )
    /// Local sheet state.  Stays on this screen so a navigation
    /// push/dismiss cycle can't interfere with the parent
    /// settings view.
    @State private var shareURL: URL? = nil
    @State private var copyToast: String? = nil
    @State private var showingClearConfirmation = false
    /// Telegram 上报状态机。`isUploading` 时 toolbar 按钮
    /// 退化为 `ProgressView`，避免用户连点。`showUploadConfirm`
    /// 触发 `confirmationDialog`，二次确认后真正发起 POST。
    @State private var isUploading = false
    @State private var showUploadConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            filterChipsBar
            eventList
        }
        .background(PaladalaTheme.canvas)
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        // System-provided search bar. Replaces the hand-rolled
        // pill surface — gets the magnifying-glass icon, clear
        // button, and cancel affordance for free.
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索消息 / 详情"
        )
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("清除日志")
                Button {
                    copyToClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .accessibilityLabel("复制报告")
                if let shareURL {
                    // Once the URL is prepared, the system
                    // `ShareLink` takes over — gives AirDrop /
                    // Save-to-Files / Mail / Messages for free
                    // without an `UIActivityViewController`
                    // bridge.
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享报告")
                } else {
                    Button {
                        exportAndShare()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享报告")
                }
                // 上报日志到 Telegram channel。图标用
                // `paperplane.fill` 与 share 图标做视觉区分
                // —— share 是"导出到任意 App"，
                // paperplane 是"直传到频道"。上传期间切换为
                // 转圈进度，避免连点触发重复请求。
                Button {
                    showUploadConfirm = true
                } label: {
                    if isUploading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .accessibilityLabel("上报日志到频道")
                .disabled(isUploading)
            }
        }
        .confirmationDialog(
            "清除以往日志？",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除日志", role: .destructive) {
                clearLogs()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清空当前诊断日志、磁盘历史日志和 bpLog 缓冲。")
        }
        // 上报日志的二次确认。放在独立 dialog 里（不与
        // 清除日志的合并）—— 两者语义不同，分开能避免
        // 误触。同时 `isUploading` 会让按钮 disable，
        // 这里是最后一道用户主动确认的门槛。
        .confirmationDialog(
            "上传日志到频道？",
            isPresented: $showUploadConfirm
        ) {
            Button("上传") {
                Task { await uploadToTelegram() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会把当前诊断日志（含设备信息、App 版本、bpLog 尾部）作为文件发送到 Telegram 频道。")
        }
        .overlay(alignment: .bottom) {
            if let copyToast {
                Text(copyToast)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(
                            cornerRadius: PaladalaTheme.cornerRadius,
                            style: PaladalaTheme.cornerStyle
                        )
                        .fill(Color.black.opacity(0.78))
                    )
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: copyToast)
        .task {
            // Start the path monitor (idempotent) in case the
            // user opened the viewer without the app launch
            // hook having fired (e.g. crash recovery).
            DeviceInfo.shared.startIfNeeded()
        }
    }

    // MARK: - subviews

    private var filterChipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(DiagnosticLogger.Category.allCases, id: \.self) { cat in
                    let isOn = enabledCategories.contains(cat)
                    Button {
                        if isOn {
                            enabledCategories.remove(cat)
                        } else {
                            enabledCategories.insert(cat)
                        }
                    } label: {
                        Text(cat.rawValue)
                            .font(PaladalaTheme.FontRole.labelMono)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .paladalaSelectionChip(
                                isSelected: isOn,
                                design: .liquidGlass
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(PaladalaTheme.paper)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PaladalaTheme.ink)
                .frame(height: PaladalaTheme.borderWidth)
        }
    }

    private var filtered: [DiagnosticLogger.Event] {
        let needle = searchText
        return logger.events.reversed().filter { event in
            guard enabledCategories.contains(event.category) else {
                return false
            }
            guard !needle.isEmpty else { return true }
            if event.message.localizedCaseInsensitiveContains(needle) {
                return true
            }
            if let details = event.details,
               String(describing: details)
                   .localizedCaseInsensitiveContains(needle) {
                return true
            }
            return false
        }
    }

    private var eventList: some View {
        let rows = filtered
        return Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "暂无日志",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("打开任意视频或回到首页即可触发新的事件。")
                )
            } else {
                List(rows) { event in
                    EventRow(event: event)
                        .listRowInsets(
                            EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
                        )
                        .listRowBackground(PaladalaTheme.paper)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(PaladalaTheme.canvas)
            }
        }
    }

    // MARK: - actions

    private func copyToClipboard() {
        let report = DiagnosticLogger.shared.generateReport(
            activeAccount: authStore.activeAccount
        )
        UIPasteboard.general.string = report
        flashToast("已复制 (\(report.count) 字符)")
    }

    private func exportAndShare() {
        let url = DiagnosticLogger.shared.export(
            activeAccount: authStore.activeAccount
        )
        guard let url else {
            // Fall back to clipboard.
            let report = DiagnosticLogger.shared.generateReport(
                activeAccount: authStore.activeAccount
            )
            UIPasteboard.general.string = report
            flashToast("已复制 (\(report.count) 字符)")
            return
        }
        // Set the URL so the toolbar's `ShareLink` picks it up
        // on the next render. No sheet flip needed — the system
        // share sheet pops itself when the user taps the link.
        shareURL = url
    }

    private func clearLogs() {
        DiagnosticLogger.shared.clearHistory()
        Logger.shared.clear()
        shareURL = nil
        flashToast("日志已清除")
    }

    private func uploadToTelegram() async {
        // 锁住 isUploading：toolbar 按钮立刻变 ProgressView，
        // 用户无法再次点击触发重复上传；defer 保证无论成功
        // 或失败都会解锁。
        isUploading = true
        defer { isUploading = false }
        // 复用既有 `export(activeAccount:)` —— 同一份文件
        // 既供 ShareLink 也供这里。activeAccount 透传，让
        // 日志里带上当前账号的 mid / 登录态。
        guard let url = DiagnosticLogger.shared.export(
            activeAccount: authStore.activeAccount
        ) else {
            flashToast("导出失败")
            return
        }
        // caption 是 Telegram 消息下方显示的小字。带上
        // App 版本 + build identifier，channel 端能立刻看
        // 到是哪个构建出的报告，不用点开文件。
        let caption =
            "Paladala iOS — \(AppVersion.current.versionLine)"
            + " — \(AppVersion.current.identifierDisplay)"
        do {
            let result = try await TelegramLogReporter.shared.upload(
                fileURL: url, caption: caption
            )
            // 把 Telegram 的 message_id 拼到 toast 里——用户
            // 与开发者同步时能直接说"我发的是 #1234"。
            flashToast("已上传（#\(result.messageID)）")
        } catch {
            // `error.localizedDescription` 走 ReporterError
            // 的中文文案，AppError 之类的也会原样上抛。
            flashToast("上传失败：\(error.localizedDescription)")
        }
    }

    private func flashToast(_ message: String) {
        copyToast = message
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                if copyToast == message { copyToast = nil }
            }
        }
    }
}

private struct EventRow: View {
    let event: DiagnosticLogger.Event

    @MainActor
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(timestampString(event.timestamp))
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                Text("[\(event.category.rawValue)]")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(categoryColor(event.category))
                Text(event.message)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.ink)
            }
            if let d = event.details, !d.isEmpty {
                Text(String(describing: d))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(.vertical, 2)
    }

    private func timestampString(_ date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }

    private func categoryColor(_ c: DiagnosticLogger.Category) -> Color {
        switch c {
        case .playback, .fullscreen, .download, .network, .proxy:
            return PaladalaTheme.biliPink
        case .auth, .recommendation, .app, .lifecycle, .system,
             .session, .music, .notification, .feed, .audio,
             .bangumi:
            return PaladalaTheme.mutedInk
        }
    }
}
