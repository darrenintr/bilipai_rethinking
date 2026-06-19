import Foundation

/// Singleton that owns the background `URLSession` used to
/// download B 站 DASH segments to disk for offline playback.
///
/// Why background?
/// ---------------
///
/// A foreground `URLSession` ties the download to the app's
/// process lifetime.  When the user backgrounds the app
/// (locks the screen, switches to another app, etc.) the
/// foreground task is suspended.  A background-configured
/// `URLSession` is owned by the system daemon and continues
/// to make progress while the app is suspended, eventually
/// waking the app via
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
/// to deliver the final delegate callbacks.
///
/// One session, one identifier
/// ---------------------------
///
/// `URLSessionConfiguration.background(withIdentifier:)`
/// enforces a single instance per identifier per process.  We
/// recreate the session in `bootstrap()` at every launch so
/// any tasks the system resumed from a previous run get
/// re-attached.  Creating two sessions with the same
/// identifier is a programming error — the second
/// `init` throws and the download silently never starts.
///
/// Identifier is namespaced under the app's bundle id to
/// avoid collisions in case the user has the iOS widget
/// extension installed (the widget has its own
/// `BiliPaiWidget.appex` bundle and could otherwise share
/// the same key).
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    /// Background session identifier.  Stable across launches
    /// so the system can match a resumed task to the right
    /// session on app relaunch.
    static let sessionIdentifier = "com.bilipai.nativeios.download"

    /// Per-bvid progress publisher, observed by
    /// `VideoDetailViewModel` to update the download button
    /// label.  We use a dictionary rather than a
    /// `PassthroughSubject<DownloadEvent, Never>` per bvid
    /// because the number of concurrent downloads is small
    /// (typically 1) and the dict lookup is O(1).
    @Published private(set) var progress: [String: Double] = [:]

    /// Per-bvid state for the UI.  `downloaded` is set by
    /// `urlSession(_:downloadTask:didFinishDownloadingTo:)`
    /// and consumed by the VM when it observes the change.
    @Published private(set) var stateByBvid: [String: DownloadState] = [:]

    /// Completion handler stashed by the app delegate.  The
    /// background session calls it once *all* of its
    /// delegate events have been delivered, so the OS knows
    /// it can suspend the app again.
    fileprivate var backgroundCompletionHandler: (() -> Void)?

    /// The actual `URLSession`.  Lazy-initialised in
    /// `bootstrap()` (which the app delegate calls on every
    /// launch) so the system daemon has time to resume any
    /// pending tasks before we re-attach.
    private var session: URLSession?

    /// In-flight bookkeeping.  Maps `URLSessionDownloadTask`'s
    /// `taskIdentifier` (stable across relaunches) to the
    /// `bvid` it is downloading.  The OS hands us a
    /// `URLSessionDownloadTask` whose `taskDescription` is
    /// the `bvid` — we set that in `start(_:)` and read it
    /// in the delegate callbacks.
    private var taskToBvid: [Int: String] = [:]

    private override init() {
        super.init()
    }

    /// Wire the session up.  Called from
    /// `BiliPaiAppDelegate.application(_:didFinishLaunchingWithOptions:)`
    /// on every launch — the OS needs a chance to resume
    /// tasks queued from a prior run before we attach the
    /// delegate.
    func bootstrap() {
        if session != nil { return }
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        // Background sessions cannot carry custom headers
        // (`Referer` etc.) in their config — those have to
        // go on the per-request `URLRequest`.  We do still
        // want the system to be willing to issue the
        // requests when the user is on cellular, so we
        // leave `discretionary` and `sessionSendsLaunchEvents`
        // at their defaults.
        configuration.allowsCellularAccess = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        // 4 in-flight connections is the same number
        // `LocalHLSProxyServer` uses to mirror B站's
        // per-track overlap detection.
        configuration.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "BiliPai.DownloadManager.delegate"
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: queue
        )
        self.session = session
        // Re-attach any in-flight tasks the system resumed
        // from a prior run.  These show up in
        // `getAllTasks()` only after the delegate is
        // wired up — we set their state to "downloading"
        // so the UI doesn't briefly think the user has no
        // active download.
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            Task { @MainActor in
                for task in tasks {
                    guard let dl = task as? URLSessionDownloadTask,
                          let bvid = dl.taskDescription else { continue }
                    self.taskToBvid[dl.taskIdentifier] = bvid
                    if self.stateByBvid[bvid] == nil {
                        self.stateByBvid[bvid] = .downloading(progress: 0)
                    }
                }
            }
        }
    }

    /// Forward the app delegate's completion handler to the
    /// session.  Called from
    /// `BiliPaiAppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func attachBackgroundCompletionHandler(
        _ handler: @escaping () -> Void
    ) {
        backgroundCompletionHandler = handler
    }

    // MARK: public API

    /// Start downloading a video.  The download is split
    /// across one or more `URLSessionDownloadTask`s — one
    /// for the init bytes, one for the media bytes, plus the
    /// same pair for audio.  All four tasks share the same
    /// `bvid` in `taskDescription` so the delegate can
    /// identify the parent.
    ///
    /// This method is non-blocking — it queues the tasks and
    /// returns.  Progress / completion is observed via
    /// `progress` and `stateByBvid`.
    func start(video: BiliVideo, playback: BiliPlayback) {
        guard let dash = playback.dash else { return }
        let bvid = video.id
        guard stateByBvid[bvid] == nil else { return }
        stateByBvid[bvid] = .downloading(progress: 0)
        progress[bvid] = 0
        let staging = DownloadStore.shared.inProgressDirectory(for: bvid)
        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true
            )
        } catch {
            bpLog("DownloadManager could not create staging: \(error)")
            stateByBvid[bvid] = .failed(message: "staging dir")
            return
        }
        scheduleSegment(
            track: dash.video,
            kind: .video,
            bvid: bvid,
            staging: staging
        )
        if let audio = dash.audio {
            scheduleSegment(
                track: audio,
                kind: .audio,
                bvid: bvid,
                staging: staging
            )
        }
    }

    /// Cancel an in-flight download.  No-op if the `bvid` is
    /// not currently downloading.  Removes the staging
    /// directory so the user does not accumulate half-files.
    func cancel(bvid: String) {
        session?.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks where task.taskDescription == bvid {
                task.cancel()
            }
            Task { @MainActor in
                self.stateByBvid[bvid] = nil
                self.progress[bvid] = nil
                self.taskToBvid = self.taskToBvid.filter { $0.value != bvid }
                let staging = DownloadStore.shared.inProgressDirectory(
                    for: bvid
                )
                try? FileManager.default.removeItem(at: staging)
            }
        }
    }

    // MARK: internal

    /// One segment of a DASH track.  A track is two
    /// segments: the init `ftyp`/`moov` bytes and the media
    /// `mdat` bytes.  We download them as two `Range`
    /// requests.
    fileprivate enum SegmentKind: String {
        case init = "init"
        case media = "media"
    }

    /// Schedule one byte-range request against the upstream
    /// CDN.  Uses `URLSession.downloadTask(with:)` so the
    /// result lands in a temp file we then move to the right
    /// place in the staging directory.
    fileprivate func scheduleSegment(
        track: BiliDashSource.Track,
        kind: SegmentKind,
        bvid: String,
        staging: URL
    ) {
        guard let session else { return }
        var request = URLRequest(url: track.baseURL)
        request.setValue(
            playbackReferer(bvid: bvid),
            forHTTPHeaderField: "Referer"
        )
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        switch kind {
        case .init:
            request.setValue(
                LocalHLSProxyServer.httpRangeHeader(
                    offset: track.initializationRange.offset,
                    end: track.initializationRange.endOffset
                ),
                forHTTPHeaderField: "Range"
            )
        case .media:
            // Open-ended range — CDN returns the bytes from
            // `mediaStartOffset` to EOF.  We use this instead
            // of an explicit end so the response is also
            // correct for tracks where the upstream has
            // added trailing metadata past the playable
            // region.
            request.setValue(
                LocalHLSProxyServer.httpRangeHeader(
                    offset: track.mediaStartOffset, end: nil
                ),
                forHTTPHeaderField: "Range"
            )
        }
        let task = session.downloadTask(with: request)
        // We tag the task with the bvid + segment kind so
        // the delegate can route the downloaded temp file
        // to the right place in the staging directory.
        // Format: "{bvid}|{video|audio}|{init|media}".
        let kindLabel: String
        switch kind {
        case .init: kindLabel = "init"
        case .media: kindLabel = "media"
        }
        let mediaLabel = (track.mimeType.contains("audio")) ? "audio" : "video"
        task.taskDescription = "\(bvid)|\(mediaLabel)|\(kindLabel)"
        taskToBvid[task.taskIdentifier] = bvid
        task.resume()
    }

    /// Resolve the `Referer` for a download.  In v1 we use
    /// the same fallback the proxy uses (`https://www.bilibili.com/`).
    /// Per-video referer is a follow-up — the playurl API
    /// returns it but we have not threaded it through
    /// `BiliVideo` yet.
    fileprivate func playbackReferer(bvid: String) -> String {
        "https://www.bilibili.com/video/\(bvid)"
    }

    /// Move a finished temp file into the staging directory
    /// and update progress.  Called from
    /// `urlSession(_:downloadTask:didFinishDownloadingTo:)`.
    ///
    /// **Important:** the temp file at `tempURL` is only
    /// valid for the duration of the delegate callback.  We
    /// must perform the move synchronously on the delegate
    /// queue (a serial `OperationQueue`) before returning —
    /// a `Task { @MainActor in … }` wrapper would defer the
    /// move past the point at which iOS reclaims the temp
    /// file.  State updates still hop to the main actor
    /// because the published dictionaries are `@MainActor`.
    nonisolated fileprivate func consumeDownloaded(
        task: URLSessionDownloadTask,
        tempURL: URL
    ) {
        guard let description = task.taskDescription else { return }
        let parts = description.split(separator: "|")
        guard parts.count == 3 else { return }
        let bvid = String(parts[0])
        let mediaLabel = String(parts[1])
        let kindLabel = String(parts[2])
        // The staging directory URL is computed from the
        // bvid only — `DownloadStore.readyDirectory` /
        // `inProgressDirectory` are pure URL builders, so
        // it is safe to call them from the nonisolated
        // delegate queue (we just want a path; we do not
        // touch the store's mutable state).
        let staging = DownloadStore.readyURL
            .deletingLastPathComponent()
            .appendingPathComponent("in_progress", isDirectory: true)
            .appendingPathComponent(bvid, isDirectory: true)
        let destination = staging.appendingPathComponent(
            "\(mediaLabel).\(kindLabel)"
        )
        do {
            // Atomic move: if `destination` already exists
            // (a re-download replacing an earlier partial),
            // remove it first.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            bpLog("DownloadManager move failed: \(error)")
        }
        Task { @MainActor in
            // Approximate progress: count the number of
            // expected segments and increment as each
            // completes.  Video has 2 segments (init+media),
            // audio has 2.  Total is 4 for VOD, 2 for
            // video-only (we do not currently offer that).
            self.progress[bvid, default: 0] += 0.25
            self.stateByBvid[bvid] = .downloading(
                progress: self.progress[bvid] ?? 0
            )
        }
    }

    /// All four (or two) segments for a `bvid` have
    /// finished.  Build the `DownloadRecord`, hand it to
    /// `DownloadStore`, and update `stateByBvid` to
    /// `.downloaded(record:)`.
    fileprivate func completeAllSegments(bvid: String) {
        Task { @MainActor in
            // Reset in-flight bookkeeping.
            session?.getAllTasks { [weak self] tasks in
                guard let self else { return }
                for task in tasks where task.taskDescription?.hasPrefix("\(bvid)|") == true {
                    self.taskToBvid.removeValue(forKey: task.taskIdentifier)
                }
            }
            self.progress[bvid] = nil
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file at `location` is *only* valid for the
        // duration of this callback — we have to move it
        // synchronously.  Delegate runs on
        // `OperationQueue(name: "BiliPai.DownloadManager.delegate")`
        // which is serial.  `consumeDownloaded` is
        // `nonisolated` so it can run on the delegate queue
        // without an actor hop; it internally schedules the
        // state mutation on the main actor.
        self.consumeDownloaded(task: downloadTask, tempURL: location)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Errors that are not cancellations propagate up to
        // the user.  Cancellations are user-initiated (the
        // download button is now "取消") and we drop the
        // state.
        guard let error else { return }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain,
              nsError.code != NSURLErrorCancelled else {
            return
        }
        let bvid = task.taskDescription?.split(separator: "|").first.map(String.init) ?? "?"
        Task { @MainActor in
            self.stateByBvid[bvid] = .failed(message: nsError.localizedDescription)
            self.progress[bvid] = nil
        }
    }

    nonisolated func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        // All enqueued system events for the background
        // session have been delivered.  Fire the completion
        // handler the app delegate stashed, then drop the
        // reference so the system can suspend us again.
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}

// MARK: - DownloadState

/// Per-bvid state surfaced to the UI.  Mirrored on
/// `VideoDetailViewModel.downloadState` (commit 11.B2) so
/// the download button can render the right label.
enum DownloadState: Equatable {
    case downloading(progress: Double)
    case downloaded(record: DownloadRecord)
    case failed(message: String)
}
