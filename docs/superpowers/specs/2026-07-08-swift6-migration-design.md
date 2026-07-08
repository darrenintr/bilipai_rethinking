# Swift 6 Migration — Design Spec

**Date:** 2026-07-08
**Branch:** `working`
**Status:** Approved (brainstorming complete)
**Type:** Build / language migration

## Goal

Migrate the iOS app (main target + widget extension + test target) to Swift 6 language mode with full strict concurrency. End state: `SWIFT_VERSION = 6.0` in every build configuration, every Swift 6 error resolved via real annotation, isolation, or refactor — no escape hatches.

## Non-Goals

- Migrating `ObservableObject` → `@Observable` macro (separate refactor PR; we annotate existing `ObservableObject`s with `@MainActor` only).
- Bumping iOS deployment target (stays at 17.5/18.0).
- Refactoring data flow or app architecture beyond what `Sendable`/isolation strictly require.
- Adding new third-party dependencies.

## Constraints (user-confirmed)

| Question | Decision |
|---|---|
| Staging | Single PR, all-in |
| Escape-hatch policy | **Strict**: no `@preconcurrency`, no `@unchecked Sendable`, no `nonisolated(unsafe)` |
| Target scope | All three: `Paladala` (app), `PaladalaWidget` (extension), `PaladalaTests` (XCTest) |
| Success bar | Green CI on `ios-unsigned-ipa.yml` + `xcodebuild` of widget and test targets compiles locally |
| Approach | Layered build-up: pre-migrate under Swift 5, then flip |

## Codebase Facts (gathered 2026-07-08)

- 71 Swift files in main app target; 7 test files; widget extension present (file count to be reconfirmed at execution time).
- 39 `ObservableObject` classes; 8 already `@MainActor` (`DownloadStore`, `DeviceInfo`, `ICloudSync`, `LiveActivityCoordinator`, `MiniPlayerStore`, `WatchSession`, `UPProfileView`, `InlineAVPlayerView`).
- 9 `DispatchQueue` call sites across 7 files: `FollowNotificationService`, `DeviceInfo`, `MusicHomeView`, `LaunchMetrics`, `PaladalaApp`, `DiagnosticLogger`, `LocalHLSProxyServer`.
- 110 existing concurrency annotations across the codebase — the team has been actively preparing for this migration.
- No third-party dependencies (no Pods, no `Package.swift`, no `LocalPackages`).
- No local Mac available for compilation — feedback loop is push to `working` and watch CI.
- CI: `ios-unsigned-ipa.yml` on `macos-15` runner, `xcodebuild` unsigned IPA from `ios/Paladala/Paladala.xcodeproj`.
- Prior 4 commits (`ecbfff17..e0a62300`) were 1-line `pbxproj` flips (SWIFT_VERSION 5.0→6.0) that were reverted because CI failed. They prove the team is committed to the goal but the migration needs code changes, not just a setting flip.

## Commit Series (5 commits)

Each commit 1–4 must compile under `SWIFT_VERSION = 5.0` with no new warnings. Commit 5 flips the version.

### Commit 1 — `Sendable` conformances on data models

- Identify every `struct` and `final class` whose instances cross an actor boundary: API responses from `BilibiliAPIClient`, `MusicService`, `SponsorBlockService`; view-model state DTOs; `Codable` types passed into `Task.detached`.
- Pattern: add `: Sendable` to each such type.
- Skip types that hold non-`Sendable` references (`AVPlayer`, `URLSession`, Combine subjects, etc.) — those get refactored in commit 3.
- Verification: `xcodebuild -scheme Paladala -configuration Debug -destination 'generic/platform=iOS Simulator' build` passes.

### Commit 2 — `@MainActor` on remaining `ObservableObject`s

- 8 are already annotated. The remaining 31 are evaluated case-by-case.
- Default: any `ObservableObject` that mutates UI-bound state from synchronous methods gets `@MainActor`.
- Pattern: where the class already uses `Task { @MainActor in … }` inside its methods, just hoist the annotation to the class level.
- Edge cases: `PaladalaRepository` (service object — judge per case; may stay non-isolated if it owns no UI state and is called only from `await` contexts).
- Verification: build passes.

### Commit 3 — Refactor `DispatchQueue` sites to structured concurrency

- 7 files use `DispatchQueue` directly. For each:
  - `DispatchQueue.main.async { … }` → `Task { @MainActor in … }`
  - `DispatchQueue.global().async` → `Task.detached { … }` (or pure `async` function called with `await`)
  - Serial queues that protect mutable state → introduce `actor`; methods become isolated; cross-boundary calls use `await`.
- `LocalHLSProxyServer` is the highest-complexity case (its connection state is currently queue-protected); it gets the most attention.
- Verification: build passes.

### Commit 4 — Closure captures and protocol `Sendable` conformances

- Audit `URLSession`/`async`/`Task` call sites for closure captures of non-`Sendable` state. Fix each capture one of three ways: (a) move the captured state into a `Sendable` owner, (b) use `[weak self]` and re-enter isolation explicitly with `await MainActor.run { … }` or `Task { @MainActor in … }`, or (c) hoist the closure's logic into a method on the owner and call it via `await`.
- For protocols in `Models.swift`, `SponsorBlockModels.swift`, `MusicService.swift` — add `: Sendable` to protocol declarations where all conforming types are themselves `Sendable`.
- Audit stored `@Sendable` closures for type-correctness.
- Verification: build passes.

### Commit 5 — Flip `SWIFT_VERSION = 6.0`

- Single-line change per build config: 6 occurrences in `ios/Paladala/Paladala.xcodeproj/project.pbxproj` (Debug+Release × Paladala, PaladalaWidget, PaladalaTests).
- Expected outcome: zero or near-zero remaining errors, because commits 1–4 pre-resolved the language-mode issues.
- If errors remain: **fix-forward in this same commit** (no separate fix commit, to keep the diff focused).
- Push to `working`. Watch `ios-unsigned-ipa.yml` CI.

## Code Patterns (templates)

| Pattern | When | Template |
|---|---|---|
| `Sendable` on struct | data type crossing actor boundary | `public struct VideoDetail: Codable, Sendable { … }` |
| `@MainActor` on class | UI state owner | `final class XViewModel: @MainActor ObservableObject { … }` |
| Replace `DispatchQueue.main.async` | UI hop | `Task { @MainActor in … }` |
| Replace serial-queue-protected state | mutable state shared across threads | introduce `actor`; methods become isolated; cross-boundary calls use `await` |
| Protocol `: Sendable` | protocol where all conformers are `Sendable` | `protocol X: Sendable { … }` |
| `@Sendable` closure | stored closure used across actor hops | `@Sendable var onComplete: (Result<T, Error>) -> Void` |

## Verification

| Stage | Check | Owner |
|---|---|---|
| After commits 1–4 | `xcodebuild -scheme Paladala -configuration Debug -destination 'generic/platform=iOS Simulator' build` succeeds | local (Mac required) |
| After commit 5 | `ios-unsigned-ipa.yml` CI is green | CI |
| After commit 5 | `xcodebuild -scheme PaladalaWidget -configuration Debug -destination 'generic/platform=iOS Simulator' build` succeeds | local (Mac required) |
| After commit 5 | `xcodebuild -scheme PaladalaTests -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15' build` succeeds | local (Mac required) |

If `ios-unsigned-ipa.yml` is red on commit 5: per the all-in decision, **fix-forward** — extend commit 5 or push follow-up commits to the same branch. Only revert if failures are catastrophic and unfixable in-session (last resort — the prior 4-commit probe/revert cycle already demonstrated that flip-and-revert yields no progress).

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `AVPlayer` / `AVPlayerItem` / `AVAsset` not `Sendable` under Swift 6 | `PlayerView` and `InlineAVPlayerView` are already `@MainActor`-isolated. If Swift 6 still rejects direct AVFoundation calls, wrap them in a small `actor` and route through `await` — no escape hatch. |
| Combine `PassthroughSubject` / `CurrentValueSubject` not `Sendable` | Most subjects live inside `@MainActor` types and are fine. Remaining cases are wrapped in `AsyncStream` (preferred) or kept on a plain `nonisolated` final class **only** if the published state is `Sendable` and all mutations go through a single serialized path. Note: this is plain `nonisolated`, **not** `nonisolated(unsafe)` — the latter is banned by policy. |
| Retain cycles from `Task` blocks | `Task` retains `self` strongly. For each conversion, audit capture lists and break cycles with `[weak self]` where the task outlives the owner. |
| Scope creep | The PR's purpose is "make Swift 6 compile". Any unrelated cleanup is deferred. |
| Widget / test target reveals a Swift 6 issue not visible in main app | The same SWIFT_VERSION applies to all three. Issues found in widget or test target are fixed in the same commit (no "deferred" — we own the full migration in this PR). |
| Test target XCTest API change under Swift 6 | Unlikely (XCTest is a stable C/Obj-C bridge), but if it happens, fix in commit 5. |

## Definition of Done

- [ ] All 5 commits pushed to `working`.
- [ ] `ios-unsigned-ipa.yml` CI is green on the final commit.
- [ ] Local `xcodebuild` of `Paladala`, `PaladalaWidget`, and `PaladalaTests` schemes all succeed.
- [ ] No new warnings in `xcodebuild` output (advisory — not a hard gate).
- [ ] `CHANGELOG.md` updated under unreleased section.
- [ ] No `@preconcurrency`, no `@unchecked Sendable`, no `nonisolated(unsafe)` in the migration's diff. Verifiable via `git diff $(git rev-list -n1 --before='2026-07-08' working)~1..working -- 'ios/**/*.swift' | grep -E '@preconcurrency|@unchecked Sendable|nonisolated\(unsafe\)'` (should return no matches).
