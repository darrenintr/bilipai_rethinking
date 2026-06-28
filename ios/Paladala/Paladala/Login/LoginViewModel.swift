import SwiftUI
import CoreImage.CIFilterBuiltins

/// Drives the Web QR login sheet. Owns the QR generation, the polling
/// loop, and the SESSDATA capture. Mirrors the Android `LoginViewModel`
/// state machine in spirit: generating → waiting → scanned → success
/// (or expired / error).
@MainActor
final class LoginViewModel: ObservableObject {
    enum State: Equatable {
        case generating
        case waiting(image: UIImage, key: String)
        case scanned(image: UIImage, key: String)
        case expired
        case success(StoredAccount)
        case error(String)
    }

    @Published private(set) var state: State = .generating
    @Published private(set) var statusText: String = "正在生成二维码…"

    private let authAPI: BilibiliAuthAPI
    private var authStore: AuthStore
    private var pollTask: Task<Void, Never>?

    init(authAPI: BilibiliAuthAPI = BilibiliAuthAPI(), authStore: AuthStore) {
        self.authAPI = authAPI
        self.authStore = authStore
    }

    /// Re-bind to the live environment-provided `AuthStore`. The sheet
    /// uses this to swap in the real store after `@StateObject` is set
    /// up, since the init doesn't have access to the environment.
    func setAuthStore(_ store: AuthStore) {
        self.authStore = store
    }

    deinit {
        pollTask?.cancel()
    }

    /// Generate a fresh QR code, render it, and start the polling loop.
    func start() {
        pollTask?.cancel()
        statusText = "正在生成二维码…"
        state = .generating
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await authAPI.webQrcodeGenerate()
                guard let image = Self.renderQR(token.url) else {
                    state = .error("二维码生成失败，请重试")
                    statusText = "二维码生成失败"
                    return
                }
                state = .waiting(image: image, key: token.qrcodeKey)
                statusText = "请使用 Bilibili App 扫码登录"
                await self.pollLoop(key: token.qrcodeKey, image: image)
            } catch {
                state = .error(error.localizedDescription)
                statusText = "生成失败：\(error.localizedDescription)"
            }
        }
    }

    /// Cancel the in-flight polling task and ask the server for a
    /// fresh token. Called when the user taps "刷新二维码".
    func regenerate() {
        start()
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLoop(key: String, image: UIImage) async {
        // Bilibili recommends a 3 s poll interval. We back off slightly
        // on errors and bail out on `.expired` / `.success`.
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                let result = try await authAPI.webQrcodePoll(qrcodeKey: key)
                switch result.state {
                case .waiting:
                    statusText = "请使用 Bilibili App 扫码登录"
                case .scanned:
                    state = .scanned(image: image, key: key)
                    statusText = "请在手机上确认登录"
                case .expired:
                    state = .expired
                    statusText = "二维码已过期，请刷新"
                    return
                case .success:
                    await completeLogin(cookies: result.cookies)
                    return
                case .error(let message):
                    statusText = "登录失败：\(message)"
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                statusText = "网络异常，正在重试…"
                // Continue the loop on transient failures.
            }
        }
    }

    private func completeLogin(cookies: [String: String]) async {
        guard let sessData = cookies["SESSDATA"], !sessData.isEmpty,
              let csrf = cookies["bili_jct"], !csrf.isEmpty else {
            state = .error("登录成功但未返回 SESSDATA 凭证")
            statusText = "登录成功但未返回凭证"
            return
        }
        var buvid3 = cookies["buvid3"]
        let dede = cookies["DedeUserID"]

        // If buvid3 is missing from the login callback (common), fetch it
        // from the SPI endpoint so Wbi signing works on first launch.
        if buvid3 == nil || buvid3!.isEmpty {
            do {
                let spi = try await authAPI.fetchDeviceID()
                buvid3 = spi.buvid3
            } catch {
                bpLog("Failed to fetch device ID during login: \(error)")
            }
        }

        let cookieHeader = StoredAccount(
            mid: 0,
            name: "",
            sessData: sessData,
            csrf: csrf,
            buvid3: buvid3,
            dedeUserID: dede
        ).cookieHeader
        do {
            let info = try await authAPI.navInfo(cookieHeader: cookieHeader)
            let account = StoredAccount(
                mid: info.mid,
                name: info.name,
                faceURL: info.faceURL,
                sessData: sessData,
                csrf: csrf,
                buvid3: buvid3,
                dedeUserID: dede
            )
            authStore.completeLogin(account)
            state = .success(account)
            statusText = "登录成功：\(info.name)"
        } catch {
            state = .error("读取账号信息失败：\(error.localizedDescription)")
            statusText = "登录成功但读取账号信息失败"
        }
    }

    private static func renderQR(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale: CGFloat = 8
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
