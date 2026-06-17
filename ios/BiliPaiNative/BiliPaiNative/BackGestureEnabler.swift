import SwiftUI
import UIKit

/// Enables swipe-back from the middle of the screen *or* the
/// left edge. By default `UINavigationController` only allows
/// its interactive pop gesture to start within the left 20pt —
/// the user wanted the gesture to work from anywhere on the
/// trailing-to-leading half of the screen, with a slightly
/// lower threshold for left-edge swipes (which is what the
/// system already does, but we widen the recognised region
/// to 32pt to match what feels natural).
///
/// The recognizer runs alongside the inner `ScrollView`'s pan
/// gesture via the `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`
/// delegate. That way scrolling the comments does not block
/// the swipe-back, and vice versa — the horizontal vs
/// vertical lock is decided in `gestureRecognizerShouldBegin`
/// based on the velocity vector.
///
/// Usage:
/// ```swift
/// NavigationStack(path: $router.path) { ... }
///     .background(BackGestureEnabler(
///         isEnabled: !router.path.isEmpty,
///         onPop: { withAnimation(.easeInOut) { router.path.removeLast() } }
///     ))
/// ```
struct BackGestureEnabler: UIViewControllerRepresentable {
    /// `false` makes the gesture a no-op. Wire this to
    /// `!router.path.isEmpty` so the root view (where
    /// there is nothing to pop) does not absorb pan
    /// gestures meant for inner content.
    let isEnabled: Bool
    /// Invoked when the gesture completes a pop-worthy
    /// translation. The view is responsible for the actual
    /// path mutation and any animation wrapper.
    let onPop: () -> Void

    func makeUIViewController(context: Context) -> BackGestureHost {
        let host = BackGestureHost()
        host.coordinator = context.coordinator
        return host
    }

    func updateUIViewController(_ host: BackGestureHost, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onPop = onPop
        // The host might have been re-parented; ask it to
        // re-check its position in the view hierarchy.
        host.tryAttach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool = true
        var onPop: () -> Void = {}

        /// The nav controller we've installed the gesture
        /// on. Tracked so a re-parent (e.g. switching tabs
        /// on iPad) does not stack multiple recognizers.
        weak var attachedNav: UINavigationController?
        private var recognizer: UIPanGestureRecognizer?

        // Gesture-begin state. Stored across the
        // began → changed → ended transitions.
        private var startX: CGFloat = 0
        private var startY: CGFloat = 0
        private var startedAtLeftEdge: Bool = false

        /// Attach (or re-attach) the recognizer to the
        /// nav controller reachable from `viewController`.
        /// Safe to call repeatedly; only one recognizer
        /// is ever live on a given nav controller.
        func attach(to nav: UINavigationController) {
            if attachedNav === nav, recognizer != nil { return }

            // Detach from any previous nav first. We
            // only ever install on one nav at a time.
            detach()

            attachedNav = nav
            // The user wants swipe-back from the middle,
            // not just the edge — disable the system's
            // edge-only recognizer so it does not
            // interfere (or fire with the wrong animation).
            nav.interactivePopGestureRecognizer?.isEnabled = false

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            pan.cancelsTouchesInView = false
            nav.view.addGestureRecognizer(pan)
            recognizer = pan
        }

        /// Drop the recognizer from whatever nav it
        /// was attached to. Idempotent.
        func detach() {
            if let nav = attachedNav, let pan = recognizer {
                nav.view.removeGestureRecognizer(pan)
            }
            attachedNav?.interactivePopGestureRecognizer?.isEnabled = true
            recognizer = nil
            attachedNav = nil
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizer(_ rec: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // The inner `ScrollView`'s pan must keep
            // working — this is what lets the user scroll
            // comments and swipe back without either
            // gesture starving the other.
            return true
        }

        func gestureRecognizerShouldBegin(_ rec: UIGestureRecognizer) -> Bool {
            guard isEnabled, let nav = attachedNav else { return false }
            // The nav controller's stack must have at
            // least one push above the root for the
            // gesture to make sense.
            guard nav.viewControllers.count > 1 else { return false }
            guard let pan = rec as? UIPanGestureRecognizer else { return true }

            // Reject gestures that start in the trailing
            // 24pt — that's where system back-swipe
            // affordances and pull-to-dismiss handles
            // live, and we don't want to fight them.
            let location = pan.location(in: nav.view)
            guard location.x < nav.view.bounds.width - 24 else { return false }

            // Lock to mostly-horizontal pans. The user
            // wanted middle-of-screen swipe; if the
            // velocity is more vertical than horizontal
            // we let the ScrollView take it.
            let v = pan.velocity(in: nav.view)
            return abs(v.x) > abs(v.y)
        }

        // MARK: Gesture handler

        @objc func handlePan(_ rec: UIPanGestureRecognizer) {
            guard isEnabled, let nav = attachedNav else { return }
            guard nav.viewControllers.count > 1 else { return }
            let translation = rec.translation(in: nav.view)
            let velocity = rec.velocity(in: nav.view)

            switch rec.state {
            case .began:
                startX = rec.location(in: nav.view).x
                startY = rec.location(in: nav.view).y
                startedAtLeftEdge = startX < 32

            case .changed:
                // Only push the view to the right; a
                // leftward swipe does nothing (matches
                // the system edge-swipe direction).
                guard translation.x > 0 else {
                    nav.view.transform = .identity
                    return
                }
                // Cap the visible drag at 200pt so the
                // page underneath does not get exposed
                // too far, and damp the translation so
                // a wild fling does not fling the page
                // off-screen.
                let dx = min(200, translation.x * 0.4)
                // Subtle scale: the dragging view
                // shrinks by up to 5% (matching the
                // iOS push/pop animation curve), giving
                // the depth cue users expect.
                let scale = 1.0 - (dx / 200) * 0.05
                nav.view.transform = CGAffineTransform(translationX: dx, y: 0)
                    .scaledBy(x: scale, y: scale)

            case .ended, .cancelled, .failed:
                let dx = translation.x
                let shouldPop =
                    dx > 100 ||
                    (startedAtLeftEdge && dx > 60) ||
                    velocity.x > 600
                // Always reset the transform — either
                // spring back to identity, or in
                // preparation for the pop animation.
                UIView.animate(
                    withDuration: 0.25,
                    delay: 0,
                    options: [.curveEaseOut, .allowUserInteraction]
                ) {
                    nav.view.transform = .identity
                }
                if shouldPop {
                    // Hand the actual pop off to the
                    // view via the closure. The view is
                    // responsible for the
                    // `withAnimation` wrapper that gives
                    // the path-removal its own slide.
                    onPop()
                }

            default:
                break
            }
        }
    }

    // MARK: - Host view controller

    /// Empty `UIViewController` whose only job is to live
    /// inside the SwiftUI tree so we can walk up to the
    /// enclosing `UINavigationController`. We never add
    /// a visible view; the host is a thin shim for the
    /// coordinator to attach to.
    final class BackGestureHost: UIViewController {
        weak var coordinator: Coordinator?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            tryAttach()
        }

        /// Re-check the parent chain and (re-)install
        /// the recognizer on the enclosing nav. Safe to
        /// call repeatedly.
        func tryAttach() {
            guard let coordinator else { return }
            var cursor: UIViewController? = parent
            while let current = cursor {
                if let nav = current as? UINavigationController {
                    coordinator.attach(to: nav)
                    return
                }
                cursor = current.parent
            }
            // We are not currently inside a
            // `UINavigationController` — drop any
            // recognizer from a previous nav so we
            // don't leak.
            coordinator.detach()
        }

        deinit {
            coordinator?.detach()
        }
    }
}
