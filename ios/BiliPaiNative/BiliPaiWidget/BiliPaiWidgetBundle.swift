import SwiftUI
import WidgetKit

/// Single entry point for the BiliPaiWidget extension.
///
/// Only the Live Activity widget ships in commit 10; home
/// screen widgets (small / medium timeline) will be added
/// here in a follow-up. The bundle stays small so the
/// extension binary stays under the iOS widget budget.
@main
struct BiliPaiWidgetBundle: WidgetBundle {
    var body: some Widget {
        LiveActivityWidget()
    }
}
