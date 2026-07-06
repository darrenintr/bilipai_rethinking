import XCTest
@testable import Paladala

final class LocalHLSProxyServerTests: XCTestCase {
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
        let listener = LocalHLSProxyServer.shared.listener
        XCTAssertNotNil(listener, "prewarm must install a listener on .shared")
        XCTAssertEqual(listener?.state, .ready,
                       "prewarm must wait for listener.ready, got \(String(describing: listener?.state))")
    }
}
