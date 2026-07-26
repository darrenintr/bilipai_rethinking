//
//  SleepTimer.swift
//  Paladala
//
//  Video-side sleep timer. Owned per-playback by
//  `VideoDetailView`; drives a small `MM:SS` countdown HUD
//  pinned to the top-trailing of the player surface and fades
//  `AVPlayer.volume` to zero before pausing playback.
//
//  Per-second updates are only observed by `SleepTimerHUDView`
//  so the parent player view is NOT re-rendered every tick —
//  matching the existing `SponsorSkipToast` pattern (which
//  publishes its own state and is observed only by itself).
//

import Foundation

@MainActor
final class SleepTimer: ObservableObject {

    enum Phase: Equatable {
        case idle
        case counting
        case fading
    }

    /// Seconds left until fade-out begins. The HUD observes
    /// this; nothing else needs it.
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var phase: Phase = .idle

    private weak var controller: PlayerController?
    private var tickTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?

    /// Default fade duration. 3 s is long enough to feel
    /// graceful, short enough that a sleep-bound user doesn't
    /// have to wait noticeably after the audio cuts out.
    static let fadeDurationSeconds: Double = 3.0

    init(controller: PlayerController?) {
        self.controller = controller
    }

    /// Late-bind the player controller. `VideoDetailView` calls
    /// this once the inline / fullscreen player materialises
    /// via `MiniPlayerStore`. `cancel()` is invoked first so we
    /// never carry a fading player across a controller swap.
    func setController(_ controller: PlayerController?) {
        cancel()
        self.controller = controller
    }

    var isActive: Bool { phase != .idle }

    /// Start a fresh countdown for `minutes` minutes. Cancel
    /// any existing timer first so concurrent taps don't stack.
    func start(minutes: Int) {
        cancel()
        guard minutes > 0 else { return }
        remainingSeconds = minutes * 60
        phase = .counting
        scheduleTick()
    }

    /// Cancel and reset. Restores volume to 1.0 so the next
    /// playback isn't muted.
    func cancel() {
        tickTask?.cancel()
        fadeTask?.cancel()
        tickTask = nil
        fadeTask = nil
        if phase != .idle {
            controller?.setVolume(1.0)
        }
        phase = .idle
        remainingSeconds = 0
    }

    // MARK: - Tick loop

    private func scheduleTick() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                await self?.tickOnce()
            }
        }
    }

    private func tickOnce() {
        guard phase == .counting else { return }
        if remainingSeconds > 1 {
            remainingSeconds -= 1
            return
        }
        // Hit zero — kick off fade-out and stop ticking.
        remainingSeconds = 0
        phase = .fading
        tickTask?.cancel()
        tickTask = nil
        startFade()
    }

    /// 30 steps × 100 ms ≈ 3 s linear fade from the current
    /// volume down to 0.  We read the actual current volume
    /// so cancelling mid-fade and restarting later resumes
    /// from where we left off rather than snapping back to 1.
    private func startFade() {
        let steps = 30
        let stepNanos: UInt64 = 100_000_000
        fadeTask = Task { [weak self] in
            guard let self else { return }
            for i in 1...steps {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: stepNanos)
                if Task.isCancelled { return }
                // 30 steps total; at step k we want (steps - k)/steps of original.
                let fraction = Double(steps - i) / Double(steps)
                self.controller?.setVolume(Float(fraction))
            }
            // Ensure fully muted before pause in case rounding landed at a tiny positive value.
            self.controller?.setVolume(0)
            self.controller?.pause()
            self.phase = .idle
            self.remainingSeconds = 0
        }
    }
}
