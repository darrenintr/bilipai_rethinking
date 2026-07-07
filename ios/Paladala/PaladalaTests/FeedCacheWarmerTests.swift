import XCTest
@testable import Paladala

/// Tests for `FeedCacheWarmer` (PR-A Task 3, audit items #6 and #14).
///
/// Uses a per-test `tmpDir` so the test cannot see (or be polluted by)
/// the production `Application Support/Paladala/` cache. The warmer
/// itself is `@MainActor`; `await` is needed on the init because the
/// method is actor-isolated.
final class FeedCacheWarmerTests: XCTestCase {
    var tmpDir: URL!
    var sut: FeedCacheWarmer!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FCWTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // FeedCacheWarmer.init is `nonisolated` so the `static let shared`
        // initializer can call it from any context; the `await` here would
        // be a no-op warning.
        sut = FeedCacheWarmer(directory: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    func test_seed_returnsNil_whenFileMissing() async {
        let cards = await sut.seedFromCache(key: "home")
        XCTAssertNil(cards)
    }

    func test_seed_returnsArray_whenFilePresentAndValid() async throws {
        let envelope = FeedSnapshotEnvelope(version: 1, cards: [
            BiliVideo.testStub(bvid: "BV1"),
            BiliVideo.testStub(bvid: "BV2"),
        ])
        let payload = try JSONEncoder().encode(envelope)
        try payload.write(to: tmpDir.appendingPathComponent("home.json"))
        let cards = await sut.seedFromCache(key: "home")
        XCTAssertEqual(cards?.map(\.bvid), ["BV1", "BV2"])
    }

    func test_seed_returnsNil_whenFileCorrupt() async throws {
        try "not-json".data(using: .utf8)!
            .write(to: tmpDir.appendingPathComponent("home.json"))
        let cards = await sut.seedFromCache(key: "home")
        XCTAssertNil(cards)
    }

    func test_seed_returnsNil_whenSchemaMigrated() async throws {
        let payload = """
            { "version": 99, "cards": [] }
            """.data(using: .utf8)!
        try payload.write(to: tmpDir.appendingPathComponent("home.json"))
        let cards = await sut.seedFromCache(key: "home")
        XCTAssertNil(cards)
    }
}

// MARK: - Test stub

private extension BiliVideo {
    /// Minimal `BiliVideo` for cache tests — only `bvid` is checked by
    /// the assertions, so the rest stay at zero. Kept private to the
    /// test target so it cannot leak into production code.
    static func testStub(bvid: String) -> BiliVideo {
        BiliVideo(
            bvid: bvid,
            aid: 0,
            cid: 0,
            title: "",
            ownerName: "",
            coverURL: nil,
            duration: 0,
            viewCount: 0,
            danmakuCount: 0,
            likeCount: 0,
            description: "",
            ownerMid: 0,
            resumeTime: nil
        )
    }
}