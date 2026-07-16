import Foundation
import SwiftUI
import UIKit
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

    func test_musicVideosUsesNewlistEndpoint() async throws {
        let session = makeStubSession { request in
            Self.emptyVideoListResponse(for: request)
        }
        defer { session.invalidateAndCancel() }

        let videos = try await BilibiliAPIClient(session: session).musicVideos(page: 2)

        XCTAssertTrue(videos.isEmpty)
        XCTAssertEqual(StubURLProtocol.metrics.lastPath, "/x/web-interface/newlist")
    }

    @MainActor
    func test_musicHomeLoadSurvivesLoadingStateTransition() async {
        let session = makeStubSession(delay: 0.2) { request in
            Self.emptyVideoListResponse(for: request)
        }
        defer { session.invalidateAndCancel() }

        let repository = PaladalaRepository(apiClient: BilibiliAPIClient(session: session))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(
            rootView: MusicHomeView(repository: repository)
                .environmentObject(AppRouter())
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        try? await Task.sleep(for: .milliseconds(350))
        let metrics = StubURLProtocol.metrics
        XCTAssertEqual(metrics.finished, 1)
        XCTAssertEqual(metrics.cancelled, 0)
    }

    private func makeStubSession(
        delay: TimeInterval = 0,
        handler: @escaping StubURLProtocol.Handler
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.configure(delay: delay, handler: handler)
        return URLSession(configuration: configuration)
    }

    private static func emptyVideoListResponse(
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = Data(#"{"code":0,"message":"OK","data":{"archives":[]}}"#.utf8)
        return (response, body)
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

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)

    private struct State {
        var delay: TimeInterval = 0
        var handler: Handler?
        var lastPath: String?
        var finished = 0
        var cancelled = 0
    }

    nonisolated(unsafe) private static var state = State()
    private static let lock = NSLock()
    private var workItem: DispatchWorkItem?

    static var metrics: (lastPath: String?, finished: Int, cancelled: Int) {
        lock.withLock {
            (
                lastPath: state.lastPath,
                finished: state.finished,
                cancelled: state.cancelled
            )
        }
    }

    static func configure(delay: TimeInterval, handler: @escaping Handler) {
        lock.withLock {
            state = State(delay: delay, handler: handler)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let configuration = Self.lock.withLock {
            Self.state.lastPath = request.url?.path
            return (Self.state.delay, Self.state.handler)
        }
        guard let handler = configuration.1 else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let urlProtocol = self
        let item = DispatchWorkItem {
            let (response, data) = handler(urlProtocol.request)
            let isCancelled = Self.lock.withLock { urlProtocol.workItem?.isCancelled == true }
            if isCancelled { return }
            Self.lock.withLock { Self.state.finished += 1 }
            urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
            urlProtocol.client?.urlProtocol(urlProtocol, didLoad: data)
            urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
        }
        workItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + configuration.0, execute: item)
    }

    override func stopLoading() {
        guard let workItem, !workItem.isCancelled else { return }
        workItem.cancel()
        Self.lock.withLock { Self.state.cancelled += 1 }
    }
}
