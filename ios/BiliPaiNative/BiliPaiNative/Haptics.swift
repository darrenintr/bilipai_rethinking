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
enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func rigid() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
