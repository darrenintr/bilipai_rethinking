import type { ReportPayload } from './types';

/**
 * Send a Telegram message summarising the report. Best effort; logs on failure.
 *
 * No-op if TG_BOT_TOKEN or TG_CHAT_ID are unset.
 *
 * The route handler MUST call this via `ctx.waitUntil(...)` so it does not
 * block the response back to the app.
 */
export async function fanoutToTelegram(opts: {
  env: { TG_BOT_TOKEN?: string; TG_CHAT_ID?: string };
  payload: ReportPayload;
  reportId: number;
  dedup: boolean;
  firstSeen: number;
}): Promise<void> {
  const { env, payload, reportId, dedup, firstSeen } = opts;
  if (!env.TG_BOT_TOKEN || !env.TG_CHAT_ID) return;

  const text = formatTgMessage(payload, reportId, dedup, firstSeen);
  const url = `https://api.telegram.org/bot${env.TG_BOT_TOKEN}/sendMessage`;

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        chat_id: env.TG_CHAT_ID,
        text,
        parse_mode: 'MarkdownV2',
        disable_web_page_preview: true,
      }),
    });
    if (!res.ok) {
      console.error('tg_send_failed', res.status, (await res.text()).slice(0, 256));
    }
  } catch (e) {
    console.error('tg_send_error', e);
  }
}

function formatTgMessage(p: ReportPayload, id: number, dedup: boolean, firstSeen: number): string {
  const tag = dedup ? '🔁' : '🆕';
  const firstSeenStr = dedup ? ` · first seen ${formatAgo(firstSeen)}` : '';
  const stack = p.stacktrace
    ? `\n\`\`\`\n${p.stacktrace.split('\n').slice(0, 6).join('\n')}\n\`\`\``
    : '';
  return [
    `${tag} *Report #${id}* — ${escape(p.error_class)}${firstSeenStr}`,
    `*${escape(p.message)}*`,
    ``,
    `📱 ${escape(p.device_model ?? 'unknown')} · iOS ${escape(p.os_version)}`,
    `🏷 v${escape(p.app_version)} \\(build ${escape(p.app_build)}\\)`,
    `🌐 ${escape(p.locale ?? 'unknown')}`,
    stack,
  ].join('\n');
}

function formatAgo(ms: number): string {
  const diff = Date.now() - ms;
  if (diff < 60_000) return `${Math.floor(diff / 1000)}s ago`;
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  return `${Math.floor(diff / 86_400_000)}d ago`;
}

function escape(s: string): string {
  // MarkdownV2 reserved characters
  return s.replace(/[_*[\]()~`>#+\-=|{}.!\\]/g, '\\$&');
}
