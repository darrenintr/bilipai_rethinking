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
    static let sessionIdentifier = "com.dt.paladala.download"

    /// Per-bvid progress publisher, observed by
    /// `VideoDetailViewModel` to update the download button
    /// label.  We use a dictionary rather than a
    /// `PassthroughSubject<DownloadEvent, Never>` per bvid
    /// because the number of concurrent downloads is small
    /// (typically 1) and the dict lookup is O(1).
    @Published private(set) var progress: [String: Double] = [:]

    /// Per-bvid state for the UI.  `downloaded` is set by
    /// `completeAllSegments(bvid:)` once all the on-disk
    /// bytes have landed and `DownloadStore.shared.add(_:)`
    /// has accepted the manifest entry.
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

    /// Pending-download metadata keyed by `bvid`.  Populated
    /// in `start(video:playback:)` and consumed in
    /// `completeAllSegments(bvid:)` to build the
    /// `DownloadRecord` that gets handed to `DownloadStore`.
    /// Without this stash the manager has no way to recover
    /// the title / owner / cover / aid / cid / dash that the
    /// `DownloadRecord` needs — the delegate callback only
    /// carries the URL, not the metadata.
    private struct PendingDownload {
        let video: BiliVideo
        let playback: BiliPlayback
        let expectedSegments: Int
        var completedSegments: Int = 0
    }
    private var pendingByBvid: [String: PendingDownload] = [:]

    /// Retry counter for individual segment downloads.  If a
    /// segment fails once (transient CDN error, dropped
    /// socket, …) we re-schedule it; on the second failure
    /// we fall through to the existing whole-download
    /// `failed(message:)` state.  Keyed by the system
    /// `taskIdentifier` so the retry survives the delegate
    /// callback boundary.
    private var retryCountByTaskId: [Int: Int] = [:]

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
        // VOD with audio = 4 segments (video.init, video.media,
        // audio.init, audio.media).  If for some reason the
        // playurl response did not include an audio track we
        // drop to 2 segments (video-only).  We never mix
        // the two — once `expectedSegments` is set the
        // completion check is fixed.
        let expected = 2 + (dash.audio == nil ? 0 : 2)
        diagLog(.download, "start",
                details: [
                    "bvid": bvid,
                    "title": video.title,
                    "expected_segments": expected,
                    "video_init_range":
                        "\(dash.video.initializationRange.offset)-\(dash.video.initializationRange.endOffset)",
                    "video_media_start": dash.video.mediaStartOffset,
                    "audio_present": dash.audio != nil,
                    "audio_init_range": dash.audio.map {
                        "\($0.initializationRange.offset)-\($0.initializationRange.endOffset)"
                    } ?? "n/a",
                    "audio_media_start": dash.audio?.mediaStartOffset ?? 0
                ])
        stateByBvid[bvid] = .downloading(progress: 0)
        progress[bvid] = 0
        // Funnel start — only fire once per bvid because
        // `guard stateByBvid[bvid] == nil` above rejects
        // duplicate calls. `expected_segments` lets the
        // console compute the completion denominator later.
        Analytics.log("download_start", [
            "bvid": bvid,
            "title": video.title,
            "expected_segments": expected
        ])
        Analytics.breadcrumb("DOWN", "download_start \(bvid)")
        let staging = DownloadStore.shared.inProgressDirectory(for: bvid)
        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true
            )
        } catch {
            bpLog("DownloadManager could not create staging: \(error)")
            diagLog(.download, "staging dir create failed",
                    details: ["bvid": bvid, "error": "\(error)"])
            stateByBvid[bvid] = .failed(message: "staging dir")
            return
        }
        pendingByBvid[bvid] = PendingDownload(
            video: video,
            playback: playback,
            expectedSegments: expected
        )
        scheduleSegment(
            track: dash.video,
            kind: .initSection,
            bvid: bvid,
            staging: staging
        )
        scheduleSegment(
            track: dash.video,
            kind: .mediaSection,
            bvid: bvid,
            staging: staging
        )
        if let audio = dash.audio {
            scheduleSegment(
                track: audio,
                kind: .initSection,
                bvid: bvid,
                staging: staging
            )
            scheduleSegment(
                track: audio,
                kind: .mediaSection,
                bvid: bvid,
                staging: staging
            )
        }
        diagLog(.download, "scheduled all segments",
                details: ["bvid": bvid, "count": expected])
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
                self.pendingByBvid[bvid] = nil
                self.taskToBvid = self.taskToBvid.filter { $0.value != bvid }
                // Drop any retry counters for tasks of this
                // bvid so a future re-download starts fresh.
                let taskIdsToDrop = self.taskToBvid
                    .filter { $0.value == bvid }
                    .map { $0.key }
                for id in taskIdsToDrop {
                    self.retryCountByTaskId[id] = nil
                }
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
    /// requests.  Cases are deliberately named
    /// `initSection` / `mediaSection` rather than `init` /
    /// `media` because Swift reserves `init` as a
    /// contextual keyword inside a type body.
    fileprivate enum SegmentKind: String {
        case initSection = "init"
        case mediaSection = "media"
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
        case .initSection:
            // Closed range covering the fMP4 init section.
            request.setValue(
                "bytes=\(track.initializationRange.offset)"
                + "-\(track.initializationRange.endOffset)",
                forHTTPHeaderField: "Range"
            )
        case .mediaSection:
            // Open-ended range — CDN returns the bytes from
            // `mediaStartOffset` to EOF.  We use this instead
            // of an explicit end so the response is also
            // correct for tracks where the upstream has
            // added trailing metadata past the playable
            // region.
            request.setValue(
                "bytes=\(track.mediaStartOffset)-",
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
        case .initSection: kindLabel = "init"
        case .mediaSection: kindLabel = "media"
        }
        let mediaLabel = (track.mimeType.contains("audio")) ? "audio" : "video"
        task.taskDescription = "\(bvid)|\(mediaLabel)|\(kindLabel)"
        taskToBvid[task.taskIdentifier] = bvid
        diagLog(.download, "scheduled segment",
                details: [
                    "bvid": bvid,
                    "media": mediaLabel,
                    "kind": kindLabel,
                    "url": track.baseURL.absoluteString,
                    "range": request.value(forHTTPHeaderField: "Range") ?? "",
                    "task_id": task.taskIdentifier
                ])
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

    /// Re-schedule one segment download after a transient
    /// failure.  Used by `urlSession(_:task:didCompleteWithError:)`
    /// when `retryCountByTaskId[id]` is below `maxRetries`.
    /// The original task is already cancelled (the URLSession
    /// hands us an error on its delegate), so we just queue
    /// a fresh `downloadTask` against the same target.
    fileprivate func retrySegment(
        task: URLSessionTask,
        bvid: String
    ) {
        guard let description = task.originalRequest?.url else { return }
        // Reconstruct the request — `originalRequest` carries
        // the URL + headers we set in `scheduleSegment`.
        var retryRequest = URLRequest(url: description)
        task.originalRequest?.allHTTPHeaderFields?.forEach { k, v in
            retryRequest.setValue(v, forHTTPHeaderField: k)
        }
        guard let session else { return }
        let newTask = session.downloadTask(with: retryRequest)
        // Preserve the same `taskDescription` so the
        // delegate can still route the file into the
        // staging directory under the right name.
        newTask.taskDescription = task.taskDescription
        taskToBvid[newTask.taskIdentifier] = bvid
        newTask.resume()
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
        let taskId = task.taskIdentifier
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
            diagLog(.download, "move failed",
                    details: [
                        "bvid": bvid,
                        "media": mediaLabel,
                        "kind": kindLabel,
                        "error": "\(error)"
                    ])
        }
        let fileSize: Int64 = {
            guard let attrs = try? FileManager.default.attributesOfItem(
                atPath: destination.path
            ) else { return 0 }
            return (attrs[.size] as? Int64) ?? 0
        }()
        Task { @MainActor in
            // A retry counter for this task is irrelevant
            // once it has actually delivered bytes — drop
            // it so the dict does not grow unbounded.
            self.retryCountByTaskId[taskId] = nil
            // Bump the completed-segment count for this
            // bvid.  If we hit the expected total this is
            // the last segment — promote to "downloaded".
            guard var pending = self.pendingByBvid[bvid] else { return }
            pending.completedSegments += 1
            self.pendingByBvid[bvid] = pending
            let progress = Double(pending.completedSegments)
                / Double(pending.expectedSegments)
            self.progress[bvid] = progress
            self.stateByBvid[bvid] = .downloading(progress: progress)
            diagLog(.download, "segment landed",
                    details: [
                        "bvid": bvid,
                        "media": mediaLabel,
                        "kind": kindLabel,
                        "bytes": fileSize,
                        "completed": pending.completedSegments,
                        "expected": pending.expectedSegments,
                        "progress": String(format: "%.2f", progress)
                    ])
            if pending.completedSegments >= pending.expectedSegments {
                self.completeAllSegments(bvid: bvid)
            }
        }
    }

    /// All expected segments for a `bvid` have finished
    /// landing on disk.  Build the `DownloadRecord` from
    /// `pendingByBvid`, hand it to `DownloadStore` (which
    /// atomically promotes the staging directory into
    /// `ready/{bvid}/` and updates the manifest), then drop
    /// our bookkeeping.  The `stateByBvid` entry is removed
    /// so `VideoDetailViewModel.refreshDownloadState()`
    /// falls through to the `DownloadStore.records` lookup
    /// and surfaces the new `.downloaded(record:)` state on
    /// its next refresh.
    fileprivate func completeAllSegments(bvid: String) {
        guard let pending = pendingByBvid[bvid] else { return }
        guard let dash = pending.playback.dash else { return }
        // Sum the four (or two) on-disk file sizes so the
        // `DownloadedVideosView` can show "71.2 MB" next to
        // each row.  We tolerate missing files (a video-only
        // download has no audio track) by skipping them.
        let readyDir = DownloadStore.shared.readyDirectory(for: bvid)
        let fm = FileManager.default
        var totalSize: Int64 = 0
        let candidates = ["video.init", "video.media",
                          "audio.init", "audio.media"]
        for name in candidates {
            let url = readyDir.appendingPathComponent(name)
            // The file currently lives in `in_progress/{bvid}/`,
            // not in `ready/{bvid}/` — `DownloadStore.add(_:)`
            // moves it before we read.  We re-compute the
            // staging location here so the size is correct
            // *before* the move happens (the move is async on
            // the ioQueue).
            let stagingURL = DownloadStore.shared
                .inProgressDirectory(for: bvid)
                .appendingPathComponent(name)
            let probeURL = fm.fileExists(atPath: stagingURL.path)
                ? stagingURL : url
            if let attrs = try? fm.attributesOfItem(atPath: probeURL.path),
               let size = attrs[.size] as? Int64 {
                totalSize += size
            }
        }
        let record = DownloadRecord(
            bvid: pending.video.id,
            aid: pending.video.aid,
            cid: pending.video.cid,
            title: pending.video.title,
            ownerName: pending.video.ownerName,
            coverURL: pending.video.coverURL,
            duration: pending.video.duration,
            dash: dash,
            referer: pending.playback.referer,
            downloadedAt: Date(),
            sizeBytes: totalSize
        )
        // Hand the record to the store.  `add(_:)` moves
        // `in_progress/{bvid}/` to `ready/{bvid}/` and
        // appends the record to the manifest — both happen
        // on the store's serial ioQueue.
        diagLog(.download, "all segments complete — building record",
                details: [
                    "bvid": bvid,
                    "title": pending.video.title,
                    "size_bytes": totalSize,
                    "expected": pending.expectedSegments,
                    "has_audio": pending.playback.dash?.audio != nil
                ])
        // Funnel success — fire only after the byte budget is
        // known so the console can compute "average download
        // size" / "average MB/sec" rollups. `has_audio` lets us
        // slice by DASH-with-audio vs video-only fallback.
        Analytics.log("download_complete", [
            "bvid": bvid,
            "title": pending.video.title,
            "size_bytes": totalSize,
            "has_audio": pending.playback.dash?.audio != nil
        ])
        Analytics.breadcrumb("DOWN", "download_complete \(bvid)")
        DownloadStore.shared.add(record)
        diagLog(.download, "handed record to DownloadStore",
                details: ["bvid": bvid, "size_bytes": totalSize])
        // Drop bookkeeping.  We intentionally leave
        // `stateByBvid[bvid]` alone for now — the
        // `DownloadStore.shared.$records` subscriber in
        // `VideoDetailViewModel` will call
        // `refreshDownloadState()` and pick up the new
        // `.downloaded(record:)` from the store on the
        // very next runloop.  Setting it to `.downloaded`
        // here too would race with that subscription.
        pendingByBvid[bvid] = nil
        progress[bvid] = nil
        // Best-effort: clear any orphan task-identifier
        // entries for this bvid.
        let orphans = taskToBvid
            .filter { $0.value == bvid }
            .map { $0.key }
        for id in orphans {
            taskToBvid.removeValue(forKey: id)
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
        // No error → the task succeeded.  The corresponding
        // `consumeDownloaded(...)` already moved the bytes
        // and may have promoted the download to `.downloaded`
        // — nothing to do here.
        guard let error else { return }
        let nsError = error as NSError
        let bvid = task.taskDescription?.split(separator: "|").first
            .map(String.init) ?? "?"
        // Cancellations are user-initiated (the download
        // button is now "取消" and `cancel(bvid:)` already
        // wiped the bookkeeping).  Drop the error.
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            diagLog(.download, "task cancelled",
                    details: ["bvid": bvid, "task_id": task.taskIdentifier])
            return
        }
        let taskId = task.taskIdentifier
        diagLog(.download, "task failed",
                details: [
                    "bvid": bvid,
                    "task_id": taskId,
                    "domain": nsError.domain,
                    "code": nsError.code,
                    "description": nsError.localizedDescription
                ])
        Task { @MainActor in
            // One-shot retry — the previous version marked
            // the whole download failed on the first segment
            // error, which is why a transient CDN hiccup on
            // the audio track would leave the user staring
            // at "75%" forever.  The retry reschedules the
            // exact same byte-range request; if it also
            // fails we fall through to `failed(message:)`.
            let retriesSoFar = self.retryCountByTaskId[taskId, default: 0]
            if retriesSoFar == 0,
               task.originalRequest != nil {
                self.retryCountByTaskId[taskId] = retriesSoFar + 1
                diagLog(.download, "retrying segment",
                        details: ["bvid": bvid, "task_id": taskId,
                                  "retry": retriesSoFar + 1])
                self.retrySegment(task: task, bvid: bvid)
                return
            }
            self.retryCountByTaskId[taskId] = nil
            self.stateByBvid[bvid] = .failed(
                message: nsError.localizedDescription
            )
            self.progress[bvid] = nil
            // Funnel failure — fires once per bvid when the
            // single retry is exhausted. Multiple segments can
            // independently reach this branch, so the same
            // `bvid` may emit several events for one failed
            // download; the console will dedupe visually.
            Analytics.recordError(nsError, context: "download")
            Analytics.log("download_error", [
                "bvid": bvid,
                "domain": nsError.domain,
                "code": nsError.code
            ])
            Analytics.breadcrumb("DOWN",
                "download_error \(bvid) code=\(nsError.code)")
            // Wipe the half-finished staging directory so a
            // retry of the whole download starts clean.
            let staging = DownloadStore.shared.inProgressDirectory(
                for: bvid
            )
            try? FileManager.default.removeItem(at: staging)
            self.pendingByBvid[bvid] = nil
            diagLog(.download, "download marked failed",
                    details: ["bvid": bvid,
                              "message": nsError.localizedDescription])
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
    case notDownloaded
    case downloading(progress: Double)
    case downloaded(record: DownloadRecord)
    case failed(message: String)

    /// `true` while a download is in flight.  Centralised
    /// here so the diagnostic report and any future UI that
    /// wants the "in flight" count doesn't have to repeat
    /// the `if case .downloading` pattern — and so a future
    /// "queued" or "verifying" case only needs a single
    /// switch update.
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}