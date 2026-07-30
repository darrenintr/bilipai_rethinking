//
//  UpdateManager.swift
//  Paladala
//
//  Manages one-tap IPA download + SideStore installation flow.
//  When the user taps "下载并安装" on the About page after an
//  update check returns `.updateAvailable`, this manager:
//    1. Fetches the latest release assets from GitHub API
//    2. Downloads the unsigned IPA to Files.app temporary storage
//    3. Opens the IPA via UIDocumentInteractionController or
//       the SideStore URL scheme so the user can install
//
//  The download runs on a background URLSession so progress
//  is trackable and the user can leave the app mid-download.
//

import Foundation
import UIKit

/// Manages the one-tap update flow: fetch release → download
/// IPA → invoke Shortcut to install via SideStore.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    @Published var updateDownloadState: UpdateDownloadState = .idle
    @Published var downloadProgress: Double = 0

    private var downloadTask: URLSessionDownloadTask?
    private var pendingIPAURL: URL? // Store the IPA download URL to pass to Shortcut

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.paladala.ipa-download"
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Fetch the latest release from GitHub, find the unsigned
    /// IPA asset, and invoke the Shortcut to download and install.
    func downloadAndInstallLatest() async {
        // Check if Shortcut is installed
        guard ShortcutManager.shared.hasInstalledShortcut else {
            bpLog("UpdateManager: Shortcut not installed, prompting user")
            ShortcutManager.shared.checkAndPromptIfNeeded()
            await MainActor.run {
                updateDownloadState = .failed("请先安装快捷指令")
            }
            return
        }

        guard updateDownloadState != .downloading else {
            bpLog("UpdateManager: download already in progress")
            return
        }

        await MainActor.run {
            updateDownloadState = .downloading
            downloadProgress = 0
        }

        do {
            // Step 1: fetch latest release JSON
            let release = try await fetchLatestRelease()
            guard let ipaAsset = release.assets?.first(where: { asset in
                asset.name?.contains("unsigned") == true &&
                asset.name?.hasSuffix(".ipa") == true
            }) else {
                throw UpdateError.noIPAFound
            }

            guard let downloadURL = ipaAsset.browser_download_url.flatMap(URL.init(string:)) else {
                throw UpdateError.invalidURL
            }

            bpLog("UpdateManager: found IPA at \(downloadURL.absoluteString)")

            // Step 2: invoke Shortcut to handle download and installation
            pendingIPAURL = downloadURL
            let success = ShortcutManager.shared.installIPA(from: downloadURL)

            await MainActor.run {
                if success {
                    updateDownloadState = .completed(downloadURL)
                    bpLog("UpdateManager: Shortcut invoked successfully")
                } else {
                    updateDownloadState = .failed("无法调用快捷指令")
                    bpLog("UpdateManager: failed to invoke Shortcut")
                }
            }

        } catch {
            bpLog("UpdateManager: download failed: \(error)")
            await MainActor.run {
                updateDownloadState = .failed(error.localizedDescription)
            }
        }
    }

    /// Cancel the active download.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        updateDownloadState = .idle
        downloadProgress = 0
        pendingIPAURL = nil
    }

    // MARK: - Private

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let repoOwner = "darrenintr"
        let repoName = "pure-bilibili-rethinking"
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases?per_page=1") else {
            throw UpdateError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Paladala-iOS/\(AppVersion.current.marketingVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw UpdateError.networkError
        }

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard let latest = releases.first else {
            throw UpdateError.noReleaseFound
        }

        return latest
    }

    // Legacy download methods kept for fallback scenarios
    // (can be removed if Shortcut-only flow is preferred)

    private func startDownload(from url: URL, filename: String) async {
        let task = urlSession.downloadTask(with: url)
        downloadTask = task
        task.resume()
        bpLog("UpdateManager: started download task for \(filename)")
    }

    /// Present the downloaded IPA via UIDocumentInteractionController
    /// or try the SideStore URL scheme.
    private func presentIPA(at fileURL: URL) {
        // Strategy 1: try SideStore URL scheme first
        let encoded = fileURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let sideStoreURL = URL(string: "sidestore://install?url=\(encoded)"),
           UIApplication.shared.canOpenURL(sideStoreURL) {
            bpLog("UpdateManager: opening via SideStore URL scheme")
            UIApplication.shared.open(sideStoreURL)
            return
        }

        // Strategy 2: UIActivityViewController (share sheet)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            bpLog("UpdateManager: no root view controller to present share sheet")
            return
        }

        let activityVC = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        activityVC.excludedActivityTypes = [
            .addToReadingList,
            .assignToContact,
            .postToFacebook,
            .postToTwitter
        ]

        // iPad popover support
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = rootVC.view
            popover.sourceRect = CGRect(
                x: rootVC.view.bounds.midX,
                y: rootVC.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }

        bpLog("UpdateManager: presenting iOS share sheet")
        rootVC.present(activityVC, animated: true)
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move the temp file to a stable location in the app's
        // Documents directory so it survives the URLSession cleanup.
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationURL = documentsURL.appendingPathComponent("Paladala-latest.ipa")

        do {
            // Remove any existing IPA at the destination
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)
            bpLog("UpdateManager: IPA saved to \(destinationURL.path)")

            Task { @MainActor in
                self.updateDownloadState = .completed(destinationURL)
                self.presentIPA(at: destinationURL)
            }
        } catch {
            bpLog("UpdateManager: failed to move IPA: \(error)")
            Task { @MainActor in
                self.updateDownloadState = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.downloadProgress = progress
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            bpLog("UpdateManager: download task failed: \(error)")
            Task { @MainActor in
                self.updateDownloadState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - UpdateDownloadState

enum UpdateDownloadState: Equatable {
    case idle
    case downloading
    case completed(URL)
    case failed(String)
}

// MARK: - UpdateError

enum UpdateError: LocalizedError {
    case invalidURL
    case networkError
    case noReleaseFound
    case noIPAFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的下载地址"
        case .networkError:
            return "网络请求失败"
        case .noReleaseFound:
            return "未找到可用的发布版本"
        case .noIPAFound:
            return "该版本没有 unsigned IPA 文件"
        }
    }
}

// MARK: - GitHub API models

struct GitHubRelease: Decodable {
    let tag_name: String?
    let name: String?
    let html_url: String?
    let assets: [GitHubAsset]?
}

struct GitHubAsset: Decodable {
    let name: String?
    let browser_download_url: String?
    let size: Int?
}
