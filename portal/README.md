# Paladala Developer Portal

Cloudflare Worker + D1 + R2 + Astro, sitting behind CF Access (email OTP).

Replaces the legacy "POST diagnostic to Telegram" path with a structured ingest
pipeline. Telegram becomes a **backup** fan-out (best effort, async).

## Layout

```
portal/
├── worker/           # Cloudflare Worker (TS, wrangler)
│   ├── src/          # routes, HMAC, fingerprint, redact, ingest, api
│   ├── migrations/   # D1 schema versions (wrangler-compatible)
│   ├── wrangler.toml # D1 + R2 + vars
│   └── .dev.vars     # dev-only secrets (HMAC_SECRET, optional TG_*)
├── pages/            # Astro portal
│   └── src/          # pages + lib/worker.ts typed client
└── scripts/          # smoke-test.ps1
```

## Quick start (local dev, no CF account needed)

```bash
# 1. Install
cd portal/worker && npm install
cd ../pages     && npm install

# 2. Apply D1 schema to local SQLite (miniflare)
cd ../worker
npx wrangler d1 execute paladala-portal --local --file=./migrations/0001_init.sql

# 3. Run worker (terminal A)
npx wrangler dev
# → http://127.0.0.1:8787

# 4. Run pages (terminal B)
cd ../pages
npm run dev
# → http://127.0.0.1:4321
```

`wrangler dev` reads `.dev.vars` for `HMAC_SECRET`. The default value in
`.dev.vars` is fine for local development.

## Smoke test (PowerShell)

```powershell
cd portal
.\scripts\smoke-test.ps1
```

This will:
1. Read `HMAC_SECRET` from `worker/.dev.vars`
2. POST a fake report to `http://127.0.0.1:8787/v1/report` (HMAC-signed)
3. GET `http://127.0.0.1:8787/api/errors` and verify the report appears

## Production setup

### 1. Create Cloudflare resources

```bash
# D1
wrangler d1 create paladala-portal
# → paste the returned id into `wrangler.toml` `[[d1_databases]].database_id`

# R2
wrangler r2 bucket create paladala-diagnostics

# KV (Phase 2 — per-build allow-list)
# wrangler kv namespace create ALLOWLIST
```

### 2. Set secrets

```bash
cd portal/worker
wrangler secret put HMAC_SECRET       # required
wrangler secret put TG_BOT_TOKEN      # optional, for fan-out
wrangler secret put TG_CHAT_ID        # optional, for fan-out
```

### 3. Apply D1 migrations to remote

```bash
cd portal/worker
npx wrangler d1 execute paladala-portal --remote --file=./migrations/0001_init.sql
```

### 4. Deploy Worker

```bash
npx wrangler deploy
# → https://paladala-portal.<account>.workers.dev
```

### 5. Deploy Pages

```bash
cd ../pages
PUBLIC_WORKER_URL="https://paladala-portal.<account>.workers.dev" npm run build
npx wrangler pages deploy ./dist --project-name=paladala-portal
# → https://paladala-portal.pages.dev
```

### 6. CF Access (gate the portal)

In the Cloudflare dashboard:
- Zero Trust → Access → Applications → Add → Self-hosted
- Application domain: `paladala-portal.pages.dev`
- Policy: Allow your email (or a team email group)

The worker (`/api/*`) is also gated in front of the same Access app.

## CI

`.github/workflows/portal-deploy.yml` deploys on push to `working` when files
under `portal/**` change.

Required GitHub repo secrets:
- `CLOUDFLARE_API_TOKEN` — token with `Workers Scripts:Edit`,
  `D1:Edit`, `R2:Edit`, `Pages:Edit` permissions
- `CLOUDFLARE_ACCOUNT_ID`

Required GitHub repo vars:
- `PORTAL_WORKER_URL` — the deployed Worker URL (e.g.
  `https://paladala-portal.<account>.workers.dev`)

## App-side integration (TODO — not in Phase 1)

The iOS app's existing `ReportLogView` currently POSTs directly to the
Telegram Bot API. To switch to the new path:

1. Add `workerBaseURL` and `hmacSecret` to `BiliAppConfig`
2. Replace the TG POST with a `ReportLogClient.swift` that:
   - Computes HMAC-SHA256(secret, `${ts}.${body}`) and sends
     `X-Signature: <hex>` + `X-Timestamp: <unix-ms>`
   - On 2xx: success
   - On failure: falls back to the existing TG Bot API path
3. `DiagnosticRedactor.swift` strips SESSDATA / buvid3 / `Cookie:`
   headers before either path

(Out of scope for Phase 1 worker MVP — only the server is shipped here.)

## API

### `POST /v1/report`

Headers:
- `X-Timestamp: <unix-ms>` (±5 min)
- `X-Signature: hex( HMAC-SHA256(HMAC_SECRET, "${ts}.${body}") )`
- `Content-Type: application/json`

Body (all fields required unless noted):
```json
{
  "app_build":   "0.5.22.322",
  "app_version": "0.5.22",
  "os_version":  "iOS 18.5",
  "error_class": "NSException",
  "message":     "...",
  "device_model": "iPad13,4",
  "locale":      "zh-HK",
  "session_id":  "...",
  "stacktrace":  "...",
  "raw":         { /* full diagnostic, will be redacted server-side */ }
}
```

Response: `{ "ok": true, "report_id": 42, "dedup": false }`

### `GET /api/errors`

Query params: `limit` (≤200), `cursor`, `app_build`, `error_class`,
`since` (unix-ms), `only_unresolved` (1/0).

Response: `{ "reports": [...], "next_cursor": 1234 | null }`

### `GET /api/errors/:id`

Response: `{ "report": ReportRecord }`. If the record has an `r2_key`,
the response includes `r2_signed_url` (5-min HMAC-signed link).

### `GET /api/r2/:id?key=…&exp=…&mac=…`

Streams a raw diagnostic dump from R2. The `exp` and `mac` query params
come from `r2_signed_url` in the detail response. Verify `exp` > now
and `mac === hex(HMAC-SHA256(HMAC_SECRET, "${id}.${key}.${exp}"))` server-side.

## Phase plan

- ✅ **Phase 1** — Worker ingest, D1 + R2, Astro placeholder
- ✅ **Phase 1.5** — Detail page `/error/:id` + R2 signed download
- ⏳ Phase 2 — FTS5 search UI, mark-resolved, timeline graph
- ⏳ Phase 3 — Analytics Engine + spike detection + Discord/Slack webhook
