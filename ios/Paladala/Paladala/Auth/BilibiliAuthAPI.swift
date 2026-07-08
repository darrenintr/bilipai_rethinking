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

    /// Step 3: with the SESSDATA cookie in hand, hit `/x/web-interface/nav`
    /// to read the user `mid`, name, and avatar.
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
            faceURL: payload.data.faceURL
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

    /// Extract cookies from the cross-domain URL query string. Falls
    /// back to the `Set-Cookie` response header (iOS strips these by
    /// default, but the helper is preserved for completeness).
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
        // Fallback / supplement: try Set-Cookie headers. iOS strips
        // these by default but the helper stays in case a future SDK
        // exposes them, or if someone swaps in a custom session config.
        if let http = response as? HTTPURLResponse {
            let headers = http.allHeaderFields
            let raw: String? = {
                if let v = http.value(forHTTPHeaderField: "Set-Cookie"), !v.isEmpty {
                    return v
                }
                return headers["Set-Cookie"] as? String
            }()
            if let raw, out.isEmpty {
                for chunk in raw.split(separator: ",") {
                    let trimmed = chunk.trimmingCharacters(in: .whitespaces)
                    guard let first = trimmed.split(separator: ";").first else { continue }
                    let pair = first.split(separator: "=", maxSplits: 1)
                    guard pair.count == 2 else { continue }
                    let name = String(pair[0]).trimmingCharacters(in: .whitespaces)
                    let value = String(pair[1]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { out[name] = value }
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

struct WebQrcodeNavInfo {
    let mid: Int64
    let name: String
    let faceURL: URL?
}

private struct WebNavResponse: Decodable, Sendable {
    let data: WebNavData
    struct WebNavData: Decodable, Sendable {
        let mid: Int64
        let uname: String?
        let face: String?
        var faceURL: URL? {
            guard let face else { return nil }
            return URL(string: face.hasPrefix("//") ? "https:\(face)" : face)
        }
    }
}
