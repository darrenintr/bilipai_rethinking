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
        List {
            identitySection
            updateSection
            footerSection
        }
        .listStyle(.insetGrouped)
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

    private var identitySection: some View {
        Section {
            IdentityRow(
                label: L10n.about.version,
                value: version.marketingVersion,
                monospaced: true
            )
            IdentityRow(
                label: L10n.about.build,
                value: version.buildNumber,
                monospaced: true
            )
            identifierRow
            IdentityRow(
                label: L10n.about.releaseType,
                value: version.releaseTypeDisplay
            )
            IdentityRow(
                label: L10n.about.channel,
                value: version.channel.nonEmptyOrDash,
                monospaced: true
            )
            if let commit = version.commitShort {
                IdentityRow(
                    label: L10n.about.commit,
                    value: commit,
                    monospaced: true
                )
            }
            IdentityRow(
                label: L10n.about.buildDate,
                value: formatDate(version.buildDate),
                monospaced: true
            )
            IdentityRow(
                label: L10n.about.bundleId,
                value: version.bundleId,
                monospaced: true
            )
        } header: {
            Text("构建信息")
        } footer: {
            Text("特别辨识号用于精确标识当前构建，反馈问题时附上它可以帮我们快速定位。")
        }
    }

    private var identifierRow: some View {
        Button {
            copyIdentifier()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.about.identifier)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(version.identifierDisplay)
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(PaladalaTheme.mutedInk)
                        .textSelection(.enabled)
                }
                Spacer()
                Image(systemName: "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var updateSection: some View {
        Section {
            Button {
                checkForUpdates()
            } label: {
                HStack {
                    Label(L10n.about.checkForUpdates, systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                    Spacer()
                    if case .checking = updateState {
                        ProgressView()
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(updateState == .checking)

            updateResultRow
        } header: {
            Text("更新")
        } footer: {
            Text("对比当前版本与 GitHub 上最新的预发布版本。")
        }
    }

    @ViewBuilder
    private var updateResultRow: some View {
        switch updateState {
        case .idle:
            EmptyView()
        case .checking:
            Text(L10n.about.checking)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .upToDate(let remote):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(L10n.about.upToDate) · \(remote)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .updateAvailable(let remote, let url):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(PaladalaTheme.biliPink)
                    Text("\(L10n.about.updateAvailable) · \(remote)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                // Download + install button
                Button {
                    Task {
                        await updateManager.downloadAndInstallLatest()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if updateManager.downloadState == .downloading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(downloadButtonLabel)
                            .font(.caption.weight(.semibold))
                        if updateManager.downloadState == .downloading {
                            Text("(\(Int(updateManager.downloadProgress * 100))%)")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(PaladalaTheme.biliPink)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(updateManager.downloadState == .downloading)

                // Show error or success
                if case .failed(let error) = updateManager.downloadState {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .completed = updateManager.downloadState {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("下载完成，请在分享菜单中选择 SideStore")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Fallback: view on GitHub
                if let url {
                    Button {
                        openURL(url)
                    } label: {
                        Label(L10n.about.viewRelease, systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
        case .devBuild(let remote, let url):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "hammer.fill")
                        .foregroundStyle(PaladalaTheme.biliPink)
                    Text(L10n.about.devBuild)
                        .font(.caption.weight(.semibold))
                }
                if let remote {
                    Text(L10n.about.upToDate + " · \(remote)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Dev builds also get the download button
                Button {
                    Task {
                        await updateManager.downloadAndInstallLatest()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if updateManager.downloadState == .downloading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(downloadButtonLabel)
                            .font(.caption.weight(.semibold))
                        if updateManager.downloadState == .downloading {
                            Text("(\(Int(updateManager.downloadProgress * 100))%)")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(PaladalaTheme.biliPink)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(updateManager.downloadState == .downloading)

                if case .failed(let error) = updateManager.downloadState {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .completed = updateManager.downloadState {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("下载完成，请在分享菜单中选择 SideStore")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let url {
                    Button {
                        openURL(url)
                    } label: {
                        Label(L10n.about.openOnGitHub, systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        Section {
            VStack(spacing: 4) {
                Text("Paladala")
                    .font(.headline)
                Text("Pure Bilibili · Native iOS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
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

// MARK: - IdentityRow

/// One labelled key/value row in the identity section.
/// Falls back to `—` when the value is empty so an unset
/// Info.plist key (e.g. commit on a local-dev build) still
/// reads sensibly.
private struct IdentityRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(monospaced ? PaladalaTheme.FontRole.labelMono : .subheadline)
                .foregroundStyle(PaladalaTheme.mutedInk)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
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
