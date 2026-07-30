import Foundation

/// A single signed-in Bilibili account, persisted in the iOS Keychain
/// via `AccountSessionStore`. Mirrors the Android `StoredAccountSession`
/// shape — only the fields we actually need to make authenticated
/// requests and render the profile header.
struct StoredAccount: Codable, Hashable, Identifiable {
    var id: Int64 { mid }

    /// Bilibili user `mid`. The unique key for the account.
    let mid: Int64
    /// Display name (e.g. "哔哩哔哩国创").
    let name: String
    /// Avatar URL.
    let faceURL: URL?
    /// `SESSDATA` — the main session cookie. Required for any
    /// authenticated request (comments, follow feed, higher-quality
    /// playback, etc.).
    let sessData: String
    /// `bili_jct` — the CSRF token. Required for write operations
    /// (like / coin / favourite / send-comment).
    let csrf: String
    /// `buvid3` — the device fingerprint. Helps the API trust the
    /// client. Optional but recommended.
    let buvid3: String?
    /// `DedeUserID` — sometimes set as a cookie separately; capture it
    /// when present so we can rebuild the cookie header verbatim.
    let dedeUserID: String?
    /// Last time the user activated this account on this device.
    var lastUsedAt: Date
    /// Decoded 大会员 badge from the last login / `nav` refresh.
    /// Persisted so the profile header can render the badge on the
    /// very first paint after a fresh launch — without paying a
    /// round-trip to `/x/web-interface/nav` for every cold start.
    /// Optional: anonymous users and accounts without VIP simply
    /// omit the field. The background VIP-refresh task (in
    /// `PaladalaApp.body.onAppear`) keeps this fresh.
    var vipBadge: BiliVIPBadge?

    init(
        mid: Int64,
        name: String,
        faceURL: URL? = nil,
        sessData: String,
        csrf: String,
        buvid3: String? = nil,
        dedeUserID: String? = nil,
        lastUsedAt: Date = Date(),
        vipBadge: BiliVIPBadge? = nil
    ) {
        self.mid = mid
        self.name = name
        self.faceURL = faceURL
        self.sessData = sessData
        self.csrf = csrf
        self.buvid3 = buvid3
        self.dedeUserID = dedeUserID
        self.lastUsedAt = lastUsedAt
        self.vipBadge = vipBadge
    }
}

extension StoredAccount {
    /// Build the `Cookie:` header value for this account. Includes the
    /// SESSDATA, bili_jct, buvid3, and DedeUserID cookies in the order
    /// the Bilibili API expects them.
    var cookieHeader: String {
        var parts: [String] = []
        parts.append("SESSDATA=\(sessData)")
        parts.append("bili_jct=\(csrf)")
        if let buvid3, !buvid3.isEmpty {
            parts.append("buvid3=\(buvid3)")
        }
        if let dedeUserID, !dedeUserID.isEmpty {
            parts.append("DedeUserID=\(dedeUserID)")
        }
        return parts.joined(separator: "; ")
    }
}
