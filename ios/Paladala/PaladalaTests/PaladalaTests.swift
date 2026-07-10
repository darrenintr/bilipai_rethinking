import XCTest
@testable import Paladala

final class PaladalaTests: XCTestCase {
    @MainActor
    func test_playProgressRejectsEmptyBvid() {
        var snapshots: [[PlayProgressEntry]] = []
        let store = makeStore { snapshots.append($0) }

        store.update(bvid: "", currentTime: 1, duration: 100)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(snapshots.isEmpty)
    }

    @MainActor
    func test_playProgressPersistsAtMostOncePerFiveSeconds() {
        let clock = TestClock()
        var snapshots: [[PlayProgressEntry]] = []
        let store = makeStore(clock: clock) { snapshots.append($0) }

        store.update(bvid: "BV1", currentTime: 0, duration: 100)
        for tick in 1...9 {
            clock.advance(by: 0.5)
            store.update(
                bvid: "BV1",
                currentTime: Double(tick) * 0.5,
                duration: 100
            )
        }

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(store.entries["BV1"]?.currentTime, 0)
        XCTAssertEqual(store.lastProgress(for: "BV1")?.currentTime, 4.5)

        clock.advance(by: 0.5)
        store.update(bvid: "BV1", currentTime: 5, duration: 100)

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(store.entries["BV1"]?.currentTime, 5)
    }

    @MainActor
    func test_playProgressForceFlushPersistsLatestPendingSample() {
        let clock = TestClock()
        var snapshots: [[PlayProgressEntry]] = []
        let store = makeStore(clock: clock) { snapshots.append($0) }

        store.update(bvid: "BV1", currentTime: 0, duration: 100)
        clock.advance(by: 1)
        store.update(bvid: "BV1", currentTime: 42, duration: 100)
        XCTAssertEqual(snapshots.count, 1)

        store.flushPending()

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(store.entries["BV1"]?.currentTime, 42)
    }

    @MainActor
    func test_playProgressForceUpdateBypassesCadence() {
        let clock = TestClock()
        var snapshots: [[PlayProgressEntry]] = []
        let store = makeStore(clock: clock) { snapshots.append($0) }

        store.update(bvid: "BV1", currentTime: 0, duration: 100)
        clock.advance(by: 1)
        store.update(
            bvid: "BV1",
            currentTime: 40,
            duration: 100,
            force: true
        )

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(store.entries["BV1"]?.currentTime, 40)
    }

    @MainActor
    private func makeStore(
        clock: TestClock = TestClock(),
        persistenceObserver: @escaping @MainActor ([PlayProgressEntry]) -> Void
    ) -> PlayProgressStore {
        PlayProgressStore(
            initialEntries: [:],
            nowProvider: { clock.now },
            persistenceObserver: persistenceObserver,
            schedulesDelayedFlushes: false,
            observesLifecycle: false
        )
    }
}

@MainActor
private final class TestClock {
    private(set) var now = Date(timeIntervalSince1970: 1_000)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
