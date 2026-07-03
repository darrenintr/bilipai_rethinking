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

    var body: some View {
        VStack(spacing: 0) {
            filterChipsBar
            eventList
        }
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
            }
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
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                isOn
                                    ? PaladalaTheme.biliPink.opacity(0.18)
                                    : Color(uiColor: .tertiarySystemFill),
                                in: RoundedRectangle(
                                    cornerRadius: PaladalaTheme.cornerRadius,
                                    style: PaladalaTheme.cornerStyle
                                )
                            )
                            .foregroundStyle(
                                isOn ? PaladalaTheme.biliPink : .secondary
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
                }
                .listStyle(.plain)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(timestampString(event.timestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("[\(event.category.rawValue)]")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(categoryColor(event.category))
                Text(event.message)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
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
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df.string(from: date)
    }

    private func categoryColor(_ c: DiagnosticLogger.Category) -> Color {
        // System colors adapt to dark mode + Increase Contrast
        // automatically; raw `Color.blue/orange/...` literals
        // stay locked to a single fixed value.
        switch c {
        case .playback, .fullscreen: return PaladalaTheme.biliPink
        case .network, .session:     return Color(uiColor: .systemBlue)
        case .auth:                  return Color(uiColor: .systemOrange)
        case .recommendation:        return Color(uiColor: .systemGreen)
        case .app, .lifecycle:       return Color(uiColor: .systemPurple)
        case .system:                return Color(uiColor: .systemGray)
        case .download:              return Color(uiColor: .systemIndigo)
        case .music:                 return Color(uiColor: .systemYellow)
        }
    }
}
