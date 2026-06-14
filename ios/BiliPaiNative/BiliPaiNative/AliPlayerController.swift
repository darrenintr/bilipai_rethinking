import UIKit
import AliyunPlayer

enum PlayerDrawableSurface: String {
    case inline
    case fullscreen
    case standalone
}

/// Owns an `AliPlayer` for its entire lifetime and exposes the same
/// interface as the previous VLC-based controller: playhead `currentTime`,
/// `duration`, `isPlaying`, `isBuffering`, `networkSpeed`, and the
/// skip/seek/toggle commands.
///
/// The `AliPlayer` render surface is bound via `player.playerView = view`
/// — a simple property assignment. No pause/play refresh trick is needed
/// for surface swaps; the renderer rebinds automatically when reassigned.
///
/// The controller outlives both the inline and fullscreen `UIView`s so the
/// player keeps decoding across the inline ↔ fullscreen transition.
@MainActor
final class PlayerController: NSObject, ObservableObject {
    /// Playhead position in seconds.
    @Published private(set) var currentTime: Double = 0
    /// Total media length in seconds. 0 while the media is still parsing.
    @Published private(set) var duration: Double = 0
    /// `true` when playback is active.
    @Published var isPlaying: Bool = true
    /// `true` while the player is buffering / opening.
    @Published private(set) var isBuffering: Bool = false
    /// Network read rate in bytes/second. AliPlayer exposes
    /// `currentDownloadSpeed` (bps); we convert to bytes/s.
    @Published private(set) var networkSpeed: Double = 0

    /// The underlying AliPlayer instance.
    let player: AliPlayer

    private weak var attachedView: UIView?
    private var preferredSurface: PlayerDrawableSurface = .standalone
    private var attachedSurface: PlayerDrawableSurface?
    private var pollTimer: Timer?
    /// AliPlayer has no direct `status` property; track it via delegate.
    private var _playerStatus: AVPStatus = .idle

    init(url: URL, referer: String) {
        diagLog(.playback, "Initializing AliPlayerController", details: ["url": url.absoluteString])

        guard let createdPlayer = AliPlayer() else {
            diagLog(.playback, "AliPlayer() init returned nil — aborting", details: [:])
            super.init()
            return
        }
        createdPlayer.playerView = nil
        createdPlayer.scalingMode = .scaleAspectFit
        self.player = createdPlayer
        super.init()

        let source = AVPUrlSource(urlString: url.absoluteString)
        createdPlayer.setUrl(source: source)

        // Set up delegate to receive status updates
        player.delegate = self

        if isPlaying {
            player.prepare()
            player.start()
        }

        startPolling()
    }

    func swapMedia(to url: URL, referer: String) {
        player.stop()
        let source = AVPUrlSource(urlString: url.absoluteString)
        player.setUrl(source: source)
        if isPlaying {
            player.prepare()
            player.start()
        }
    }

    func preferDrawableSurface(_ surface: PlayerDrawableSurface) {
        preferredSurface = surface
        diagLog(.playback, "Preferred drawable surface changed", details: ["surface": surface.rawValue])
    }

    /// Make `view` the player's render surface. AliPlayer rebinds
    /// automatically when `playerView` is reassigned — no pause/play
    /// trick needed.
    func attach(drawable view: UIView, surface: PlayerDrawableSurface) {
        guard surface == .standalone || surface == preferredSurface else {
            diagLog(.playback, "AliPlayer attach ignored for inactive surface", details: [
                "surface": surface.rawValue,
                "preferred": preferredSurface.rawValue,
                "view": String(describing: view)
            ])
            return
        }
        if attachedView === view, attachedSurface == surface {
            return
        }

        let wasPlaying = (_playerStatus == .started)
        player.playerView = nil
        attachedView = view
        attachedSurface = surface
        player.playerView = view

        diagLog(.playback, "AliPlayer attaching drawable", details: [
            "surface": surface.rawValue,
            "view": String(describing: view),
            "wasPlaying": wasPlaying
        ])
    }

    /// Release the drawable if it still belongs to `currentView`.
    func detach(currentView: UIView, surface: PlayerDrawableSurface) {
        guard attachedView === currentView else {
            diagLog(.playback, "AliPlayer detach ignored for stale surface", details: [
                "surface": surface.rawValue,
                "attachedSurface": attachedSurface?.rawValue ?? "none",
                "view": String(describing: currentView)
            ])
            return
        }
        diagLog(.playback, "AliPlayer detaching drawable", details: ["surface": surface.rawValue, "view": String(describing: currentView)])
        if player.playerView === currentView {
            player.playerView = nil
        }
        attachedView = nil
        attachedSurface = nil
    }

    /// Stop the player and release resources. Called from
    /// `VideoDetailView.onDisappear` when navigating away.
    func tearDown() {
        stopPolling()
        player.stop()
        player.destroy()
        player.playerView = nil
        attachedView = nil
        attachedSurface = nil
        diagLog(.playback, "AliPlayerController teardown complete")
    }

    func play() {
        player.start()
    }

    func pause() {
        player.pause()
    }

    func toggle() {
        isPlaying.toggle()
        if isPlaying { player.start() } else { player.pause() }
    }

    /// Skip the playhead by `seconds`, clamped to `[0, duration]`.
    func skip(by seconds: Double) {
        let totalMs = Int64(max(0, duration * 1000))
        let currentMs = Int64(currentTime * 1000)
        let raw = currentMs + Int64(seconds * 1000)
        let clampedMs = min(totalMs, max(0, raw))
        player.seek(toTime: clampedMs, seekMode: .accurate)
        currentTime = Double(clampedMs) / 1000
    }

    /// Seek to an absolute time in seconds, clamped to `[0, duration]`.
    func seek(to seconds: Double) {
        let target = max(0, min(duration, seconds))
        let targetMs = Int64(target * 1000)
        player.seek(toTime: targetMs, seekMode: .accurate)
        currentTime = target
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        let ct = player.currentPosition
        if ct >= 0 {
            currentTime = Double(ct) / 1000
        }
        let dur = player.duration
        if dur > 0 {
            duration = Double(dur) / 1000
        }
        let nowPlaying = (_playerStatus == .started)
        if nowPlaying != isPlaying {
            isPlaying = nowPlaying
            diagLog(.playback, "AliPlayer isPlaying changed", details: ["isPlaying": isPlaying])
        }
        networkSpeed = Double(player.currentDownloadSpeed) / 8.0
    }

    deinit {
        pollTimer?.invalidate()
    }
}

// MARK: - AVPDelegate

extension PlayerController: AVPDelegate {
    nonisolated func onPlayerStatusChanged(_ player: AliPlayer, oldStatus: AVPStatus, newStatus: AVPStatus) {
        Task { @MainActor in
            self._playerStatus = newStatus
            let nowPlaying = (newStatus == .started)
            if nowPlaying != self.isPlaying {
                self.isPlaying = nowPlaying
                diagLog(.playback, "AliPlayer status changed", details: [
                    "oldStatus": String(describing: oldStatus),
                    "newStatus": String(describing: newStatus),
                    "isPlaying": nowPlaying
                ])
            }
        }
    }

    nonisolated func onCurrentPositionUpdate(_ player: AliPlayer, position: Int64) {
        Task { @MainActor in
            if position >= 0 {
                self.currentTime = Double(position) / 1000
            }
        }
    }

    nonisolated func onLoadingProgress(_ player: AliPlayer, progress: Float) {
        Task { @MainActor in
            let buffering = progress < 1.0
            if buffering != self.isBuffering {
                self.isBuffering = buffering
            }
        }
    }

    nonisolated func onPlayerEvent(_ player: AliPlayer, eventType: AVPEventType) {
        Task { @MainActor in
            switch eventType {
            case .loadingStart:
                self.isBuffering = true
            case .loadingEnd:
                self.isBuffering = false
            case .completion:
                self.isPlaying = false
            case .prepareDone:
                let dur = player.duration
                if dur > 0 {
                    self.duration = Double(dur) / 1000
                }
            default:
                break
            }
        }
    }

    nonisolated func onError(_ player: AliPlayer, errorModel: AVPErrorModel) {
        Task { @MainActor in
            diagLog(.playback, "AliPlayer error", details: [
                "code": errorModel.code,
                "message": errorModel.message ?? ""
            ])
        }
    }
}

// =============================================================================
// WatchSession — no AliPlayer dependency, kept verbatim from archived file
// =============================================================================

/// Owns the periodic history-reporting `Timer` for one playback
/// session. The official Bilibili iOS client calls
/// `POST /x/v2/history/report` with `progress=0` on play start and
/// every 30 seconds during playback.
@MainActor
final class WatchSession {
    private let repository: BiliPaiRepository
    private let aid: Int
    private let cid: Int
    private let getCurrentSeconds: () -> Double
    private let isActive: () -> Bool
    private var timer: Timer?
    private var lastFire: Date = .distantPast

    private static let reportInterval: TimeInterval = 30
    private static let minimumGap: TimeInterval = 5

    init(
        repository: BiliPaiRepository,
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

    func start() {
        guard timer == nil else { return }
        guard aid > 0, cid > 0 else { return }
        fire(progress: 0)
        timer = Timer.scheduledTimer(withTimeInterval: Self.reportInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard Date().timeIntervalSince(lastFire) >= Self.minimumGap else { return }
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
                bpLog("history report failed (aid=\(aid) progress=\(progress)): \(error)")
            }
        }
    }
}