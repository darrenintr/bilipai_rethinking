/**
 * Stacktrace fingerprint — SHA-256 of a normalized stack.
 *
 * Normalization:
 *   - Strip absolute paths       /Users/foo/.../file.swift  → /<path>/file.swift
 *   - Strip line/column          file.swift:42:13           → file.swift:?:?
 *   - Strip memory addresses     0x00007ff...                → 0x<addr>
 *   - Strip bracketed addresses  [stack frame info]          → []
 *   - Collapse whitespace
 *   - Take first 8 lines
 *   - Lowercase
 *
 * Inputs: error_class + message + normalized stack (top 8 lines).
 */
export async function fingerprintStacktrace(
  stack: string | undefined,
  errorClass: string,
  message: string,
): Promise<string> {
  const normStack = stack
    ? stack
        .split('\n')
        .slice(0, 8)
        .map((line) =>
          line
            .replace(/\/[^\s:]+/g, '/<path>')        // absolute paths
            .replace(/:\d+:\d+/g, ':?:?')            // line:col
            .replace(/0x[0-9a-f]+/gi, '0x<addr>')    // memory addresses
            .replace(/\[[^\]]*\]/g, '[]')             // bracketed addresses
            .replace(/\s+/g, ' ')
            .trim(),
        )
        .filter(Boolean)
        .join(' | ')
    : '';

  const input = `${errorClass}::${message}::${normStack}`;
  const enc = new TextEncoder();
  const hash = await crypto.subtle.digest('SHA-256', enc.encode(input));
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
