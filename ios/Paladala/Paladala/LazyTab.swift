import SwiftUI

/// Defers child body evaluation until armed via `.onChange(of: tag)`
/// matching `tag`. Use to avoid paying the cost of a tab's
/// `@StateObject` init on every `TabView` first body evaluation.
///
/// State preservation across tab switches is automatic via SwiftUI's
/// `@State` machinery — once armed, the child view keeps its identity
/// even when the wrapper is re-evaluated (e.g. on a category change).
///
/// PR-A, audit item #5 (lazy `@StateObject` for the 5 tabs).
struct LazyTab<Tag: Hashable, V: View>: View {
    let tag: Tag
    let activeTag: Tag?
    @ViewBuilder let content: () -> V

    @State private var armed: Bool = false

    var body: some View {
        Group {
            if armed {
                content()
            } else {
                EmptyView()
            }
        }
        .onChange(of: activeTag, initial: true) { _, new in
            // `new` is `Tag?`; lift to compare with the non-optional `tag`.
            if let unwrapped = new, unwrapped == tag, !armed {
                armed = true
            }
        }
    }
}