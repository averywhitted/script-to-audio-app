// Table Read bug-report relay (Cloudflare Worker).
//
// The app POSTs an anonymous report here; this Worker checks it, strips
// anything risky, and files it as an issue in a (private) GitHub repo using a
// token only this Worker holds. Nothing is stored and nothing is logged here.
//
// Safety, for Avery:
// - The GitHub token never leaves Cloudflare (a Worker secret). It should be
//   a fine-grained token limited to Issues on ONE repo, with an expiry.
// - Reporters can't choose the repo, labels, assignees or title format.
// - Sizes are capped; requests are rate-limited per sender and overall.
// - All reporter text is placed in code blocks: no links, images, @mentions,
//   or HTML render, so a report can't ping people or embed tracking.
// Safety, for reporters:
// - No name, account or email is needed; contact is optional and blank by
//   default. The app strips home-folder paths, emails and keys before
//   sending, and this Worker strips them again.
// - The sender's IP address is never stored, logged or put in the issue. Rate
//   limiting uses a salted hash of it that only lives in Cloudflare's limiter.
// - No CORS headers: web pages can't use this endpoint from a browser.

export const LIMITS = {
  bodyBytes: 32 * 1024,
  what: 4000,
  steps: 4000,
  log: 6000,
  contact: 200,
  version: 40,
  os: 80,
};

const json = (status, obj) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });

/// Removes control characters (keeping newlines and tabs), trims, and caps length.
export function cleanText(value, max) {
  if (typeof value !== 'string') return '';
  // eslint-disable-next-line no-control-regex
  let s = value.replace(/\r\n?/g, '\n').replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F‎‏‪-‮⁦-⁩]/g, '');
  s = s.trim();
  if (s.length > max) s = s.slice(0, max) + '…';
  return s;
}

/// Strips things that could identify someone or leak a secret: home-folder
/// paths (/Users/<name>), emails, API keys and tokens, long secrets.
export function redact(s) {
  return s
    .replace(/\/(Users|home)\/[^/\s'"]+/g, '~')
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[email]')
    .replace(/\bsk-[A-Za-z0-9_-]{12,}/g, '[key]')
    .replace(/\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/g, '[token]')
    .replace(/\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{16,}/gi, '[credential]');
}

/// A code fence longer than any run of backticks in [text], so the text can't
/// close the block early.
export function fence(text) {
  const longest = Math.max(0, ...[...text.matchAll(/`+/g)].map((m) => m[0].length));
  const f = '`'.repeat(Math.max(3, longest + 1));
  return `${f}text\n${text}\n${f}`;
}

/// Checks the app's payload. Returns { ok: true, report } or { ok: false, error }.
export function validate(payload) {
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) return { ok: false, error: 'bad request' };
  const allowed = new Set(['what', 'steps', 'log', 'contact', 'version', 'os']);
  for (const k of Object.keys(payload)) if (!allowed.has(k)) return { ok: false, error: 'bad request' };
  const report = {
    what: redact(cleanText(payload.what, LIMITS.what)),
    steps: redact(cleanText(payload.steps, LIMITS.steps)),
    log: redact(cleanText(payload.log, LIMITS.log)),
    contact: cleanText(payload.contact, LIMITS.contact),
    version: cleanText(payload.version, LIMITS.version).replace(/[^0-9A-Za-z.+\- ()]/g, ''),
    os: cleanText(payload.os, LIMITS.os).replace(/[^0-9A-Za-z.,+\- ()]/g, ''),
  };
  if (report.what.length < 3) return { ok: false, error: 'Please say what happened.' };
  if (report.contact && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(report.contact)) return { ok: false, error: 'That contact email looks wrong.' };
  return { ok: true, report };
}

/// The issue to file. Title is plain text (no mentions render in titles);
/// everything the reporter wrote goes in code blocks.
export function buildIssue(report) {
  const firstLine = report.what.split('\n')[0].replace(/[@#`]/g, '').slice(0, 70);
  const parts = [
    `**App version:** \`${report.version || 'unknown'}\` · **macOS:** \`${report.os || 'unknown'}\``,
    '',
    '### What happened',
    fence(report.what),
    '### Steps to reproduce',
    fence(report.steps || '(not provided)'),
  ];
  if (report.log) parts.push('### Recent app log (redacted)', fence(report.log));
  parts.push(
    '### Contact',
    report.contact ? fence(report.contact) : '_None — anonymous report._',
    '',
    '<sub>Filed by the Table Read report relay. The sender’s IP address and identity are not recorded.</sub>',
  );
  return {
    title: `User report ${report.version ? `(${report.version}) ` : ''}· ${firstLine}`,
    body: parts.join('\n'),
    labels: ['bug', 'user-report'],
  };
}

async function hashedSender(request, salt) {
  const ip = request.headers.get('cf-connecting-ip') || 'unknown';
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(salt), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(ip));
  return [...new Uint8Array(sig)].slice(0, 16).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/report') return json(404, { ok: false, error: 'not found' });
    if (request.method !== 'POST') return json(405, { ok: false, error: 'method not allowed' });
    if (!(request.headers.get('content-type') || '').toLowerCase().startsWith('application/json')) {
      return json(415, { ok: false, error: 'json only' });
    }
    if (request.headers.get('x-table-read') !== '1') return json(400, { ok: false, error: 'bad request' });

    // Misconfigured? Refuse rather than run without limits or a target.
    if (!env.GITHUB_TOKEN || !env.GITHUB_REPO || !env.RATE_SALT || !env.SENDER_LIMITER || !env.GLOBAL_LIMITER) {
      return json(503, { ok: false, error: 'reports are unavailable right now' });
    }

    const declared = Number(request.headers.get('content-length') || '0');
    if (declared > LIMITS.bodyBytes) return json(413, { ok: false, error: 'too large' });

    const sender = await hashedSender(request, env.RATE_SALT);
    const perSender = await env.SENDER_LIMITER.limit({ key: sender });
    const overall = await env.GLOBAL_LIMITER.limit({ key: 'all' });
    if (!perSender.success || !overall.success) return json(429, { ok: false, error: 'Too many reports. Please try again in a minute.' });

    const raw = await request.text();
    if (new TextEncoder().encode(raw).length > LIMITS.bodyBytes) return json(413, { ok: false, error: 'too large' });
    let payload;
    try {
      payload = JSON.parse(raw);
    } catch {
      return json(400, { ok: false, error: 'bad request' });
    }
    const checked = validate(payload);
    if (!checked.ok) return json(400, { ok: false, error: checked.error });

    const issue = buildIssue(checked.report);
    let gh;
    try {
      gh = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/issues`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${env.GITHUB_TOKEN}`,
          accept: 'application/vnd.github+json',
          'x-github-api-version': '2022-11-28',
          'user-agent': 'table-read-report-relay',
          'content-type': 'application/json',
        },
        body: JSON.stringify(issue),
      });
    } catch {
      return json(502, { ok: false, error: 'Could not reach the report service.' });
    }
    // Never pass GitHub's reply through: it could reveal repo details.
    if (!gh.ok) return json(502, { ok: false, error: 'The report service had a problem. Please try again later.' });
    const created = await gh.json().catch(() => ({}));
    return json(200, { ok: true, reference: typeof created.number === 'number' ? created.number : null });
  },
};
