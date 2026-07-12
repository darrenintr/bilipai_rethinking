import Foundation

// MARK: - GenerationGuard
//
// "Generation counter" pattern used in three places:
//
// 1. `HomeViewModel.suggestGeneration` — `searchQueryChanged`
//    bumps it on every keystroke; `runSuggest` captures the
//    pre-call value and discards the response if a newer
//    keystroke already bumped it.  Without this guard the user
//    sees the suggestion strip flash for an older term after a
//    newer one is rendered.
//
// 2. `HomeViewModel.requestGeneration` — same shape:
//    `loadPage` captures the value, fires the network call,
//    and throws away the response if `beginNewRequestGeneration`
//    has already advanced the counter (category switch,
//    refresh, sign-out).  See commit 9af1a8fa's neighbours
//    for the original observation.
//
// 3. `LocalHLSProxyServer.currentPrepGeneration` — gates
//    `/init`, `/media`, `/segment` HTTP requests so a
//    stale-prep request can't poison a new playback session.
//    Bumped in `beginServing()`.  Same invariant, different
//    transport — the route handler checks the counter before
//    touching any state.
//
// The pattern was re-implemented three times.  `GenerationGuard`
// collapses the invariant into a single struct: bump() returns
// the new value; isCurrent(_:) compares against the latest.  A
// `loadState` closure (optional) lets callers flip the counter
// inside the same call site as a state machine transition.
//
// Sendable / thread-safety
// -----------------------
// Value-type with internal `UInt64` mutation.  Used from
// `@MainActor` ViewModels (cases 1+2) and from inside the
// ProxyServer actor (case 3) — the latter holds the guard as
// an actor-isolated stored property so all access stays
// serialised.
struct GenerationGuard: Sendable {
    private var value: UInt64 = 0

    /// The most recent generation.  Read by callers that
    /// capture "the value that was current when I fired the
    /// request" so they can compare on response.
    var current: UInt64 { value }

    /// Bump the counter and return the new value.  Callers
    /// typically capture the return value as the
    /// "request-scoped" generation so a late response can be
    /// discarded via `isCurrent(_:)`.
    @discardableResult
    mutating func bump() -> UInt64 {
        value &+= 1
        return value
    }

    /// True when `generation` matches the most recent
    /// `bump()` result.  The whole point of the guard — a
    /// response from an earlier request will fail this check
    /// and the caller can drop it without mutating any
    /// state.
    func isCurrent(_ generation: UInt64) -> Bool {
        generation == value
    }

    /// Convenience: bump the counter and run `work`.  Used
    /// when the bump and the in-flight request kick-off
    /// have to happen atomically — e.g. `HomeViewModel`'s
    /// `searchQueryChanged` bumps the generation, kicks off
    /// the debounced suggest task, and the task captures
    /// the bumped value (not the old one) so the very next
    /// keystroke correctly invalidates it.
    @discardableResult
    mutating func bumpAnd<T>(_ work: (UInt64) throws -> T) rethrows -> T {
        let generation = bump()
        return try work(generation)
    }
}