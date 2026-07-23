import Combine
import Foundation

// MARK: - LoadState<T>
//
// Single-source-of-truth for the "load → error → empty" state
// machine that 20+ ViewModels in this target repeat
// wholesale.  Each VM owns a `@Published` `isLoading`,
// `errorMessage`, and an items array, plus a `load(...)` method
// that follows the exact same shape:
//
//     isLoading = true
//     errorMessage = nil
//     do {
//         items = try await repository.x()
//     } catch {
//         errorMessage = "X加载失败"
//         items = []
//     }
//     isLoading = false
//
// The pattern has been copied verbatim into `AccountContentViews`
// (5 VMs), `UPProfileView` (4), `HomeViewModel`, `ViewModels.swift`
// (the rest), and the test surface in `ProfileSettingsView`.
// Any bug fix — e.g. a different error message, retry-vs-reset
// semantics — has to be applied 20+ times.
//
// `LoadState<T>` collapses the boilerplate into a single
// `@MainActor` `ObservableObject` so each VM becomes:
//
//     @Published var feed = LoadState<[BiliVideo]>()
//
//     func load(repository: PaladalaRepository) async {
//         await feed.load { try await repository.feed(...) }
//                  errorText: "动态加载失败"
//     }
//
// `load(_:errorText:)` handles `isLoading`/`errorMessage`/`value`
// bookkeeping under the same invariants the hand-rolled code
// does.  Pagination is handled by `loadMore(_:errorText:)` which
// keeps an internal `isLoadingMore` flag and an `append`-vs-
// `replace` policy set per call.
//
// Why a class (not a struct)
// -------------------------
// SwiftUI views observe the items via `@ObservedObject` so the
// `@Published` setters can drive re-renders.  A struct cannot
// publish — `ObservableObject` is reference-typed.  Each VM
// holds one or more `LoadState` properties as `@Published`
// references; the VM itself stays the parent `ObservableObject`
// for the view, the inner `LoadState` is observed only where
// needed.
@MainActor
final class LoadState<T: Sendable>: ObservableObject {
    /// The currently-loaded value.  `nil` while the very first
    /// `load(_:)` is still in flight, and after a load error
    /// that resets `value` to `nil` (matching the existing
    /// hand-rolled behaviour — see e.g. `HistoryListViewModel`).
    @Published private(set) var value: T?
    /// True while `load(_:)` is running.  False during
    /// `loadMore(_:)` so the view can keep the existing items
    /// on screen while pagination is in flight.
    @Published private(set) var isLoading: Bool = false
    /// True while `loadMore(_:)` is running.  Mutually
    /// exclusive with `isLoading` — `loadMore` is a no-op when
    /// `isLoading` is true.
    @Published private(set) var isLoadingMore: Bool = false
    /// User-visible error string.  Set when a `load(_:)` call
    /// throws; cleared at the top of the next `load(_:)`.  The
    /// `errorText` argument supplies the fixed user-visible
    /// label; the underlying error is normalized and logged through
    /// `AppErrorCenter` for diagnostics.
    @Published private(set) var errorMessage: String?

    /// Initialise with no value.  The typical entry point —
    /// the surrounding VM calls `load(_:errorText:)` once the
    /// first page is needed.
    init() {}

    /// Initialise with a pre-seeded value.  Used by tests and
    /// by VMs that want to render a cached snapshot before
    /// the first network call lands (mirrors
    /// `HomeViewModel.seedFromCache(_:)`).
    init(value: T) {
        self.value = value
    }

    /// Run the supplied `work` closure, treating it as the
    /// canonical "first load / refresh" path.  Sets `isLoading`,
    /// clears `errorMessage`, calls `work`, and on success
    /// assigns the result to `value`.  On failure assigns
    /// `errorText` to `errorMessage` and clears `value` (the
    /// existing convention — the view renders the error state
    /// in place of the items).
    ///
    /// Concurrent calls short-circuit: while `isLoading` is
    /// already true, a second `load(_:)` is a no-op.  This
    /// matches the `guard !isLoading else { return }` pattern
    /// in `ShortVideoFeedViewModel.load`.
    func load(
        _ work: @escaping () async throws -> T,
        errorText: String,
        context: String = "loadState.load"
    ) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await work()
            value = result
        } catch {
            guard !AppErrorDescriptor.isCancellation(error) else { return }
            value = nil
            let descriptor = AppErrorCenter.shared.record(
                error,
                context: context,
                fallbackMessage: errorText
            )
            errorMessage = descriptor?.message ?? errorText
        }
    }

    /// Pagination path.  Runs `work` only when the current
    /// `value` is non-nil (the caller is asking for "the next
    /// page of what we already have"), and the existing
    /// `value` is preserved on failure.  The result of `work`
    /// is appended to the existing value via the caller's
    /// `append` closure — typically `existing + result` after
    /// a dedupe pass.
    ///
    /// Short-circuits while `isLoading` or `isLoadingMore` is
    /// already true.  Matches `HistoryListViewModel.loadMore`'s
    /// `guard !isLoading, !isLoadingMore, hasMore, ... else
    /// { return }` semantics.
    func loadMore(
        _ work: @escaping () async throws -> T,
        append: @escaping (T, T) -> T,
        errorText: String,
        context: String = "loadState.pagination"
    ) async {
        guard !isLoading, !isLoadingMore else { return }
        guard let current = value else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await work()
            value = append(current, next)
        } catch {
            guard !AppErrorDescriptor.isCancellation(error) else { return }
            let descriptor = AppErrorCenter.shared.record(
                error,
                context: context,
                fallbackMessage: errorText
            )
            errorMessage = descriptor?.message ?? errorText
        }
    }

    /// Manually reset to the empty state.  Used when the
    /// VM's parent state changes in a way that invalidates
    /// the cached value (e.g. switching accounts, signing
    /// out).
    func reset() {
        value = nil
        isLoading = false
        isLoadingMore = false
        errorMessage = nil
    }
}