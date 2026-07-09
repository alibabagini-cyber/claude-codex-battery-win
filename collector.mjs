#!/usr/bin/env node
// claude-codex-battery Windows port — WSL-side collector.
// 원본: https://github.com/dennykim123/claude-codex-battery (macOS SwiftBar)
// 역할: Claude 한도(공식 OAuth usage API) + Codex rate_limits(~/.codex/sessions)를
//       읽어 JSON 한 덩어리를 stdout으로 출력. Windows 트레이(tray.ps1)가 2분마다 호출.
// 보안: OAuth 토큰은 이 프로세스 안에서만 사용, api.anthropic.com(HTTPS) 외 전송 없음, 출력/로그 금지.

import { readFileSync, readdirSync, statSync, existsSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const HOME = homedir();
const CACHE_DIR = join(HOME, ".claude", "usage-widget");
const CACHE = join(CACHE_DIR, "usage-cache.json");
const now = Math.floor(Date.now() / 1000);

// ── 1. Claude 한도: 공식 OAuth usage 엔드포인트 ─────────────
function readAccessToken() {
  const raw = readFileSync(join(HOME, ".claude", ".credentials.json"), "utf8");
  const d = JSON.parse(raw);
  return d.claudeAiOauth?.accessToken ?? d.accessToken ?? null;
}

async function fetchClaudeUsage() {
  let token;
  try {
    token = readAccessToken();
  } catch {
    return { error: "no-credentials" };
  }
  if (!token) return { error: "no-token" };
  try {
    const res = await fetch("https://api.anthropic.com/api/oauth/usage", {
      headers: {
        Authorization: `Bearer ${token}`,
        "anthropic-beta": "oauth-2025-04-20",
        "Content-Type": "application/json",
      },
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) return { error: `http-${res.status}` };
    return { data: await res.json() };
  } catch (e) {
    return { error: String(e.message || e).split("\n")[0] };
  }
}

// API 응답 → {fiveHour, weekly, fable} (원본 getClaudeUsage와 동일 의미)
function normalizeClaude(d) {
  const toTs = (iso) => (iso ? Math.floor(Date.parse(iso) / 1000) : null);
  const win = (o) =>
    o ? { pct: o.utilization ?? o.percent ?? 0, resetsAt: toTs(o.resets_at) } : null;
  let fable = null;
  for (const l of d.limits || []) {
    const mdl = l.scope?.model?.display_name;
    if (l.group === "weekly" && mdl) {
      fable = { pct: l.percent ?? l.utilization ?? 0, resetsAt: toTs(l.resets_at), model: mdl };
      break;
    }
  }
  return { fiveHour: win(d.five_hour), weekly: win(d.seven_day), fable };
}

// ── 2. Codex rate_limits (원본 로직 이식, ~/.codex 없으면 null) ──
const CODEX_SESSIONS = join(HOME, ".codex", "sessions");
function walkJsonl(dir, out) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const ent of entries) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) walkJsonl(p, out);
    else if (ent.name.endsWith(".jsonl")) {
      try {
        out.push({ path: p, mtime: statSync(p).mtimeMs });
      } catch {}
    }
  }
}
function getCodex() {
  if (!existsSync(CODEX_SESSIONS)) return null;
  const files = [];
  walkJsonl(CODEX_SESSIONS, files);
  files.sort((a, b) => b.mtime - a.mtime);
  for (const f of files.slice(0, 8)) {
    try {
      const lines = readFileSync(f.path, "utf8").trim().split("\n");
      for (let i = lines.length - 1; i >= 0; i--) {
        if (!lines[i].includes("rate_limits")) continue;
        let obj;
        try {
          obj = JSON.parse(lines[i]);
        } catch {
          continue;
        }
        const rl = obj.payload?.rate_limits ?? obj.rate_limits;
        if (rl && (rl.primary || rl.secondary || rl.credits)) {
          return {
            measuredAt: Math.floor(f.mtime / 1000),
            plan: rl.plan_type || rl.limit_id || null,
            primary: rl.primary || null,
            secondary: rl.secondary || null,
            credits: rl.credits || null,
          };
        }
      }
    } catch {}
  }
  return null;
}

// ── main ───────────────────────────────────────────────────
const out = { at: now, claude: null, claudeError: null, codex: getCodex() };
const r = await fetchClaudeUsage();
if (r.data) {
  out.claude = normalizeClaude(r.data);
  out.claude.measuredAt = now;
  // 성공 응답은 캐시(600) — API 실패 시 마지막 값 폴백용
  try {
    mkdirSync(CACHE_DIR, { recursive: true });
    writeFileSync(CACHE, JSON.stringify({ at: now, raw: r.data }), { mode: 0o600 });
  } catch {}
} else {
  out.claudeError = r.error;
  // 폴백: 최근 캐시가 있으면 그걸로 (stale 표시용 measuredAt은 캐시 시각)
  try {
    const c = JSON.parse(readFileSync(CACHE, "utf8"));
    out.claude = normalizeClaude(c.raw);
    out.claude.measuredAt = c.at;
  } catch {}
}
console.log(JSON.stringify(out));
