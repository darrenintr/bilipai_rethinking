import type { Env } from './types';

/**
 * HMAC-signed R2 download URL helper.
 *
 * Wire format:
 *   /api/r2/:id?key=<r2_key>&exp=<unix-secs>&mac=<hex>
 *
 *   - exp: when the URL expires (unix seconds, typically now + 5min)
 *   - mac: hex( HMAC-SHA256(HMAC_SECRET, `${reportId}.${r2Key}.${exp}`) )
 *
 * Server verifies exp > now and mac matches before streaming the object.
 */

const TTL_SECONDS = 5 * 60;

export async function signR2Url(opts: {
  env: Env;
  reportId: number;
  r2Key: string;
}): Promise<string> {
  const exp = Math.floor(Date.now() / 1000) + TTL_SECONDS;
  const mac = await hmacHex(opts.env.HMAC_SECRET, `${opts.reportId}.${opts.r2Key}.${exp}`);
  const qs = new URLSearchParams({
    key: opts.r2Key,
    exp: String(exp),
    mac,
  });
  return `/api/r2/${opts.reportId}?${qs.toString()}`;
}

export async function verifyR2Token(opts: {
  env: Env;
  reportId: number;
  r2Key: string;
  exp: number;
  mac: string;
}): Promise<{ ok: true } | { ok: false; reason: string }> {
  if (!Number.isFinite(opts.exp)) return { ok: false, reason: 'invalid_exp' };
  if (opts.exp < Math.floor(Date.now() / 1000)) return { ok: false, reason: 'expired' };
  const expected = await hmacHex(opts.env.HMAC_SECRET, `${opts.reportId}.${opts.r2Key}.${opts.exp}`);
  if (!constantTimeEqual(expected, opts.mac)) return { ok: false, reason: 'mac_mismatch' };
  return { ok: true };
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
