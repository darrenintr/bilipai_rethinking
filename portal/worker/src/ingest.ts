import type { Env, ReportPayload, IngestResponse } from './types';
import { fingerprintStacktrace } from './fingerprint';
import { redactObject, redactString } from './redact';
import { fanoutToTelegram } from './tg-fanout';

const DEDUP_WINDOW_MS = 24 * 60 * 60 * 1000; // 24h
const MAX_R2_BYTES = 256 * 1024;             // 256KB cap per dump

export interface IngestResult {
  response: Response;
  fanout: Promise<void> | null;
}

export async function handleIngest(opts: {
  env: Env;
  payload: ReportPayload;
  rawBody: string;
}): Promise<IngestResult> {
  const { env, payload, rawBody } = opts;

  // 1. Build allow-list
  if (compareBuild(payload.app_build, env.MIN_APP_BUILD) < 0) {
    return {
      response: jsonResponse(
        { error: 'build_too_old', min: env.MIN_APP_BUILD, got: payload.app_build },
        403,
      ),
      fanout: null,
    };
  }

  // 2. Defense-in-depth redact
  payload.message = redactString(payload.message);
  if (payload.stacktrace) {
    payload.stacktrace = redactString(payload.stacktrace);
  }
  if (payload.raw) {
    payload.raw = redactObject(payload.raw);
  }

  // 3. Fingerprint
  const now = Date.now();
  const fingerprint = await fingerprintStacktrace(
    payload.stacktrace,
    payload.error_class,
    payload.message,
  );

  // 4. D1 dedup-or-insert
  const existing = await env.DB
    .prepare(
      `SELECT id, count, first_seen
         FROM reports
        WHERE fingerprint = ? AND last_seen > ?
        ORDER BY last_seen DESC
        LIMIT 1`,
    )
    .bind(fingerprint, now - DEDUP_WINDOW_MS)
    .first<{ id: number; count: number; first_seen: number }>();

  let reportId: number;
  let dedup: boolean;
  let firstSeen: number;

  if (existing) {
    reportId = existing.id;
    firstSeen = existing.first_seen;
    dedup = true;
    await env.DB
      .prepare(`UPDATE reports SET count = count + 1, last_seen = ? WHERE id = ?`)
      .bind(now, reportId)
      .run();
  } else {
    // 5. R2 put (best effort)
    let storedKey: string | null = null;
    if (rawBody.length <= MAX_R2_BYTES) {
      try {
        const r2Key = `reports/${now}-${crypto.randomUUID()}.json`;
        await env.DIAGNOSTICS.put(r2Key, rawBody, {
          httpMetadata: { contentType: 'application/json' },
          customMetadata: {
            app_build: payload.app_build,
            fingerprint,
          },
        });
        storedKey = r2Key;
      } catch (e) {
        console.error('r2_put_failed', e);
      }
    } else {
      console.warn('r2_skipped_too_large', { size: rawBody.length });
    }

    const result = await env.DB
      .prepare(
        `INSERT INTO reports (
           received_at, app_build, app_version, os_version, device_model, locale, session_id,
           error_class, message, stacktrace, fingerprint, r2_key,
           count, first_seen, last_seen
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
      )
      .bind(
        now, payload.app_build, payload.app_version, payload.os_version,
        payload.device_model ?? null, payload.locale ?? null, payload.session_id ?? null,
        payload.error_class, payload.message, payload.stacktrace ?? null,
        fingerprint, storedKey, now, now,
      )
      .run();
    reportId = Number(result.meta.last_row_id);
    firstSeen = now;
    dedup = false;
  }

  // 6. Response
  const responseBody: IngestResponse = { ok: true, report_id: reportId, dedup };
  const response = jsonResponse(responseBody, 200);

  // 7. TG fan-out (best effort, async via ctx.waitUntil in the route handler)
  const fanout = env.TG_BOT_TOKEN && env.TG_CHAT_ID
    ? fanoutToTelegram({ env, payload, reportId, dedup, firstSeen })
    : null;

  return { response, fanout };
}

/**
 * Compare "X.Y.Z.N" build strings. Returns -1, 0, 1.
 */
function compareBuild(a: string, b: string): number {
  const pa = a.split('.').map(Number);
  const pb = b.split('.').map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] ?? 0;
    const y = pb[i] ?? 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

export function jsonResponse(body: unknown, status: number, extraHeaders?: Record<string, string>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json',
      ...(extraHeaders ?? {}),
    },
  });
}
