//
//  AboutView.swift
//  Paladala
//
//  "关于" (About) screen reachable from the 我的 (Profile)
//  settings list.  Surfaces the build identity (marketing
//  version, build number, special identifier, release type,
//  channel, commit, build date, bundle ID) and provides a
//  "检查更新" action that hits the GitHub Releases API for
//  the project's public repository.
//
//  Identity values come from `AppVersion.current` — see
//  AppVersion.swift for the fingerprint algorithm and the
//  fallback path used by local dev builds.
//

import SwiftUI
import UIKit

struct AboutView: View {
    @State private var version = AppVersion.current
    @State private var copyToast: String? = nil
    @State private var updateState: UpdateState = .idle
    @StateObject private var updateManager = UpdateManager.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: PaladalaTheme.Spacing.xxl) {
                headerSection
                identitySection
                updateSection
                footerSection
            }
            .padding(PaladalaTheme.Spacing.l)
        }
        .scrollContentBackground(.hidden)
        .background(PaladalaTheme.canvas)
        .navigationTitle(L10n.about.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast = copyToast {
                copyToastView(toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: PaladalaTheme.Spacing.m) {
            // App icon placeholder
            Rectangle()
                .fill(PaladalaTheme.biliPink)
                .frame(width: 88, height: 88)
                .overlay(
                    Text("BP")
                        .font(.system(size: 36, weight: .black, design: .monospaced))
                        .foregroundStyle(PaladalaTheme.ink)
                )
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                }

            Text("Paladala")
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundStyle(PaladalaTheme.ink)

            Text("Pure Bilibili · Native iOS")
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.mutedInk)

            Text(version.versionLine)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(PaladalaTheme.mutedInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, PaladalaTheme.Spacing.l)
    }

    private var identitySection: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("构建信息")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.bottom, PaladalaTheme.Spacing.s)

            // Card
            VStack(spacing: 0) {
                identityRow(label: L10n.about.version, value: version.marketingVersion, showDivider: true)
                identityRow(label: L10n.about.build, value: version.buildNumber, showDivider: true)
                identifierRowStyled
                identityRow(label: L10n.about.releaseType, value: version.releaseTypeDisplay, showDivider: true)
                identityRow(label: L10n.about.channel, value: version.channel.nonEmptyOrDash, showDivider: version.commitShort != nil)

                if let commit = version.commitShort {
                    identityRow(label: L10n.about.commit, value: commit, showDivider: true)
                }

                identityRow(label: L10n.about.buildDate, value: formatDate(version.buildDate), showDivider: true)
                identityRow(label: L10n.about.bundleId, value: version.bundleId, showDivider: false)
            }
            .background(PaladalaTheme.paper)
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
            }
            .background {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .offset(x: PaladalaTheme.hardShadowOffset, y: PaladalaTheme.hardShadowOffset)
            }

            // Footer note
            Text("特别辨识号用于精确标识当前构建，反馈问题时附上它可以帮我们快速定位。")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PaladalaTheme.mutedInk)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.top, PaladalaTheme.Spacing.s)
        }
    }

    private func identityRow(label: String, value: String, showDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: PaladalaTheme.Spacing.m) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .frame(width: 90, alignment: .leading)

                Text(value)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.vertical, PaladalaTheme.Spacing.m)

            if showDivider {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .frame(height: PaladalaTheme.hairlineWidth)
            }
        }
    }

    private var identifierRowStyled: some View {
        VStack(spacing: 0) {
            Button {
                copyIdentifier()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: PaladalaTheme.Spacing.m) {
                    Text(L10n.about.identifier)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(PaladalaTheme.mutedInk)
                        .frame(width: 90, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.identifierDisplay)
                            .font(PaladalaTheme.FontRole.labelMono)
                            .foregroundStyle(PaladalaTheme.biliPink)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PaladalaTheme.mutedInk)
                }
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.vertical, PaladalaTheme.Spacing.m)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(PaladalaTheme.ink)
                .frame(height: PaladalaTheme.hairlineWidth)
        }
    }

    private var updateSection: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("更新")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.bottom, PaladalaTheme.Spacing.s)

            // Card
            VStack(spacing: 0) {
                // Check for updates button
                Button {
                    checkForUpdates()
                } label: {
                    HStack(spacing: PaladalaTheme.Spacing.m) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(PaladalaTheme.ink)
                            .frame(width: 28)

                        Text(L10n.about.checkForUpdates)
                            .font(PaladalaTheme.FontRole.cardTitle)
                            .foregroundStyle(PaladalaTheme.ink)

                        Spacer()

                        if case .checking = updateState {
                            ProgressView()
                                .tint(PaladalaTheme.ink)
                        }
                    }
                    .padding(.horizontal, PaladalaTheme.Spacing.l)
                    .padding(.vertical, PaladalaTheme.Spacing.m)
                }
                .buttonStyle(.plain)
                .disabled(updateState == .checking)

                // Update result
                if updateState != .idle {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .frame(height: PaladalaTheme.hairlineWidth)

                    updateResultCard
                }
            }
            .background(PaladalaTheme.paper)
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
            }
            .background {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .offset(x: PaladalaTheme.hardShadowOffset, y: PaladalaTheme.hardShadowOffset)
            }

            // Footer note
            Text("对比当前版本与 GitHub 上最新的预发布版本。")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PaladalaTheme.mutedInk)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.top, PaladalaTheme.Spacing.s)
        }
    }

    @ViewBuilder
    private var updateResultCard: some View {
        switch updateState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: PaladalaTheme.Spacing.s) {
                ProgressView()
                    .tint(PaladalaTheme.ink)
                Text(L10n.about.checking)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
            .padding(PaladalaTheme.Spacing.l)
        case .upToDate(let remote):
            HStack(spacing: PaladalaTheme.Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text("\(L10n.about.upToDate) · \(remote)")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
            .padding(PaladalaTheme.Spacing.l)
        case .updateAvailable(let remote, let url):
            updateAvailableCard(remote: remote, url: url)
        case .devBuild(let remote, let url):
            devBuildCard(remote: remote, url: url)
        case .failed(let message):
            HStack(spacing: PaladalaTheme.Spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
            .padding(PaladalaTheme.Spacing.l)
        }
    }

    private func updateAvailableCard(remote: String, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: PaladalaTheme.Spacing.m) {
            HStack(spacing: PaladalaTheme.Spacing.s) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(PaladalaTheme.biliPink)
                Text("\(L10n.about.updateAvailable) · \(remote)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.ink)
            }

            downloadButton

            downloadStatusMessages

            if let url {
                githubLink(url: url, label: L10n.about.viewRelease)
            }
        }
        .padding(PaladalaTheme.Spacing.l)
    }

    private func devBuildCard(remote: String?, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: PaladalaTheme.Spacing.m) {
            HStack(spacing: PaladalaTheme.Spacing.s) {
                Image(systemName: "hammer.fill")
                    .foregroundStyle(PaladalaTheme.biliPink)
                Text(L10n.about.devBuild)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.ink)
            }

            if let remote {
                Text(L10n.about.upToDate + " · \(remote)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }

            downloadButton

            downloadStatusMessages

            if let url {
                githubLink(url: url, label: L10n.about.openOnGitHub)
            }
        }
        .padding(PaladalaTheme.Spacing.l)
    }

    private var downloadButton: some View {
        Button {
            Task {
                await updateManager.downloadAndInstallLatest()
            }
        } label: {
            HStack(spacing: PaladalaTheme.Spacing.s) {
                if updateManager.downloadState == .downloading {
                    ProgressView()
                        .tint(PaladalaTheme.ink)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                Text(downloadButtonLabel)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                if updateManager.downloadState == .downloading {
                    Text("(\(Int(updateManager.downloadProgress * 100))%)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(PaladalaTheme.ink)
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(PaladalaTheme.biliPink)
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
            }
            .background {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .offset(x: 3, y: 3)
            }
        }
        .buttonStyle(.plain)
        .disabled(updateManager.downloadState == .downloading)
    }

    @ViewBuilder
    private var downloadStatusMessages: some View {
        if case .failed(let error) = updateManager.downloadState {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
        }

        if case .completed = updateManager.downloadState {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("下载完成，请在分享菜单中选择 SideStore")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
        }
    }

    private func githubLink(url: URL, label: String) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                Text(label)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(PaladalaTheme.mutedInk)
        }
    }

    private var downloadButtonLabel: String {
        switch updateManager.downloadState {
        case .idle, .failed:
            return "下载并安装"
        case .downloading:
            return "下载中"
        case .completed:
            return "重新下载"
        }
    }

    private var footerSection: some View {
        VStack(spacing: PaladalaTheme.Spacing.xs) {
            Text("Paladala")
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundStyle(PaladalaTheme.ink)
            Text("Pure Bilibili · Native iOS")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PaladalaTheme.mutedInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PaladalaTheme.Spacing.l)
    }

    // MARK: - Copy toast

    private func copyToastView(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(PaladalaTheme.paper)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(PaladalaTheme.ink)
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.paper, lineWidth: 1)
            }
    }

    // MARK: - Actions

    private func copyIdentifier() {
        UIPasteboard.general.string = version.identifierDisplay
        Haptics.selection()
        withAnimation(.easeOut(duration: 0.18)) {
            copyToast = L10n.about.identifierCopied
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeIn(duration: 0.22)) {
                copyToast = nil
            }
        }
    }

    private func checkForUpdates() {
        updateState = .checking
        Task {
            let result = await UpdateChecker.check(current: version)
            await MainActor.run {
                updateState = result
            }
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return f.string(from: date)
    }
}

// MARK: - UpdateState

/// Result of the most recent "检查更新" tap.  Drives the
/// inline message under the button.  All cases except
/// `.idle` and `.checking` carry enough context for the
/// row to render a complete message without a follow-up
/// network call.
enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(remote: String)
    case updateAvailable(remote: String, url: URL?)
    case devBuild(remote: String?, url: URL?)
    case failed(String)
}

// MARK: - UpdateChecker

/// Hits the GitHub Releases API for the public project repo
/// and reports whether a newer prerelease exists.  Lives in
/// its own type so the call site can stay a `Button { }`
/// inside the SwiftUI view.
enum UpdateChecker {

    private static let repoOwner = "darrenintr"
    private static let repoName = "pure-bilibili-rethinking"
    private static let releasesURL = URL(string:
        "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
    )
    private static let repoURL = URL(string:
        "https://github.com/\(repoOwner)/\(repoName)/releases"
    )

    /// Public entry point.  Async so the view's `Task { }`
    /// can await the result and update the UI on the main
    /// actor.
    static func check(current: AppVersionInfo) async -> UpdateState {
        guard let releasesURL else { return .failed(L10n.about.updateFailed) }
        var request = URLRequest(url: releasesURL)
        request.httpMethod = "GET"
        // Use a recognisable UA so the GitHub side (and any
        // upstream proxy) can tell this is Paladala polling
        // itself instead of a generic scraper.
        request.setValue("Paladala-iOS/\(current.marketingVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(L10n.about.updateFailed)
            }
            // GitHub returns 404 when the repo has no
            // published releases yet — treat that as "no
            // comparison possible, dev build" rather than
            // a hard error.
            if http.statusCode == 404 {
                return .devBuild(remote: nil, url: repoURL)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed(L10n.about.updateFailed)
            }
            let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
            let remote = payload.tag_name ?? payload.name ?? "?"
            let html = payload.html_url.flatMap(URL.init(string:))
            // Local dev builds never match a real release
            // line, so skip the "up to date" branch and
            // surface the GitHub releases tab instead so a
            // tester can grab the latest unsigned IPA.
            if current.releaseType.isDevelopment {
                return .devBuild(remote: remote, url: html ?? repoURL)
            }
            switch VersionComparator.compare(current.fullVersion, remote) {
            case .orderedAscending:
                return .updateAvailable(remote: remote, url: html ?? repoURL)
            case .orderedSame, .orderedDescending:
                return .upToDate(remote: remote)
            }
        } catch {
            bpLog("About: update check failed: \(error.localizedDescription)")
            return .failed(L10n.about.updateFailed)
        }
    }

    /// Subset of the GitHub release JSON we care about.
    /// `tag_name` is the canonical version source
    /// (matches the CI workflow's release-tag step);
    /// `html_url` is where the user lands on tap.
    private struct ReleasePayload: Decodable {
        let tag_name: String?
        let name: String?
        let html_url: String?
        let prerelease: Bool?
    }
}

// MARK: - AppVersionInfo full-version helper

private extension AppVersionInfo {
    /// `marketingVersion + . + buildNumber`, e.g. `0.5.1.2`.
    /// Used as the comparison operand against a remote tag
    /// like `v0.5.1.195` so the version comparator sees the
    /// same number of components on both sides.
    var fullVersion: String {
        "\(marketingVersion).\(buildNumber)"
    }
}

// MARK: - String helpers

private extension String {
    /// Returns the receiver when non-empty, otherwise a
    /// single em-dash.  Used for "—" placeholders so the
    /// About page never renders an empty cell for a
    /// missing Info.plist value.
    var nonEmptyOrDash: String {
        isEmpty ? "—" : self
    }
}
