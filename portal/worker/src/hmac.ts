/**
 * HMAC-SHA256 verify.
 *
 * Wire format:
 *   X-Timestamp: <unix-ms, sent by client>
 *   X-Signature: hex( HMAC-SHA256(secret, `${ts}.${body}`) )
 *
 * Replay protection: ±5 min window.
 *
 * The client MUST use the same canonical byte sequence (raw request body)
 * for both the request and the signature input. The server reads `body` as
 * text, which is byte-for-byte equivalent for any non-binary JSON payload.
 */
export async function verifyHmac(opts: {
  secret: string;
  body: string;
  signature: string;
  timestamp: string;
  nowMs: number;
}): Promise<{ ok: true } | { ok: false; reason: string }> {
  const { secret, body, signature, timestamp, nowMs } = opts;

  // 1. Parse timestamp
  const ts = Number(timestamp);
  if (!Number.isFinite(ts)) {
    return { ok: false, reason: 'invalid_timestamp' };
  }

  // 2. Replay window
  if (Math.abs(nowMs - ts) > 5 * 60 * 1000) {
    return { ok: false, reason: 'timestamp_out_of_window' };
  }

  // 3. Constant-time compare
  const expected = await hmacSha256Hex(secret, `${ts}.${body}`);
  if (!constantTimeEqual(expected, signature)) {
    return { ok: false, reason: 'signature_mismatch' };
  }

  return { ok: true };
}

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
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
