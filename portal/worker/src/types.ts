/**
 * Shared types for the worker + portal.
 *
 * The portal `<script>` imports these via a relative path and re-exports them
 * verbatim. When you change a field here, regenerate the portal's
 * `src/lib/types.ts` (or have it re-export from a shared file once the
 * monorepo has a TypeScript path alias).
 */

export interface Env {
  // Bindings
  DB: D1Database;
  DIAGNOSTICS: R2Bucket;
  // ALLOWLIST: KVNamespace;  // (disabled in MVP 1; using MIN_APP_BUILD var only)

  // Non-secret vars
  ENVIRONMENT: string;
  MIN_APP_BUILD: string;
  ALLOWED_ORIGIN: string;

  // Secrets (set via `wrangler secret put` or `.dev.vars`)
  HMAC_SECRET: string;
  TG_BOT_TOKEN?: string;
  TG_CHAT_ID?: string;
}

export interface ReportPayload {
  // Required
  app_build: string;          // "0.5.22.322"
  app_version: string;        // "0.5.22"
  os_version: string;         // "iOS 18.5"
  error_class: string;        // "NSException" / Swift error type
  message: string;            // human-readable message (will be redacted)

  // Optional
  device_model?: string;      // "iPad13,4"
  locale?: string;            // "zh-HK"
  session_id?: string;        // anonymous per-launch UUID
  stacktrace?: string;        // multiline stack
  raw?: unknown;              // full diagnostic object (will be redacted)
}

export interface ReportRecord {
  id: number;
  received_at: number;
  app_build: string;
  app_version: string;
  os_version: string;
  device_model: string | null;
  locale: string | null;
  session_id: string | null;
  error_class: string;
  message: string;
  stacktrace: string | null;
  fingerprint: string;
  r2_key: string | null;
  count: number;
  first_seen: number;
  last_seen: number;
  resolved: number;            // 0 = open, 1 = resolved (Phase 2 UI)
  r2_signed_url?: string;      // injected on detail GET
}

export interface IngestResponse {
  ok: true;
  report_id: number;
  dedup: boolean;
}

export interface ErrorListResponse {
  reports: ReportRecord[];
  next_cursor: number | null;
}

export interface ErrorDetailResponse {
  report: ReportRecord;
}
