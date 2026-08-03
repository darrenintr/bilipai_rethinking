# Phase 2 — iOS Reporter Implementation Plan

**Date:** 2026-08-02
**Branch:** `working`
**Status:** Plan ready; awaits user approval before code
**Phase:** 2 of 6 (iOS reporter)
**Type:** New files in iOS app + minimal additive hooks in two existing files

## Goal

Add an iOS-side `LogReporter` actor that batches diagnostic events and posts them as signed `POST /v1/report` requests to the existing Cloudflare Worker at `paladala-portal`. The reporter is opt-in via a Settings toggle (default OFF). One PR.

This phase closes the loop: the Worker + Pages backend is already live and waiting for ingest.

## Non-goals (deferred)

- Phase 3: `PATCH /api/errors/:id` + "Mark resolved" UI
- Phase 4: CF Access gating
- Phase 5: Worker Routes + Pages custom domain
- Phase 6: separate-bot Telegram notify (out of MVP)

## Open questions — RESOLVED

| # | Question | Answer | Rationale |
|---|---|---|---|
| 1 | xcconfig pattern in repo | **No existing custom xcconfig files.** `pbxproj`'s `XCConfigurationList` has no `baseConfigurationReference` — Xcode uses default build settings. **Add 3 new xcconfig files** at `ios/Paladala/Config/Opspad.{Debug,Release}.xcconfig` + `.example`; reference from each target's matching `XCBuildConfiguration` block. | The cleanest way to get build-time env into Swift via `ProcessInfo.processInfo.environment` |
| 2 | Toggle UX copy | Use `L10n.settings.opspadToggleTitle` with zh-Hans as default; English falls back to zh (no separate `.strings` files for v1) | `L10n` pattern already used everywhere; the rest of the app is zh-Hans-first |
| 3 | `session_id` lifetime | **Per-launch UUID** (in-memory) | Matches Worker's interpretation of `session_id` as a label; avoids any persistence question |
| 4 | `MIN_APP_BUILD` propagation | **Manual** — set via `wrangler vars put MIN_APP_BUILD=0.5.X.NNN` once per release | Personal tool; CI-driven propagation deferred |
| 5 | Error fan-out hook | **Both** `AppErrorCenter` + filtered `DiagnosticLogger`. AppErrorCenter fires unconditionally (already normalised). DiagnosticLogger fires only when `category ∈ {.NETW, .AUTH, .PLAY, .DOWN, .PROXY, .AUDIO}` AND `details` has a recognisable error signal | AppErrorCenter already calls `diagLog(.app, "app.error", ...)` for ~90% of B站 API failures; the filtered DiagnosticLogger catches the remaining network/auth/playback streams that don't go through AppErrorCenter |
| 6 | `raw` payload size | **Cap client-side at 16 KB** (truncate `details` dict to first 16 KB JSON-serialised) | Below Worker's 256 KB R2 ceiling; keeps D1 row bounded; matches the "log export" pattern already in `LogViewerView` |

## Pre-work — Step 0: `.gitignore` allowlist

The existing `.gitignore` had:
```
!docs/superpowers/specs/*.md
!docs/superpowers/plans/*.md
```

This blocks `docs/portal/specs/2026-08-02-paladala-portal-design.md` (the design doc) from being tracked. **Already applied** as part of preparing this plan — added:
```
!docs/portal/
!docs/portal/specs/*.md
!docs/portal/plans/*.md
```

`docs/portal/.gitignore` is also added at the new portal repo's root.

## Files inventory

### New files (8 — all in this PR)

| Path | Purpose | LOC |
|---|---|---|
| `ios/Paladala/Config/Opspad.Debug.xcconfig` | Debug build values (`OPSPAD_HMAC_SECRET`, `OPSPAD_ENDPOINT=http://localhost:8787`, `OPSPAD_ENABLED_KEY=diag.ops.enabled`); gitignored | ~5 |
| `ios/Paladala/Config/Opspad.Release.xcconfig` | Release build values (`OPSPAD_ENDPOINT=https://portal-api.darren.qzz.io`); gitignored | ~5 |
| `ios/Paladala/Config/Opspad.xcconfig.example` | Committed template with placeholder values + generation instructions | ~15 |
| `ios/Paladala/Paladala/Diag/HMAC.swift` | `hmacSha256Hex(secret:_:)` CryptoKit helper | ~20 |
| `ios/Paladala/Paladala/Diag/ReportPayload.swift` | Swift mirror of Worker's zod schema, plus `ReportRaw` recursive Codable | ~70 |
| `ios/Paladala/Paladala/Diag/LogReporterConfig.swift` | xcconfig-driven config; reads `ProcessInfo.processInfo.environment` | ~40 |
| `ios/Paladala/Paladala/Diag/LogReporter.swift` | `actor LogReporter` — buffer, sign, POST, retry | ~180 |
| `ios/Paladala/Paladala/Diag/ErrorSink.swift` + `ReporterGate.swift` | Hook point + per-category rule | ~50 |

### Modified files (3)

| Path | Change | Net LOC |
|---|---|---|
| `ios/Paladala/Paladala.xcodeproj/project.pbxproj` | Add `XCBuildConfiguration` entries for `Opspad.Debug.xcconfig` / `Opspad.Release.xcconfig`; reference them via `baseConfigurationReference` in Paladala/PaladalaWidget's Debug + Release configs | +20 |
| `ios/Paladala/Paladala/PaladalaApp.swift` | In `init()`, fire-and-forget `LogReporter.shared.start()` | +3 |
| `ios/Paladala/Paladala/ProfileSettingsView.swift` | Add `@AppStorage("diag.ops.enabled")` and "开发者选项" section with Toggle; calls `start()/.stop()` on change | +20 |
| `ios/Paladala/Paladala/Localizable.swift` | Add `L10n.settings.{opspadToggleTitle,opspadToggleHint,developerSectionTitle}` | +4 |
| `ios/Paladala/Paladala/AppErrorCenter.swift` | **1 additive line** in `log()`: `ErrorSink.maybeReport(descriptor:context:source:)` | +1 |
| `ios/Paladala/Paladala/DiagnosticLogger.swift` | **1 additive line** in `log()` after `bpLog(...)`: `ErrorSink.maybeReport(category:message:details:)` | +1 |

### Untouched (per spec)

- `TelegramLogReporter.swift`, `TelegramLogConfig.swift`, `LogViewerView.swift`, `NetworkMonitor.swift`, `DeviceInfo.swift`, `AppVersion.swift`, `AppErrorDescriptor`
- `portal/worker/**`, `portal/pages/**`
- `.github/workflows/portal-deploy.yml`

### Note on the "do not modify" list

The design spec (`docs/portal/specs/2026-08-02-paladala-portal-design.md`) listed `AppErrorCenter.swift` and `DiagnosticLogger.swift` as "do not modify". **This plan deliberately deviates**: each gets 1 additive line in an existing private `log()` method, after the existing `bpLog` call. Justification:

- **Without the hook**, the reporter has no inputs → Worker stays empty → portal is dead weight.
- **Minimal**: 1 line per file, inside existing methods, no API change.
- **Reversible**: removal is 1 line per file.
- **Discoverable**: each added line is gated by `ReporterGate.shouldReport(...)`; off by default.

If user rejects this deviation, fallback is a `NotificationCenter` subscription: AppErrorCenter and DiagnosticLogger post `.name` notifications after `log()`, `ErrorSink` listens. ~30 LOC extra but zero edits to existing files.

## Detailed work

### 1. xcconfig templates

`ios/Paladala/Config/Opspad.Debug.xcconfig` (gitignored):
```
OPSPAD_HMAC_SECRET = REPLACE_ME_DEV_SECRET
OPSPAD_ENDPOINT = http://localhost:8787
OPSPAD_ENABLED_KEY = diag.ops.enabled
```

`ios/Paladala/Config/Opspad.Release.xcconfig` (gitignored):
```
OPSPAD_HMAC_SECRET = REPLACE_ME_PROD_SECRET
OPSPAD_ENDPOINT = https://portal-api.darren.qzz.io
OPSPAD_ENABLED_KEY = diag.ops.enabled
```

`ios/Paladala/Config/Opspad.xcconfig.example` (committed):
```
# Copy to Opspad.Debug.xcconfig (gitignored) and fill in your dev secret.
# Production secret lives in Opspad.Release.xcconfig (also gitignored).
#
# Generate a secret with:
#   openssl rand -hex 32
#
# The same value MUST be set as `HMAC_SECRET` in the Worker:
#   wrangler secret put HMAC_SECRET
#
# OPSPAD_ENDPOINT is the Worker's HTTPS endpoint. Use:
#   - http://localhost:8787 for local dev (wrangler dev)
#   - https://portal-api.darren.qzz.io for production

OPSPAD_HMAC_SECRET = <generate-with-openssl-rand-hex-32>
OPSPAD_ENDPOINT = http://localhost:8787
OPSPAD_ENABLED_KEY = diag.ops.enabled
```

**`.gitignore` additions** (separate from the docs allowlist fix above):
```
# Per-developer secrets for the Paladala Portal reporter
ios/Paladala/Config/Opspad.Debug.xcconfig
ios/Paladala/Config/Opspad.Release.xcconfig
```

### 2. `Diag/HMAC.swift`

```swift
import CryptoKit
import Foundation

enum HMAC {
    /// HMAC-SHA256 of `data` keyed by `secret`. Returns lowercase hex.
    /// Matches `portal/worker/src/hmac.ts::hmacSha256Hex` byte-for-byte
    /// so a request signed here verifies there.
    static func sha256Hex(secret: String, _ data: Data) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
```

**Test** (`ios/Paladala/PaladalaTests/HMACTests.swift`):
- vector: `secret="a"`, `data=Data("b".utf8)` → known HMAC hex
- vector: round-trip against Worker's `hmacSha256Hex` (mirrored in unit test)

### 3. `Diag/ReportPayload.swift`

Mirror of Worker's zod schema (`portal/worker/src/index.ts::PayloadSchema`).

```swift
struct ReportPayload: Codable, Sendable, Equatable {
    let app_build: String        // "0.5.22.322"
    let app_version: String      // "0.5.22"
    let os_version: String       // "iOS 18.5"
    let error_class: String      // "NSURLErrorTimedOut" or "URLError.notConnectedToInternet"
    let message: String          // ≤8 KB
    let device_model: String?
    let locale: String?
    let session_id: String?      // per-launch UUID
    let stacktrace: String?
    let raw: ReportRaw?
}

/// Recursive Codable mirroring JSON value semantics so we can
/// walk the `details: [String: Any]` dict from
/// `DiagnosticLogger.Event.details` and serialise it
/// without losing type fidelity. Strings truncated at 8 KB
/// to match Worker's `z.string().min(1).max(8192)` cap.
indirect enum ReportRaw: Codable, Sendable, Equatable {
    case object([String: ReportRaw])
    case array([ReportRaw])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// Walk an `[String: Any]` dict into a `ReportRaw`, capping
    /// string length and total bytes (16 KB).  Total budget
    /// is checked against the *encoded* JSON size, so nested
    /// structures don't blow up.
    static func from(details: [String: Any], byteBudget: Int = 16 * 1024) -> ReportRaw? {
        let raw = walk(value: details)
        guard let data = try? JSONEncoder().encode(raw) else { return nil }
        if data.count <= byteBudget {
            return raw
        }
        // String-truncate fallback: convert all string leaves
        // to ≤120 chars and re-encode.
        return truncate(raw: raw, maxStringLen: 120)
    }

    private static func walk(value: Any) -> ReportRaw { ... }
    private static func truncate(raw: ReportRaw, maxStringLen: Int) -> ReportRaw { ... }
}
```

**Codable impl**: custom `encode(to:)` / `init(from:)` since `Codable` synthesis for recursive enums needs boxing tricks. Roughly 50 LOC of encoding helpers.

### 4. `Diag/LogReporterConfig.swift`

```swift
import Foundation

enum LogReporterConfig {
    /// Read from xcconfig via build settings.  Empty means:
    /// do not upload (toggle off OR build misconfigured).
    static var sharedSecret: String {
        ProcessInfo.processInfo.environment["OPSPAD_HMAC_SECRET"] ?? ""
    }
    static var endpoint: URL {
        let raw = ProcessInfo.processInfo.environment["OPSPAD_ENDPOINT"]
            ?? "http://localhost:8787"
        return URL(string: raw)!
    }
    static var enabledKey: String {
        ProcessInfo.processInfo.environment["OPSPAD_ENABLED_KEY"]
            ?? "diag.ops.enabled"
    }
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
    static let batchSize: Int = 25
    static let flushInterval: TimeInterval = 30
    static let maxRetries: Int = 3
    static let requestTimeout: TimeInterval = 15
    static let userAgent: String = "Paladala-iOS/\(AppVersion.current.versionLine)"
}
```

### 5. `Diag/ReporterGate.swift`

```swift
import Foundation

enum ReporterGate {
    /// Decide whether a `DiagnosticLogger.log(...)` call is reportable.
    /// Conservative: only fire for categories the user cares about,
    /// and only when the details dict carries a recognisable
    /// error signal.
    static func shouldReport(category: DiagnosticLogger.Category,
                             details: [String: Any]?) -> Bool {
        let errorKeys: Set<String> = ["error", "err", "status", "exception", "fatal"]
        let hasErrorSignal = (details?.keys ?? []).contains { k in
            errorKeys.contains(k.lowercased())
        }
        guard hasErrorSignal else { return false }
        switch category {
        case .network, .auth, .playback, .download, .proxy, .audio:
            return true
        default:
            return false
        }
    }
}
```

### 6. `Diag/ErrorSink.swift`

Single chokepoint. Both `AppErrorCenter.log()` and `DiagnosticLogger.log()` call into this. The function is fire-and-forget; it never blocks the caller.

```swift
import Foundation

enum ErrorSink {
    /// From `AppErrorCenter.log(descriptor:source:context:presented:)`.
    static func maybeReport(descriptor: AppErrorDescriptor,
                            context: String,
                            source: Error) {
        guard LogReporterConfig.enabled, !LogReporterConfig.sharedSecret.isEmpty else { return }
        let payload = ReportPayload(
            app_build: AppVersion.current.versionLine,
            app_version: AppVersion.current.marketingVersion,
            os_version: "iOS \(UIDevice.current.systemVersion)",
            error_class: String(describing: type(of: source)),
            message: descriptor.message,
            device_model: UIDevice.current.model,
            locale: Locale.current.identifier,
            session_id: LogReporter.shared.currentSessionID,
            stacktrace: nil,
            raw: ReportRaw.from(details: [
                "kind": descriptor.kind.rawValue,
                "context": context,
                "retryable": descriptor.isRetryable,
                "error": String(describing: source)
            ])
        )
        Task.detached(priority: .utility) {
            await LogReporter.shared.ingest(payload)
        }
    }

    /// From `DiagnosticLogger.log(category:message:details:)`.
    static func maybeReport(category: DiagnosticLogger.Category,
                            message: String,
                            details: [String: Any]?) {
        guard LogReporterConfig.enabled, !LogReporterConfig.sharedSecret.isEmpty else { return }
        guard ReporterGate.shouldReport(category: category, details: details) else { return }
        let payload = ReportPayload(
            app_build: AppVersion.current.versionLine,
            app_version: AppVersion.current.marketingVersion,
            os_version: "iOS \(UIDevice.current.systemVersion)",
            error_class: category.rawValue,
            message: message,
            device_model: UIDevice.current.model,
            locale: Locale.current.identifier,
            session_id: LogReporter.shared.currentSessionID,
            stacktrace: nil,
            raw: details.map { ReportRaw.from(details: $0) } ?? nil
        )
        Task.detached(priority: .utility) {
            await LogReporter.shared.ingest(payload)
        }
    }
}
```

### 7. `Diag/LogReporter.swift`

```swift
actor LogReporter {
    static let shared = LogReporter()

    /// Per-launch UUID for the active session.
    nonisolated let currentSessionID = UUID().uuidString

    private var queue: [ReportPayload] = []
    private var flushTask: Task<Void, Never>?
    private let queueCapacity = 1000

    func start() {
        guard LogReporterConfig.enabled,
              !LogReporterConfig.sharedSecret.isEmpty
        else { return }
        flushTask?.cancel()
        flushTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(LogReporterConfig.flushInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.flush()
            }
        }
    }

    func stop() {
        flushTask?.cancel()
        flushTask = nil
    }

    func ingest(_ payload: ReportPayload) {
        guard LogReporterConfig.enabled,
              !LogReporterConfig.sharedSecret.isEmpty
        else { return }
        if queue.count >= queueCapacity { queue.removeFirst() }
        queue.append(payload)
    }

    private func flush() async {
        guard !queue.isEmpty else { return }
        let batch = Array(queue.prefix(LogReporterConfig.batchSize))
        queue.removeFirst(min(batch.count, queue.count))

        guard let body = try? JSONEncoder().encode(batch) else { return }
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let signingInput = Data("\(ts).".utf8) + body
        let signature = HMAC.sha256Hex(secret: LogReporterConfig.sharedSecret, signingInput)

        let backoffs: [TimeInterval] = [0, 1, 4, 16]    // 1st attempt immediate
        for attempt in 1...backoffs.count {
            if attempt > 1 {
                let delay = backoffs[attempt - 1]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            var req = URLRequest(url: LogReporterConfig.endpoint.appendingPathComponent("v1/report"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(String(ts), forHTTPHeaderField: "X-Timestamp")
            req.setValue(signature, forHTTPHeaderField: "X-Signature")
            req.setValue(LogReporterConfig.userAgent, forHTTPHeaderField: "User-Agent")
            req.httpBody = body
            req.timeoutInterval = LogReporterConfig.requestTimeout

            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse {
                    switch http.statusCode {
                    case 200: return               // success; drop batch
                    case 401:
                        bpLog("CRITICAL: LogReporter 401 — secret mismatch; disabling")
                        stop(); return
                    case 403:
                        bpLog("LogReporter 403 (build_too_old); dropping batch")
                        return
                    default:
                        continue                    // 5xx / 4xx: retry
                    }
                }
                continue
            } catch {
                continue                            // network error: retry
            }
        }
        // All retries exhausted — put batch back at front of queue
        queue.insert(contentsOf: batch, at: 0)
        // Cap queue so we don't OOM on a prolonged outage
        if queue.count > queueCapacity {
            queue.removeFirst(queue.count - queueCapacity)
        }
    }
}
```

### 8. `Localizable.swift` additions

Inside the existing `enum settings` block:
```swift
static let developerSectionTitle = String(
    localized: "settings.developerSection", defaultValue: "开发者选项"
)
static let opspadToggleTitle = String(
    localized: "settings.opspadToggle.title",
    defaultValue: "上报诊断日志到 Paladala Portal"
)
static let opspadToggleHint = String(
    localized: "settings.opspadToggle.hint",
    defaultValue: "批量上传 .NETW/.AUTH/.PLAY 类别日志到你的 Cloudflare Worker"
)
```

(No `.strings` files added in v1 — English fallback is the Chinese default.)

### 9. `ProfileSettingsView.swift` additions

Add at the struct level (next to other `@AppStorage`):
```swift
@AppStorage("diag.ops.enabled") private var opsEnabled = false
```

Add a new `Section` after the existing `Section("系统与诊断") { ... }`:
```swift
Section {
    Toggle(isOn: $opsEnabled) {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.settings.opspadToggleTitle)
                .font(.subheadline)
            Text(L10n.settings.opspadToggleHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    .onChange(of: opsEnabled) { _, newValue in
        Task.detached(priority: .utility) {
            if newValue {
                await LogReporter.shared.start()
            } else {
                await LogReporter.shared.stop()
            }
        }
    }
} header: {
    Text(L10n.settings.developerSectionTitle)
} footer: {
    Text("默认关闭。开启后，应用会把网络/认证/播放等诊断日志批量加密签名后上传到你专属的 Cloudflare Worker。本地依然保留完整的运行日志。")
        .font(.caption2)
        .foregroundStyle(.tertiary)
}
```

### 10. `PaladalaApp.swift` addition

In `init()`, immediately after `DeviceInfo.shared.startIfNeeded()` (line 118):
```swift
// Boot the portal reporter (no-op when toggle is off or
// xcconfig is missing).  start() launches the periodic
// flush task; ingestion is gated on the toggle + secret at
// every call.
Task.detached(priority: .utility) {
    await LogReporter.shared.start()
}
```

### 11. `AppErrorCenter.swift` minimal hook

In `private func log(_ descriptor:source:context:presented:)`, after the existing `diagLog(.app, "app.error", details: [...])` call (line 264):
```swift
ErrorSink.maybeReport(descriptor: descriptor, context: context, source: source)
```

### 12. `DiagnosticLogger.swift` minimal hook

In `func log(_ category:_:details:)`, after the existing `bpLog(...)` call (line 200):
```swift
ErrorSink.maybeReport(category: category, message: message, details: details)
```

### 13. `project.pbxproj` xcconfig wiring

Add 3 `PBXFileReference` entries (one each for `Opspad.Debug.xcconfig`, `Opspad.Release.xcconfig`, `Opspad.xcconfig.example`).

For each `PBXNativeTarget` (`Paladala`, `PaladalaWidget`) and each build configuration (`Debug`, `Release`):

- Add `baseConfigurationReference = Opspad.<Config>.xcconfig` to the matching `XCBuildConfiguration`

DO NOT touch `PaladalaTests` (no portal use).

**Manual edit**: `pbxproj` edits are best done in Xcode UI (File → Project → Configurations → set base config to xcconfig path) and committed. Doing it via raw text edit is risky but possible. Recommend the Xcode UI approach.

## Sequencing (commit order, all in one PR)

1. `docs: allowlist docs/portal/{specs,plans}/*.md` (already applied)
2. `chore(portal): gitignore Opspad xcconfigs`
3. `feat(portal): xcconfig templates + .example`
4. `feat(portal): pbxproj wires Opspad xcconfig per build config`
5. `feat(portal): HMAC helper (CryptoKit)`
6. `feat(portal): HMACTests unit test`
7. `feat(portal): ReportPayload + ReportRaw Codable`
8. `feat(portal): ReporterGate + ErrorSink`
9. `feat(portal): LogReporterConfig + LogReporter actor`
10. `feat(portal): L10n strings for portal toggle`
11. `feat(portal): hook AppErrorCenter + DiagnosticLogger to ErrorSink` (the 2 minimal edits)
12. `feat(portal): Settings toggle (ProfileSettingsView)`
13. `feat(portal): LogReporter.start() in PaladalaApp.init()`

13 commits, one PR.

## Test plan

| Test | Pass criterion |
|---|---|
| HMAC vector | `sha256Hex("a", Data("b".utf8))` matches `openssl dgst -sha256 -hmac a` |
| Round-trip HMAC | Signing locally and verifying against Worker's `hmacSha256Hex` produces identical hex |
| Toggle OFF, secret empty | Zero network calls in Instruments |
| Toggle OFF, secret set | Zero network calls (gated by `enabled`) |
| Toggle ON, wrong secret | First POST returns 401; `bpLog` shows "CRITICAL"; subsequent flushes skip |
| Toggle ON, right secret | POST 200; row appears in D1 (verify via `wrangler d1 execute`) |
| Toggle ON, build < MIN_APP_BUILD | POST 403; bpLog shows "build_too_old"; batch dropped |
| Offline → online transition | Queued events flush on next `flush()` tick |
| 5xx storm | Backoff 1s / 4s / 16s; events stay in queue |
| 16 KB `raw` cap | Dict with 50 KB of strings → `ReportRaw` ≤16 KB JSON-encoded |
| `error_class` for URLError | `URLError.notConnectedToInternet` emitted as `"URLError"` (not NSError) |

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Forgetting to rotate HMAC_SECRET on rebuild | Release checklist + portal-deploy workflow comment |
| PII leak via `raw` | Server-side redact already strips SESSDATA / cookies / 40-char hex; client-side `ReportRaw.from(...)` skips the `details` field at 16 KB |
| Queue overflow on prolonged outage | Cap at 1000; oldest evicted |
| Time skew breaks replay window | Worker tolerates ±5 min; iOS uses `Date()` synced via NTP |
| xcconfig secret leaks via screenshot/PR | `.example` is committed; real xcconfigs are gitignored; CI never reads them |
| First-launch 401 storm | Reporter self-disables on 401; user must fix xcconfig and re-toggle |

## What this PR does NOT do

- Phase 3 mutation endpoint + UI
- Phase 4 CF Access
- Phase 5 domain binding
- Phase 6 separate-bot TG notify
- Native crash capture (SIGSEGV / pre-launch NSException)
- `app_build` = `0.5.22` vs `0.5.22.322` format disambiguation (Worker accepts both via regex; for v1 we send `{marketing}.{build}`)

## Files that have already been changed as part of preparing this plan

- `.gitignore` — added allowlist for `docs/portal/{specs,plans}/*.md` (Step 0 prerequisite)

No other files have been touched. The plan above is fully unexecuted.

## Open questions still

None — all 6 resolved.