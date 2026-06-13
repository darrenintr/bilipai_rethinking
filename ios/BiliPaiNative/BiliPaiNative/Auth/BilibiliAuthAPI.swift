import Foundation

/// Login-only endpoints. Public and password / SMS flows both share
/// the same `/x/passport-login/web/*` surface. Cookies returned by
/// the Web QR flow come back as `Set-Cookie` headers — we surface the
/// raw response so the caller can extract `SESSDATA`, `bili_jct`,
/// `buvid3`, and `DedeUserID` from the response headers.
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
            "User-Agent": "Mozilla/5.0 BiliPai-iOS/0.1",
            "Referer": "https://passport.bilibili.com/"
        ]
        return URLSession(configuration: config)
    }

    // MARK: - Web QR login (recommended path)

    /// Step 1: ask the server for a fresh QR token. The token drives
    /// the QR encoding and the polling.
    func webQrcodeGenerate() async throws -> WebQrcodeToken {
        let url = baseURL.appendingPathComponent("/x/passport-login/web/qrcode/login")
        let body: [String: String] = ["source": "main-mini"]
        let payload: WebQrcodeGenerateResponse = try await postForm(
            url: url,
            body: body
        )
        return WebQrcodeToken(
            qrcodeKey: payload.data.qrcodeKey,
            url: payload.data.url
        )
    }

    /// Step 2: poll the QR status. Returns the current state plus any
    /// `Set-Cookie` headers the server attached on success.
    func webQrcodePoll(qrcodeKey: String) async throws -> WebQrcodePollResult {
        let url = baseURL.appendingPathComponent("/x/passport-login/web/qrcode/poll")
        let body: [String: String] = ["qrcode_key": qrcodeKey]
        let (data, response) = try await postFormRaw(
            url: url,
            body: body
        )
        let payload = try decoder.decode(WebQrcodePollResponse.self, from: data)
        let cookies = WebQrcodePollResult.cookies(from: response)
        return WebQrcodePollResult(
            code: payload.data.code,
            message: payload.data.message,
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

    // MARK: - Generic form post

    private func postForm<T: Decodable>(
        url: URL,
        body: [String: String]
    ) async throws -> T {
        let (data, _) = try await postFormRaw(url: url, body: body)
        return try decoder.decode(T.self, from: data)
    }

    private func postFormRaw(
        url: URL,
        body: [String: String]
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://passport.bilibili.com/", forHTTPHeaderField: "Referer")
        let encoded = body
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
        request.httpBody = encoded.data(using: .utf8)
        return try await session.data(for: request)
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

// MARK: - Web QR DTOs

struct WebQrcodeToken: Hashable {
    let qrcodeKey: String
    let url: String
}

private struct WebQrcodeGenerateResponse: Decodable {
    let data: WebQrcodeGenerateData
    struct WebQrcodeGenerateData: Decodable {
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
    /// `Set-Cookie` headers captured from the response, parsed into a
    /// `name=value` map. Empty on intermediate states.
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

    static func cookies(from response: URLResponse) -> [String: String] {
        guard let http = response as? HTTPURLResponse else { return [:] }
        let headers = http.allHeaderFields
        // `Set-Cookie` may be lowercased or not depending on the
        // platform; check both. URLResponse also exposes the
        // dedicated `value(forHTTPHeaderField:)` helper which is
        // case-insensitive — use that first.
        let raw: String? = {
            if let v = http.value(forHTTPHeaderField: "Set-Cookie"), !v.isEmpty {
                return v
            }
            return headers["Set-Cookie"] as? String
        }()
        guard let raw else { return [:] }
        // A single response can include multiple cookies, each on its
        // own `Set-Cookie` line — or comma-separated with attributes.
        // Split on `,` then take the first `name=value` pair from
        // each chunk, which is enough for the four we care about
        // (SESSDATA, bili_jct, buvid3, DedeUserID).
        var out: [String: String] = [:]
        for chunk in raw.split(separator: ",") {
            let trimmed = chunk.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.split(separator: ";").first else { continue }
            let pair = first.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = String(pair[0]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[1]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out[name] = value }
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

private struct WebQrcodePollResponse: Decodable {
    let data: WebQrcodePollData
    struct WebQrcodePollData: Decodable {
        let code: Int
        let message: String
    }
}

struct WebQrcodeNavInfo {
    let mid: Int64
    let name: String
    let faceURL: URL?
}

private struct WebNavResponse: Decodable {
    let data: WebNavData
    struct WebNavData: Decodable {
        let mid: Int64
        let uname: String?
        let face: String?
        var faceURL: URL? {
            guard let face else { return nil }
            return URL(string: face.hasPrefix("//") ? "https:\(face)" : face)
        }
    }
}
