# Swift 6 Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the iOS app (main target + widget extension + test target) to Swift 6 language mode with full strict concurrency in a single 5-commit PR.

**Architecture:** Layered build-up — pre-migrate under Swift 5.0 (Sendable conformances, @MainActor annotations, DispatchQueue→structured-concurrency, closure/protocol fixes), then flip SWIFT_VERSION=6.0 in the final commit. Strict policy: no `@preconcurrency`, no `@unchecked Sendable`, no `nonisolated(unsafe)`.

**Tech Stack:** Swift 6, iOS 17.5/18.0, SwiftUI + Combine + AVFoundation, xcodebuild unsigned IPA via `ios-unsigned-ipa.yml` on `macos-15` CI. No third-party deps.

## Global Constraints

- **Branch:** `working`. All 5 commits land here, pushed together at the end of the migration.
- **No escape hatches:** `@preconcurrency`, `@unchecked Sendable`, `nonisolated(unsafe)` are banned. Plain `nonisolated` on a `Sendable` type with a single serialized mutation path is allowed.
- **Build target scope:** All three targets — `Paladala` (app), `PaladalaWidget` (extension), `PaladalaTests` (XCTest). All three share the same `SWIFT_VERSION` build setting.
- **No `@Observable` migration:** This PR only adds `@MainActor` to existing `ObservableObject`s. Migrating to the `@Observable` macro is a separate refactor.
- **No deployment-target bump:** Stays at iOS 17.5/18.0.
- **No scope creep:** Any unrelated cleanup is deferred. The PR's purpose is "make Swift 6 compile", not "redesign the app."
- **Verification path:** No local Mac available (Linux runner). Verification is by `xcodebuild` on CI (`ios-unsigned-ipa.yml`) and by static review for commits 1–4. The `xcodebuild` of `PaladalaWidget` and `PaladalaTests` schemes is part of Definition of Done; it runs on the CI machine or by the user on their own Mac.
- **CHANGELOG:** Updated in commit 5 under the unreleased section.
- **Spec source of truth:** `docs/superpowers/specs/2026-07-08-swift6-migration-design.md`.

## Repository facts (carried from the spec, for quick reference)

- 71 Swift files in `ios/Paladala/Paladala/`.
- 7 test files in `ios/Paladala/PaladalaTests/`.
- 2 widget files: `ios/Paladala/PaladalaWidget/LiveActivityWidget.swift`, `ios/Paladala/PaladalaWidget/PaladalaWidgetBundle.swift`.
- 39 `ObservableObject` classes total; 8 already `@MainActor` (`DownloadStore`, `DeviceInfo`, `ICloudSync`, `LiveActivityCoordinator`, `MiniPlayerStore`, `WatchSession`, `UPProfileView`, `InlineAVPlayerView`); 31 to evaluate.
- 9 `DispatchQueue` sites across 7 files: `FollowNotificationService`, `DeviceInfo`, `MusicHomeView`, `LaunchMetrics`, `PaladalaApp`, `DiagnosticLogger`, `LocalHLSProxyServer`.
- 110 existing concurrency annotations — the team has been actively preparing.

---

## Task 1: Sendable conformances on data models

**Files:**
- Modify: `ios/Paladala/Paladala/Models.swift` (primary — ~30 data types)
- Modify: `ios/Paladala/Paladala/ViewModels.swift` (DTOs)
- Modify: `ios/Paladala/Paladala/AccountContentViews.swift` (DTOs)
- Modify: `ios/Paladala/Paladala/UPProfileView.swift` (UP DTOs)
- Modify: `ios/Paladala/Paladala/SponsorBlockModels.swift` (model types)
- Modify: `ios/Paladala/Paladala/PlayerView.swift` (player DTOs)
- Modify: `ios/Paladala/Paladala/MusicService.swift` (music DTOs)
- Modify: `ios/Paladala/Paladala/PaladalaRepository.swift` (data-layer types)
- Modify: `ios/Paladala/Paladala/BilibiliAPIClient.swift` (response types)
- Modify: `ios/Paladala/Paladala/SponsorBlockService.swift` (response types)
- Modify: `ios/Paladala/Paladala/FollowNotificationService.swift` (notification types)
- Modify: `ios/Paladala/Paladala/Shared/LiveRoomActivityAttributes.swift` (Live Activity `ActivityAttributes` type)
- Modify: `ios/Paladala/PaladalaWidget/LiveActivityWidget.swift` (the Live Activity widget that consumes the attributes)

**Interfaces:**
- Consumes: existing data types as-is.
- Produces: every cross-actor data type gains `: Sendable` conformance, which task 5's `SWIFT_VERSION = 6.0` flip then relies on for region-isolation.

- [ ] **Step 1: Inventory candidate types in `Models.swift`**

Run:
```bash
grep -nE '^public struct |^public final class |^struct |^final class |^public enum |^enum ' \
  ios/Paladala/Paladala/Models.swift
```
Expected: a list of every type declaration. For our `Models.swift` we observed 30+ types including `BiliVideo`, `BiliUserCard`, `BiliAISummary`, `BiliPlayback`, `LocalPlaybackContext`, `DownloadRecord`, `BiliLiveRoom`, `BiliComment`, `DynamicPost`, `HistoryEntry`, `FavoriteFolderSummary`, `BiliLyricInfo`, `BiliDanmakuItem`, etc.

- [ ] **Step 2: Skip types that hold non-`Sendable` references**

For each candidate, check its stored properties. If a type stores `AVPlayer`, `AVPlayerItem`, `AVAsset`, `URLSession`, `Combine.Subject`, `class`-only non-`final` types, or `Task`/`@MainActor`-isolated closures, **skip it in this task** — those are refactored in task 3 (DispatchQueue→actor) or task 4 (closure captures). For our `Models.swift`, all 30+ types are pure value types holding primitives, `URL`, `String`, `Int`, `Double`, arrays, and dictionaries — all `Sendable` by inference. None should be skipped.

- [ ] **Step 3: Add `Sendable` to each in-scope type in `Models.swift`**

Apply the pattern `: Sendable` to every type declaration. Concrete examples from our file (substitute exact names for the rest of the file):

```swift
// Line 70 — BiliVideo
struct BiliVideo: Identifiable, Hashable, Codable, Sendable {

// Line 121 — BiliUserCard
struct BiliUserCard: Codable, Hashable, Sendable {

// Line 144 — BiliUserSearchResult
struct BiliUserSearchResult: Identifiable, Hashable, Codable, Sendable {

// Line 160 — BiliSearchSuggestion
struct BiliSearchSuggestion: Identifiable, Hashable, Decodable, Sendable {

// Line 200 — BiliAllSearchResults
struct BiliAllSearchResults: Sendable {

// Line 220 — BiliRelation (enum, only needs Sendable on the type)
enum BiliRelation: Int, Codable, Hashable, Sendable {

// Line 259 — BiliAISummary
struct BiliAISummary: Codable, Hashable, Sendable {

// Line 345, 395, 426, 452 — BiliAISummaryChapter / Bullet / Subtitle / SubtitleLine
struct BiliAISummaryChapter: Codable, Hashable, Identifiable, Sendable {
struct BiliAISummaryBullet: Codable, Hashable, Identifiable, Sendable {
struct BiliAISummarySubtitle: Codable, Hashable, Identifiable, Sendable {
struct BiliAISummarySubtitleLine: Codable, Hashable, Identifiable, Sendable {

// Line 487 — BiliPlayback
struct BiliPlayback: Hashable, Sendable {

// Line 539 — LocalPlaybackContext
struct LocalPlaybackContext: Hashable, Sendable {

// Line 570 — DownloadRecord
struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {

// Line 628 — BiliDashSource
struct BiliDashSource: Hashable, Codable, Sendable {

// Line 719 — BiliLiveRoom
struct BiliLiveRoom: Identifiable, Hashable, Sendable {

// Line 741 — BiliAppConfig
struct BiliAppConfig: Hashable, Sendable {

// Line 756 — BiliLiveStreamFormat (enum)
enum BiliLiveStreamFormat: String, Codable, CaseIterable, Identifiable, Sendable {

// Line 773 — BiliLivePlayback
struct BiliLivePlayback: Hashable, Sendable {

// Line 798 — DynamicPostKind (enum)
enum DynamicPostKind: String, Codable, Hashable, Sendable {

// Line 815, 825, 832, 853, 871, 877, 884, 889, 897, 903, 924, 959, 992, 1026, 1055
struct BiliComment: Identifiable, Hashable, Sendable {
struct CommentPage: Hashable, Sendable {
struct DynamicPost: Identifiable, Hashable, Sendable {
struct DynamicFeedPage: Hashable, Sendable {
struct HistoryCursorState: Hashable, Sendable {
struct HistoryEntry: Identifiable, Hashable, Sendable {
struct HistoryPageResult: Hashable, Sendable {
struct FavoriteFolderSummary: Identifiable, Hashable, Sendable {
struct FavoriteFolderVideosPage: Hashable, Sendable {
struct ReplyRoute: Hashable, Sendable {
enum UPProfileRoute: Hashable, Sendable {
enum CommentSort: String, CaseIterable, Identifiable, Codable, Sendable {
struct BiliLyricInfo: Hashable, Codable, Sendable {
struct BiliLyricTrack: Hashable, Codable, Sendable {
struct BiliLyricLine: Hashable, Codable, Identifiable, Sendable {
struct BiliDanmakuItem: Hashable, Codable, Identifiable, Sendable {

// Line 1069 — MusicRoute (enum)
enum MusicRoute: Hashable, Sendable {
```

- [ ] **Step 4: Apply the same pattern in the other files**

For each of `ViewModels.swift`, `AccountContentViews.swift`, `UPProfileView.swift`, `SponsorBlockModels.swift`, `PlayerView.swift`, `MusicService.swift`, `PaladalaRepository.swift`, `BilibiliAPIClient.swift`, `SponsorBlockService.swift`, `FollowNotificationService.swift`, `Shared/LiveRoomActivityAttributes.swift`: run the same `grep` to find type declarations, skip any that hold non-`Sendable` references, and add `, Sendable` to the conformance list. For `LiveRoomActivityAttributes` (in `Shared/LiveRoomActivityAttributes.swift`): add `Sendable` to both the outer `ActivityAttributes` struct and its nested `ContentState` (the widget extension in `PaladalaWidget/LiveActivityWidget.swift` consumes both — Swift 6 will reject the widget if the attributes are not `Sendable`).

- [ ] **Step 5: Verify by static review**

Open each modified file and confirm:
- Every value-type `struct`/`final class`/`enum` that crosses an actor boundary now declares `Sendable`.
- No type was annotated `Sendable` while still holding a non-`Sendable` stored property (the compiler will reject this in task 5 — but a pre-check here saves a CI round trip).
- No new compile errors visible to the eye (a type that became `Sendable` does not require other sites to change in this commit).

```bash
git diff --stat HEAD -- ios/
```
Expected: a list of modified files, all of which have only added `, Sendable` to type declarations.

- [ ] **Step 6: Commit**

```bash
git add ios/Paladala/Paladala/Models.swift \
        ios/Paladala/Paladala/ViewModels.swift \
        ios/Paladala/Paladala/AccountContentViews.swift \
        ios/Paladala/Paladala/UPProfileView.swift \
        ios/Paladala/Paladala/SponsorBlockModels.swift \
        ios/Paladala/Paladala/PlayerView.swift \
        ios/Paladala/Paladala/MusicService.swift \
        ios/Paladala/Paladala/PaladalaRepository.swift \
        ios/Paladala/Paladala/BilibiliAPIClient.swift \
        ios/Paladala/Paladala/SponsorBlockService.swift \
        ios/Paladala/Paladala/FollowNotificationService.swift \
        ios/Paladala/Paladala/Shared/LiveRoomActivityAttributes.swift \
        ios/Paladala/PaladalaWidget/LiveActivityWidget.swift

git commit -m "feat(swift6): add Sendable conformances to data models

Pre-migration step for SWIFT_VERSION 5.0 → 6.0. All cross-actor
data types (Models.swift, view-model DTOs, response types) now
declare Sendable. No escape hatches; this is a real conformance
on real value types. Compiles under Swift 5.0 strict mode."
```

---

## Task 2: `@MainActor` on remaining `ObservableObject`s

**Files:**
- Modify: `ios/Paladala/Paladala/ViewModels.swift` (`HomeViewModel`, `VideoDetailViewModel`, `LiveViewModel`, `ReplyListViewModel`)
- Modify: `ios/Paladala/Paladala/AccountContentViews.swift` (`DynamicFeedViewModel`, `HistoryListViewModel`, `FavoriteFoldersViewModel`, `FavoriteFolderVideosViewModel`, `WatchLaterViewModel`)
- Modify: `ios/Paladala/Paladala/MusicService.swift` (`MusicViewModel`)
- Modify: `ios/Paladala/Paladala/UPProfileView.swift` (`UPProfileViewModel`)
- Modify: `ios/Paladala/Paladala/SponsorBlockManager.swift` (`SponsorBlockManager`)
- Modify: `ios/Paladala/Paladala/ProfileSettingsView.swift` (`ProfileViewModel`)
- Modify: `ios/Paladala/Paladala/AppRouter.swift` (`AppRouter`)
- Modify: `ios/Paladala/Paladala/NetworkMonitor.swift` (`NetworkMonitor`)
- Modify: `ios/Paladala/Paladala/HomeView.swift` (`ShortVideoFeedViewModel`)
- Modify: `ios/Paladala/Paladala/PaladalaRepository.swift` (judge per case — see step 3)

**Interfaces:**
- Consumes: task 1's `Sendable` data types (the view models' published state is now `Sendable`).
- Produces: every `ObservableObject` that owns UI state is `@MainActor`-isolated, which task 5's Swift 6 flip requires to avoid isolation errors.

- [ ] **Step 1: Inventory all `ObservableObject` declarations**

Run:
```bash
grep -rnE 'class .*ObservableObject|: ObservableObject' \
  ios/Paladala/Paladala/ --include='*.swift'
```
Expected: ~39 hits. Cross off the 8 already `@MainActor` (`DownloadStore`, `DeviceInfo`, `ICloudSync`, `LiveActivityCoordinator`, `MiniPlayerStore`, `WatchSession`, `UPProfileView`, `InlineAVPlayerView`). The remaining ~31 need evaluation.

- [ ] **Step 2: Apply `@MainActor` to UI-state `ObservableObject`s**

For each remaining `ObservableObject`, default to marking the class `@MainActor`. Pattern:

```swift
@MainActor
final class HomeViewModel: ObservableObject {
    // existing body unchanged
}
```

When the class already uses `Task { @MainActor in … }` inside its methods, the per-call `Task` can stay (defense in depth) or be removed in favor of the class-level annotation — leave the per-call `Task` alone to minimize the diff. The goal is **only to add the class-level annotation**, not to refactor the existing `Task` blocks (those are task 3's scope).

Concrete edits:
- `ViewModels.swift`: `@MainActor` on `HomeViewModel`, `VideoDetailViewModel`, `LiveViewModel`, `ReplyListViewModel`.
- `AccountContentViews.swift`: `@MainActor` on `DynamicFeedViewModel`, `HistoryListViewModel`, `FavoriteFoldersViewModel`, `FavoriteFolderVideosViewModel`, `WatchLaterViewModel`.
- `MusicService.swift`: `@MainActor` on `MusicViewModel`.
- `UPProfileView.swift`: `@MainActor` on `UPProfileViewModel`.
- `SponsorBlockManager.swift`: `@MainActor` on `SponsorBlockManager`.
- `ProfileSettingsView.swift`: `@MainActor` on `ProfileViewModel`.
- `AppRouter.swift`: `@MainActor` on `AppRouter`.
- `NetworkMonitor.swift`: `@MainActor` on `NetworkMonitor`.
- `HomeView.swift`: `@MainActor` on `ShortVideoFeedViewModel`.

- [ ] **Step 3: Handle `PaladalaRepository` separately**

`PaladalaRepository` may be a service object (not a UI-state owner). Read its declaration in `ios/Paladala/Paladala/PaladalaRepository.swift`:
- If it inherits from `ObservableObject` and publishes UI state: add `@MainActor` like the others.
- If it is a plain service object (no `@Published` properties, called only from `await` contexts): **leave it non-isolated**. The compiler will infer isolation from the call sites in task 5.
- If it has both UI-state and service-method responsibilities: split it (out of scope for this PR) — for now, prefer `@MainActor` and accept that the service methods become main-actor-isolated. Document the choice in the commit message.

- [ ] **Step 4: Verify by static review**

Open each modified file and confirm:
- Every `ObservableObject` that publishes UI-bound state now has `@MainActor` on the class.
- No `@MainActor` was added to a class that legitimately needs to be called from a non-isolated context with non-`Sendable` state (the compiler will reject this in task 5 — pre-check here).

```bash
git diff HEAD~1..HEAD --stat -- '*.swift'
```
Expected: the same set of files as task 1 (no new files), all with `@MainActor` added on class lines.

- [ ] **Step 5: Commit**

```bash
git add ios/Paladala/Paladala/ViewModels.swift \
        ios/Paladala/Paladala/AccountContentViews.swift \
        ios/Paladala/Paladala/MusicService.swift \
        ios/Paladala/Paladala/UPProfileView.swift \
        ios/Paladala/Paladala/SponsorBlockManager.swift \
        ios/Paladala/Paladala/ProfileSettingsView.swift \
        ios/Paladala/Paladala/AppRouter.swift \
        ios/Paladala/Paladala/NetworkMonitor.swift \
        ios/Paladala/Paladala/HomeView.swift \
        ios/Paladala/Paladala/PaladalaRepository.swift

git commit -m "feat(swift6): mark remaining ObservableObjects @MainActor

Pre-migration step for SWIFT_VERSION 5.0 → 6.0. All UI-state
ObservableObjects are now @MainActor-isolated. Compiles under
Swift 5.0 strict mode; pre-resolves the isolation errors that
would surface in task 5's language-mode flip."
```

---

## Task 3: Replace `DispatchQueue` with structured concurrency

**Files:**
- Modify: `ios/Paladala/Paladala/FollowNotificationService.swift`
- Modify: `ios/Paladala/Paladala/DeviceInfo.swift`
- Modify: `ios/Paladala/Paladala/MusicHomeView.swift`
- Modify: `ios/Paladala/Paladala/LaunchMetrics.swift`
- Modify: `ios/Paladala/Paladala/PaladalaApp.swift`
- Modify: `ios/Paladala/Paladala/DiagnosticLogger.swift`
- Modify: `ios/Paladala/Paladala/LocalHLSProxyServer.swift` (highest complexity — see step 4)

**Interfaces:**
- Consumes: task 2's `@MainActor` view models. `Task { @MainActor in … }` is the target for any main-thread hop.
- Produces: zero `DispatchQueue` call sites in the app target. Serial-queue-protected state is now an `actor`. Cross-boundary callers use `await`.

- [ ] **Step 1: Inventory all `DispatchQueue` call sites**

Run:
```bash
grep -rnE 'DispatchQueue\.' ios/Paladala/Paladala/ --include='*.swift'
```
Expected: 9 sites across 7 files (per spec). Some may be `DispatchQueue.main.async` (UI hop), some `DispatchQueue.global().async` (background), some `DispatchQueue(label:)` (custom serial queue protecting state).

- [ ] **Step 2: Replace `DispatchQueue.main.async` with `Task { @MainActor in … }`**

For each `DispatchQueue.main.async { … }` site, replace with:

```swift
// Before
DispatchQueue.main.async {
    self.someState = newValue
}

// After
Task { @MainActor in
    self.someState = newValue
}
```

Files expected to contain at least one such site: `MusicHomeView.swift`, `PaladalaApp.swift`, possibly `LaunchMetrics.swift`.

- [ ] **Step 3: Replace `DispatchQueue.global().async` with `Task.detached` or pure `async`**

For each `DispatchQueue.global(qos: .userInitiated).async { … }` site, replace with either:

```swift
// Option A — fire-and-forget background work
Task.detached(priority: .userInitiated) {
    // body unchanged
}

// Option B — if the work is awaitable, change the surrounding function to `async`
// and call it with `await`
```

`LocalHLSProxyServer.swift` has one `DispatchQueue.global(qos: .userInitiated).asyncAfter` site at line 4274 — convert to `Task.detached(priority: .userInitiated) { try? await Task.sleep(nanoseconds: …) }` or to a structured sleep inside the calling `async` function.

- [ ] **Step 4: Convert serial-queue-protected state to `actor`**

For any custom serial queue (`let q = DispatchQueue(label: "…")`) that protects mutable state, introduce a small `actor`. Pattern:

```swift
// Before
final class ConnectionRegistry {
    private let q = DispatchQueue(label: "ConnectionRegistry.q")
    private var connections: [String: Connection] = [:]
    func add(_ c: Connection, for key: String) {
        q.sync { connections[key] = c }
    }
    func get(_ key: String) -> Connection? {
        q.sync { connections[key] }
    }
}

// After
actor ConnectionRegistry {
    private var connections: [String: Connection] = [:]
    func add(_ c: Connection, for key: String) {
        connections[key] = c
    }
    func get(_ key: String) -> Connection? {
        connections[key]
    }
}
```

Cross-boundary callers change from `registry.get(key)` to `await registry.get(key)`. The compiler enforces that `actor` state is only touched from inside the actor.

`LocalHLSProxyServer` is the highest-complexity case — its connection state, in-flight ranges, and on-disk segment metadata are all candidates for `actor` extraction. Identify the protected state, propose an `actor` per concern, and apply.

- [ ] **Step 5: Verify by static review**

Open each modified file and confirm:
- No `DispatchQueue.` calls remain:
  ```bash
  grep -rnE 'DispatchQueue\.' ios/Paladala/Paladala/ --include='*.swift'
  ```
  Expected: no output.
- Every new `Task { @MainActor in … }` does not retain `self` strongly across a long-lived task (use `[weak self]` where the task can outlive the owner). Audit each capture.
- Every new `actor` has its cross-boundary callers updated to `await`.

- [ ] **Step 6: Commit**

```bash
git add ios/Paladala/Paladala/FollowNotificationService.swift \
        ios/Paladala/Paladala/DeviceInfo.swift \
        ios/Paladala/Paladala/MusicHomeView.swift \
        ios/Paladala/Paladala/LaunchMetrics.swift \
        ios/Paladala/Paladala/PaladalaApp.swift \
        ios/Paladala/Paladala/DiagnosticLogger.swift \
        ios/Paladala/Paladala/LocalHLSProxyServer.swift

git commit -m "refactor(swift6): replace DispatchQueue with structured concurrency

Pre-migration step for SWIFT_VERSION 5.0 → 6.0. DispatchQueue.main
hops become Task { @MainActor in … }; background queues become
Task.detached; serial-queue-protected state becomes actor. Zero
DispatchQueue sites remain in the app target. Compiles under
Swift 5.0 strict mode."
```

---

## Task 4: Fix closure captures and protocol `Sendable` conformances

**Files:**
- Modify: `ios/Paladala/Paladala/Models.swift` (protocol declarations)
- Modify: `ios/Paladala/Paladala/SponsorBlockModels.swift` (protocols)
- Modify: `ios/Paladala/Paladala/MusicService.swift` (protocols)
- Modify: any file in `ios/Paladala/Paladala/` with `@Sendable` closures, `URLSession` callbacks, or `Task.detached` call sites
- Modify: `ios/Paladala/PaladalaTests/*.swift` (closure captures in test setUp/tearDown that capture the SUT)

**Interfaces:**
- Consumes: tasks 1–3's annotations. Closure capture audit must respect the new actor isolations.
- Produces: every protocol with all-`Sendable` conformers gains `: Sendable`; every cross-actor closure captures only `Sendable` state.

- [ ] **Step 1: Audit protocol declarations**

Run:
```bash
grep -rnE '^protocol ' ios/Paladala/Paladala/ --include='*.swift'
```
For each protocol, check whether all conforming types are `Sendable` (they should be after task 1). If yes, add `: Sendable` to the protocol declaration:

```swift
// Before
protocol XService {
    func fetch() async -> XData
}

// After (only if all XData and the conformers are Sendable)
protocol XService: Sendable {
    func fetch() async -> XData
}
```

Concretely, expect edits in `Models.swift`, `SponsorBlockModels.swift`, `MusicService.swift`. Skip protocols whose conformers are not yet `Sendable` (those are deferred — task 5 will surface them as errors and they'll be fixed in this same task's follow-up).

- [ ] **Step 2: Audit closure captures in `URLSession` / `Task` / `Task.detached` call sites**

Run:
```bash
grep -rnE 'URLSession.*\.(dataTask|upload|download)|Task\.detached|Task \{' \
  ios/Paladala/Paladala/ --include='*.swift'
```
For each closure, check its capture list. If the closure captures non-`Sendable` state (a class instance that is not `Sendable`, a closure variable that is not `@Sendable`, etc.), fix one of three ways:

1. **Move the captured state into a `Sendable` owner** (e.g., a value-type snapshot).
2. **Use `[weak self]` and re-enter isolation explicitly**:
   ```swift
   Task { [weak self] in
       guard let self else { return }
       let result = await self.compute()
       await MainActor.run { self.publish(result) }
   }
   ```
3. **Hoist the closure's logic into a method on the owner and call it via `await`**:
   ```swift
   // Before
   Task.detached {
       let result = await heavyCompute()
       self.callback(result)  // not Sendable
   }
   // After
   await self.heavyComputeAsync()  // self is the owner, method is on the owner
   ```

- [ ] **Step 3: Audit stored `@Sendable` closures**

Run:
```bash
grep -rnE '@Sendable' ios/Paladala/Paladala/ --include='*.swift'
```
For each `@Sendable` stored property whose closure type does not actually have `Sendable` semantics, fix the closure's capture list (apply the same three patterns as step 2).

- [ ] **Step 4: Audit test target for closure captures**

Run:
```bash
grep -rnE 'Task \{|Task\.detached|XCTestCase' ios/Paladala/PaladalaTests/ --include='*.swift'
```
Test setUp/tearDown and async test bodies that capture `self` (the test case) cross actor boundaries. XCTest's `XCTestCase` is not `Sendable` in Swift 6. Fix the same three ways as step 2 — usually `[weak self]` + re-entry works for tests.

- [ ] **Step 5: Verify by static review**

Open each modified file and confirm:
- Every protocol that has only `Sendable` conformers now declares `Sendable`.
- Every cross-actor closure captures only `Sendable` state (or uses `[weak self]` + explicit re-entry).
- No new compile errors visible to the eye.

```bash
git diff HEAD~1..HEAD --stat -- '*.swift'
```
Expected: edits to the listed files only, with no `@preconcurrency`, `@unchecked Sendable`, or `nonisolated(unsafe)` introduced (banned by policy).

- [ ] **Step 6: Commit**

```bash
git add ios/Paladala/Paladala/Models.swift \
        ios/Paladala/Paladala/SponsorBlockModels.swift \
        ios/Paladala/Paladala/MusicService.swift \
        ios/Paladala/Paladala/*.swift \
        ios/Paladala/PaladalaTests/*.swift

git commit -m "fix(swift6): closure captures and protocol Sendable conformances

Pre-migration step for SWIFT_VERSION 5.0 → 6.0. Protocols whose
conformers are all Sendable now declare Sendable. Cross-actor
closure captures are fixed via Sendable snapshots, [weak self]
+ explicit re-entry, or hoisted async methods. No escape hatches
introduced. Compiles under Swift 5.0 strict mode."
```

---

## Task 5: Flip `SWIFT_VERSION = 6.0` and update CHANGELOG

**Files:**
- Modify: `ios/Paladala/Paladala.xcodeproj/project.pbxproj` (6 occurrences of `SWIFT_VERSION = 5.0;` → `SWIFT_VERSION = 6.0;`)
- Modify: `CHANGELOG.md` (add migration entry under unreleased)

**Interfaces:**
- Consumes: tasks 1–4's pre-migration. This is the language-mode flip.
- Produces: a build configuration that requires Swift 6 conformance. Any errors that tasks 1–4 missed are fixed in this commit (fix-forward).

- [ ] **Step 1: Locate the 6 `SWIFT_VERSION` lines**

Run:
```bash
grep -nE 'SWIFT_VERSION = 5\.0' ios/Paladala/Paladala.xcodeproj/project.pbxproj
```
Expected: 6 hits, one per build configuration (Debug + Release for each of the 3 targets).

- [ ] **Step 2: Flip each line to `SWIFT_VERSION = 6.0`**

In the pbxproj file, replace every `SWIFT_VERSION = 5.0;` with `SWIFT_VERSION = 6.0;`. Verify:

```bash
grep -nE 'SWIFT_VERSION = 5\.0|SWIFT_VERSION = 6\.0' \
  ios/Paladala/Paladala.xcodeproj/project.pbxproj
```
Expected: zero hits for `5.0`, six hits for `6.0`.

- [ ] **Step 3: Update CHANGELOG**

Open `CHANGELOG.md`. Add a new entry under the unreleased / next-version section. Match the existing format (read the file first to follow its conventions). The entry should mention the Swift 6 language-mode upgrade and reference PR-C.

- [ ] **Step 4: Fix-forward any errors tasks 1–4 missed**

Push the 5 commits to `working` and watch the `ios-unsigned-ipa.yml` CI run. If the run is green: done. If the run is red: read the error log, locate the failing file and line, apply the minimum fix, amend the commit (or push a follow-up commit on `working`), and re-push. Common remaining issues and their fixes:

| Error pattern | Fix |
|---|---|
| `Type 'X' does not conform to protocol 'Sendable'` | Add `: Sendable` to `X` (or its stored properties if it's a generic). Should have been caught in task 1. |
| `Call to main actor-isolated instance method in a synchronous nonisolated context` | Add `@MainActor` to the calling function, or use `Task { @MainActor in … }`. |
| `Reference to property 'x' is not concurrency-safe because non-'Sendable' type 'X' may have shared mutable state` | Make `X` `Sendable` (snapshot the value) or guard the access with an actor. |
| `Expression is 'async' but is not marked with 'await'` | Add `await` to the call (every cross-actor hop). |
| `Stored property 'x' of 'Sendable'-conforming class 'Y' is mutable` | Mark `x` `nonisolated(unsafe)` only if the policy allows it (it doesn't — fix the property to be `let`, or move the state to an actor). |

Iterate the fix-forward loop until CI is green. Each iteration is a new commit (or an amend of the prior) on the same `working` branch.

- [ ] **Step 5: Compile-check `PaladalaWidget` and `PaladalaTests` targets**

Once `ios-unsigned-ipa.yml` is green, run on a Mac (the user) or on the CI machine:

```bash
xcodebuild -project ios/Paladala/Paladala.xcodeproj \
  -scheme PaladalaWidget -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

```bash
xcodebuild -project ios/Paladala/Paladala.xcodeproj \
  -scheme PaladalaTests -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Both must succeed. If either fails, fix the same way as step 4 (fix-forward on `working`).

- [ ] **Step 6: Confirm Definition of Done**

```bash
# No escape hatches in the migration's diff
git diff $(git rev-list -n1 --before='2026-07-08' working)~1..working -- 'ios/**/*.swift' \
  | grep -E '@preconcurrency|@unchecked Sendable|nonisolated\(unsafe\)'
```
Expected: no output (the grep finds nothing). If it does find matches, revert the offending line and re-push.

```bash
git log --oneline -5
```
Expected: 5 commit titles matching tasks 1–5 (plus any fix-forward commits from step 4/5).

```bash
git status --short --branch
```
Expected: clean tree, `working...origin/working` with no ahead/behind (after `git push`).

- [ ] **Step 7: Commit + push**

```bash
git add ios/Paladala/Paladala.xcodeproj/project.pbxproj CHANGELOG.md
git commit -m "build: upgrade SWIFT_VERSION 5.0 → 6.0

Final commit of PR-C. Pre-migrated in 4 prior commits (Sendable
conformances, @MainActor on remaining ObservableObjects,
DispatchQueue→structured concurrency, closure/protocol fixes).
No escape hatches (@preconcurrency, @unchecked Sendable,
nonisolated(unsafe)) used anywhere in the migration.

Co-Authored-By: Claude <noreply@anthropic.com>"

git push origin working
```

---

## Final verification

After all 5 commits are on `working`:

- [ ] **`ios-unsigned-ipa.yml` is green** (PR-C's primary signal).
- [ ] **`PaladalaWidget` xcodebuild succeeds** locally on a Mac.
- [ ] **`PaladalaTests` xcodebuild succeeds** locally on a Mac.
- [ ] **No escape hatches in the diff** (the grep in task 5 step 6 returns nothing).
- [ ] **CHANGELOG updated** under unreleased.
- [ ] **No ad-hoc commits in the wrong place** — `git log` shows 5 task-shaped commits + any fix-forward commits, in order, on `working`.
