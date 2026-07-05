import Foundation

@MainActor
final class SponsorBlockService {
    static let shared = SponsorBlockService()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    private var baseURL: String {
        SponsorBlockManager.shared.config.serverURL
    }

    // MARK: - Fetch Segments

    func fetchSegments(videoID: String, categories: [SponsorCategory]) async throws -> [SponsorSegment] {
        var components = URLComponents(string: "\(baseURL)/skipSegments")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "videoID", value: videoID)
        ]
        if !categories.isEmpty {
            let cats = categories.map(\.rawValue)
            if let data = try? JSONSerialization.data(withJSONObject: cats),
               let str = String(data: data, encoding: .utf8) {
                queryItems.append(URLQueryItem(name: "categories", value: str))
            }
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw SponsorError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Paladala-iOS", forHTTPHeaderField: "origin")
        request.setValue("1.0.0", forHTTPHeaderField: "x-ext-version")
        request.setValue("1", forHTTPHeaderField: "x-skip-cache")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SponsorError.networkError
        }

        if http.statusCode == 404 {
            return []
        }
        guard http.statusCode == 200 else {
            throw SponsorError.httpError(http.statusCode)
        }

        do {
            let segments = try decoder.decode([SponsorSegment].self, from: data)
            return segments
        } catch {
            throw SponsorError.decodeError
        }
    }

    // MARK: - Submit Segment

    func submitSegment(videoID: String, cid: String?, category: String, startTime: Double, endTime: Double, userID: String, videoDuration: Double) async throws {
        let url = URL(string: "\(baseURL)/skipSegments")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Paladala-iOS", forHTTPHeaderField: "origin")
        request.setValue("1.0.0", forHTTPHeaderField: "x-ext-version")

        var body: [String: Any] = [
            "videoID": videoID,
            "userID": userID,
            "videoDuration": videoDuration,
            "segments": [
                [
                    "segment": [startTime, endTime],
                    "category": category,
                    "actionType": "skip"
                ]
            ]
        ]
        if let cid {
            body["cid"] = cid
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SponsorError.networkError
        }
        guard http.statusCode == 200 else {
            if let bodyStr = String(data: data, encoding: .utf8) {
                throw SponsorError.submitFailed(bodyStr)
            }
            throw SponsorError.httpError(http.statusCode)
        }
    }

    // MARK: - Vote

    func vote(uuid: String, userID: String, type: Int) async throws {
        let url = URL(string: "\(baseURL)/voteOnSponsorTime")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Paladala-iOS", forHTTPHeaderField: "origin")
        request.setValue("1.0.0", forHTTPHeaderField: "x-ext-version")

        let body: [String: Any] = [
            "UUID": uuid,
            "userID": userID,
            "type": type
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SponsorError.networkError
        }
        guard http.statusCode == 200 else {
            throw SponsorError.httpError(http.statusCode)
        }
    }

    // MARK: - Record View

    func recordView(uuid: String) async throws {
        let url = URL(string: "\(baseURL)/viewedVideoSponsorTime")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Paladala-iOS", forHTTPHeaderField: "origin")
        request.setValue("1.0.0", forHTTPHeaderField: "x-ext-version")

        let body = ["UUID": uuid]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SponsorError.networkError
        }
        guard http.statusCode == 200 else {
            throw SponsorError.httpError(http.statusCode)
        }
    }
}

enum SponsorError: LocalizedError {
    case invalidURL
    case networkError
    case httpError(Int)
    case decodeError
    case submitFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的URL"
        case .networkError: return "网络错误"
        case .httpError(let code): return "HTTP错误: \(code)"
        case .decodeError: return "数据解析失败"
        case .submitFailed(let msg): return "提交失败: \(msg)"
        }
    }
}
