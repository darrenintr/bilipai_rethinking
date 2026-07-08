import UIKit

/// Centralised haptic feedback. The system throttles feedback
/// generators when fired too often — these helpers intentionally
/// use fresh generators (no `prepare()` warm-up) so the
/// throttling behaviour matches the system default.
///
/// Use `Haptics` only on user-initiated discrete events; firing on
/// every state change will feel buzzy. The intended mapping is:
/// - `tap()`      – VideoCard tap, mini-player play/pause tap
/// - `medium()`   – Pull-to-refresh threshold, player double-tap seek
/// - `rigid()`    – Long-press context menu open
/// - `success()`  – Comment posted, video liked (server-confirmed)
/// - `selection()` – Comment sort picker change, mini-player play/pause
///
/// PR-C Task 5: `UIImpactFeedbackGenerator` and friends are
/// `@MainActor`-isolated under Swift 6.  The helpers stay
/// nonisolated so non-SwiftUI callers (`@objc` gesture
/// recognisers on the player's contentOverlayView, etc.) do
/// not have to re-architect to be MainActor themselves; each
/// helper internally dispatches the `MainActor`-isolated
/// call through a structured `Task { @MainActor in … }`.
/// The hop is fire-and-forget; haptic feedback timing is
/// not synchronised with any caller.
enum Haptics {
    static func tap() {
        Task { @MainActor in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    static func medium() {
        Task { @MainActor in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    static func rigid() {
        Task { @MainActor in
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
    }

    static func success() {
        Task { @MainActor in
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    static func warning() {
        Task { @MainActor in
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    static func error() {
        Task { @MainActor in
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    static func selection() {
        Task { @MainActor in
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
