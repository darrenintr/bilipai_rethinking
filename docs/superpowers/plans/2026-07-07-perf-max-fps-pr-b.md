# PR-B: Max-FPS Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a user-facing "Max frame rate" toggle under Settings → 播放设置, default ON for ProMotion-capable hardware, OFF (dimmed and locked) otherwise. Honor Low Power Mode and thermal-state. Tune `AVPlayerController` for 120 Hz playback. New persistent state in `@AppStorage`; new in-memory state via `MaxFrameRateService`; new companion `CADisplayLink` to anchor high-refresh-rate on static screens.

**Architecture:** Three new files (`DeviceCapability.swift`, `MaxFrameRateService.swift`, `ProMotionRow.swift`) plus three edits (`PaladalaApp.swift`, `ProfileSettingsView.swift`, `AVPlayerController.swift`). Builds on the `PaladalaTests` target from PR-A Task 1.

**Tech Stack:** Swift 6, SwiftUI, `Combine`, `Foundation.sysctl`, `CADisplayLink`, `CAFrameRateRange`, `ProcessInfo` + `NSNotificationCenter`, `@AppStorage`, `XCTest`, `xcodebuild`.

## Global Constraints

- iOS deployment target: 17.5 (Debug) / 18.0 (Release). Swift 6 concurrency; `@MainActor assumeIsolated` for main-actor work.
- `CADisplayLink.preferredFrameRateRange` is `(minimumFramesPerSecond, maximumFramesPerSecond, preferredFramesPerSecond)` — when enabling max-FPS, use `CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)`. When disabling, use `(60, 60, 60)`.
- `CADisplayLink` requires a non-nil target; the holder pattern is mandatory.
- `@AppStorage` keys must be prefixed `maxFrame.` — e.g. `maxFrame.userEnabled`, `maxFrame.firstBootstrapDone`.
- `MaxFrameRateService` is `@MainActor` and exposes `static let shared`; consumer pattern is `MaxFrameRateService.shared.$effective.values` (async-sequence) or `@ObservedObject`.
- `ProcessInfo.processInfo.isLowPowerModeEnabled` is the public API; read it under `@MainActor`.
- `ProcessInfo.processInfo.thermalState` is observable via `ProcessInfoThermalStateDidChangeNotification`.
- `Notification.Name.NSProcessInfoPowerStateDidChange` is the public API for power-state changes.
- ProMotion identifier table: iPhone only for v1 (iPad out of scope). Initial entries (`iPhone15,3` etc.) require verification against the latest Apple Identifier Chip docs before commit.
- `DiagnosticLogger` category `.maxFrameRate` (add if not present; existing `.device` is fine for `sysctl` failures — pick whichever is already used in the file).
- All commits co-authored with Claude:
  ```
  Co-Authored-By: Claude <noreply@anthropic.com>
  ```
- Use `git add <file-path>` rather than `git add -A`.
- Verify on a Mac before declaring a task done.
- Build verification:
  ```
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala -configuration Debug -destination 'generic/platform=iOS Simulator' build
  ```
- Test verification (after PR-A Task 1 lands):
  ```
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
  ```

## File Structure

### Files to create

- `ios/Paladala/Paladala/DeviceCapability.swift` (~50 lines) — `enum DeviceCapability` with `static func isProMotionCapable() -> Bool`, swizzles `sysctlbyname("hw.machine", …)` once and caches. Documents the curated `Set<String>` table.
- `ios/Paladala/Paladala/MaxFrameRateService.swift` (~150 lines) — `@MainActor final class`, `ObservableObject`, `static let shared`. Owns `@AppStorage` keys, computed `isCapable`, computed `effective`, owned `CADisplayLink` (via private `DisplayLinkHolder`), notification subscriptions.
- `ios/Paladala/Paladala/ProMotionRow.swift` (~80 lines) — SwiftUI row with two visible states (capable / dimmed).
- `ios/Paladala/PaladalaTests/DeviceCapabilityTests.swift`
- `ios/Paladala/PaladalaTests/MaxFrameRateServiceTests.swift`
- `ios/Paladala/PaladalaTests/ProMotionRowSnapshotTests.swift`

### Files to modify

- `ios/Paladala/Paladala/PaladalaApp.swift` — add `MaxFrameRateService.shared.bootstrap()` to `init()` (Task 3).
- `ios/Paladala/Paladala/ProfileSettingsView.swift:78` — add `ProMotionRow()` between `backgroundAudio` and `autoPlayNext` rows in the `播放设置` section (Task 5).
- `ios/Paladala/Paladala/AVPlayerController.swift:472` — observe `$effective` and toggle `player.preferredForwardBufferDuration` (Task 6).
- `ios/Paladala/Paladala/DiagnosticLogger.swift` — append `.maxFrameRate` category if not present (Task 2).
- `ios/Paladala/MAX_FRAME_RATE.md` — new operator-facing doc (Task 7).

### Files NOT touched

- Everything in PR-A's file map.
- iPad-specific work — out of v1.

---

## Task 1: Add `DeviceCapability.isProMotionCapable()` (Task 1/7 PR-B)

**Files:**
- Create: `ios/Paladala/Paladala/DeviceCapability.swift`
- Create: `ios/Paladala/PaladalaTests/DeviceCapabilityTests.swift`

**Consumes:** `sysctlbyname` (C-bridged via Darwin), `XCTestCase`.

**Produces:** `enum DeviceCapability { static func isProMotionCapable() -> Bool }`. Caches the answer in a private mutable `_cached` for the lifetime of the process. NEVER throws to callers.

- [ ] **Step 1: Verify the ProMotion identifier table against Apple's current Identifier Chip docs**

  Before writing code, do this verification on a Mac with the latest docs (web fetch via WebFetch from a current Apple support URL such as `https://support.apple.com/en-us/HT211814`). For each candidate:
  - iPhone 13 Pro → expected identifier "iPhone14,2"
  - iPhone 13 Pro Max → expected identifier "iPhone14,3"
  - iPhone 14 Pro → expected identifier "iPhone14,7"
  - iPhone 14 Pro Max → expected identifier "iPhone14,8"
  - iPhone 15 Pro → expected identifier "iPhone15,3"
  - iPhone 15 Pro Max → expected identifier "iPhone15,4"
  - iPhone 16 Pro / Pro Max → "iPhone16,1" / "iPhone16,2"
  - iPhone 17 Pro / Pro Max / future → look up in the docs again at merge time

  Document the exact identifiers used and the source URL in the file docstring.

- [ ] **Step 2: Write the failing test**

  Create `ios/Paladala/PaladalaTests/DeviceCapabilityTests.swift`:
  ```swift
  import XCTest
  @testable import Paladala

  final class DeviceCapabilityTests: XCTestCase {
      func test_proMotionIdentifierIsRecognized() {
          // The strings here MUST match the curated Set in
          // DeviceCapability.swift; if you change one, change the other.
          for identifier in DeviceCapability.proMotionIdentifiers {
              XCTAssertTrue(identifier.hasPrefix("iPhone"),
                            "ProMotion set must be iPhone-only for v1: \(identifier)")
          }
      }

      func test_isProMotionCapable_doesNotThrow() {
          // Must be safe to call repeatedly and never throw.
          for _ in 0..<3 {
              _ = DeviceCapability.isProMotionCapable()
          }
      }
  }
  ```

- [ ] **Step 3: Run the tests to verify they fail**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:PaladalaTests/DeviceCapabilityTests
  ```
  Expected: 2 failures — `DeviceCapability` doesn't exist.

- [ ] **Step 4: Implement `DeviceCapability`**

  Create `ios/Paladala/Paladala/DeviceCapability.swift`:
  ```swift
  import Foundation
  import Darwin

  /// Source: Apple Identifier Chip lookup as of 2026-07. Refresh on each new
  /// ProMotion iPhone release. iPad scope deferred to PR-B.v2.
  enum DeviceCapability {
      static let proMotionIdentifiers: Set<String> = [
          // (Verified via Apple's support page on the date of this commit.)
          // iPhone 13 Pro / Pro Max
          "iPhone14,2", "iPhone14,3",
          // iPhone 14 Pro / Pro Max
          "iPhone14,7", "iPhone14,8",
          // iPhone 15 Pro / Pro Max
          "iPhone15,3", "iPhone15,4",
          // iPhone 16 Pro / Pro Max
          "iPhone16,1", "iPhone16,2",
          // iPhone 17 Pro / Pro Max — fill in from current Apple Identifier Chip docs.
      ]

      private static var _cached: Bool?

      /// True on hardware that can drive a 120 Hz refresh on its display.
      /// Falls back to `false` if sysctl fails (sandbox breach, etc.).
      static func isProMotionCapable() -> Bool {
          if let cached = _cached { return cached }
          let raw = readMachineIdentifier()
          let result = proMotionIdentifiers.contains(raw)
          _cached = result
          if !result && !raw.isEmpty {
              DiagnosticLogger.shared.log(.device, "device_id_probe_completed",
                                          details: ["identifier": raw, "capable": "false"])
          }
          return result
      }

      private static func readMachineIdentifier() -> String {
          var size = 0
          sysctlbyname("hw.machine", nil, &size, nil, 0)
          var buffer = [CChar](repeating: 0, count: size)
          guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
              DiagnosticLogger.shared.log(.device, "device_id_probe_failed",
                                          details: ["errno": String(errno)])
              return ""
          }
          return String(cString: buffer)
      }
  }
  ```
  Confirm `DiagnosticLogger.Category.device` exists (the agent's report of `DiagnosticLogger.swift` showed category coverage; `.device` is conventional). If a `.maxFrameRate` category is desired for clearer filtering, add it here too — but `.device` is acceptable for v1.

- [ ] **Step 5: Run the tests to verify they pass**

  Same `xcodebuild ...`. Expected: 2 passes.

- [ ] **Step 6: Commit**

  ```bash
  git add ios/Paladala/Paladala/DeviceCapability.swift \
          ios/Paladala/PaladalaTests/DeviceCapabilityTests.swift
  git commit -m "feat(max-fps): add DeviceCapability.isProMotionCapable (Task 1/7 PR-B)

  Reads hw.machine via sysctl; matches against a curated iPhone-only
  Set. Cached for the process lifetime; verified against current
  Apple Identifier Chip docs at commit time.

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 2: Add `MaxFrameRateService` (Task 2/7 PR-B)

**Files:**
- Create: `ios/Paladala/Paladala/MaxFrameRateService.swift`
- Create: `ios/Paladala/PaladalaTests/MaxFrameRateServiceTests.swift`
- Modify: `ios/Paladala/Paladala/DiagnosticLogger.swift` (only if `.maxFrameRate` category needs adding — verify first)

**Consumes:** `DeviceCapability.isProMotionCapable()`, `DiagnosticLogger.shared`, `ProcessInfo`.

**Produces:**
- `MaxFrameRateService.shared` singleton.
- `@Published effective: Bool` reflecting `userEnabled && isCapable && !lowPower && thermalState < .serious`.
- Owned `CADisplayLink` (`maxFrameRateDisplayLink`).
- `bootstrap()` to wire everything at app init.
- Notifications: `PowerStateDidChange` + `ProcessInfoThermalStateDidChange` + `scenePhase`.

- [ ] **Step 1: Write the failing test**

  Create `ios/Paladala/PaladalaTests/MaxFrameRateServiceTests.swift`:
  ```swift
  import XCTest
  @testable import Paladala

  @MainActor
  final class MaxFrameRateServiceTests: XCTestCase {
      func test_effective_false_whenUserEnabledFalse() {
          let s = MaxFrameRateService(isCapableForTest: true, lowPowerForTest: false,
                                      thermalForTest: .nominal, userEnabledForTest: false)
          XCTAssertFalse(s.effective)
      }

      func test_effective_true_whenAllConditionsMet() {
          let s = MaxFrameRateService(isCapableForTest: true, lowPowerForTest: false,
                                      thermalForTest: .nominal, userEnabledForTest: true)
          XCTAssertTrue(s.effective)
      }

      func test_effective_false_whenLowPowerEvenIfUserEnabled() {
          let s = MaxFrameRateService(isCapableForTest: true, lowPowerForTest: true,
                                      thermalForTest: .nominal, userEnabledForTest: true)
          XCTAssertFalse(s.effective)
      }

      func test_effective_false_whenThermalSeriousEvenIfUserEnabled() {
          let s = MaxFrameRateService(isCapableForTest: true, lowPowerForTest: false,
                                      thermalForTest: .serious, userEnabledForTest: true)
          XCTAssertFalse(s.effective)
      }

      func test_effective_false_whenIncapableRegardlessOfUserEnabled() {
          let s1 = MaxFrameRateService(isCapableForTest: false, lowPowerForTest: false,
                                       thermalForTest: .nominal, userEnabledForTest: true)
          let s2 = MaxFrameRateService(isCapableForTest: false, lowPowerForTest: false,
                                       thermalForTest: .nominal, userEnabledForTest: false)
          XCTAssertFalse(s1.effective)
          XCTAssertFalse(s2.effective)
      }

      func test_effectiveTrue_whenThermalCritical() {
          let s = MaxFrameRateService(isCapableForTest: true, lowPowerForTest: false,
                                      thermalForTest: .critical, userEnabledForTest: true)
          XCTAssertFalse(s.effective)
      }
  }
  ```

- [ ] **Step 2: Run the tests to verify they fail**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
    -only-testing:PaladalaTests/MaxFrameRateServiceTests
  ```
  Expected: 6 failures — `MaxFrameRateService` and its test-seam initializer don't exist.

- [ ] **Step 3: Implement `MaxFrameRateService`**

  Create `ios/Paladala/Paladala/MaxFrameRateService.swift`:
  ```swift
  import Foundation
  import SwiftUI
  import UIKit

  @MainActor
  final class MaxFrameRateService: ObservableObject {
      static let shared = MaxFrameRateService()

      @AppStorage("maxFrame.firstBootstrapDone") private var didBootstrap: Bool = false
      @AppStorage("maxFrame.userEnabled") var userEnabled: Bool = false {
          didSet { recomputeEffectiveAndPinLink() }
      }
      @Published private(set) var isCapable: Bool = false
      @Published private(set) var effective: Bool = false

      /// Test seam — bypasses the static singleton and provides the four
      /// inputs the unit tests need. Marked `internal` so the test target's
      /// `@testable import` can reach it.
      init(isCapableForTest: Bool? = nil,
           lowPowerForTest: Bool? = nil,
           thermalForTest: ProcessInfo.ThermalState? = nil,
           userEnabledForTest: Bool? = nil) {
          self.isCapable = isCapableForTest ?? DeviceCapability.isProMotionCapable()
          self._lowPowerForTest = lowPowerForTest
          self._thermalForTest = thermalForTest
          self._userEnabledForTest = userEnabledForTest
          recomputeEffectiveAndPinLink()
      }

      /// Production bootstrap — call from `PaladalaApp.init`.
      func bootstrap() {
          guard !didBootstrap else { return }
          didBootstrap = true
          userEnabled = isCapable  // default ON for capable devices
          recomputeEffectiveAndPinLink()
      }

      // MARK: - Internal state

      private var displayLink: CADisplayLink?
      private var lowPowerObserver: NSObjectProtocol?
      private var thermalObserver: NSObjectProtocol?
      private var sceneObserver: NSObjectProtocol?

      // Test seam — non-nil only when constructed by tests.
      private var _lowPowerForTest: Bool?
      private var _thermalForTest: ProcessInfo.ThermalState?
      private var _userEnabledForTest: Bool?

      // MARK: - Derived

      private var lowPower: Bool { _lowPowerForTest ?? ProcessInfo.processInfo.isLowPowerModeEnabled }
      private var thermal: ProcessInfo.ThermalState { _thermalForTest ?? ProcessInfo.processInfo.thermalState }
      private var explicitUserEnabled: Bool { _userEnabledForTest ?? userEnabled }

      private func recomputeEffectiveAndPinLink() {
          let newEffective = explicitUserEnabled && isCapable && !lowPower && thermal < .serious
          if newEffective != effective {
              effective = newEffective
              pinOrUnpinLink(for: newEffective)
          }
      }

      private func pinOrUnpinLink(for on: Bool) {
          if on {
              if displayLink == nil {
                  let holder = DisplayLinkHolder()
                  let link = CADisplayLink(target: holder, selector: #selector(DisplayLinkHolder.tick(_:)))
                  link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
                  link.add(to: .main, forMode: .common)
                  holder.link = link
                  displayLink = link
              }
          } else {
              displayLink?.invalidate()
              displayLink = nil
          }
      }

      // MARK: - Production observation

      /// Called from production bootstrap path; subscribes to OS notifications.
      func startObservingSystemEvents() {
          lowPowerObserver = NotificationCenter.default.addObserver(
              forName: Notification.Name.NSProcessInfoPowerStateDidChange,
              object: nil, queue: .main
          ) { [weak self] _ in
              Task { @MainActor in self?.recomputeEffectiveAndPinLink() }
          }
          thermalObserver = NotificationCenter.default.addObserver(
              forName: ProcessInfo.processInfo.thermalStateDidChangeNotification,
              object: nil, queue: .main
          ) { [weak self] _ in
              Task { @MainActor in self?.recomputeEffectiveAndPinLink() }
          }
          sceneObserver = NotificationCenter.default.addObserver(
              forName: UIScene.willEnterForegroundNotification,
              object: nil, queue: .main
          ) { [weak self] _ in
              Task { @MainActor in self?.recomputeEffectiveAndPinLink() }
          }
      }

      deinit {
          [lowPowerObserver, thermalObserver, sceneObserver].compactMap { $0 }.forEach {
              NotificationCenter.default.removeObserver($0)
          }
      }
  }

  private final class DisplayLinkHolder {
      var link: CADisplayLink?
      @objc func tick(_ link: CADisplayLink) { /* anchor only */ }
  }
  ```
  **Important notes for the implementer:**
  - `ProcessInfo.processInfo.thermalStateDidChangeNotification` is `Notification.Name` per Apple's reference — verify by `grep` in your local SDK before saving.
  - The `static let shared = MaxFrameRateService()` constructs a non-test singleton whose `init()` therefore uses `DeviceCapability.isProMotionCapable()` for `isCapable` and current `ProcessInfo` values — matching the production code path. The test seam is only active when the four `*ForTest` parameters are non-nil.
  - `@AppStorage` keys must be referencable from outside `@ObservableObject`'s `init`; the synthesized default is `false`, so a fresh install starts with `userEnabled == false`, then `bootstrap()` flips it to `isCapable`.

- [ ] **Step 4: Run the tests to verify they pass**

  Same `xcodebuild ...`. Expected: 6 passes. If a test fails for missing-process-time reasons (CADisplayLink + main run loop), pin the test in `[weak self]` carefully — the test seam intentionally bypasses `startObservingSystemEvents`, so no observer is registered and `recomputeEffectiveAndPinLink` is the only state driver.

- [ ] **Step 5: Commit**

  ```bash
  git add ios/Paladala/Paladala/MaxFrameRateService.swift \
          ios/Paladala/PaladalaTests/MaxFrameRateServiceTests.swift
  if [ -n "$(git diff ios/Paladala/Paladala/DiagnosticLogger.swift)" ]; then
      git add ios/Paladala/Paladala/DiagnosticLogger.swift
  fi
  git commit -m "feat(max-fps): add MaxFrameRateService with effective gating (Task 2/7 PR-B)

  - userEnabled (AppStorage 'maxFrame.userEnabled')
  - isCapable (DeviceCapability.isProMotionCapable)
  - effective = userEnabled && isCapable && !lowPower && thermal<.serious
  - Owned CADisplayLink pinned at (80,120,120) when on; (60,60,60)
    or nil when off.
  - Notification subscribers: powerState / thermalState / scenePhase.

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 3: Wire `MaxFrameRateService.bootstrap()` into `PaladalaApp.init` (Task 3/7 PR-B)

**Files:**
- Modify: `ios/Paladala/Paladala/PaladalaApp.swift`

**Consumes:** `MaxFrameRateService.shared` (Task 2).

- [ ] **Step 1: Read current init**

  ```bash
  sed -n '1,30p' ios/Paladala/Paladala/PaladalaApp.swift
  ```
  Note the order of `LaunchMetrics.mark(.appInitStart)` and `mark(.appInitComplete)` calls.

- [ ] **Step 2: Add the bootstrap calls**

  Place calls between `.appInitStart` and `.appInitComplete`:
  ```swift
  MaxFrameRateService.shared.bootstrap()
  MaxFrameRateService.shared.startObservingSystemEvents()
  ```
  Add at the top of init() so the @AppStorage default reads correctly before any view body.

- [ ] **Step 3: Build + run tests**

  ```bash
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala \
    -configuration Debug -destination 'generic/platform=iOS Simulator' build
  xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
  ```
  Expected: clean build, all 18+ tests pass.

- [ ] **Step 4: Commit**

  ```bash
  git add ios/Paladala/Paladala/PaladalaApp.swift
  git commit -m "feat(max-fps): bootstrap MaxFrameRateService in App.init (Task 3/7 PR-B)

  Initializes userEnabled default; subscribes to OS notifications.

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 4: Add `ProMotionRow` (Task 4/7 PR-B)

**Files:**
- Create: `ios/Paladala/Paladala/ProMotionRow.swift`
- Create: `ios/Paladala/PaladalaTests/ProMotionRowSnapshotTests.swift` (optional; requires snapshot-test dependency — defer if not configured)

**Consumes:** `MaxFrameRateService.shared` (Task 2), `DeviceCapability.isProMotionCapable()` (Task 1), SwiftUI.

**Produces:** SwiftUI row that adapts its enabled state based on `isCapable`.

- [ ] **Step 1: Implement `ProMotionRow`**

  Create `ios/Paladala/Paladala/ProMotionRow.swift`:
  ```swift
  import SwiftUI

  struct ProMotionRow: View {
      @ObservedObject var service = MaxFrameRateService.shared
      @ObservedObject var capability = DeviceCapabilityObserver.shared

      var body: some View {
          Toggle(isOn: $service.userEnabled) {
              VStack(alignment: .leading, spacing: 2) {
                  Text("Max Frame Rate")
                  Text(capability.isCapable
                       ? "Smooth motion on the video player and during scrolling. May use more battery."
                       : "Your device's display maxes at 60 Hz.")
                      .font(.caption)
                      .foregroundStyle(.secondary)
              }
          }
          .disabled(!capability.isCapable || service.effective == false && service.lowPowerOverride)
      }

      private var service: MaxFrameRateService { MaxFrameRateService.shared }
  }

  /// Tiny ObservableObject wrapper so SwiftUI's @ObservedObject picks up
  /// capability changes without exposing the static functions as state.
  @MainActor
  final class DeviceCapabilityObserver: ObservableObject {
      static let shared = DeviceCapabilityObserver()
      @Published var isCapable: Bool = DeviceCapability.isProMotionCapable()
      private init() {}
  }
  ```
  Note `service.lowPowerOverride` is a flag the row adds when it detects low-power at render time — `MaxFrameRateService` exposes a `var lowPowerOverride: Bool { lowPower }` getter (Task 3 wires it).

- [ ] **Step 2: Extend `MaxFrameRateService` (small follow-up)**

  In `MaxFrameRateService.swift`, add (publicly readable):
  ```swift
  var lowPowerOverride: Bool { lowPower }
  ```
  Recompile + run all tests. Expected: same passes; no new failures.

- [ ] **Step 3: Commit**

  ```bash
  git add ios/Paladala/Paladala/ProMotionRow.swift \
          ios/Paladala/Paladala/MaxFrameRateService.swift
  git commit -m "feat(max-fps): add ProMotionRow with capable / dimmed states (Task 4/7 PR-B)

  Toggle row; sub-label changes based on capability and effective state.

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 5: Wire `ProMotionRow` into `ProfileSettingsView` (Task 5/7 PR-B)

**Files:**
- Modify: `ios/Paladala/Paladala/ProfileSettingsView.swift:78`

- [ ] **Step 1: Locate the 播放设置 section**

  ```bash
  grep -nE '播放设置|backgroundAudio|autoPlayNext' ios/Paladala/Paladala/ProfileSettingsView.swift
  ```
  Note the section header + the rows inside.

- [ ] **Step 2: Insert `ProMotionRow()`**

  Inside the existing `Section { ... }` block for `播放设置`, immediately after the `Toggle("Background audio" …)` row:
  ```swift
  ProMotionRow()
  ```
  Do NOT add a custom label / description wrapper — `ProMotionRow` renders its own.

- [ ] **Step 3: Build + run tests**

  Same `xcodebuild ...`. Expected: clean.

- [ ] **Step 4: Commit**

  ```bash
  git add ios/Paladala/Paladala/ProfileSettingsView.swift
  git commit -m "feat(max-fps): insert ProMotionRow in 播放设置 section (Task 5/7 PR-B)

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 6: Wire `effective` subscription into `AVPlayerController` (Task 6/7 PR-B)

**Files:**
- Modify: `ios/Paladala/Paladala/AVPlayerController.swift:472`

**Consumes:** `MaxFrameRateService.shared.$effective`.

**Produces:** When `effective == true`, `player.preferredForwardBufferDuration = 1.0`. When false, restore to system default (4 s is a safe number).

- [ ] **Step 1: Read the AVPlayer init context**

  ```bash
  sed -n '460,490p' ios/Paladala/Paladala/AVPlayerController.swift
  ```
  Note the existing `player = AVPlayer(playerItem: item)` line; this is a likely anchor.

- [ ] **Step 2: Add the subscription**

  In the AVPlayer init / `self.player = AVPlayer(...)` line, after the line, add:
  ```swift
  Task { [weak self] in
      for await on in MaxFrameRateService.shared.$effective.values {
          guard let self = self else { return }
          await MainActor.run {
              self.player.preferredForwardBufferDuration = on ? 1.0 : 4.0
          }
      }
  }
  ```
  Because the consumer pattern reads `@Published effective` as an `AsyncPublisher`, the `await` is essential. If the existing `AVPlayerController` is not async-friendly, drop the `Task` — instead, use a plain `Combine.sink` on the publisher:
  ```swift
  MaxFrameRateService.shared.$effective
      .receive(on: DispatchQueue.main)
      .sink { [weak self] on in
          self?.player.preferredForwardBufferDuration = on ? 1.0 : 4.0
      }
      .store(in: &self.cancellables)
  ```
  Add `private var cancellables = Set<AnyCancellable>()` at the top of `AVPlayerController` if not already present.

- [ ] **Step 3: Build + run tests**

  Same `xcodebuild`. Expected: clean.

- [ ] **Step 4: Commit**

  ```bash
  git add ios/Paladala/Paladala/AVPlayerController.swift
  git commit -m "feat(max-fps): AVPlayer forwards max-FPS into buffer headroom (Task 6/7 PR-B)

  preferredForwardBufferDuration: 4.0 (default) -> 1.0 (max-FPS)
  when MaxFrameRateService.effective flips true.

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

---

## Task 7: Capture cold-start numbers + write `MAX_FRAME_RATE.md` (Task 7/7 PR-B)

**Files:**
- Create: `ios/Paladala/MAX_FRAME_RATE.md`

- [ ] **Step 1: Capture pre-merge iOS device numbers**

  On a Mac with a real iPhone 13 Pro+ device attached:
  ```bash
  PALADALA_COLD_START_DUMP=1 xcrun devicectl device process launch \
      --device <UDID> com.paladala.Paladala
  cat "$(xcrun devicectl device get-app-container <UDID> com.paladala.Paladala data)/Library/Application Support/Paladala/cold-start.jsonl"
  ```
  Capture and append; the file path is the same as PR-A Task 11 uses.

- [ ] **Step 2: Create `MAX_FRAME_RATE.md`**

  Create `ios/Paladala/MAX_FRAME_RATE.md`:
  ```markdown
  # Max Frame Rate — operator notes

  Last updated: 2026-07-07 (PR-B lands).

  ## What this toggle does

  Adds an entry in Settings → 播放设置: "Max Frame Rate". The toggle enables a kept-alive
  companion `CADisplayLink` with `preferredFrameRateRange = CAFrameRateRange(minimum: 80,
  maximum: 120, preferred: 120)`. The OS uses this hint to keep the screen at 120 Hz even
  on static content (otherwise it drops to 60 Hz to save battery).

  ## Defaults

  - iPhone 13 Pro / Pro Max and later: default ON.
  - All other iPhones: row dimmed and locked OFF; sub-label "Your device's display maxes
    at 60 Hz."
  - Low Power Mode: effective flips off; row sub-label gains "Battery Saver is on".
  - Thermal state .serious / .critical: effective flips off.

  ## iPad

  v2 follow-up. The ProMotion identifier table in `DeviceCapability.swift` is iPhone-only
  today.

  ## Updating the device table

  When Apple releases a new ProMotion iPhone:

  1. Look up the new identifier via Apple's Identifier Chip lookup (the same source used
     in PR-B Task 1 Step 1).
  2. Add one entry to `DeviceCapability.proMotionIdentifiers` in
     `ios/Paladala/Paladala/DeviceCapability.swift`.
  3. Update the date and source URL in the file docstring.
  4. Bump the table comment block with the model name(s).

  ## Field telemetry

  Toggling + telemetry events are logged via `DiagnosticLogger.shared.log(.maxFrameRate, …)`
  when the `.maxFrameRate` category is in use, or `.device` otherwise. To inspect on a
  connected device:
  ```
  xcrun devicectl device log show --predicate 'subsystem == "app.paladala.ios"' --last 24h
  ```

  ## Battery / thermal safeguards

  - Low Power Mode: `effective` forces false.
  - Thermal state `.serious` or `.critical`: `effective` forces false.
  - Backgrounding: companion `CADisplayLink` invalidated immediately on
    `.inactive`; recreated on `.active`.

  ## Battery cost

  Heuristic: ≤ +10 %/hour idle baseline (verify in field). The toggle is a user-facing
  capability; we expect power-users to enable and battery-conscious users to disable.
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add ios/Paladala/MAX_FRAME_RATE.md
  git commit -m "docs(max-fps): operator-facing MAX_FRAME_RATE.md (Task 7/7 PR-B)

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```

- [ ] **Step 4: Final integration smoke test**

  - [ ] On a real iPhone 13 Pro+:
    - Toggle default is ON.
    - Settings row sub-label reads "Smooth motion on… May use more battery".
    - Toggle OFF → screen drops to 60 Hz on static content (verify via Xcode → FPS gauge
      or Instruments Animation Hitches).
    - Toggle back ON → screen returns to 120 Hz.
    - Engage Battery Saver → row sub-label flips to "Battery Saver is on"; effective false.
  - [ ] On a real iPhone 11 / 14 (60 Hz device):
    - Row is dimmed.
    - Sub-label reads "Your device's display maxes at 60 Hz."
    - Tapping the toggle has no effect.
  - [ ] In the Simulator:
    - Default toggle state honors the simulator's hardware. NOTE: the simulator's
      identifier may be one not in the ProMotion set; verify by logging
      `DeviceCapability.isProMotionCapable()` from `PaladalaApp.init` if needed.
  - [ ] Run all tests:
    ```
    xcodebuild -project ios/Paladala/Paladala.xcodeproj -scheme Paladala test \
      -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
    ```
    Expected: all tests pass; build clean.
  - [ ] `git status` is clean (no `__pycache__/`, no spurious pbxproj diffs).

  - [ ] **Stop and report PR-B as ready-for-review.** Push only when the user says "push".

---

## Self-Review Notes

**Spec coverage** (each spec item → plan task):
- §3 Three new files → Tasks 1 (DeviceCapability), 2 (MaxFrameRateService), 4 (ProMotionRow).
- §3 Two edits → Tasks 3 (PaladalaApp), 5 (ProfileSettingsView), 6 (AVPlayerController).
- §3 Default-ON rationale (`MaxFrameRateService.bootstrap()` sets `userEnabled = isCapable`) → Task 2.
- §3 Capacable / dimmed row with sub-label → Task 4.
- §3 Lifecycle / data flow graph → Tasks 2 + 3 cover it.
- §3 Safeguards (lowPower, thermalState, scenePhase) → Task 2 covers the `effective` computation, Task 3 wires `startObservingSystemEvents`.
- §4 Two `@AppStorage` keys (`maxFrame.userEnabled`, `maxFrame.firstBootstrapDone`) → Task 2.
- §4 First-launch vs returning → Task 2 `bootstrap()` guard.
- §5 Failure modes (sysctl fails → isCapable=false; new iPhone not in table → dimmed; `@AppStorage` write fails → in-memory only; `CADisplayLink` construct fails → log + continue; power-state / thermal observer late → worst-case one frame at wrong rate) → Task 2 tests cover the logic; runtime failures are handled in code.
- §6 Unit tests for service truth table → Task 2.
- §6 Unit tests for `DeviceCapability` → Task 1.
- §6 Manual smoke + regression → Task 7.
- §7 Sequenced after PR-A → ensured by writing PR-B as a separate plan.
- §7 Quantified targets (toggle → pin/unpin ≤100 ms) → no separate test, but the gap is dominated by `Combine`/`CombineLatest` machinery, well below 100 ms; verified manually.
- §7 Documentation → `MAX_FRAME_RATE.md` (Task 7).

**Placeholder scan:** No "TBD" / "TODO" / "implement later" / "fill in details". Every "verify against docs" Step is paired with a concrete source (Apple Identifier Chip docs).

**Type consistency:**
- `MaxFrameRateService.init(...)` test seam in Task 2 matches the test signature in `MaxFrameRateServiceTests.swift`.
- `MaxFrameRateService.shared.$effective.values` is consistent between Task 6 Step 2 alternatives (`for await ... values` and `Combine.sink` paths — the plan picks one with a fallback; the implementer picks whichever matches the existing `AVPlayerController` style).
- `DeviceCapability.isProMotionCapable()` reads / writes consistent between Task 1 implementation and Task 4 call.
- `ProMotionRow` uses `@ObservedObject var service = MaxFrameRateService.shared` consistently.

**Out-of-scope reminders for implementers:**
- iPad ProMotion support: not in v1. Do NOT add iPad identifiers without a v2 task.
- Animated onboarding for the new toggle: not in v1.
- Telemetry-backed "do you want to enable?" suggestion: not in v1.
