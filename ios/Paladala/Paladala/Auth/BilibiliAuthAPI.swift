import Foundation

/// Login-only endpoints. Public and password / SMS flows both share
/// the same `/x/passport-login/web/*` surface. On success, the cookies
/// arrive as `Set-Cookie` headers *and* as query parameters on
/// `data.url` in the success body. We read them from the URL because
/// `URLSession` on iOS hides `Set-Cookie` by default — the URL body
/// path is reliable across iOS versions.
struct BilibiliAuthAPI {
    private let baseURL = URL(string: "https://passport.bilibili.com")!
    private let apiBaseURL = URL(string: "https://api.bilibili.com")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = BilibiliAuthAPI.makeSession()) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            "Referer": "https://passport.bilibili.com/"
        ]
        return URLSession(configuration: config)
    }

    // MARK: - Web QR login (recommended path)

    /// Step 1: ask the server for a fresh QR token. The token drives
    /// the QR encoding and the polling.
    func webQrcodeGenerate() async throws -> WebQrcodeToken {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/x/passport-login/web/qrcode/generate"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "source", value: "main-mini")]
        let url = components.url!
        let (data, _) = try await session.data(from: url)
        let payload = try decoder.decode(WebQrcodeGenerateResponse.self, from: data)
        return WebQrcodeToken(
            qrcodeKey: payload.data.qrcodeKey,
            url: payload.data.url
        )
    }

    /// Step 2: poll the QR status. On success, the cookies arrive in
    /// the `data.url` query string (and on `Set-Cookie` headers which
    /// iOS hides) — we extract them from the URL.
    func webQrcodePoll(qrcodeKey: String) async throws -> WebQrcodePollResult {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/x/passport-login/web/qrcode/poll"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "qrcode_key", value: qrcodeKey)]
        let url = components.url!
        let (data, response) = try await session.data(from: url)
        let payload = try decoder.decode(WebQrcodePollResponse.self, from: data)
        // Prefer the body's `data.url` for cookies — iOS's URLSession
        // strips `Set-Cookie` from the response we can read. The
        // fallback (response header parsing) is preserved for the day
        // Apple exposes the cookies in a future SDK.
        let cookies = WebQrcodePollResult.cookies(
            fromPollURL: payload.data.url,
            response: response
        )
        return WebQrcodePollResult(
            code: payload.data.code,
            message: payload.data.message,
            url: payload.data.url,
            cookies: cookies
        )
    }

    // MARK: - App QR login (preferred — returns access_key for appkey+sign auth)

    /// Step 1 (alternate): ask the server for a fresh QR token on the
    /// **app** endpoint. The QR code itself is identical to the web
    /// one (so the user scans with the same B站 iOS app), but the
    /// server-side polling context identifies us as the iOS app and
    /// returns an `access_key` alongside SESSDATA — the long-lived
    /// bearer token required for the appkey+sign auth path that the
    /// official B站 iOS app uses for the comments endpoint (the WBI
    /// sign path is gated by the 风控 silent-block on URLSession
    /// clients, see agent memory).
    ///
    /// The `source` query param differentiates the polling context —
    /// common values seen in the wild: `main-mini` (web mini),
    /// `main_app` (iOS), `main_web` (web). Picking `main_app` aligns
    /// the polling context with the B站 iOS app so the server issues
    /// the matching app credentials.
    func appQrcodeGenerate() async throws -> WebQrcodeToken {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/x/passport-login/app/qrcode/generate"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "source", value: "main_app")]
        let url = components.url!
        let (data, _) = try await session.data(from: url)
        let payload = try decoder.decode(WebQrcodeGenerateResponse.self, from: data)
        return WebQrcodeToken(
            qrcodeKey: payload.data.qrcodeKey,
            url: payload.data.url
        )
    }

    /// Step 2 (alternate): poll the **app** QR endpoint. On success the
    /// response body carries both the cross-domain cookie URL (same
    /// format as the web endpoint, parsed via the shared `cookies`
    /// helper below) AND a top-level `access_token` field — that token
    /// is what the appkey+sign auth flow uses instead of SESSDATA. The
    /// `refresh_token` is included in the same payload for long-term
    /// session maintenance; we capture it alongside the access token so
    /// a future silent-refresh pass can extend the session without
    /// forcing another QR scan.
    func appQrcodePoll(qrcodeKey: String) async throws -> AppQrcodePollResult {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/x/passport-login/app/qrcode/poll"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "qrcode_key", value: qrcodeKey)]
        let url = components.url!
        let (data, response) = try await session.data(from: url)
        let payload = try decoder.decode(AppQrcodePollResponse.self, from: data)
        // Same cookie extraction as the web endpoint — the cross-domain
        // SSO URL embeds SESSDATA + bili_jct in the query string and
        // we read those values out. The app endpoint adds the bearer
        // token + refresh token on top.
        let cookies = AppQrcodePollResult.cookies(
            fromPollURL: payload.data.url,
            response: response
        )
        return AppQrcodePollResult(
            code: payload.data.code,
            message: payload.data.message,
            url: payload.data.url,
            cookies: cookies,
            accessToken: payload.data.accessToken,
            refreshToken: payload.data.refreshToken,
            expiresIn: payload.data.expiresIn,
            mid: payload.data.mid
        )
    }

    /// Step 3: with the SESSDATA cookie in hand, hit `/x/web-interface/nav`
    /// to read the user `mid`, name, avatar, and 大会员 badge. The badge
    /// projection (`BiliVIPBadge`) is persisted onto the resulting
    /// `StoredAccount` so the profile header can render the colored
    /// chip on the very first paint after launch without a second
    /// round-trip.
    func navInfo(cookieHeader: String) async throws -> WebQrcodeNavInfo {
        let url = apiBaseURL.appendingPathComponent("/x/web-interface/nav")
        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        let payload = try decoder.decode(WebNavResponse.self, from: data)
        return WebQrcodeNavInfo(
            mid: payload.data.mid,
            name: payload.data.uname ?? "Bilibili 用户",
            faceURL: payload.data.faceURL,
            vipBadge: payload.data.vip?.badge() ?? .none
        )
    }

    /// Fetches the device identifiers (buvid3/buvid4) from Bilibili's
    /// SPI endpoint. These are required for Wbi signing and tracking.
    func fetchDeviceID() async throws -> (buvid3: String, buvid4: String) {
        let url = apiBaseURL.appendingPathComponent("/x/frontend/finger/spi")
        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        let payload = try decoder.decode(SpiResponse.self, from: data)
        return (buvid3: payload.data.b3, buvid4: payload.data.b4)
    }
}

// MARK: - SPI DTOs

private struct SpiResponse: Decodable, Sendable {
    let code: Int
    let data: SpiData
    struct SpiData: Decodable, Sendable {
        let b3: String
        let b4: String
    }
}

// MARK: - Web QR DTOs

struct WebQrcodeToken: Hashable {
    let qrcodeKey: String
    let url: String
}

private struct WebQrcodeGenerateResponse: Decodable, Sendable {
    let data: WebQrcodeGenerateData
    struct WebQrcodeGenerateData: Decodable, Sendable {
        let qrcodeKey: String
        let url: String
        enum CodingKeys: String, CodingKey {
            case qrcodeKey = "qrcode_key"
            case url
        }
    }
}

struct WebQrcodePollResult {
    /// `0` = logged in, `86038` = expired, `86090` = scanned (not
    /// confirmed), `86101` = not scanned.
    let code: Int
    let message: String
    /// On success, the cross-domain SSO URL with the cookies embedded
    /// as query parameters. Empty on intermediate states.
    let url: String
    /// Cookies extracted from `data.url` (and the `Set-Cookie` headers
    /// as a fallback). Empty on intermediate states.
    let cookies: [String: String]

    var state: WebQrcodeState {
        switch code {
        case 0: return .success
        case 86038: return .expired
        case 86090: return .scanned
        case 86101: return .waiting
        default: return .error(message)
        }
    }

    /// Extract cookies from the cross-domain URL query string.
    /// Supplements with cookies parsed from the `Set-Cookie`
    /// response header when the URL is missing one of the
    /// credentials we need (most commonly `SESSDATA` — B站
    /// has been observed to ship it via header instead of
    /// query params when the QR-confirm flow lands through
    /// the cross-domain SSO redirect).
    ///
    /// The previous implementation only consulted the
    /// `Set-Cookie` path when the URL was *entirely* empty
    /// (`out.isEmpty`); B站's `data.url` always carries
    /// non-cookie query items like `gourl=`, so that branch
    /// never fired even when SESSDATA was sitting in the
    /// response header. Now the Set-Cookie cookies are
    /// *merged* in — query items win on collision (so the
    /// upstream's intended values are not overwritten) and
    /// any credential that the URL omits falls through to
    /// the header parser.
    ///
    /// Set-Cookie parsing uses Foundation's
    /// `HTTPCookie.cookies(withResponseHeaderFields:for:)`
    /// (RFC 6265) rather than a hand-rolled `,` split, which
    /// broke the `Expires=Wed, 01 Jan 2026 00:00:00 GMT`
    /// attribute (a real cookie's expiry is one field, but
    /// naive `,` splitting tore it into two halves and
    /// truncated every cookie that followed the expiry).
    static func cookies(
        fromPollURL urlString: String,
        response: URLResponse
    ) -> [String: String] {
        var out: [String: String] = [:]
        if !urlString.isEmpty, let url = URLComponents(string: urlString),
           let items = url.queryItems {
            for item in items {
                out[item.name] = item.value
            }
        }
        // Supplement: Set-Cookie header. The poll endpoint
        // sometimes returns the auth cookies via the
        // `Set-Cookie` response header instead of
        // embedding them in the cross-domain `data.url`
        // (the upstream behaviour is a moving target).
        // iOS URLSession *does* surface Set-Cookie in
        // `allHeaderFields` when the session is configured
        // with `httpShouldSetCookies = false` (the existing
        // setup) — the helper just has to ask Foundation
        // for an RFC-6265 parse instead of slicing on `,`.
        if let http = response as? HTTPURLResponse {
            // `cookies(withResponseHeaderFields:for:)` only
            // reads the `Set-Cookie` keys, so a single dict
            // pull is enough. We pass a sentinel URL so the
            // parser accepts cookies without a `Domain=`
            // attribute (the cross-domain SSO redirect
            // legitimately omits the domain on some B站
            // responses); the parsed cookies' `.name` /
            // `.value` are the only fields we use downstream.
            let parsed = HTTPCookie.cookies(
                withResponseHeaderFields: http.allHeaderFields as! [String: String],
                for: URL(string: "https://passport.bilibili.com")!
            )
            for cookie in parsed {
                // Query items win on collision so a
                // B站-mandated URL-side override of any
                // cookie is preserved. Empty values are
                // dropped so a stray `Set-Cookie: foo=`
                // doesn't blank a real `foo=bar` the URL
                // already provided.
                if !cookie.value.isEmpty, out[cookie.name] == nil {
                    out[cookie.name] = cookie.value
                }
            }
        }
        return out
    }
}

enum WebQrcodeState {
    case waiting
    case scanned
    case expired
    case success
    case error(String)
}

private struct WebQrcodePollResponse: Decodable, Sendable {
    let data: WebQrcodePollData
    struct WebQrcodePollData: Decodable, Sendable {
        let code: Int
        let message: String
        let url: String
        enum CodingKeys: String, CodingKey {
            case code, message, url
        }
    }
}

// MARK: - App QR DTOs (returns access_key + refresh_token alongside cookies)

/// Result of polling the app-style QR endpoint. Adds two bearer
/// tokens to the cookies the web flow returns: `accessToken` is the
/// short-lived (1h) bearer used for appkey+sign requests, and
/// `refreshToken` is the long-lived (30d) refresher that the auth
/// pipeline can later trade for a fresh access_token without
/// forcing the user to scan the QR code again.
struct AppQrcodePollResult {
    /// `0` = logged in, `86038` = expired, `86090` = scanned (not
    /// confirmed), `86101` = not scanned.
    let code: Int
    let message: String
    /// On success, the cross-domain SSO URL with the cookies embedded
    /// as query parameters. Empty on intermediate states.
    let url: String
    /// Cookies extracted from `data.url` (and `Set-Cookie` headers
    /// as a fallback). Empty on intermediate states.
    let cookies: [String: String]
    /// `access_token` — the bearer token used in the `access_key`
    /// query param for appkey+sign requests. `nil` on intermediate
    /// states and on web-only logins.
    let accessToken: String?
    /// `refresh_token` — long-lived (typically 30 days). Captured
    /// for future silent-refresh; not used in the first iteration.
    let refreshToken: String?
    /// `expires_in` — seconds until `accessToken` expires. `0` on
    /// intermediate states.
    let expiresIn: Int
    /// `mid` — server-confirmed user mid, useful for sanity-checking
    /// the account being created. `0` on intermediate states.
    let mid: Int64

    /// Mirrors `WebQrcodePollResult.state` so the existing
    /// `LoginViewModel.pollLoop` switch handles the app endpoint
    /// without a separate branch. The state codes are identical
    /// between the web and app QR endpoints (both sides of B站
    /// return 0/86038/86090/86101 with the same semantics).
    var state: WebQrcodeState {
        switch code {
        case 0: return .success
        case 86038: return .expired
        case 86090: return .scanned
        case 86101: return .waiting
        default: return .error(message)
        }
    }

    /// The same `data.url` + `Set-Cookie` cookie extraction the web
    /// flow uses. Kept as a static helper so the two endpoints
    /// share the Set-Cookie / query-string fallback logic without
    /// each carrying their own copy.
    static func cookies(
        fromPollURL urlString: String,
        response: URLResponse
    ) -> [String: String] {
        var out: [String: String] = [:]
        if !urlString.isEmpty, let url = URLComponents(string: urlString),
           let items = url.queryItems {
            for item in items {
                out[item.name] = item.value
            }
        }
        if let http = response as? HTTPURLResponse {
            let parsed = HTTPCookie.cookies(
                withResponseHeaderFields: http.allHeaderFields as! [String: String],
                for: URL(string: "https://passport.bilibili.com")!
            )
            for cookie in parsed {
                if !cookie.value.isEmpty, out[cookie.name] == nil {
                    out[cookie.name] = cookie.value
                }
            }
        }
        return out
    }
}

private struct AppQrcodePollResponse: Decodable, Sendable {
    let data: AppQrcodePollData
    struct AppQrcodePollData: Decodable, Sendable {
        let code: Int
        let message: String
        let url: String
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int
        let mid: Int64
        enum CodingKeys: String, CodingKey {
            case code, message, url
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case mid
        }
    }
}

struct WebQrcodeNavInfo {
    let mid: Int64
    let name: String
    let faceURL: URL?
    /// Decoded 大会员 badge. `.none` for accounts without a paid
    /// membership. The login flow plumbs this into
    /// `StoredAccount.vipBadge` so the profile chrome can
    /// render the badge without a fresh fetch.
    let vipBadge: BiliVIPBadge
}

private struct WebNavResponse: Decodable, Sendable {
    let data: WebNavData
    struct WebNavData: Decodable, Sendable {
        let mid: Int64
        let uname: String?
        let face: String?
        /// 大会员 block. `nil` for non-VIP accounts (or when the
        /// upstream omits the field, e.g. a future API drift).
        let vip: BilibiliNavVIPDTO?
        var faceURL: URL? {
            guard let face else { return nil }
            return URL(string: face.hasPrefix("//") ? "https:\(face)" : face)
        }
    }
}
