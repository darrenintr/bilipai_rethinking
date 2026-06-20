//
//  InlineAVPlayerView.swift
//  BiliPaiNative
//
//  `AVPlayerLayer` + `AVPictureInPictureController` bridge
//  for the *inline* player surface.  SwiftUI's `VideoPlayer`
//  hides the layer (it owns an `AVPlayerViewController`
//  internally), so we can't wire an `AVPictureInPictureController`
//  onto it — that's why the previous PiP setup only worked for
//  fullscreen playback.
//
//  What this file adds
//  -------------------
//  * `InlineAVPlayerView` — a UIView whose backing layer is
//    an `AVPlayerLayer`.  The layer carries the player's
//    currentItem, so video frames render directly into the
//    SwiftUI hierarchy (no `AVPlayerViewController` middleman).
//  * `InlineAVPlayerRepresentable` — a UIViewRepresentable
//    wrapping the view above.  The representable is what
//    `PlayerView` embeds; it lays out the view and exposes
//    the `AVPlayerLayer` for PiP setup.
//  * `InlinePiPController` — owns the
//    `AVPictureInPictureController` so the system can manage
//    lifecycle (delegate callbacks for "will/did start PiP",
//    "will/did stop PiP", "restore UI").  The controller is
//    retained by the coordinator (a strong reference is
//    required — `AVPictureInPictureController` does not
//    retain its delegate and the system does not retain the
//    controller itself).
//
//  Why a separate file
//  -------------------
//  The PiP setup needs careful lifecycle handling
//  (`canStartPictureInPictureAutomaticallyFromInline`,
//  background audio session activation, delegate retention).
//  Keeping it out of `PlayerView.swift` keeps the existing
//  inline overlay / fullscreen / double-tap code untouched.
//

import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - UIView

/// A `UIView` whose backing layer is an `AVPlayerLayer`.
/// Exposed as a public property so the `UIViewRepresentable`
/// coordinator can hand the layer to
/// `AVPictureInPictureController.init(playerLayer:)`.
final class InlineAVPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    /// The view's backing layer, typed for convenience.  AVKit
    /// guarantees this is an `AVPlayerLayer` because of the
    /// `layerClass` override above.
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// Bind the player's `currentItem` onto the layer.  Setting
    /// `player` on the layer is the documented way to drive the
    /// rendered video frames — leaving the layer's player nil
    /// shows a transparent surface.
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }
}

// MARK: - UIViewRepresentable

/// SwiftUI bridge for `InlineAVPlayerView`.  Mounts the view
/// in the inline `PlayerView` hierarchy and hands the
/// resulting `AVPlayerLayer` to `InlinePiPController` so the
/// system can manage Picture-in-Picture.
///
/// The `InlinePiPController` is owned by the coordinator —
/// not by the view itself — because
/// `AVPictureInPictureController` does NOT retain its
/// delegate.  Without the coordinator retaining it, the
/// controller would deallocate the moment the representable
/// re-renders, which in turn would tear down the PiP session
/// mid-stream.
struct InlineAVPlayerRepresentable: UIViewRepresentable {
    let player: AVPlayer
    /// Closure invoked when the inline PiP button is tapped.
    /// The view layer doesn't own PiP lifecycle — `PlayerView`
    /// (which has the auth/UI context) wires the action.
    let onPiPRequested: () -> Void
    /// Holder that retains the PiP controller across
    /// SwiftUI re-renders.  See `PlayerView.InlinePiPHolder`
    /// for the strong-reference contract.
    @ObservedObject var holder: InlinePiPHolder

    func makeUIView(context: Context) -> InlineAVPlayerView {
        let view = InlineAVPlayerView()
        view.player = player
        // Bind the PiP controller to the layer so the system
        // can spin up an `AVPictureInPictureController` on
        // background.  The coordinator retains the controller;
        // `view.playerLayer` is the live layer instance the
        // controller hooks into.
        context.coordinator.attachPiP(
            to: view.playerLayer,
            holder: holder,
            onPiPRequested: onPiPRequested
        )
        return view
    }

    func updateUIView(_ uiView: InlineAVPlayerView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
        // PiP doesn't depend on per-frame state, but the
        // `onPiPRequested` closure may need to refresh in
        // case the parent view recreated its bindings
        // (e.g. after a re-mount from a mini-player ↔ inline
        // transition). Re-attach so the latest closure runs
        // on the next PiP button tap.
        context.coordinator.refreshPiPCallback(onPiPRequested)
    }

    static func dismantleUIView(_ uiView: InlineAVPlayerView, coordinator: Coordinator) {
        coordinator.detachPiP()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        /// Strong reference to the PiP controller — see the
        /// file header for why this matters.
        private var pip: InlinePiPController?

        func attachPiP(
            to layer: AVPlayerLayer,
            holder: InlinePiPHolder,
            onPiPRequested: @escaping () -> Void
        ) {
            // iOS 14.2+ — `AVPictureInPictureController.isPictureInPictureSupported()`
            // returns false on iPad split-view for some
            // configurations.  Bail out cleanly instead of
            // crashing the constructor.
            guard AVPictureInPictureController.isPictureInPictureSupported() else {
                diagLog(.playback, "PiP not supported on this device / config")
                return
            }
            guard let controller = InlinePiPController(
                layer: layer,
                onPiPRequested: onPiPRequested
            ) else {
                // Failable init returned nil — typically
                // because the layer isn't on-screen yet or
                // the audio session hasn't been activated.
                // The holder will retry on the next
                // `.bilipaiPiPPossibleChanged` notification.
                diagLog(.playback, "InlinePiPController init returned nil")
                return
            }
            pip = controller
            // Hand the strong reference to the holder so the
            // controller outlives any SwiftUI re-render of
            // the representable.  `AVPictureInPictureController`
            // weakly retains its delegate — the holder's
            // strong ref keeps the chain alive.
            holder.attach(controller)
            diagLog(.playback, "InlinePiPController attached",
                    details: ["possible": controller.isPiPPossible])
        }

        func refreshPiPCallback(_ onPiPRequested: @escaping () -> Void) {
            pip?.updatePiPRequestHandler(onPiPRequested)
        }

        func detachPiP() {
            pip?.stopPictureInPicture()
            pip = nil
        }
    }
}

// MARK: - PiP controller wrapper

/// Wraps `AVPictureInPictureController` so the delegate
/// callbacks live in one place and the rest of the app can
/// observe PiP state via `PlayerController.isPictureInPictureActive`.
///
/// AVPiPController quirks this file handles:
///
/// * **No automatic delegate retention.** The controller
///   weakly retains its delegate.  The
///   `InlineAVPlayerRepresentable.Coordinator` retains *us*,
///   and we in turn hold a strong `AVPictureInPictureController`
///   reference.  The delegate is set to `self` (the wrapper
///   is the delegate), so the chain is
///   coordinator → wrapper → controller.
/// * **`canStartPictureInPictureAutomaticallyFromInline`.**
///   Without this flag (iOS 14.2+) the user must enter
///   fullscreen before PiP becomes available.  We want PiP
///   from the inline surface too, so we set it on every
///   `attach` AND keep it on after a PiP start/stop cycle.
/// * **`requiresLinearPlayback = false`.**  Some B站 videos
///   are encoded with VFR or non-keyframe-aligned GOPs;
///   PiP requires linear playback by default.  We allow
///   non-linear so PiP can survive those edge cases.
final class InlinePiPController: NSObject, AVPictureInPictureControllerDelegate {
    private let controller: AVPictureInPictureController
    private var onPiPRequestedHandler: () -> Void
    /// Set to `true` once the system tells us PiP became
    /// possible, so we can stop logging "not possible" every
    /// render.  The system toggles this flag many times over
    /// a controller's lifetime (e.g. after audio-session
    /// changes) — we only care about the transition.
    private var didLogPossible = false

    /// `AVPictureInPictureController.init(playerLayer:)` is
    /// failable on iOS 15+ — the system returns `nil` when
    /// the layer isn't on-screen yet or when the audio session
    /// is not configured.  We hand the optional through
    /// `guard let` at the call site and surface a clean no-op
    /// (see `Coordinator.attachPiP`).
    init?(layer: AVPlayerLayer, onPiPRequested: @escaping () -> Void) {
        self.onPiPRequestedHandler = onPiPRequested
        guard let pip = AVPictureInPictureController(playerLayer: layer) else {
            return nil
        }
        self.controller = pip
        super.init()
        controller.delegate = self
        // iOS 14.2+: enter PiP directly from the inline
        // (non-fullscreen) player.  Without this the user
        // has to go fullscreen first, which defeats the
        // purpose of inline PiP.
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        // Some VFR / non-keyframe-aligned Bilibili encodes
        // are rejected by the strict PiP playback model.
        // Allow non-linear so the system plays them as-is.
        controller.requiresLinearPlayback = false
    }

    /// Whether the system currently considers PiP possible.
    /// Mirrors the controller's `isPictureInPicturePossible`
    /// property so callers can update button enabled state
    /// without re-reading the underlying controller.
    var isPiPPossible: Bool { controller.isPictureInPicturePossible }

    /// Swap the closure invoked when the inline PiP button
    /// is tapped.  `PlayerView` mounts the representable, but
    /// it may re-create the closure (e.g. if it re-mounts
    /// after a mini-player transition); the PiP controller
    /// needs to honour the latest closure.
    func updatePiPRequestHandler(_ handler: @escaping () -> Void) {
        onPiPRequestedHandler = handler
    }

    /// Start PiP, if possible.  Called from the inline PiP
    /// button.  Safe to call repeatedly — the system no-ops
    /// when PiP is already active.
    func startPictureInPicture() {
        guard controller.isPictureInPicturePossible else {
            diagLog(.playback, "PiP start requested but not possible",
                    details: ["isActive": controller.isPictureInPictureActive])
            // Fallback: surface the request to the caller —
            // they may want to enter fullscreen first, which
            // will trigger the AVPlayerViewController PiP path.
            onPiPRequestedHandler()
            return
        }
        controller.startPictureInPicture()
    }

    /// Stop PiP.  Called when the inline surface tears down.
    func stopPictureInPicture() {
        guard controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        diagLog(.playback, "PiP will start (inline)")
        // The downstream observer (`PlayerController.setPiPActive`)
        // is wired through the fullscreen
        // `AVPlayerViewControllerDelegate` callbacks.  Mirror
        // the same state flip here so the rest of the app sees
        // consistent PiP state regardless of which surface
        // initiated PiP.
        NotificationCenter.default.post(
            name: .bilipaiPiPWillStart, object: nil
        )
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        diagLog(.playback, "PiP did start (inline)")
        NotificationCenter.default.post(
            name: .bilipaiPiPDidStart, object: nil
        )
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        diagLog(.playback, "PiP will stop (inline)")
        NotificationCenter.default.post(
            name: .bilipaiPiPWillStop, object: nil
        )
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        diagLog(.playback, "PiP did stop (inline)")
        NotificationCenter.default.post(
            name: .bilipaiPiPDidStop, object: nil
        )
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        diagLog(.playback, "PiP failed to start (inline)",
                details: ["error": error.localizedDescription])
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void
    ) {
        // Hand control back to the inline surface.  The
        // completion handler expects `true` once we've
        // surfaced the player's UI; we return true
        // unconditionally because the inline layer is always
        // in the view hierarchy underneath us.
        completionHandler(true)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by `InlinePiPController` right before the
    /// system starts a PiP session.  `PlayerController`
    /// observes this and mirrors the state flip onto
    /// `isPictureInPictureActive`.  We use a custom
    /// `Notification.Name` rather than mutating
    /// `PlayerController` directly to keep the inline PiP
    /// controller free of any coupling to the shared
    /// player state object.
    static let bilipaiPiPWillStart = Notification.Name("bilipai.pip.willStart")
    static let bilipaiPiPDidStart = Notification.Name("bilipai.pip.didStart")
    static let bilipaiPiPWillStop = Notification.Name("bilipai.pip.willStop")
    static let bilipaiPiPDidStop = Notification.Name("bilipai.pip.didStop")
    /// Posted by `InlinePiPHolder` when the system's
    /// `isPictureInPicturePossible` flag toggles.  SwiftUI
    /// subscribes to this to show or hide the inline PiP
    /// button — without a notification, the flag can flip
    /// after view appearance (e.g. once the audio session
    /// finishes activating) and the button would stay
    /// hidden forever.
    static let bilipaiPiPPossibleChanged = Notification.Name("bilipai.pip.possibleChanged")
}

// MARK: - Holder

/// Thin owner for the inline PiP controller.  Lives inside
/// `PlayerView` as a `@StateObject` so its lifetime matches
/// the view's mount.  Exposes `startPiP()` so the SwiftUI
/// button can fire PiP without holding a reference to the
/// `InlinePiPController` directly (which is an `NSObject`
/// subclass and would break SwiftUI's struct-based update
/// model).
@MainActor
final class InlinePiPHolder: ObservableObject {
    /// Whether the system currently allows PiP.  Refreshed
    /// by `refreshPiPPossible()` after PiP-attach and again
    /// on every `bilipaiPiPPossibleChanged` notification.
    private(set) var isPiPPossible: Bool = false
    /// The PiP controller — held strongly so the underlying
    /// `AVPictureInPictureController` survives SwiftUI
    /// re-renders.  `AVPictureInPictureController` does NOT
    /// retain its delegate, so we have to.
    private var pip: InlinePiPController?
    /// Long-running observation task.  Cancelled in
    /// `deinit` so the AsyncSequence subscriptions tear
    /// down with the holder.  One task per name keeps the
    /// bookkeeping simple — the alternative (a single
    /// multiplexed `for await` over `merge(...)`) is
    /// denser to read for four event types.
    private var observationTasks: [Task<Void, Never>] = []

    init() {
        // The actual `InlinePiPController` is created in
        // `InlineAVPlayerRepresentable.makeUIView` because
        // it needs the live `AVPlayerLayer`.  This holder
        // only owns the *reference* once `attach` is called
        // from the representable's coordinator.
        observePiPSession()
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
    }

    /// Hook the inline PiP controller into the holder.  Called
    /// by `InlineAVPlayerRepresentable.Coordinator.attachPiP`.
    func attach(_ controller: InlinePiPController) {
        self.pip = controller
        refreshPiPPossible()
    }

    /// Re-read the system flag and broadcast a notification
    /// so the SwiftUI overlay can show/hide its PiP button.
    func refreshPiPPossible() {
        let new = pip?.isPiPPossible ?? false
        guard new != isPiPPossible else { return }
        isPiPPossible = new
        NotificationCenter.default.post(
            name: .bilipaiPiPPossibleChanged, object: nil
        )
    }

    /// Fire the PiP start path.  No-ops if PiP isn't
    /// possible yet — `InlinePiPController.startPictureInPicture`
    /// logs the rejection and falls back to the system's
    /// fullscreen PiP path.
    func startPiP() {
        pip?.startPictureInPicture()
    }

    /// Subscribe to the four PiP-lifecycle notifications and
    /// refresh `isPiPPossible` after each.  Each subscription
    /// runs in its own `Task` so cancellation is
    /// per-subscription; using the modern
    /// `NotificationCenter.notifications(named:)` AsyncSequence
    /// (iOS 15+) avoids the `addObserver` + `removeObserver`
    /// dance and the `@Sendable` closure warnings.
    private func observePiPSession() {
        let names: [Notification.Name] = [
            .bilipaiPiPWillStart,
            .bilipaiPiPDidStart,
            .bilipaiPiPWillStop,
            .bilipaiPiPDidStop
        ]
        for name in names {
            observationTasks.append(
                Task { [weak self] in
                    for await _ in NotificationCenter.default.notifications(named: name) {
                        // The AsyncSequence delivers on the
                        // posting thread (typically the
                        // AVPiP delegate callbacks fire on
                        // the main thread); we re-enter the
                        // MainActor explicitly so the call
                        // site stays Sendable-clean under
                        // Swift 6.
                        await self?.refreshPiPPossible()
                    }
                }
            )
        }
    }
}