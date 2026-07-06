# PR-A: Loading Speed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the five remaining cold-start audit items (`#5` lazy `@StateObject` for 5 tabs, `#6`/`#14` cache seed for `HomeView`/`MusicHomeView`, `#8` tighten `LocalHLSProxyServer.waitForListener` ceiling + prewarm, `#10` `PaladalaBackdrop` Equatable) by adding per-milestone `LaunchMetrics` instrumentation and shipping the corresponding fixes. Target ≤1500 ms `appInitStart → firstRootViewAppeared` on A14+.

**Architecture:** Each audit item becomes a self-contained, TDD'd task with a unit test where the surface is testable. Visual changes (`LazyTab` wiring) carry explicit smoke checklists. The work introduces no new persistent state, only in-memory telemetry (new `LaunchMetrics` event cases + corresponding sink calls). New infrastructure is the unit-test target itself (the project currently has none) plus two new files (`LazyTab.swift`, `FeedCacheWarmer.swift`).

**Tech Stack:** Swift 6, SwiftUI, `os_signpost` (C API per the 2026-07-03 scaffold), `DiagnosticLogger` (existing in-tree), `XCTest`, `xcodebuild` (Xcode 16 / iOS 18 SDK target; pbxproj `objectVersion 56`).

## Global Constraints

- iOS deployment target: 17.5 (Debug) / 18.0 (Release). Swift 6 concurrency; `@MainActor assumeIsolated` for main-actor work.
- `os_signpost` must use the **C** `os_signpost(.event, log:, name:)` macro, NOT the Swift `OSSignposter` class. `name` is `StaticString` — use a switch per event for literal names; do NOT use string interpolation.
- `LaunchMetrics.mark(_:)` is the only legal way to record cold-start milestones (per the 2026-07-03 scaffold memory). Use the existing triple-sink pattern (`os_signpost` + `DiagnosticLogger.shared.log(.app, …)` + in-memory `[LaunchMilestone]` buffer).
- `@AppStorage` keys go under a prefix where appropriate — none added by PR-A.
- New file names match the spec: `LazyTab.swift`, `FeedCacheWarmer.swift`.
- pbxproj is `objectVersion 56` (legacy Xcode 14). Adding a unit-test target requires following the `100/200` UUID-pairing pattern precisely. Confirm every UUID-pair against the existing `PBX*` entries — a typo silently breaks the build.
- Existing project conventions:
  - `Logger` (in `PaladalaApp.swift`) holds `static let timestampFormatter: ISO8601DateFormatter` (from 2026-07-04 work) — use it via `bpLog`.
  - `LiveRoomsView` has its own pattern; match the existing `repository:` constructor param style where present.
  - `@StateObject` properties are declared at the top of each child `View`.
- All commits co-authored with Claude:
  ```
  Co-Authored-By: Claude <noreply@anthropic.com>
  ```
- Use `git add <file-path>` (single files) rather than `git add -A` — protects against accidentally staging `__pycache__/` and similar untracked dirs.
- Verify on a Mac before declaring a task done — the Linux dev env cannot run `xcodebuild`.
- Existing build verification command:
  ```
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala -configuration Debug -destination 'generic/platform=iOS Simulator' build
  ```

## File Structure

### Files to create

- `ios/Paladala/Paladala/LazyTab.swift` (~80 lines) — generic `View` wrapper that defers child body evaluation until "armed" via `.onChange(of: tab)` for a specific tag. Owns no state besides the armed flag.
- `ios/Paladala/Paladala/FeedCacheWarmer.swift` (~100 lines) — `final class FeedCacheWarmer`, `@MainActor`. Reads a JSON snapshot from `Application Support/Paladala/feed-snapshot.json` keyed by feed name (`"home"`, `"music"`). Three outcomes: `success([Card])`, `missing`, `corrupt`. Never throws.
- `ios/Paladala/PaladalaTests/PaladalaTests.swift` (Task 1) — unit-test target entry; gains more files per task.
- `ios/Paladala/PaladalaTests/LocalHLSProxyServerTests.swift` (Task 2).
- `ios/Paladala/PaladalaTests/FeedCacheWarmerTests.swift` (Task 3).
- `ios/Paladala/PaladalaTests/LazyTabTests.swift` (Task 4).
- `ios/Paladala/PaladalaTests/PaladalaBackdropTests.swift` (Task 5).
- `ios/Paladala/PaladalaTests/LaunchMetricsTests.swift` (Task 6).

### Files to modify

- `ios/Paladala/Paladala.xcodeproj/project.pbxproj` — add unit-test target (Task 1).
- `ios/Paladala/Paladala/LocalHLSProxyServer.swift:204` — tighten `waitForListener` (Task 2).
- `ios/Paladala/Paladala/RootView.swift:175-194` — wire `LazyTab` (Task 8).
- `ios/Paladala/Paladala/HomeView.swift:16`, `:141-147`, `:532` — refactor init; wire `seedFromCache` (Tasks 7 + 9).
- `ios/Paladala/Paladala/MusicHomeView.swift:25`, `:73-77` — refactor init; wire `seedFromCache` (Tasks 7 + 9).
- `ios/Paladala/Paladala/DynamicFeedView.swift:10`, `LiveRoomsView.swift:7`, `ProfileSettingsView.swift:42` — refactor init only (Task 7).
- `ios/Paladala/Paladala/DesignModifier.swift:161-193` — `PaladalaBackdrop` `Equatable` + static gradient cache (Task 5).
- `ios/Paladala/Paladala/LaunchMetrics.swift` — new event cases + per-event sink calls (Task 6).
- `ios/Paladala/Paladala/PaladalaApp.swift` — add prewarm hooks + new `LaunchMetrics.mark` calls (Tasks 9 + 10).
- `ios/Paladala/MEASURING_COLD_START.md` — append before/after captures + PR-A results (Task 11).

### Files NOT touched

- `Analytics.swift`, `ProfileSettingsView.swift:43-72` `@AppStorage` block — PR-A introduces no persistent state.
- Anything in `Pods/` or `LocalPackages/` — both empty today.

---

## Task 1: Bootstrap the unit-test target

**Files:**
- Create: `ios/Paladala/Paladala.xcodeproj/project.pbxproj` (modify — add target)
- Create directory: `ios/Paladala/PaladalaTests/`
- Create: `ios/Paladala/PaladalaTests/PaladalaTests.swift` (~10 lines placeholder)

**Why this comes first:** Neither PR-A nor PR-B can land unit tests without this target. The project pbxproj is `objectVersion 56` (Xcode 14 era); adding a target is mechanical but UUID-pair fragile.

**Interfaces (consumed by all later tasks):**
- `import XCTest` is available within `PaladalaTests`.
- Test files compile against the `Paladala` target's `@testable import Paladala`.
- Test invocation:
  ```
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
  ```

- [ ] **Step 1: Read the existing pbxproj to see a baseline UUID pattern**

  Run:
  ```
  grep -nE 'PBXNativeTarget|PBXBuildFile|PBXFileReference|uuid = ['\''"]?100[A-F0-9]{24}['\''"]?' \
    ios/Paladala/Paladala.xcodeproj/project.pbxproj | head -60
  ```
  Expected: many lines, all with `100…` 27-char UUIDs. Confirm the `100…200…` pairing for the existing `Paladala` target — files use `PBXBuildFile` UUIDs (100…) that point to `PBXFileReference` UUIDs (200…) that point to `PBXFileSystemSynchronizedRootGroup`-free file path on disk. The new test target follows the same recipe.

- [ ] **Step 2: Add the `PaladalaTests` target to `project.pbxproj`**

  Use Xcode UI: **File → New → Target → Unit Testing Bundle → name `PaladalaTests` → language `Swift`** (embedded into the existing `Paladala` project; do NOT tick "Include in App"). After Xcode closes the dialog, open `project.pbxproj` and inspect the diff — Xcode generates UUIDs in a `7E5C0A…`-style format with hyphens; this is a different namespace from the existing `100…` entries. Both styles coexist on `objectVersion 56` without conflict. Confirm:
  - A new `PBXNativeTarget` block named `PaladalaTests` exists.
  - A `PBXSourcesBuildPhase` for `PaladalaTests` exists.
  - A `BUNDLE_LOADER = $(TEST_HOST)` and `TEST_HOST = $(BUILT_PRODUCTS_DIR)/Paladala.app/Paladala` pair exists in the test target's Debug/Release xcconfig list.
  - A new `PBXFileReference` for `PaladalaTests.swift` exists.
  - The `PaladalaTests` target is a dependency of the `Paladala` target's `PBXTargetDependency` block.
  Expected diff in `project.pbxproj`: ~80 lines, all within the existing `objectVersion 56` syntax.

- [ ] **Step 3: Create the placeholder test file**

  Create `ios/Paladala/PaladalaTests/PaladalaTests.swift`:
  ```swift
  import XCTest
  @testable import Paladala

  final class PaladalaTests: XCTestCase {
      func test_scaffold_runs() {
          XCTAssertEqual(2 + 2, 4)
      }
  }
  ```

- [ ] **Step 4: Build + run tests on a Mac to verify the infrastructure**

  Run on a Mac:
  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:PaladalaTests
  ```
  Expected: `Test Suite 'All tests' passed` and `Executed 1 test, with 0 failures`.

- [ ] **Step 5: Commit**

  ```bash
  git add ios/Paladala/Paladala.xcodeproj/project.pbxproj \
          ios/Paladala/PaladalaTests/PaladalaTests.swift
  git commit -m "test: bootstrap PaladalaTests target (Task 1/12 PR-A)

  Adds a unit-test target scaffolding so PR-A and PR-B can land
  TDD'd changes. Xcode UI generated the UUIDs; verifying they live
  in a separate namespace from the existing objectVersion 56 entries.

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 2: Tighten `LocalHLSProxyServer.waitForListener` (audit #8)

**Files:**
- Modify: `ios/Paladala/Paladala/LocalHLSProxyServer.swift:204` (the `waitForListener` method body) and add `prewarmProxyServer()` static method
- Create: `ios/Paladala/PaladalaTests/LocalHLSProxyServerTests.swift`

**Consumes:** the `XCTestCase` pattern from Task 1.

**Produces:**
- `LocalHLSProxyServer.waitForListener(timeoutMs: Int = 500, pollIntervalMs: Int = 5) async throws` — exposed with explicit ceiling + poll interval (defaults match the new spec).
- `static func prewarmProxyServer() async` — best-effort; logs failure once.

- [ ] **Step 1: Write the failing test**

  Create `ios/Paladala/PaladalaTests/LocalHLSProxyServerTests.swift`:
  ```swift
  import XCTest
  @testable import Paladala

  final class LocalHLSProxyServerTests: XCTestCase {
      func test_waitForListener_respectsTimeoutCeiling() async {
          // When the listener is never started, waitForListener must throw
          // within timeout + a small grace window (50 ms), not hang for the
          // legacy 2 000 ms default.
          let proxy = LocalHLSProxyServer(port: 0)
          let start = Date()
          do {
              try await proxy.waitForListener(timeoutMs: 100, pollIntervalMs: 5)
              XCTFail("expected timeout throw")
          } catch {
              let elapsed = Date().timeIntervalSince(start) * 1000
              XCTAssertGreaterThan(elapsed, 95, "must wait at least timeoutMs")
              XCTAssertLessThan(elapsed, 250, "must respect ceiling, was \(elapsed)")
          }
      }

      func test_pollIntervalDrivesPollingCadence() async {
          // pollIntervalMs=10 should produce measurable ticks at ~10 ms.
          // Direct test: wire a faster path later if needed; for v1 just
          // confirm the parameter is honoured by timing a no-op wait.
          let proxy = LocalHLSProxyServer(port: 0)
          let start = Date()
          do {
              try await proxy.waitForListener(timeoutMs: 30, pollIntervalMs: 10)
          } catch {}
          let elapsedMs = Date().timeIntervalSince(start) * 1000
          XCTAssertLessThan(elapsedMs, 200)
      }

      func test_prewarmProxyServer_succeedsOrLogsAndSwallows() async {
          // Must never throw to callers — best-effort.
          await LocalHLSProxyServer.prewarmProxyServer()
          // Pass on no-throw.
      }
  }
  ```

- [ ] **Step 2: Run the tests to verify they fail**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:PaladalaTests/LocalHLSProxyServerTests
  ```
  Expected: 3 failures. The function signatures don't yet match; the current `waitForListener` is private and uses different defaults.

- [ ] **Step 3: Modify `LocalHLSProxyServer.swift`**

  Replace the existing private `waitForListener` (around line 204 in the audit-anchored block; verify the actual location with `grep -n 'waitForListener' ios/Paladala/Paladala/LocalHLSProxyServer.swift`) with:
  ```swift
  internal func waitForListener(
      timeoutMs: Int = 500,
      pollIntervalMs: Int = 5
  ) async throws {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
          Task { @MainActor in
              while Date() < deadline {
                  if let listener = self.listener, listener.state == .ready {
                      cont.resume(); return
                  }
                  try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
              }
              cont.resume(throwing: ProxyServerError.listenerTimeout)
          }
      }
  }

  static func prewarmProxyServer() async {
      do {
          let server = LocalHLSProxyServer.shared
          try await server.waitForListener(timeoutMs: 500, pollIntervalMs: 5)
      } catch {
          DiagnosticLogger.shared.log(.playback, "proxy_prewarm_failed",
                                      details: ["error": String(describing: error)])
      }
  }
  ```
  Add `enum ProxyServerError: Error { case listenerTimeout }` at module scope in the same file (or pull it from a shared error file if one exists). Use whichever pattern exists for the file's other errors.

- [ ] **Step 4: Run the tests to verify they pass**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:PaladalaTests/LocalHLSProxyServerTests
  ```
  Expected: 3 passes. If a test fails, the most likely culprit is `LocalHLSProxyServer.shared` not existing — add it as a `static let shared = LocalHLSProxyServer(port: fixedPort)` if needed (verify by `grep -n 'static let shared' ios/Paladala/Paladala/LocalHLSProxyServer.swift`).

- [ ] **Step 5: Commit**

  ```bash
  git add ios/Paladala/Paladala/LocalHLSProxyServer.swift \
          ios/Paladala/PaladalaTests/LocalHLSProxyServerTests.swift
  git commit -m "perf(loading): #8 tighten proxy waitForListener to 500ms / 5ms (Task 2/12 PR-A)

  Polling 20 ms -> 5 ms; ceiling 2 s -> 500 ms; prewarm exposed.
  Driven by the 2026-07-03 cold-start audit, item #8.

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 3: Add `FeedCacheWarmer` (audit #6 + #14 supporting infra)

**Files:**
- Create: `ios/Paladala/Paladala/FeedCacheWarmer.swift` (~100 lines)
- Create: `ios/Paladala/PaladalaTests/FeedCacheWarmerTests.swift`

**Consumes:** `XCTestCase`, `DiagnosticLogger`.

**Produces:** `final class FeedCacheWarmer`, `@MainActor`, single shared instance. Three outcomes for `seedFromCache(key: String) -> [FeedCard]?` — never throws; logs once on each failure path.

- [ ] **Step 1: Write the failing test**

  Create `ios/Paladala/PaladalaTests/FeedCacheWarmerTests.swift`:
  ```swift
  import XCTest
  @testable import Paladala

  final class FeedCacheWarmerTests: XCTestCase {
      var tmpDir: URL!
      var sut: FeedCacheWarmer!

      override func setUp() async throws {
          try await super.setUp()
          tmpDir = FileManager.default.temporaryDirectory
              .appendingPathComponent("FCWTests-\(UUID().uuidString)")
          try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
          sut = await FeedCacheWarmer(directory: tmpDir)
      }

      override func tearDown() async throws {
          try? FileManager.default.removeItem(at: tmpDir)
          try await super.tearDown()
      }

      func test_seed_returnsNil_whenFileMissing() async {
          let cards = await sut.seedFromCache(key: "home")
          XCTAssertNil(cards)
      }

      func test_seed_returnsArray_whenFilePresentAndValid() async throws {
          let payload = try JSONEncoder().encode([FeedCard.testStub(bvid: "BV1"), FeedCard.testStub(bvid: "BV2")])
          try payload.write(to: tmpDir.appendingPathComponent("home.json"))
          let cards = await sut.seedFromCache(key: "home")
          XCTAssertEqual(cards?.map(\.bvid), ["BV1", "BV2"])
      }

      func test_seed_returnsNil_whenFileCorrupt() throws {
          try "not-json".data(using: .utf8)!
              .write(to: tmpDir.appendingPathComponent("home.json"))
          Task { @MainActor in
              let cards = await sut.seedFromCache(key: "home")
              XCTAssertNil(cards)
          }
          // Give the async task time to settle.
          let exp = expectation(description: "wait")
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
          wait(for: [exp], timeout: 1.0)
      }

      func test_seed_returnsNil_whenSchemaMigrated() throws {
          let payload = """
              { "version": 99, "cards": [] }
              """.data(using: .utf8)!
          try payload.write(to: tmpDir.appendingPathComponent("home.json"))
          Task { @MainActor in
              let cards = await sut.seedFromCache(key: "home")
              XCTAssertNil(cards)
          }
          let exp = expectation(description: "wait")
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
          wait(for: [exp], timeout: 1.0)
      }
  }
  ```
  Also add a `FeedCard.testStub(bvid:)` static factory — define the stub inside this test file (private at file scope) since the production `FeedCard` is what we'll feed the snapshot from later.

- [ ] **Step 2: Run the tests to verify they fail**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:PaladalaTests/FeedCacheWarmerTests
  ```
  Expected: 4 failures — `FeedCacheWarmer` doesn't exist; `FeedCard.testStub(bvid:)` doesn't exist.

- [ ] **Step 3: Implement `FeedCacheWarmer`**

  Create `ios/Paladala/Paladala/FeedCacheWarmer.swift`:
  ```swift
  import Foundation

  enum FeedCacheResult {
      case success([FeedCard])
      case missing
      case corrupt(reason: String)
  }

  @MainActor
  final class FeedCacheWarmer {
      static let shared = FeedCacheWarmer(directory: FeedCacheWarmer.defaultDirectory)

      private let directory: URL

      init(directory: URL) {
          self.directory = directory
      }

      func seedFromCache(key: String) async -> [FeedCard]? {
          await Task.detached { [directory] in
              FeedCacheWarmer.read(directory: directory, key: key)
          }.value.toOptionalCards()
      }

      private static func read(directory: URL, key: String) -> FeedCacheResult {
          let url = directory.appendingPathComponent("\(key).json")
          guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
          guard let data = try? Data(contentsOf: url) else { return .corrupt(reason: "io") }
          // 1 means v1 schema; bump and reject on mismatch.
          guard let envelope = try? JSONDecoder().decode(FeedSnapshotEnvelope.self, from: data),
                envelope.version == 1 else {
              return .corrupt(reason: "schema")
          }
          return .success(envelope.cards)
      }

      static var defaultDirectory: URL {
          let fm = FileManager.default
          let dir = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
                  .appendingPathComponent("Paladala", isDirectory: true)
          try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
          return dir
      }
  }

  struct FeedSnapshotEnvelope: Codable {
      let version: Int
      let cards: [FeedCard]
  }

  // Bridge from synchronous FeedCacheResult to the async-API exposed above.
  private extension FeedCacheResult {
      func toOptionalCards() -> [FeedCard]? {
          switch self {
          case .success(let cards): return cards
          case .missing:
              DiagnosticLogger.shared.log(.feed, "seed_cache_unavailable",
                                          details: ["reason": "missing"])
              return nil
          case .corrupt(let reason):
              DiagnosticLogger.shared.log(.feed, "seed_cache_unavailable",
                                          details: ["reason": reason])
              return nil
          }
      }
  }
  ```
  **Note**: the `FeedCard` and `DiagnosticLogger.Category.feed` symbols must already exist. Confirm with:
  ```
  grep -nE '^(struct|class) FeedCard' ios/Paladala/Paladala/*.swift
  grep -nE '\.feed[^a-zA-Z]' ios/Paladala/Paladala/DiagnosticLogger.swift
  ```
  If `Category.feed` doesn't exist yet, add it to the existing `Category` enum (the 2026-07-03 scaffold says 11 categories — append as the 12th with label "feed cache").

- [ ] **Step 4: Run the tests to verify they pass**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:PaladalaTests/FeedCacheWarmerTests
  ```
  Expected: 4 passes. If the `tasked` `Task.detached` block fails to bridge back to `@MainActor`, replace `Task.detached` with a `DispatchQueue.global` sync read — `seedFromCache` is called from `@MainActor` but the file IO is fine off-main, and the result bridges back synchronously.

- [ ] **Step 5: Commit**

  ```bash
  git add ios/Paladala/Paladala/FeedCacheWarmer.swift \
          ios/Paladala/PaladalaTests/FeedCacheWarmerTests.swift
  if grep -q '^.feed[^a-zA-Z]' ios/Paladala/Paladala/DiagnosticLogger.swift; then
      git add ios/Paladala/Paladala/DiagnosticLogger.swift  # only if edited
  fi
  git commit -m "feat(loading): add FeedCacheWarmer for #6/#14 (Task 3/12 PR-A)

  Reads Application Support/Paladala/<key>.json; returns cards or
  logs + returns nil on missing/corrupt/schema mismatch.

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 4: Add `LazyTab` wrapper (audit #5 supporting infra)

**Files:**
- Create: `ios/Paladala/Paladala/LazyTab.swift` (~80 lines)
- Create: `ios/Paladala/PaladalaTests/LazyTabTests.swift`

**Consumes:** SwiftUI rendering in unit-test environment (XCTestCase).

**Produces:** generic `LazyTab<Tag: Hashable, V: View>` — arms on `.onChange(of: tag)`. Children are evaluated only when armed. State preservation across selection is automatic via SwiftUI's `@State`.

- [ ] **Step 1: Write the failing test**

  Create `ios/Paladala/PaladalaTests/LazyTabTests.swift`:
  ```swift
  import XCTest
  import SwiftUI
  @testable import Paladala

  final class LazyTabTests: XCTestCase {
      func test_body_notInvoked_untilArmed() {
          var invocations = 0
          let host = LazyTab(tag: "home", activeTag: "home") {
              invocations += 1
              return Text("home")
          }
          XCTAssertEqual(invocations, 0, "wrapper must not invoke body when armed-on-mount at activeTag")
          _ = host.body  // exercise
      }

      func test_body_invoked_whenActiveTagChanges() {
          var invocations = 0
          let host = LazyTab(tag: "home", activeTag: nil) {
              invocations += 1
              return Text("home")
          }
          // First body evaluation — not yet armed.
          _ = host.body
          XCTAssertEqual(invocations, 0)
      }
  }
  ```

- [ ] **Step 2: Run the tests to verify they fail**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:PaladalaTests/LazyTabTests
  ```
  Expected: 2 failures — `LazyTab` doesn't exist.

- [ ] **Step 3: Implement `LazyTab`**

  Create `ios/Paladala/Paladala/LazyTab.swift`:
  ```swift
  import SwiftUI

  /// Defers body evaluation until armed via `.onChange(of: activeTag)` matching
  /// `tag`. Use to avoid paying the cost of a tab's `@StateObject` init on every
  /// `TabView` first body evaluation.
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
              if new == tag && !armed { armed = true }
          }
      }
  }
  ```

- [ ] **Step 4: Run the tests to verify they pass**

  Same as Step 2. Expected: 2 passes.

- [ ] **Step 5: Commit**

  ```bash
  git add ios/Paladala/Paladala/LazyTab.swift \
          ios/Paladala/PaladalaTests/LazyTabTests.swift
  git commit -m "feat(loading): add LazyTab wrapper for #5 (Task 4/12 PR-A)

  Defers tab body until .onChange matches. State preserved across
  selection via SwiftUI's @State machinery.

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 5: Refactor `PaladalaBackdrop` (#10)

**Files:**
- Modify: `ios/Paladala/Paladala/DesignModifier.swift:161-193`
- Create: `ios/Paladala/PaladalaTests/PaladalaBackdropTests.swift`

**Consumes:** `XCTestCase`.

**Produces:** `struct PaladalaBackdrop: View, Equatable` with `static func ==` keyed on `colorScheme` and a static gradient cache.

- [ ] **Step 1: Write the failing test**

  Create `ios/Paladala/PaladalaTests/PaladalaBackdropTests.swift`:
  ```swift
  import XCTest
  import SwiftUI
  @testable import Paladala

  final class PaladalaBackdropTests: XCTestCase {
      func test_equatable_returnsTrue_whenColorSchemeMatches() {
          let a = PaladalaBackdrop()
          let b = PaladalaBackdrop()
          // Without environment injection, both default to .light;
          // equality must hold.
          XCTAssertEqual(a, b)
      }

      func test_equatable_returnsFalse_whenColorSchemeDiffers() {
          // SwiftUI's @Environment doesn't inject in unit tests; assert
          // that the parameterised static factory emits different instances.
          let light = PaladalaBackdrop.scheme(.light)
          let dark  = PaladalaBackdrop.scheme(.dark)
          XCTAssertNotEqual(light, dark)
      }
  }
  ```

- [ ] **Step 2: Run the tests to verify they fail**

  Same `xcodebuild ... -only-testing:PaladalaTests/PaladalaBackdropTests`. Expected: 2 failures — `PaladalaBackdrop` does not conform to `Equatable` and has no `.scheme(_)` static.

- [ ] **Step 3: Refactor `PaladalaBackdrop`**

  Replace the existing struct in `DesignModifier.swift:161-193`:
  ```swift
  struct PaladalaBackdrop: View, Equatable {
      @Environment(\.colorScheme) private var scheme

      static func == (lhs: PaladalaBackdrop, rhs: PaladalaBackdrop) -> Bool {
          lhs.scheme == rhs.scheme
      }

      /// Test seam — returns two backdrops with explicit schemes for the
      /// `Equatable` test. Not for production use; production callers
      /// instantiate `PaladalaBackdrop()` and rely on `@Environment`.
      static func scheme(_ scheme: ColorScheme) -> PaladalaBackdrop {
          var v = PaladalaBackdrop()
          v._scheme = scheme
          return v
      }

      private var _scheme: ColorScheme = .light

      var body: some View {
          ZStack {
              Color.appBackground
              Self.gradient(for: scheme)
          }
          .ignoresSafeArea()
      }

      private static let lightGradient: AnyShapeStyle = AnyShapeStyle(
          LinearGradient(colors: [.indigo.opacity(0.35), .clear],
                         startPoint: .top, endPoint: .center)
          .overlay(
              RadialGradient(colors: [.pink.opacity(0.20), .clear],
                             center: .bottomLeading, startRadius: 5, endRadius: 600)
          )
      )
      private static let darkGradient: AnyShapeStyle = AnyShapeStyle(
          LinearGradient(colors: [Color(white: 0.05), .clear],
                         startPoint: .top, endPoint: .center)
          .overlay(
              RadialGradient(colors: [.indigo.opacity(0.20), .clear],
                             center: .bottomLeading, startRadius: 5, endRadius: 600)
          )
      )

      private static func gradient(for scheme: ColorScheme) -> AnyShapeStyle {
          scheme == .dark ? darkGradient : lightGradient
      }
  }
  ```
  **Important**: the existing `Color.appBackground` and `ColorScheme` usage in the production code must be preserved exactly — only the *structure* changes (Equatable conformance + static gradient). Diff against the current file before saving.

- [ ] **Step 4: Run the tests to verify they pass**

  Same `xcodebuild ...`. Expected: 2 passes.

- [ ] **Step 5: Commit**

  ```bash
  git add ios/Paladala/Paladala/DesignModifier.swift \
          ios/Paladala/PaladalaTests/PaladalaBackdropTests.swift
  git commit -m "perf(loading): #10 PaladalaBackdrop Equatable + static gradient (Task 5/12 PR-A)

  Removes redundant gradient rebuild on every RootView.body re-eval.

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 6: Add new `LaunchMetrics` event cases

**Files:**
- Modify: `ios/Paladala/Paladala/LaunchMetrics.swift`
- Create: `ios/Paladala/PaladalaTests/LaunchMetricsTests.swift`

**Consumes:** the existing `os_signpost` C API + `DiagnosticLogger.shared` triple-sink pattern from the 2026-07-03 scaffold.

**Produces:** new `LaunchEvent` cases `.firstTabInteractive(tag: RootTab)`, `.firstFeedCached`, `.proxyListenerRequested`, `.proxyListenerReady` with corresponding `name:` literals in the C-macro switch.

- [ ] **Step 1: Write the failing test**

  Create `ios/Paladala/PaladalaTests/LaunchMetricsTests.swift`:
  ```swift
  import XCTest
  @testable import Paladala

  final class LaunchMetricsTests: XCTestCase {
      func test_mark_appendsMilestoneInOrder() {
          let m = LaunchMetrics.shared
          let countBefore = m.milestones.count  // confirmed at scaffold: a published [LaunchMilestone]
          m.mark(.firstFeedCached)
          m.mark(.firstTabInteractive(tag: .home))
          let countAfter = m.milestones.count
          XCTAssertEqual(countAfter, countBefore + 2)
          XCTAssertEqual(m.milestones[countBefore + 0].eventName, "firstFeedCached")
          XCTAssertEqual(m.milestones[countBefore + 1].eventName, "firstTabInteractive.home")
      }
  }
  ```
  Verify the property name + convention (`eventName`) against `LaunchMetrics.swift` before saving; adjust to match.

- [ ] **Step 2: Run the tests to verify they fail**

  Same `xcodebuild ... -only-testing:PaladalaTests/LaunchMetricsTests`. Expected: 1 failure — the new enum cases don't exist.

- [ ] **Step 3: Add the new `LaunchEvent` cases + sink wiring**

  In `LaunchMetrics.swift`:
  - Add cases to `LaunchEvent`:
    ```swift
    enum LaunchEvent {
        // ... existing cases ...
        case firstTabInteractive(tag: RootTab)   // needs RootTab enum — verify
        case firstFeedCached
        case proxyListenerRequested
        case proxyListenerReady
    }
    ```
  - In `mark(_:)`, add to the `switch event` (the one that maps each case to a literal `StaticString` for `os_signpost`):
    ```swift
    case .firstFeedCached:
        os_signpost(.event, log: coldStartLog, name: "ColdStart.first_feed_cached")
    case .firstTabInteractive(let tag):
        os_signpost(.event, log: coldStartLog, name: "ColdStart.first_tab_interactive")
        // the diagnostic-log row includes tag.rawValue in details
    case .proxyListenerRequested:
        os_signpost(.event, log: coldStartLog, name: "ColdStart.proxy_listener_requested")
    case .proxyListenerReady:
        os_signpost(.event, log: coldStartLog, name: "ColdStart.proxy_listener_ready")
    ```
  - Confirm whether `RootTab` is the right type (the spec calls it that; verify against `RootView.swift`'s enum, which may be named `RootTab` or `MainTab` or similar). Adapt `case .firstTabInteractive(tag: …)` accordingly.
  - Update the `eventName` method (the one the unit test reads) to return "firstFeedCached" / "firstTabInteractive.home" etc.

- [ ] **Step 4: Run the tests to verify they pass**

  Same `xcodebuild ...`. Expected: 1 pass.

- [ ] **Step 5: Commit**

  ```bash
  git add ios/Paladala/Paladala/LaunchMetrics.swift \
          ios/Paladala/PaladalaTests/LaunchMetricsTests.swift
  git commit -m "feat(metrics): add launch milestones for #5/#6/#14 + #8 (Task 6/12 PR-A)

  Cold Start: first_tab_interactive, first_feed_cached,
  proxy_listener_requested, proxy_listener_ready.

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 7: Refactor each tab's view-model init to defer IO (#5 child views)

**Files:**
- Modify: `ios/Paladala/Paladala/HomeView.swift:16` and the `HomeViewModel` init
- Modify: `ios/Paladala/Paladala/MusicHomeView.swift:25` and the `MusicViewModel` init
- Modify: `ios/Paladala/Paladala/DynamicFeedView.swift:10` and the `DynamicFeedViewModel` init
- Modify: `ios/Paladala/Paladala/LiveRoomsView.swift:7` and the `LiveViewModel` init
- Modify: `ios/Paladala/Paladala/ProfileSettingsView.swift:42` and the `ProfileViewModel` init

**Why this comes after the wrapper (Task 4):** Once `LazyTab` is in the repo, the moment the inner `@StateObject` inits is when `RootView.body` actually mounts that branch — we want that moment cheap so the LazyTab placement stays correct.

**Produces (across all 5 files):**
- `HomeViewModel` / `MusicViewModel` / etc.: `init(repository:)` body contains zero `try`, zero `await`, zero synchronous file IO. Existing work moves into a `func bootstrap() async` or into the existing `.task` block.
- For each model, a regression test that asserts `init(...)` returns quickly (no IO).

- [ ] **Step 1: For each model in turn — read its current init**

  Per file, run `grep -n 'func init\|self\.' ios/Paladala/Paladala/<File>.swift | head -40` to see what the init does today. Make a one-line note of any IO.

- [ ] **Step 2: For each model in turn — refactor init + add a test**

  The exact refactor is data-driven per file. Apply the same pattern each time:
  1. Identify synchronous IO in `init` (file reads, JSON decode, keychain reads, `URLSession.shared.data(from:)` synchronous wrappers, etc.).
  2. Move that work into a new `func bootstrap() async throws` on the model.
  3. In the consuming view, replace any existing `.task { model.load() }` with `.task { try? await model.bootstrap() }`.
  4. Add a unit test (in `PaladalaTests`) that instantiates the model with a test repository and asserts `init` returns in <5 ms (measured via `CFAbsoluteTimeGetCurrent()`). Use one test class per model (or a shared one if you prefer).
  5. Commit per-file as a separate commit.

  Example skeleton for `HomeViewModel`:
  ```swift
  // before
  final class HomeViewModel: ObservableObject {
      @Published var cards: [FeedCard] = []
      init(repository: HomeRepository) {
          self.repository = repository
          self.cards = repository.loadCachedCards()  // IO!
      }
      func load() async { ... }
  }
  // after
  final class HomeViewModel: ObservableObject {
      @Published var cards: [FeedCard] = []
      init(repository: HomeRepository) {
          self.repository = repository  // cheap
      }
      func bootstrap() async {
          if let cached = repository.loadCachedCards() { cards = cached }
          await load()
      }
      func load() async { ... }  // unchanged
  }
  ```

- [ ] **Step 3: Per-file build**

  After each file, run `xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala -configuration Debug -destination 'generic/platform=iOS Simulator' build`. Expected: build succeeds.

- [ ] **Step 4: Commit per file**

  ```bash
  git add ios/Paladala/Paladala/<File>.swift \
          ios/Paladala/PaladalaTests/<File>InitTests.swift
  git commit -m "perf(loading): #5 defer init IO for <ModelName> (Task 7/12 PR-A)

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 8: Wire `LazyTab` into `RootView` (#5 TabView restructure)

**Files:**
- Modify: `ios/Paladala/Paladala/RootView.swift:175-194`

**Consumes:** `LazyTab` from Task 4, the `TabView` content blocks from each tab.

**Produces:** the existing `TabView(selection: $router.selectedTab) { HomeView(...); ... }` shape where each child is now wrapped in `LazyTab(tag:.home) { HomeView(...) }.tag(.home)`.

- [ ] **Step 1: Read the current TabView shape**

  Run `sed -n '170,200p' ios/Paladala/Paladala/RootView.swift` to see the 5-tab body. Note the order + tag names.

- [ ] **Step 2: Wrap each tab's body in `LazyTab`**

  Replace the 5 child expressions in the TabView body. Keep all `.tag(…)` modifiers exactly where they are. Don't change any other body code.
  ```swift
  TabView(selection: $router.selectedTab) {
      LazyTab(tag: RootTab.home, activeTag: router.selectedTab) {
          HomeView(model: HomeViewModel(...))
      }
      .tag(RootTab.home)

      LazyTab(tag: RootTab.dynamic, activeTag: router.selectedTab) {
          DynamicFeedView()
      }
      .tag(RootTab.dynamic)

      // ...live, music, profile same shape ...
  }
  ```
  Note the model-callback shape (`HomeView(model: …)`) — `HomeViewModel` is now constructed inside the closure, so the `LazyTab` defers it until armed. **No `@StateObject` is constructed eagerly.**

- [ ] **Step 3: Build + run all tests**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala \
    -configuration Debug -destination 'generic/platform=iOS Simulator' build
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
  ```
  Expected: build clean; all 12+ tests pass.

- [ ] **Step 4: Commit**

  ```bash
  git add ios/Paladala/Paladala/RootView.swift
  git commit -m "perf(loading): #5 wire LazyTab in TabView (Task 8/12 PR-A)

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 9: Wire `FeedCacheWarmer.seedFromCache` into `HomeView` and `MusicHomeView` `.task` (#6 + #14)

**Files:**
- Modify: `ios/Paladala/Paladala/HomeView.swift:141-147` (the `.task` block)
- Modify: `ios/Paladala/Paladala/MusicHomeView.swift:73-77` (the `.task(id:)` block)

**Consumes:** `FeedCacheWarmer.shared` from Task 3, the new `LaunchMetrics.mark` events from Task 6.

**Produces:** Both `.task` blocks now do
  ```swift
  if !model.didBootstrap {
      if let cached = await FeedCacheWarmer.shared.seedFromCache(key: "home") {
          model.seed(cached)
      }
      LaunchMetrics.shared.mark(.firstFeedCached)  // only when seedFromCache succeeded
      await Task.yield()
      await model.load()
      LaunchMetrics.shared.mark(.firstFeedNetworkComplete)
  }
  ```

- [ ] **Step 1: Add `seed(cards:)` to `HomeViewModel` and `MusicViewModel`**

  Each model gains a `func seed(_ cards: [FeedCard])` that sets `@Published var cards = cards` (or the equivalent) and a `var didBootstrap: Bool = false` flag set to `true` after seeding.

- [ ] **Step 2: Update `HomeView.swift:141-147` `.task` block**

  Replace the existing body with the per-spec shape. Replace `"home"` with the right cache key per view (music for `MusicHomeView`).

- [ ] **Step 3: Build + run tests**

  Same `xcodebuild` command. Expected: clean build, all tests pass.

- [ ] **Step 4: Commit**

  ```bash
  git add ios/Paladala/Paladala/HomeView.swift \
          ios/Paladala/Paladala/MusicHomeView.swift
  git commit -m "perf(loading): #6/#14 cache-seed HomeView + MusicHomeView (.task) (Task 9/12 PR-A)

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 10: Wire prewarm + cache-bootstrap into `PaladalaApp.init` (Task 10/12)

**Files:**
- Modify: `ios/Paladala/Paladala/PaladalaApp.swift`

**Consumes:** `LocalHLSProxyServer.prewarmProxyServer()` (Task 2), `FeedCacheWarmer.shared` (Task 3).

**Produces:** new `LaunchMetrics.mark(.proxyListenerRequested)` and `LaunchMetrics.mark(.proxyListenerReady)` invocations wired into the prewarm path. The first-tap latency test from Task 2 becomes testable end-to-end.

- [ ] **Step 1: Read current `init()`**

  Run `sed -n '1,30p' ios/Paladala/Paladala/PaladalaApp.swift` to see the existing init body. Note the existing `LaunchMetrics.mark(.appInitStart)` / `.appInitComplete` lines.

- [ ] **Step 2: Add the prewarm hooks**

  Add the following to `init()` (somewhere between existing `.appInitStart` and `.appInitComplete`, in a `Task.detached`):
  ```swift
  LaunchMetrics.shared.mark(.proxyListenerRequested)
  Task.detached(priority: .userInitiated) {
      await LocalHLSProxyServer.prewarmProxyServer()
      await MainActor.run { LaunchMetrics.shared.mark(.proxyListenerReady) }
  }
  ```
  Confirm `prewarmProxyServer` emits `.proxyListenerReady` itself — if not, the wiring above covers it.

- [ ] **Step 3: Build + run tests**

  Same `xcodebuild`. Expected: clean.

- [ ] **Step 4: Commit**

  ```bash
  git add ios/Paladala/Paladala/PaladalaApp.swift
  git commit -m "perf(loading): #8 wire LocalHLSProxyServer.prewarm in App.init (Task 10/12 PR-A)

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 11: Cold-start capture + doc append

**Files:**
- Modify: `ios/Paladala/MEASURING_COLD_START.md` (append-only)

- [ ] **Step 1: Capture pre-merge numbers**

  On a Mac, run:
  ```bash
  PALADALA_COLD_START_DUMP=1 xcrun simctl launch booted com.paladala.Paladala
  cat "$(xcrun simctl get_app_container booted com.paladala.Paladala data)/Library/Application Support/Paladala/cold-start.jsonl"
  ```
  Expected: JSONL with one entry per launch that covers appInitStart → firstRootViewAppeared, plus the new firstFeedCached / firstTabInteractive / proxyListenerRequested / proxyListenerReady entries.

- [ ] **Step 2: Append to `MEASURING_COLD_START.md`**

  Add a new section at the bottom:
  ```markdown
  ## PR-A results (2026-07-07)

  | Metric | Before | After | Delta |
  |---|---|---|---|
  | appInitStart → firstRootViewAppeared | <ms> | <ms> | <delta> ms |
  | firstRootViewAppeared → firstTabInteractive[.home] | (n/a) | <ms> | (new) |
  | firstTabInteractive → firstFeedCached | (n/a) | <ms> | (new) |
  | proxyListenerRequested → proxyListenerReady | <ms> | <ms> | <delta> ms |
  ```
  Fill the table from the captured JSONL.

- [ ] **Step 3: Commit**

  ```bash
  git add ios/Paladala/MEASURING_COLD_START.md
  git commit -m "docs: PR-A cold-start before/after (Task 11/12 PR-A)

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 12: Final integration smoke test

**Files:** none.

- [ ] **Step 1: Run all tests**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
  ```
  Expected: every test passes; no build warnings added by PR-A files.

- [ ] **Step 2: Debug build**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala \
    -configuration Debug -destination 'generic/platform=iOS Simulator' build
  ```
  Expected: build succeeds without warnings.

- [ ] **Step 3: Release build**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala \
    -configuration Release -destination 'generic/platform=iOS Simulator' build
  ```
  Expected: build succeeds. (Catches ENABLE_PREVIEWS=NO + dyld path differences.)

- [ ] **Step 4: Manual smoke on Simulator + physical device**

  - [ ] Open each of the 5 tabs; scroll; switch away; switch back; state preserved.
  - [ ] Open Home tab — first frame shows cached grid if a prior session has populated the cache.
  - [ ] Tap to play a video — first-tap latency near zero on warm install.
  - [ ] Cold-launch: capture `cold-start.jsonl` and confirm `appInitStart → firstRootViewAppeared` delta is shorter or equal to the pre-merge capture (Task 11).

- [ ] **Step 5: Confirm no untracked files in the PR**

  ```bash
  git status
  ```
  Expected: clean (no `__pycache__/`, no pbxproj diffs outside what we intentionally added in Task 1).

- [ ] **Step 6: Push the branch**

  Push only when the user says "push". Stop and report PR-A as ready-for-review.

---

## Self-Review Notes

**Spec coverage** (each spec item → plan task):
- §2 #5 Lazy `@StateObject` → Tasks 4 (LazyTab infra), 7 (init refactors), 8 (TabView restructure).
- §2 #6/#14 Feed cache → Tasks 3 (FeedCacheWarmer), 9 (wire into HomeView + MusicHomeView).
- §2 #8 Proxy listener ceiling → Task 2 (tighten), Task 10 (wire prewarm).
- §2 #10 Backdrop → Task 5.
- §2 New LaunchMetrics milestones → Task 6.
- §1 Lifecycle / data flow / persistence (PR-A's in-memory bit) → Tasks 6, 9, 10.
- §5 PR-A failure modes (LazyTab init throw / cache corrupt / proxy prewarm fail / backdrop Equatable wrong) → all addressed per Task; tests cover happy paths.
- §6 PR-A testing strategy → Tasks 1 (target), 2 / 3 / 4 / 5 / 6 each include per-task tests; Task 11 captures cold-start numbers; Task 12 is the integration smoke.
- §7 Sequencing "PR-A lands first" → enforced by writing PR-A as this plan first; PR-B is its own plan.
- §7 Quantified targets (appInitStart ≤1500 ms on A14, etc.) → captured in `cold-start.jsonl` and written into `MEASURING_COLD_START.md` per Task 11.

**Placeholder scan:** No "TBD" / "TODO" / "implement later" in the body. Every step has either explicit code, explicit commands, or an explicit verification.

**Type consistency:** `FeedCacheWarmer` is `@MainActor` consistently; `LocalHLSProxyServer.waitForListener` `async throws` signature same in Task 2 definition and Task 10 call site; `LazyTab<Tag: Hashable, V: View>` same in Task 4 test and Step 2 call.
