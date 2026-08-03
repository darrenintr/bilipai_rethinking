import type { ErrorListResponse, ErrorDetailResponse, ReportRecord } from './types';

const WORKER_URL: string =
  (import.meta.env.PUBLIC_WORKER_URL as string | undefined) ?? 'http://localhost:8787';

export async function fetchErrors(opts: {
  limit?: number;
  cursor?: number;
  app_build?: string;
  error_class?: string;
  since?: number;
  only_unresolved?: boolean;
} = {}): Promise<ErrorListResponse> {
  const url = new URL('/api/errors', WORKER_URL);
  if (opts.limit) url.searchParams.set('limit', String(opts.limit));
  if (opts.cursor) url.searchParams.set('cursor', String(opts.cursor));
  if (opts.app_build) url.searchParams.set('app_build', opts.app_build);
  if (opts.error_class) url.searchParams.set('error_class', opts.error_class);
  if (opts.since) url.searchParams.set('since', String(opts.since));
  if (opts.only_unresolved) url.searchParams.set('only_unresolved', '1');

  const res = await fetch(url.toString());
  if (!res.ok) {
    throw new Error(`worker ${res.status}: ${await res.text()}`);
  }
  return (await res.json()) as ErrorListResponse;
}

export async function fetchErrorDetail(id: number): Promise<ReportRecord> {
  const url = new URL(`/api/errors/${id}`, WORKER_URL);
  const res = await fetch(url.toString());
  if (res.status === 404) {
    throw new Error(`Report #${id} not found`);
  }
  if (!res.ok) {
    throw new Error(`worker ${res.status}: ${await res.text()}`);
  }
  const body = (await res.json()) as ErrorDetailResponse;
  return body.report;
}

export function formatTimestamp(ms: number): string {
  return new Date(ms).toISOString().replace('T', ' ').slice(0, 19) + ' UTC';
}

export function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + '…' : s;
}
