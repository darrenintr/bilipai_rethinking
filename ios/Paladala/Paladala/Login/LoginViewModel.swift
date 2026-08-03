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
    /// Uses the **app/TV** QR endpoint (`/x/passport-tv-login/qrcode/...`).
    ///
    /// The TV endpoint is the only B站 login surface that issues an
    /// `access_token` (the bearer used in the `access_key` query param
    /// for appkey+sign requests). B站's official iOS / Android apps
    /// also use the TV endpoint under the hood, despite the
    /// "TV" naming — see pskdje/bilibili-API-collect
    /// `docs/login/login_action/QR.md` §"扫码登录(TV端)".
    ///
    /// Why we need `access_key` at all: the comments pipeline's
    /// LegacyPnEndpoint and WbiSignedEndpoint are both silently
    /// gated by B站's URLSession 風控 (200 OK with valid cursor but
    /// empty `replies[]`). The `AppSignedEndpoint` with a valid
    /// `access_key` is the only path B站 still serves real comment
    /// lists to a third-party iOS client. See `CommentPipeline.swift`
    /// for the full diagnosis.
    ///
    /// Trade-off: the TV endpoint pairs the `access_token` with the
    /// TV-flavored `appkey` (`tvAppKey` = `4409e2ce8ffd12b8`). Earlier
    /// testing (v0.5.10) showed B站 classifying TV-paired tokens as
    /// TV client and the comments endpoint returning `replies: null`
    /// even with a valid signature. Re-trying the TV flow here
    /// because the upstream's classification heuristic may have
    /// loosened, and the WBI/legacy paths are confirmed dead for
    /// URLSession clients in v0.5.15. If TV flow still gates, the
    /// next iteration would substitute a reverse-engineered iOS
    /// `appkey` for the minting step.
    func start() {
        pollTask?.cancel()
        statusText = "正在生成二维码…"
        state = .generating
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await authAPI.appQrcodeGenerate()
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
                let result = try await authAPI.appQrcodePoll(qrcodeKey: key)
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
                    // App/TV flow pairs SESSDATA with an
                    // `access_token` — the bearer we plumb into
                    // `StoredAccount.accessKey` so the comment
                    // pipeline can pick `AppSignedEndpoint` over
                    // the silently-gated WBI/legacy paths.
                    // `result.accessToken` is `nil` on intermediate
                    // states and on edge cases where the server
                    // ships cookies without the bearer; `completeLogin`
                    // logs the length (never the value) so we can
                    // verify capture without exposing the secret.
                    await completeLogin(cookies: result.cookies, accessKey: result.accessToken)
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

    private func completeLogin(cookies: [String: String], accessKey: String?) async {
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

        // Diagnostic so we can verify the access_key actually arrived
        // on first capture — the field is the long-lived bearer token
        // used by the appkey+sign auth path; logging just its length
        // (never the value) keeps the diagnostic useful without
        // shipping a credential into the log file. The web QR flow
        // never returns one (nil here is the norm, not an error).
        if let accessKey, !accessKey.isEmpty {
            bpLog("QR login: access_key captured, length=\(accessKey.count)")
        } else {
            bpLog("QR login: web flow — no access_key (comments use the legacy /x/v2/reply path)")
        }

        let cookieHeader = StoredAccount(
            mid: 0,
            name: "",
            sessData: sessData,
            csrf: csrf,
            buvid3: buvid3,
            dedeUserID: dede,
            accessKey: accessKey
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
                dedeUserID: dede,
                accessKey: accessKey,
                vipBadge: info.vipBadge.isActive ? info.vipBadge : nil
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
