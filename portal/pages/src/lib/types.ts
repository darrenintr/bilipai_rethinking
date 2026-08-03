/**
 * Mirrors `portal/worker/src/types.ts`. Phase 1 keeps the portal as a thin
 * client; once the monorepo gains a shared `types` package, replace this
 * with `import { ... } from '@paladala/portal-types'`.
 */

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
  resolved: number;
  r2_signed_url?: string;
}

export interface ErrorListResponse {
  reports: ReportRecord[];
  next_cursor: number | null;
}

export interface ErrorDetailResponse {
  report: ReportRecord;
}
