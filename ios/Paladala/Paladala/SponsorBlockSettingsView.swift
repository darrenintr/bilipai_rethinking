import SwiftUI

struct SponsorBlockSettingsView: View {
    @ObservedObject private var manager = SponsorBlockManager.shared
    @State private var showSubmitReport = false
    @State private var reportStartTime = ""
    @State private var reportEndTime = ""
    @State private var reportCategory: SponsorCategory = .sponsor
    @State private var isSubmitting = false
    @State private var submitMessage: String?

    var body: some View {
        List {
            Section {
                Toggle("启用拦截恰饭", isOn: $manager.config.isEnabled)
                    .onChange(of: manager.config.isEnabled) { _, _ in }

                if manager.config.isEnabled {
                    Toggle("自动跳过", isOn: $manager.config.autoSkip)
                }

                Picker("最低投票数", selection: $manager.config.minVotes) {
                    Text("不限").tag(-1)
                    Text("≥ 1 票").tag(1)
                    Text("≥ 3 票").tag(3)
                    Text("≥ 5 票").tag(5)
                }
            } header: {
                Text("拦截设置")
            } footer: {
                Text("开启后播放视频时将自动查询并跳过恰饭片段。数据来源于社区用户标注。")
            }

            Section("拦截类别") {
                ForEach(SponsorCategory.allCases) { category in
                    Toggle(isOn: Binding(
                        get: { manager.config.categories.contains(category) },
                        set: { isOn in
                            if isOn {
                                manager.config.categories.append(category)
                            } else {
                                manager.config.categories.removeAll { $0 == category }
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.displayName)
                                .font(.subheadline)
                            Text(categoryHint(category))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button {
                    showSubmitReport = true
                } label: {
                    Label("上报恰饭片段", systemImage: "exclamationmark.bubble.fill")
                }
                .disabled(!manager.isEnabled)

                if !manager.segments.isEmpty {
                    NavigationLink {
                        SegmentListView(segments: manager.segments)
                    } label: {
                        Label("查看已加载的片段 (\(manager.segments.count))", systemImage: "list.bullet")
                    }
                }

                if manager.totalTimeSaved > 0 {
                    HStack {
                        Label("已节省时间", systemImage: "clock.badge.checkmark")
                        Spacer()
                        Text(formatTime(manager.totalTimeSaved))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("数据")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("拦截恰饭")
        .sheet(isPresented: $showSubmitReport) {
            submitReportSheet
        }
    }

    private var submitReportSheet: some View {
        NavigationStack {
            Form {
                Section("时间范围（秒）") {
                    TextField("开始时间（秒）", text: $reportStartTime)
                        .keyboardType(.decimalPad)
                    TextField("结束时间（秒）", text: $reportEndTime)
                        .keyboardType(.decimalPad)
                }

                Section("片段类别") {
                    Picker("类别", selection: $reportCategory) {
                        ForEach(SponsorCategory.allCases) { category in
                            Text(category.displayName).tag(category)
                        }
                    }
                }

                Section {
                    Button {
                        submitReport()
                    } label: {
                        if isSubmitting {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else {
                            Text("提交")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isSubmitting || reportStartTime.isEmpty || reportEndTime.isEmpty)
                }

                if let msg = submitMessage {
                    Section {
                        Text(msg)
                            .foregroundStyle(msg.contains("成功") ? .green : .red)
                    }
                }
            }
            .navigationTitle("上报恰饭片段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showSubmitReport = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submitReport() {
        guard let start = Double(reportStartTime),
              let end = Double(reportEndTime),
              end > start else {
            submitMessage = "请填写有效的时间范围"
            return
        }

        isSubmitting = true
        submitMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                try await manager.submitSegment(
                    videoID: manager.lastVideoID ?? "",
                    cid: nil,
                    category: reportCategory.rawValue,
                    startTime: start,
                    endTime: end,
                    videoDuration: 0
                )
                submitMessage = "提交成功！感谢您的贡献。"
                reportStartTime = ""
                reportEndTime = ""
            } catch {
                submitMessage = "提交失败：\(error.localizedDescription)"
            }
        }
    }

    private func categoryHint(_ category: SponsorCategory) -> String {
        switch category {
        case .sponsor: return "赞助商广告、贴片广告、口播广告"
        case .intro: return "视频开场的动画/片头"
        case .outro: return "视频结尾的鸣谢/片尾"
        case .interaction: return "求赞、求三连、关注提醒"
        case .selfpromo: return "UP主推荐自己的其他内容"
        case .musicOfftopic: return "音乐视频中的非音乐部分"
        case .preview: return "下集预告、内容回顾"
        case .filler: return "凑数填充内容"
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = Int(seconds) / 60 % 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分钟"
        } else if minutes > 0 {
            return "\(minutes) 分钟 \(secs) 秒"
        } else {
            return "\(secs) 秒"
        }
    }
}

private struct SegmentListView: View {
    let segments: [SponsorSegment]

    var body: some View {
        List(segments) { segment in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(SponsorCategory(rawValue: segment.category)?.displayName ?? segment.category)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let votes = segment.votes {
                        Text("\(votes) 票")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(formatTimeRange(segment.startTime, segment.endTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("片段列表")
    }

    private func formatTimeRange(_ start: Double, _ end: Double) -> String {
        let s = Int(start)
        let e = Int(end)
        return "\(s / 60):\(String(format: "%02d", s % 60)) → \(e / 60):\(String(format: "%02d", e % 60))"
    }
}
