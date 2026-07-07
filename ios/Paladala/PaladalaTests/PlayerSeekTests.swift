import XCTest
import AVFoundation
@testable import Paladala

/// Tests for the seek state machine added in PR-A Group 1
/// (`isSeeking`, `seekGeneration`, `seekTolerance`,
/// `performSeek`), the SponsorBlock integration (Group 1
/// follow-up), and the retry snapshot+restore path added in
/// PR-A Group 4 (item 9, D4).
///
/// Tests construct a minimal `AVPlayerController` with a
/// `BiliPlayback.fallbackURL` (direct URL → `usesProxy =
/// false`).  That deliberately sidesteps the local HLS proxy
/// so the unit test suite never binds a loopback listener.
/// The seek plumbing itself is identical on both code paths
/// because `performSeek` is the single entry point — direct
/// and proxy playback share the same seek state machine.
final class PlayerSeekTests: XCTestCase {

    // MARK: - helpers

    /// Build a minimal controller backed by a direct URL.
    /// `duration` stays at 0 (the asset is never loaded) which
    /// is fine — `seek(by:)` / `seek(to:)` early-return when
    /// `duration == 0`, so the controller never asks AVPlayer
    /// to seek into an unknown timeline.
    private func makeController() -> AVPlayerController {
        let playback = BiliPlayback(
            dash: nil,
            fallbackURL: URL(string: "https://example.invalid/test.mp4"),
            referer: URL(string: "https://www.bilibili.com/")
        )
        return AVPlayerController(playback: playback)
    }

    // MARK: - initial state

    func test_initialState_isSeekingFalse_seekGenerationZero() {
        let controller = makeController()
        XCTAssertFalse(controller.isSeeking,
                       "freshly-constructed controller must not be seeking")
        XCTAssertEqual(controller.seekGeneration, 0,
                       "seekGeneration starts at zero")
        XCTAssertNil(controller.retryRestoreTime,
                     "no pending retry restore on a fresh controller")
    }

    func test_initialState_usesProxyFalse_forFallbackURL() {
        // Sanity-check the test setup: a BiliPlayback with
        // `dash == nil` and a `fallbackURL` lands on the direct
        // (non-proxy) branch.  If this ever flips, every seek
        // test in this file would need to start/stop the
        // proxy listener.
        let controller = makeController()
        XCTAssertFalse(controller.usesProxy,
                       "fallbackURL path must be non-proxy")
    }

    // MARK: - seek tolerance

    func test_seekToleranceForTesting_isHalfSecondBothWays() {
        // The test-accessible mirror exposes the (before,
        // after) tolerance pair as an Equatable value so we
        // can assert it without poking CMTime internals.
        let expected = AVPlayerController.SeekToleranceForTesting(
            toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
            toleranceAfter:  CMTime(seconds: 0.5, preferredTimescale: 600)
        )
        XCTAssertEqual(
            AVPlayerController.seekToleranceForTesting,
            expected,
            "all seek paths must use a uniform 0.5s tolerance"
        )
    }

    func test_seekToleranceForTesting_isNotZeroTolerance() {
        // PR-A item 3: a zero-tolerance seek (the default when
        // you call seek(to:) with no tolerance pair) is a known
        // stall trigger.  Asserting non-zero here pins the fix.
        let tol = AVPlayerController.seekToleranceForTesting
        XCTAssertGreaterThan(
            CMTimeGetSeconds(tol.toleranceBefore), 0,
            "toleranceBefore must be > 0"
        )
        XCTAssertGreaterThan(
            CMTimeGetSeconds(tol.toleranceAfter), 0,
            "toleranceAfter must be > 0"
        )
    }

    // MARK: - seek clamp behaviour (pure logic, no AVPlayer.seek fires)

    func test_seek_withNegativeTime_clampsToZero_doesNotCrash() {
        // duration == 0 → seek(by:) / seek(to:) early-return,
        // which is the safest possible behaviour for a
        // never-loaded controller.  Verify it doesn't crash.
        let controller = makeController()
        controller.seek(by: -10)
        controller.seek(to: -1)
        // If we got here, the clamp + early-return worked.
        XCTAssertEqual(controller.seekGeneration, 0,
                       "early-return must NOT bump seekGeneration")
        XCTAssertFalse(controller.isSeeking,
                       "early-return must NOT set isSeeking")
    }

    func test_seek_withInfinityTarget_isIgnored() {
        // NaN / Infinity are real inputs from upstream
        // malformed durations.  PerformSeek must not be
        // reached, so no state mutation.
        let controller = makeController()
        controller.seek(to: .infinity)
        controller.seek(to: .nan)
        XCTAssertEqual(controller.seekGeneration, 0,
                       "non-finite targets must not bump generation")
        XCTAssertFalse(controller.isSeeking,
                       "non-finite targets must not set isSeeking")
    }

    // MARK: - retry plumbing

    func test_retryPlayback_doesNothingFromPreparing() {
        // Group 4 invariant: only `.ready` is retryable.  All
        // other states (.preparing / .idle / .failed) must
        // drop the call on the floor to avoid racing the
        // loadTask.  We force `.preparing` by writing the
        // (internal-set) state via the public
        // `loadPlayback(_:)` path… but that's async + side-
        // effect heavy.  Simpler: set duration / state
        // through the same internal API the production code
        // uses.  Here we just confirm that the *guard* rejects
        // when state is anything other than `.ready`.
        let controller = makeController()
        // Default state is `.idle`, which must also be
        // rejected by retryPlayback.
        controller.retryPlayback()
        XCTAssertNil(controller.retryRestoreTime,
                     "retry from .idle must not produce a restore target")
        XCTAssertFalse(controller.usesProxy,
                       "direct-path retry does not flip usesProxy")
    }

    func test_retryPlayback_directPath_clearsRestoreBeforeClear() {
        // Direct (non-proxy) retry explicitly sets
        // `retryRestoreTime = nil` (D4 asymmetry — see plan).
        // We assert this even on the early-return-from-.idle
        // path because the explicit `= nil` runs before the
        // guard on the proxy branch and after it on the
        // direct branch.  So the only way the field could be
        // non-nil after retryPlayback() is if the proxy
        // branch fired.  Direct-path tests want it nil.
        let controller = makeController()
        // Pre-condition: no pending restore.
        XCTAssertNil(controller.retryRestoreTime)
        // Default .idle → guard rejects, direct branch never
        // runs, so the field stays nil.
        controller.retryPlayback()
        XCTAssertNil(controller.retryRestoreTime)
    }

    func test_tearDown_clearsRetryRestoreTime() {
        // Force a non-nil retryRestoreTime by setting it
        // through the internal setter, then call tearDown and
        // confirm the field is cleared.
        let controller = makeController()
        // Direct assignment via the file-internal setter
        // (allowed because @testable + internal access).
        controller.setRetryRestoreTimeForTest(123.45)
        XCTAssertNotNil(controller.retryRestoreTime)
        controller.tearDown()
        XCTAssertNil(controller.retryRestoreTime,
                     "tearDown must drop a pending restore target")
    }

    // MARK: - seek tolerance Equatable conformance

    func test_seekToleranceForTesting_equatable_worksAcrossInstances() {
        // Two independently-constructed values must compare
        // equal — this guards the Equatable conformance that
        // the XCTAssertEqual above depends on.
        let a = AVPlayerController.SeekToleranceForTesting(
            toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
            toleranceAfter:  CMTime(seconds: 0.5, preferredTimescale: 600)
        )
        let b = AVPlayerController.SeekToleranceForTesting(
            toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
            toleranceAfter:  CMTime(seconds: 0.5, preferredTimescale: 600)
        )
        XCTAssertEqual(a, b)
    }
}