/**
 * Defense-in-depth redaction. The app MUST redact SESSDATA / buvid3 / cookies
 * before upload; this is the second line in case the app is bypassed.
 *
 * Strips:
 *   - SESSDATA, buvid3/4, bili_jct, DedeUserID, sid, ac_time_value, etc.
 *   - JSON `cookie` / `cookies` / `set-cookie` / `Set-Cookie` values
 *   - `Authorization: Bearer xxx` headers
 *   - 40+ char hex strings (likely tokens)
 */
const REDACT_TOKEN_REGEX = new RegExp(
  [
    '(?:SESSDATA|buvid3|buvid4|bili_jct|DedeUserID|dedeuserid|DedeUserID|',
    'sid|ac_time_value|browser_id|guid|mid|bfe_id|_uuid|b_nut|rpdid|',
    'device_id|',
    'access_key|refresh_key|',
    'appkey|sign)',
  ].join(''),
  'gi',
);
const COOKIE_VALUE_REGEX = /(\b(?:SESSDATA|buvid3|buvid4|bili_jct|DedeUserID|sid|mid)\s*=\s*)([^;\s"']+)/gi;
const AUTH_HEADER_REGEX = /(Authorization\s*:\s*Bearer\s+)([A-Za-z0-9._\-]+)/gi;
const HEX_TOKEN_REGEX = /\b[0-9a-f]{40,}\b/gi;
const JSON_FIELD_REGEX = /("(?:cookie|cookies|set-cookie|Set-Cookie|headers|Authorization)"\s*:\s*)"[^"]*"/gi;

const SENSITIVE_FIELD_NAMES = new Set([
  'cookie', 'cookies', 'set-cookie', 'authorization', 'headers',
  'sessdata', 'access_key', 'refresh_key', 'sign', 'token', 'password',
]);

export function redactString(s: string): string {
  return s
    .replace(COOKIE_VALUE_REGEX, '$1<redacted>')
    .replace(JSON_FIELD_REGEX, '$1"<redacted>"')
    .replace(AUTH_HEADER_REGEX, '$1<redacted>')
    .replace(HEX_TOKEN_REGEX, '<redacted-hex>');
}

export function redactObject<T>(obj: T): T {
  if (obj === null || obj === undefined) return obj;
  if (typeof obj === 'string') return redactString(obj) as unknown as T;
  if (Array.isArray(obj)) return obj.map(redactObject) as unknown as T;
  if (typeof obj === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
      if (SENSITIVE_FIELD_NAMES.has(k.toLowerCase())) {
        out[k] = '<redacted>';
      } else {
        out[k] = redactObject(v);
      }
    }
    return out as T;
  }
  return obj;
}
