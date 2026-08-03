# Paladala Portal — Design Spec

**Date:** 2026-08-02 (revised in-place; the earlier draft at this path was overtaken by an implementation that began in parallel and has now shipped — see "Reality check" below)
**Branch:** `working`
**Status:** Phase 1 (backend + dashboard) **shipped**. Phase 2 (iOS reporter), Phase 3 (mutation + UI), Phase 4 (CF Access), Phase 5 (domain binding) pending.
**Type:** Cloudflare Worker + Pages + D1 + R2 + iOS reporter

## Reality check

The first draft of this spec (`2026-08-02-opspad-design.md`, now deleted) made several assumptions that diverged from how the portal was actually being built while the assistant was elsewhere:

| Draft assumption | Actual implementation |
|---|---|
| Single Worker, two domain routes | **Worker + Pages, two services, two `wrangler.toml`s** |
| Project name `opspad` | **`paladala-portal`** |
| 3-table D1 (event / case_t / case_event) | **Single `reports` table + FTS5 + sync triggers** |
| iOS dual-write to CF + Telegram | **Server-side fan-out to Telegram** (`tg-fanout.ts`) |
| Heavy classification rules + KV index | **Fingerprint-only dedup; no rules engine; no KV used** |
| Taxonomy preservation via raw strings | **Flat `error_class` + message + stacktrace** (iOS can still emit the existing `DiagnosticLogger.Category` taxonomy as `error_class`) |
| R2 only for stacks >4 KB | **Whole raw body to R2 per report (≤256 KB); HMAC-signed download URL, 5 min TTL** |

This revision replaces the deleted draft and reflects the actual codebase as of 2026-08-02.

## What is already shipped (Phase 1)

### Worker — `portal/worker/src/`

| File | Purpose |
|---|---|
| `index.ts` | `itty-router` entry; routes `/health`, `POST /v1/report`, `GET /api/errors`, `GET /api/errors/:id`, `GET /api/r2/:id`; CORS via `corsHeaders(env)`; zod schema for ingest payload |
| `ingest.ts` | Build-allowlist check (`MIN_APP_BUILD`); defense-in-depth redact; fingerprint; D1 dedup-or-insert (24 h window via `fingerprint + last_seen > now - 24h`); R2 best-effort raw dump; TG fan-out trigger |
| `hmac.ts` | HMAC-SHA256 verify; replay window ±5 min via `X-Timestamp`; constant-time compare |
| `fingerprint.ts` | SHA-256 of `error_class :: message :: normalized_stack_top_8_lines`; normalises paths, line:col, hex addresses, bracketed addresses; lowercased |
| `redact.ts` | Strips `SESSDATA / buvid3/4 / bili_jct / DedeUserID / sid / access_key / refresh_key / appkey / sign`; 40+ char hex; `Authorization: Bearer …`; JSON keys `cookie / cookies / set-cookie / authorization / headers / token / password / sessdata / sign` |
| `api.ts` | List (`cursor`, `app_build`, `error_class`, `since`, `only_unresolved` filters, `limit ≤ 200`); detail; R2 stream with HMAC-signed token |
| `r2-signed.ts` | HMAC-signed R2 download URLs, format `?key=&exp=&mac=`, 5 min TTL |
| `tg-fanout.ts` | Server-side `sendMessage` (MarkdownV2) to `TG_BOT_TOKEN` / `TG_CHAT_ID`; best-effort via `ctx.waitUntil` |
| `types.ts` | `Env`, `ReportPayload`, `ReportRecord`, `IngestResponse`, `ErrorListResponse`, `ErrorDetailResponse` |

### Schema — `portal/worker/migrations/0001_init.sql`

```sql
reports(id PK AUTOINCREMENT, received_at, app_build, app_version, os_version,
        device_model?, locale?, session_id?,
        error_class, message, stacktrace?,
        fingerprint, r2_key?,
        count DEFAULT 1, first_seen, last_seen,
        resolved DEFAULT 0)
+ idx_reports_fingerprint(fingerprint, last_seen DESC)
+ idx_reports_received_at(received_at DESC)
+ idx_reports_app_build(app_build, error_class)
+ idx_reports_error_class(error_class, last_seen DESC)
+ idx_reports_open(resolved, last_seen DESC) WHERE resolved = 0
+ reports_fts(message, stacktrace) FTS5 + sync triggers (ai / ad / au)
```

### Pages — `portal/pages/src/`

| File | Purpose |
|---|---|
| `pages/index.astro` | List page (50 rows; stats cards: Reports / Unique / Open / Last 24h derived client-side from the rows) |
| `pages/error/[id].astro` | Detail page; stacktrace + "Download raw dump" button (calls `/api/errors/:id` which signs R2 URL) |
| `lib/worker.ts` | `fetchErrors`, `fetchErrorDetail`, `formatTimestamp`, `truncate` |
| `lib/types.ts` | Mirror of worker types (re-exports will collapse to a shared package later) |
| `env.d.ts` | `PUBLIC_WORKER_URL` env declaration |

### Deploy — `.github/workflows/portal-deploy.yml`

- Push to `working` with paths under `portal/**` triggers deploy
- Two jobs: `deploy-worker` (`wrangler d1 execute … --remote` + `wrangler deploy`) then `deploy-pages` (`npm run build` + `cloudflare/pages-action@v1`)
- Secrets used: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`

### Endpoint contract (as deployed)

```
POST /v1/report
  Headers: X-Timestamp (unix-ms), X-Signature (hex HMAC-SHA256 of `${ts}.${body}`), Content-Type
  Body (zod-validated):
    {
      "app_build":   "0.5.22.322",   // required, X.Y.Z.N
      "app_version": "0.5.22",        // required, X.Y.Z
      "os_version":  "iOS 18.5",      // required
      "error_class": "NSURLErrorTimedOut",   // required
      "message":     "DNS timeout …", // required, ≤8 KB
      "device_model?": "iPad13,4",
      "locale?":       "zh-HK",
      "session_id?":   "uuid",
      "stacktrace?":   "…",          // ≤64 KB
      "raw?":          { … }         // arbitrary object, will be redacted
    }
  200: { ok: true, report_id, dedup: bool }
  400: invalid_json | invalid_payload
  401: hmac_failed
  403: build_too_old
  500: server_misconfigured (HMAC_SECRET not set)

GET /api/errors?limit=&cursor=&app_build=&error_class=&since=&only_unresolved=
  → { reports: ReportRecord[], next_cursor: number|null }
  // NOTE: not yet behind CF Access — see Phase 4

GET /api/errors/:id
  → { report: ReportRecord & { r2_signed_url?: string } }

GET /api/r2/:id?key=&exp=&mac=
  → Streams the R2 object after HMAC token verifies
```

## What is NOT built (Phases 2-5)

| # | Item | Why now |
|---|---|---|
| 1 | **iOS reporter** (`Diag/LogReporter.swift` + `Diag/LogReporterConfig.swift` + `Diag/HMAC.swift` + Settings toggle + xcconfig) | Without it, the portal has nothing to ingest. Worker just sits empty. |
| 2 | **`PATCH /api/errors/:id`** (toggle `resolved`) | Schema column exists; UI shows it; no way to flip it. |
| 3 | **"Mark resolved" button on detail page** | UI for #2. |
| 4 | **CF Access on `/api/errors/*` and Pages** | Anyone with the URL currently reads errors. Production concern; deferred until iOS reporter is producing real data. |
| 5 | **Worker Routes + Pages custom domain in `wrangler.toml`** | `portal-api.darren.qzz.io` and `portal.darren.qzz.io` not declared. Need DNS / route config before production. |

## Goals

- Personal developer control panel for the Paladala iOS app's diagnostic surface (crashes, network, auth).
- Daily driver for triage: list, filter, drill in, mark resolved, view raw dump.
- Single owner. No multi-user / RBAC / org model.
- $0/month on Cloudflare free tier at ≤500 events/day.

## Non-Goals

- Multi-user / team RBAC.
- Crash symbolication (no `atos` against dSYMs).
- Replacing the user-facing `TelegramLogReporter` "上报日志" flow.
- Native crash capture (SIGSEGV / pre-launch NSException). Future iteration.
- Symbolication / source-mapping.
- Stack-trace dedup across iOS versions (deferred until version tagging is added).

## Constraints (user-confirmed)

| Question | Decision |
|---|---|
| Audience | One owner (the developer) |
| Log source | `pure-bilibili-rethinking` (this repo's iOS app) |
| Existing code (iOS) | Do **not** modify `DiagnosticLogger`, `TelegramLogReporter`, `AppErrorCenter`, `LogViewerView`, `NetworkMonitor` |
| iOS upload trigger | **Opt-in toggle**, default OFF, in Settings → 开发者选项 |
| Auth | HMAC-SHA256; replay window ±5 min; **iOS secret stored in gitignored `.xcconfig`** (NOT in source, NOT in Keychain) |
| Cost target | $0/month on CF free tier for ≤500 events/day |
| Phasing | One PR per phase; Phase 2 is "iOS reporter", Phase 3 is "mutation + UI" |
| Cloudflare account | Available, with `darren.qzz.io` |
| Production domains | `portal-api.darren.qzz.io` (Worker), `portal.darren.qzz.io` (Pages) |
| Telegram notify (Phase 6) | Separate `@BotFather` bot for high-severity DM — **out of MVP** |

## Architecture

```
iOS App                          Cloudflare                            Dashboard
   │                                │                                     │
   │  diagLog(.NETW, msg, details)  │                                     │
   ▼                                │                                     │
Diag/LogReporter  (NEW, Phase 2)   │                                     │
   │  POST /v1/report               │                                     │
   │  X-Timestamp, X-Signature      │                                     │
   ├───────────────────────────────►│  Worker                             │
   │                                │   ├─ verifyHmac (replay ±5min)     │
   │                                │   ├─ payload (zod)                  │
   │                                │   ├─ build ≥ MIN_APP_BUILD ?        │
   │                                │   ├─ redact (defense-in-depth)      │
   │                                │   ├─ fingerprintStacktrace         │
   │                                │   ├─ D1 dedup-or-insert            │
   │                                │   ├─ R2 raw dump (≤256 KB)         │
   │                                │   └─ fanoutToTelegram (best-effort) │
   │                                │       │                             │
   │                                │       ├─► D1 (paladala-portal)      │
   │                                │       ├─► R2 (paladala-diagnostics)│
   │                                │       └─► TG bot (sendMessage)      │
   │                                │                                     │
   │                                │  GET /api/errors[?filters]          │
   │                                │◄────────────────────────────────────│ Pages (Astro SSR)
   │                                │                                     │   - /           list + stats
   │                                │                                     │   - /error/:id  detail + dump
```

Telegram fan-out is server-side. iOS does not talk to Telegram for portal reports. The iOS `TelegramLogReporter` (user-facing manual report) remains untouched and operates independently.

## Schema (current)

See "Schema" above. **Phase 2 does not change D1.** Phase 3 does not change D1 either — `PATCH /api/errors/:id` only flips the existing `resolved` column.

## Auth model

### Server (Worker)

```
HMAC_SECRET  ─► wrangler secret put HMAC_SECRET          (CF dashboard, prod)
            ─► .dev.vars                                  (local dev, gitignored)
```

### iOS (NEW, Phase 2)

```
OPSPAD_HMAC_SECRET ─► ios/Paladala/Config/Opspad.xcconfig
                   ─► .gitignore includes that path
                   ─► Debug.xcconfig (and Release.xcconfig) #include "Config/Opspad.xcconfig"
                   ─► Swift reads via
                       ProcessInfo.processInfo.environment["OPSPAD_HMAC_SECRET"]
                   ─► LogReporterConfig.sharedSecret = env["OPSPAD_HMAC_SECRET"] ?? ""
```

**Trust model**: identical posture to `TelegramLogConfig.botToken` already in source. The TG token lives in `TelegramLogConfig.swift` and is in git history. `Opspad.xcconfig` is **gitignored** so the HMAC secret is *not* in git history. If compromised: rotate via `wrangler secret put HMAC_SECRET` on the Worker, edit local `Opspad.xcconfig`, rebuild IPA.

**Why not Keychain**: user explicitly rejected ("Secret 落盘：不接受"). xcconfig matches existing trust posture and adds nothing on disk at runtime that wasn't already there. See "Auth trade-off" section in the appendix for the rejected alternatives (runtime fetch / asymmetric keypair / CF Access Service Token).

## iOS-side additions (Phase 2)

Three new Swift files; do not touch existing ones.

### `ios/Paladala/Paladala/Diag/LogReporterConfig.swift`

```swift
import Foundation

enum LogReporterConfig {
    /// xcconfig-driven.  Empty string means: do not upload (toggle off OR build misconfigured).
    static var sharedSecret: String {
        ProcessInfo.processInfo.environment["OPSPAD_HMAC_SECRET"] ?? ""
    }
    /// Settings toggle — default OFF.  No default value, so absent key = false.
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "diag.ops.enabled")
    }
    /// Endpoint from xcconfig; defaults to wrangler dev URL.
    static var endpoint: URL {
        let raw = ProcessInfo.processInfo.environment["OPSPAD_ENDPOINT"]
            ?? "http://localhost:8787"
        return URL(string: raw)!
    }
    static let batchSize: Int = 25
    static let flushInterval: TimeInterval = 30
    static let maxRetries: Int = 3
    static let requestTimeout: TimeInterval = 15
    static let userAgent: String = "Paladala-iOS/\(AppVersion.short)"
}
```

### `ios/Paladala/Paladala/Diag/LogReporter.swift`

`actor LogReporter` (sibling to `TelegramLogReporter`):

```swift
public func start() async
    // no-op if !enabled or sharedSecret empty
    // schedule periodic flush() Task
    // subscribe to NetworkMonitor path transitions for offline→online drain

public func report(error: Error, context: String, raw: [String: Any]? = nil)
    // builds ReportPayload
    // enqueue

private func enqueue(_ payload: ReportPayload)
    // append to in-memory ring (cap 1000, oldest evicted)

private func flush() async
    // if batch empty: return
    // take up to .batchSize
    // compute HMAC-SHA256(secret, `${ts}.${body}`) (CryptoKit)
    // POST with retries (1s / 4s / 16s)
    // on 2xx: drop from ring, write "ok" to bpLog
    // on 401: disable reporter + write CRITICAL to bpLog (likely xcconfig mismatch)
    // on 5xx / 429 / network: keep events in ring, back off
```

### `ios/Paladala/Paladala/Diag/HMAC.swift`

Tiny `CryptoKit` helper. One function:

```swift
static func hmacSha256Hex(_ key: SymmetricKey, _ data: Data) -> String
```

Wire format MUST match `portal/worker/src/hmac.ts`:
```
X-Timestamp: <unix-ms>
X-Signature: hex( HMAC-SHA256(secret, `${ts}.${body}`) )
```

### Settings UI toggle (also Phase 2)

Add a section in `ProfileSettingsView` titled "开发者选项". One Toggle: "上报诊断日志到 Paladala Portal". Writes `UserDefaults.standard.set(_, forKey: "diag.ops.enabled")` and calls `LogReporter.shared.start() / .stop()`. Default state: OFF.

### Mapping existing iOS error surface → Worker payload

| Worker field | iOS source |
|---|---|
| `app_build` | `AppVersion.short` (e.g. `0.5.1.301`) |
| `app_version` | `AppVersion.majorMinor` (e.g. `0.5.1`) |
| `os_version` | `"iOS \(UIDevice.current.systemVersion)"` |
| `error_class` | `String(describing: error)` first path component, e.g. `"NSURLErrorTimedOut"` or `"URLError.notConnectedToInternet"` |
| `message` | `error.localizedDescription` (redact-rescanned server-side anyway) |
| `device_model` | `DeviceInfo.shared.modelIdentifier` (e.g. `"iPhone15,3"`) |
| `locale` | `Locale.current.identifier` (e.g. `"en_HK"`) |
| `session_id` | `DeviceInfo.shared.sessionID` — anonymous per-launch UUID (see Open Question 3) |
| `stacktrace` | first 6 KB of stack string (truncate if longer) |
| `raw` | full `details` dict from `DiagnosticLogger.Event`, server-side redacted |

## Phased Plan (revised)

| # | Phase | Deliverable | Verifiable via |
|---|---|---|---|
| 1 | ✅ Backend + dashboard | Worker + Pages + D1 + R2 + CI (already shipped) | `curl https://<worker-url>/health`; live URL returns content |
| 2 | **iOS reporter** | 3 new Swift files + xcconfig + .gitignore + Settings toggle; one PR | CI xcodebuild green; toggle ON → curl-side proof of events landing in D1 |
| 3 | **Mutation + UI** | `PATCH /api/errors/:id` (toggle `resolved`); "Mark resolved" button on detail page; filter on list page | curl PATCH sets `resolved=1`; UI button hides row from default view |
| 4 | **CF Access gate** | Enable CF Access app on `portal.darren.qzz.io` + `portal-api.darren.qzz.io/api/errors/*`; allow your email | Unauthenticated browser → 403; `POST /v1/report` still works without Access |
| 5 | **Domain binding** | Add Worker routes for `portal-api.darren.qzz.io/*`; Pages custom domain `portal.darren.qzz.io` | DNS resolves; both URLs serve content |
| 6 | **Phase 6 TG notify (separate bot)** *(out of MVP)* | Second `@BotFather` bot; Worker notifies on `severity=high` | Defer until phase 2-3 ship and there's real data |
| 7+ | (future) Stats / heatmap / per-rule config / attachments viewer | — | — |

Each phase ends with: green CI run, CHANGELOG entry, and a `curl` / screenshot in this repo's `docs/portal/runbooks/`.

## Decisions log

| Decision | Choice |
|---|---|
| Project name | `paladala-portal` |
| Architecture | Worker + Pages (two services) |
| DB | D1 single `reports` table + FTS5 |
| Auth | HMAC-SHA256 with `X-Timestamp` / `X-Signature`; ±5 min replay window |
| iOS secret storage | gitignored `.xcconfig` (not Keychain, not source) |
| Upload trigger | opt-in Settings toggle, default OFF |
| TG fan-out | server-side, gated on `TG_BOT_TOKEN` + `TG_CHAT_ID` env |
| R2 | raw body per report (≤256 KB); HMAC-signed download URLs, 5 min TTL |
| Production domains | `portal-api.darren.qzz.io` (Worker), `portal.darren.qzz.io` (Pages) |
| CF Access | Phase 4 — defer until iOS reporter lands and there's real data |
| MVP | Phase 2 (iOS reporter) + Phase 3 (mutation + UI); Phases 4-5 follow |
| TG notify (Phase 6) | second bot for high-severity DM; deferred |
| Build allowlist | `MIN_APP_BUILD` Worker var (already shipped) |
| PII redaction | server-side defense-in-depth; client also scrubs sensitive JSON fields before send |

## Auth trade-off (appendix — rejected alternatives)

| Alternative | Why rejected |
|---|---|
| iOS HMAC secret in **Keychain** | User rejected — "Secret 落盘：不接受" |
| iOS HMAC secret in **source** (like `TelegramLogConfig.botToken`) | In git history; riskier than gitignored xcconfig. Picked xcconfig as same trust posture, better hygiene. |
| **Runtime fetch** from `POST /v1/handshake` | The secret would still need to be persisted somewhere to reuse → falls back to Keychain. Chicken-and-egg. |
| **Asymmetric keypair** registered on first launch | Private key has to live somewhere; non-Keychain options can't survive reinstalls → every install is a new identity → fingerprint dedup collapses. |
| **CF Access Service Token** | Replaces HMAC entirely; would require deleting `hmac.ts` and adding JWT validation in `index.ts`. Higher upfront cost; viable Phase 4+ migration if user wants stricter auth. |

## Files NOT to modify

For future contributors / grep-agents searching for context:

iOS:
- `ios/.../DiagnosticLogger.swift` — owned by existing telemetry
- `ios/.../TelegramLogReporter.swift`, `TelegramLogConfig.swift` — owned by user-facing report flow
- `ios/.../AppErrorCenter.swift` — owned by user-facing error UX
- `ios/.../LogViewerView.swift` — manual-user-only path
- `ios/.../NetworkMonitor.swift` — read by the new `LogReporter`; never modified

Worker + Pages under `portal/**`: fair game (and encouraged) for Phase 2-5 work.

## Open Questions (resolve in the Phase 2 implementation plan)

1. **xcconfig discovery**: Is there an existing per-target xcconfig pattern in `ios/Paladala/Paladala.xcodeproj` to follow, or do we create a new one?
2. **Toggle UX copy**: bilingual (zh-Hans + en) label, or zh-Hans only?
3. **`session_id` lifetime**: generate UUID once per process launch (in-memory only), or persist across launches (UserDefaults)? — affects cross-session dedup visibility.
4. **`MIN_APP_BUILD` propagation**: same CI workflow, or manual CF dashboard update?
5. **Error fan-out: hook into `AppErrorCenter` only, or also `DiagnosticLogger` directly?** — affects breadth of what's uploaded.
6. **`raw` payload size**: cap at 16 KB client-side, or trust server's 256 KB R2 ceiling?

These are answered during the *plan* phase, not here.