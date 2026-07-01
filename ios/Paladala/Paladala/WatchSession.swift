//
//  WatchSession.swift
//  Paladala
//
//  Periodic history reporter.  Lives in the View layer (next
//  to `VideoDetailView`) and forwards watch progress to
//  `PaladalaRepository.reportHistoryForWatchSession` every
//  30 seconds.  Originally lived inside `VLCPlayerView.swift`,
//  which is now disabled (renamed to `.vlc`) because VLC is
//  no longer the playback engine — the SwiftUI host now points
//  at `PlayerView` (which uses AVKit's `VideoPlayer`).
//

import Foundation

/// 30-second heart-beat that reports the user's playhead
/// progress to B站's history endpoint.  Lives in the View
/// layer (one instance per `VideoDetailView`) and is
/// created/torn down with the inline ↔ fullscreen transition
/// surface.
///
/// Failures are `bpLog`'d so a flaky network never breaks
/// playback.  A missed tick just means the history entry's
/// progress is a few seconds behind — Bilibili recomputes it
/// on the next successful call.
@MainActor
final class WatchSession {
    private let repository: PaladalaRepository
    private let aid: Int
    private let cid: Int
    private let getCurrentSeconds: () -> Double
    private let isActive: () -> Bool
    private var timer: Timer?
    /// Tracks the last time we fired so we can throttle a
    /// "play then immediately pause" pair — without this, a quick
    /// tap on play/pause could fire two `progress=0` reports back
    /// to back and overwrite the resume point.
    private var lastFire: Date = .distantPast

    private static let reportInterval: TimeInterval = 30
    private static let minimumGap: TimeInterval = 5

    init(
        repository: PaladalaRepository,
        aid: Int,
        cid: Int,
        getCurrentSeconds: @escaping () -> Double,
        isActive: @escaping () -> Bool
    ) {
        self.repository = repository
        self.aid = aid
        self.cid = cid
        self.getCurrentSeconds = getCurrentSeconds
        self.isActive = isActive
    }

    /// Begin reporting.  Sends `progress=0` immediately, then
    /// every `reportInterval` seconds.  Idempotent — calling
    /// `start` while already running is a no-op so SwiftUI
    /// re-renders don't queue duplicate timers.
    func start() {
        guard timer == nil else { return }
        guard aid > 0, cid > 0 else {
            // The video either came from a feed entry that
            // only had a `bvid` (no `aid`) or the detail load
            // failed to populate a `cid` — the history endpoint
            // requires both, so we silently skip rather than
            // spam bpLog on every play.  The user can still see
            // the watch in their local client, it just won't
            // sync to Bilibili's history.
            return
        }
        // Fire the first report immediately so the watch shows
        // up in the history list even if the user only watches
        // for <30s.
        fire(progress: 0)
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.reportInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    /// Idempotent cancel.  Safe to call from `onDisappear`.
    nonisolated func stop() {
        Task { @MainActor in
            timer?.invalidate()
            timer = nil
        }
    }

    @MainActor
    private func tick() {
        // Throttle: if the user just paused (or just opened
        // the view and `start` fired <5s ago) skip the report
        // to avoid a noisy pair of `progress=...` ticks.
        guard Date().timeIntervalSince(lastFire) >= Self.minimumGap else {
            return
        }
        guard isActive() else { return }
        let progress = Int(max(0, getCurrentSeconds().rounded()))
        fire(progress: progress)
    }

    private func fire(progress: Int) {
        lastFire = Date()
        Task { [repository, aid, cid] in
            do {
                try await repository.reportHistoryForWatchSession(
                    aid: aid,
                    cid: cid,
                    progress: progress
                )
            } catch {
                // Non-fatal: bpLog the failure so the in-app
                // log export surfaces it, but do not propagate
                // — the user is mid-watch, retrying on the
                // next tick is the right behaviour.
                bpLog("history report failed (aid=\(aid) progress=\(progress)): \(error)")
            }
        }
    }
}
