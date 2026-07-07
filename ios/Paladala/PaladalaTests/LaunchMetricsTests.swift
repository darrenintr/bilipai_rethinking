import XCTest
@testable import Paladala

/// Tests for `LaunchMetrics` (PR-A Task 6).
///
/// The new event cases (firstFeedCached, firstTabInteractive,
/// proxyListenerRequested, proxyListenerReady) need to be recorded
/// in order, with the full key (event + tag) on the milestone so
/// each tab fires independently.
final class LaunchMetricsTests: XCTestCase {
    func test_mark_appendsMilestoneInOrder() {
        let m = LaunchMetrics.shared
        let countBefore = m.milestones.count
        m.mark(.firstFeedCached)
        m.mark(.firstTabInteractive(tag: .home))
        let countAfter = m.milestones.count
        XCTAssertEqual(countAfter, countBefore + 2)
        XCTAssertEqual(m.milestones[countBefore + 0].eventName, "firstFeedCached")
        XCTAssertEqual(m.milestones[countBefore + 1].eventName, "firstTabInteractive.home")
    }
}