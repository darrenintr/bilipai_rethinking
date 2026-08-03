import type { Env, ReportRecord, ErrorListResponse, ErrorDetailResponse } from './types';
import { jsonResponse } from './ingest';
import { signR2Url } from './r2-signed';

const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;

/**
 * GET /api/errors
 *   ?limit=50
 *   &cursor=<id>           (id < cursor)
 *   &app_build=0.5.22.322
 *   &error_class=NSException
 *   &since=<unix-ms>
 *   &only_unresolved=1
 */
export async function handleErrorList(opts: {
  request: Request;
  env: Env;
}): Promise<Response> {
  const url = new URL(opts.request.url);
  const params = url.searchParams;

  const limit = Math.min(Number(params.get('limit') ?? DEFAULT_LIMIT), MAX_LIMIT);
  const cursor = Number(params.get('cursor') ?? '0');
  const appBuild = params.get('app_build');
  const errorClass = params.get('error_class');
  const since = Number(params.get('since') ?? '0');
  const onlyUnresolved = params.get('only_unresolved') === '1';

  const where: string[] = [];
  const args: unknown[] = [];

  if (cursor > 0) {
    where.push('id < ?');
    args.push(cursor);
  }
  if (appBuild) {
    where.push('app_build = ?');
    args.push(appBuild);
  }
  if (errorClass) {
    where.push('error_class = ?');
    args.push(errorClass);
  }
  if (since > 0) {
    where.push('received_at >= ?');
    args.push(since);
  }
  if (onlyUnresolved) {
    where.push('resolved = 0');
  }

  const whereClause = where.length ? `WHERE ${where.join(' AND ')}` : '';
  const sql = `SELECT * FROM reports ${whereClause} ORDER BY id DESC LIMIT ?`;
  args.push(limit + 1); // fetch one extra to detect "has more"

  const { results } = await opts.env.DB
    .prepare(sql)
    .bind(...args)
    .all<ReportRecord>();

  const hasMore = results.length > limit;
  const reports = hasMore ? results.slice(0, limit) : results;
  const next_cursor = hasMore ? reports[reports.length - 1]!.id : null;

  const body: ErrorListResponse = { reports, next_cursor };
  return jsonResponse(body, 200);
}

/**
 * GET /api/errors/:id
 */
export async function handleErrorDetail(opts: {
  env: Env;
  id: number;
}): Promise<Response> {
  const record = await opts.env.DB
    .prepare('SELECT * FROM reports WHERE id = ?')
    .bind(opts.id)
    .first<ReportRecord>();

  if (!record) {
    return jsonResponse({ error: 'not_found' }, 404);
  }

  // Sign R2 download URL (5 min TTL) if a dump exists
  if (record.r2_key) {
    record.r2_signed_url = await signR2Url({
      env: opts.env,
      reportId: record.id,
      r2Key: record.r2_key,
    });
  }

  const body: ErrorDetailResponse = { report: record };
  return jsonResponse(body, 200);
}

/**
 * GET /api/r2/:id?key=…&exp=…&mac=…
 * Streams a single R2 dump object after verifying the HMAC token.
 */
export async function handleR2Stream(opts: {
  env: Env;
  reportId: number;
  url: URL;
}): Promise<Response> {
  const { env, reportId, url } = opts;
  const r2Key = url.searchParams.get('key');
  const exp = Number(url.searchParams.get('exp'));
  const mac = url.searchParams.get('mac') ?? '';

  if (!r2Key) {
    return jsonResponse({ error: 'missing_key' }, 400);
  }

  const { verifyR2Token } = await import('./r2-signed');
  const verify = await verifyR2Token({ env, reportId, r2Key, exp, mac });
  if (!verify.ok) {
    return jsonResponse({ error: 'invalid_token', reason: verify.reason }, 403);
  }

  const obj = await env.DIAGNOSTICS.get(r2Key);
  if (!obj) {
    return jsonResponse({ error: 'not_found' }, 404);
  }

  return new Response(obj.body, {
    headers: {
      'content-type': obj.httpMetadata?.contentType ?? 'application/json',
      'content-disposition': `attachment; filename="report-${reportId}.json"`,
      'cache-control': 'private, no-cache',
    },
  });
}
