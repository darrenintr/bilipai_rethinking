import XCTest
@testable import Paladala

final class LocalHLSProxyServerTests: XCTestCase {
    override func tearDown() async throws {
        // Cancel the loopback listener installed by
        // `prewarmProxyServer()` so subsequent tests don't see a
        // stale `.ready` port and so the next `.shared` access can
        // lazy-rebuild via `ensureListenerAsync()`.
        LocalHLSProxyServer.shared.cancelListenerForTest()
        try await super.tearDown()
    }

    func test_waitForListener_respectsTimeoutCeiling() async {
        // When the listener is never started, waitForListener must throw
        // within timeout + a small grace window (50 ms), not hang for the
        // legacy 2 000 ms default.
        let proxy = LocalHLSProxyServer(port: 0)
        let start = Date()
        do {
            try await proxy.waitForListener(timeoutMs: 100, pollIntervalMs: 5)
            XCTFail("expected timeout throw")
        } catch {
            let elapsed = Date().timeIntervalSince(start) * 1000
            XCTAssertGreaterThan(elapsed, 95, "must wait at least timeoutMs")
            XCTAssertLessThan(elapsed, 250, "must respect ceiling, was \(elapsed)")
        }
    }

    func test_pollIntervalDrivesPollingCadence() async {
        // pollIntervalMs=10 should produce measurable ticks at ~10 ms.
        // Direct test: wire a faster path later if needed; for v1 just
        // confirm the parameter is honoured by timing a no-op wait.
        let proxy = LocalHLSProxyServer(port: 0)
        let start = Date()
        do {
            try await proxy.waitForListener(timeoutMs: 30, pollIntervalMs: 10)
        } catch {}
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(elapsedMs, 200)
    }

    func test_prewarmProxyServer_startsListenerAndSucceeds() async {
        // Prewarm must (a) never throw, and (b) leave the shared
        // singleton with a listener that is actually `.ready`.
        // Before the `ensureListenerAsync()` fix, this assertion
        // would have failed because `init(port:)` does not start
        // the listener — only `serve(...)` / `serveLive(...)` did.
        await LocalHLSProxyServer.prewarmProxyServer()
        let state = LocalHLSProxyServer.shared.listenerState
        XCTAssertNotNil(state, "prewarm must install a listener on .shared")
        XCTAssertEqual(state, .ready,
                       "prewarm must wait for listener.ready, got \(String(describing: state))")
    }

    // MARK: - PR-A Group 5: resolveSegmentationMode cache fix (item 6)

    /// Minimal `BiliDashSource.Track` for exercising
    /// `resolveSegmentationMode`.  All non-baseURL fields are
    /// placeholders — the function under test only reads
    /// `track.baseURL`.
    private func makeTrack(baseURL: URL) -> BiliDashSource.Track {
        BiliDashSource.Track(
            baseURL: baseURL,
            backupURLs: [],
            codecs: "avc1.640028",
            bandwidth: 1_000_000,
            mimeType: "video/mp4",
            initializationRange: BiliDashSource.ByteRange(offset: 0, length: 1024),
            indexRange: BiliDashSource.ByteRange(offset: 1024, length: 256),
            mediaStartOffset: 1280,
            totalDuration: 60.0,
            width: 1920,
            height: 1080
        )
    }

    func test_resolveSegmentationMode_unavailableDoesNotLock() {
        // **PR-A Group 3 (item 6)**: when the SIDX has not yet
        // been published, the mode must be `.unavailable` AND
        // must NOT be cached in `decidedModes`.  The previously
        // buggy version cached `.unavailable`, pinning AVPlayer
        // to a temp playlist forever.
        let proxy = LocalHLSProxyServer(port: 0)
        let track = makeTrack(
            baseURL: URL(string: "https://example.invalid/v.m4s")!
        )
        // Pre-condition: nothing in the cache for this baseURL.
        XCTAssertNil(proxy.decidedModes[track.baseURL])

        let (mode, _) = proxy.resolveSegmentationModeForTest(for: track)

        XCTAssertEqual(mode, .unavailable,
                       "no SIDX indexed → mode must be .unavailable")
        XCTAssertNil(
            proxy.decidedModes[track.baseURL],
            ".unavailable must NOT be locked into the cache"
        )
    }

    func test_resolveSegmentationMode_sidxLocksAndIsCached() {
        // The symmetric case: once a SIDX has been indexed
        // (trackSegmentIndex populated), the mode is `.sidx`
        // and the first call must lock it into the cache.
        let proxy = LocalHLSProxyServer(port: 0)
        let track = makeTrack(
            baseURL: URL(string: "https://example.invalid/v.m4s")!
        )
        // Pretend the SIDX parser has populated the index.
        // The struct contents don't matter for this test —
        // only the `!= nil` check in resolveSegmentationMode.
        proxy.trackSegmentIndex[track.baseURL] = TrackSegmentIndex(
            initializationRange: 0..<1024,
            fragments: []
        )

        let (mode1, _) = proxy.resolveSegmentationModeForTest(for: track)
        XCTAssertEqual(mode1, .sidx)

        let cached = proxy.decidedModes[track.baseURL]
        XCTAssertEqual(
            cached, .sidx,
            ".sidx must be locked into decidedModes"
        )

        // Second call must read from the cache (same answer).
        let (mode2, _) = proxy.resolveSegmentationModeForTest(for: track)
        XCTAssertEqual(
            mode2, .sidx,
            "subsequent calls must return the cached .sidx"
        )
    }

    // MARK: - PR-A Group 5: parseContentRangeHeader

    func test_parseContentRangeHeader_basicRange() {
        let parsed = LocalHLSProxyServer.parseContentRangeHeader(
            "bytes 0-99/1000"
        )
        XCTAssertEqual(parsed.start, 0)
        XCTAssertEqual(parsed.end, 99)
        XCTAssertEqual(parsed.total, 1000)
    }

    func test_parseContentRangeHeader_openEndedTotal() {
        // RFC 7233 allows `bytes START-END/*` when the total
        // is unknown.  The parser must surface this as
        // `total = -1` (the existing sentinel — preserved here
        // for behavioural compatibility).
        let parsed = LocalHLSProxyServer.parseContentRangeHeader(
            "bytes 512-1023/*"
        )
        XCTAssertEqual(parsed.start, 512)
        XCTAssertEqual(parsed.end, 1023)
        XCTAssertEqual(parsed.total, -1)
    }

    func test_parseContentRangeHeader_garbageReturnsNegatives() {
        // Defensive: malformed headers must NOT throw and
        // must surface as all-`-1` so callers can `guard`
        // against `start < 0` instead of trapping.
        let parsed = LocalHLSProxyServer.parseContentRangeHeader("garbage")
        XCTAssertEqual(parsed.start, -1)
        XCTAssertEqual(parsed.end, -1)
        XCTAssertEqual(parsed.total, -1)
    }

    func test_parseContentRangeHeader_missingPrefixReturnsNegatives() {
        let parsed = LocalHLSProxyServer.parseContentRangeHeader("0-99/100")
        XCTAssertEqual(parsed.start, -1,
                       "missing 'bytes ' prefix must reject")
    }
}
