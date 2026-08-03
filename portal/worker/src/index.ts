import { Router, type IRequest } from 'itty-router';
import { z } from 'zod';
import type { Env, ReportPayload } from './types';
import { verifyHmac } from './hmac';
import { handleIngest, jsonResponse } from './ingest';
import { handleErrorList, handleErrorDetail, handleR2Stream } from './api';

type Params = Request & { params: Record<string, string> };

const PayloadSchema = z.object({
  app_build: z.string().regex(/^\d+\.\d+\.\d+\.\d+$/, 'app_build must be X.Y.Z.N'),
  app_version: z.string().regex(/^\d+\.\d+\.\d+$/),
  os_version: z.string().min(1).max(64),
  error_class: z.string().min(1).max(256),
  message: z.string().min(1).max(8192),
  device_model: z.string().max(128).optional(),
  locale: z.string().max(32).optional(),
  session_id: z.string().max(64).optional(),
  stacktrace: z.string().max(65536).optional(),
  raw: z.unknown().optional(),
});

const router = Router<Request, [Env, ExecutionContext]>();

// ---------- Health ----------
router.get('/health', () => jsonResponse({ ok: true, ts: Date.now() }, 200));

// ---------- Ingest ----------
router.post('/v1/report', async (request, env, ctx) => {
  // 1. Read raw body (text, byte-exact)
  const body = await request.text();

  // 2. HMAC verify
  if (!env.HMAC_SECRET) {
    return jsonResponse(
      { error: 'server_misconfigured', reason: 'HMAC_SECRET not set' },
      500,
    );
  }
  const signature = request.headers.get('x-signature') ?? '';
  const timestamp = request.headers.get('x-timestamp') ?? '';
  const hmac = await verifyHmac({
    secret: env.HMAC_SECRET,
    body,
    signature,
    timestamp,
    nowMs: Date.now(),
  });
  if (!hmac.ok) {
    return jsonResponse({ error: 'hmac_failed', reason: hmac.reason }, 401);
  }

  // 3. Parse + validate
  let json: unknown;
  try {
    json = JSON.parse(body);
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }
  const parsed = PayloadSchema.safeParse(json);
  if (!parsed.success) {
    return jsonResponse(
      { error: 'invalid_payload', issues: parsed.error.issues.slice(0, 5) },
      400,
    );
  }
  const payload: ReportPayload = parsed.data;

  // 4. Ingest
  const { response, fanout } = await handleIngest({ env, payload, rawBody: body });

  // 5. Schedule fan-out (best effort)
  if (fanout) ctx.waitUntil(fanout);

  return response;
});

// ---------- Read API (CF Access protected in prod) ----------
router.get('/api/errors', (request, env) => handleErrorList({ request, env }));
router.get<Params>('/api/errors/:id', (request, env) => {
  const id = Number(request.params.id);
  if (!Number.isFinite(id) || id <= 0) {
    return jsonResponse({ error: 'invalid_id' }, 400);
  }
  return handleErrorDetail({ env, id });
});
router.get<Params>('/api/r2/:id', (request, env) => {
  const id = Number(request.params.id);
  if (!Number.isFinite(id) || id <= 0) {
    return jsonResponse({ error: 'invalid_id' }, 400);
  }
  return handleR2Stream({ env, reportId: id, url: new URL(request.url) });
});

// ---------- 404 ----------
router.all('*', () => jsonResponse({ error: 'not_found' }, 404));

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    // CORS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: corsHeaders(env),
      });
    }

    const response = await router.fetch(request, env, ctx);
    // Attach CORS headers to the response
    const headers = new Headers(response.headers);
    for (const [k, v] of Object.entries(corsHeaders(env))) {
      headers.set(k, v);
    }
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};

function corsHeaders(env: Env): Record<string, string> {
  return {
    'access-control-allow-origin': env.ALLOWED_ORIGIN,
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'content-type, x-signature, x-timestamp',
    'access-control-max-age': '86400',
  };
}
