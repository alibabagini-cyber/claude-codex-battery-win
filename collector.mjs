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
const ACCOUNTS = join(CACHE_DIR, "accounts.json");
const now = Math.floor(Date.now() / 1000);

// 현재 로그인 계정 식별 (~/.claude.json oauthAccount — 로그인 시 credentials와 함께 갱신됨)
function readAccountEmail() {
  try {
    const d = JSON.parse(readFileSync(join(HOME, ".claude.json"), "utf8"));
    return d.oauthAccount?.emailAddress ?? null;
  } catch {
    return null;
  }
}

// 계정별 마지막 관측 스냅샷 장부 — 퍼센트·리셋시각·측정시각만 (토큰 저장 없음)
function loadAccountBook() {
  try {
    return JSON.parse(readFileSync(ACCOUNTS, "utf8"));
  } catch {
    return {};
  }
}

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
const out = { at: now, claude: null, claudeError: null, codex: getCodex(), accounts: [] };
const email = readAccountEmail();
const book = loadAccountBook();
const r = await fetchClaudeUsage();
if (r.data) {
  out.claude = normalizeClaude(r.data);
  out.claude.measuredAt = now;
  // 성공 응답은 캐시(600) — API 실패 시 마지막 값 폴백용 + 계정별 장부 갱신
  try {
    mkdirSync(CACHE_DIR, { recursive: true });
    writeFileSync(CACHE, JSON.stringify({ at: now, raw: r.data }), { mode: 0o600 });
    if (email) {
      book[email] = { at: now, fiveHour: out.claude.fiveHour, weekly: out.claude.weekly, fable: out.claude.fable };
      writeFileSync(ACCOUNTS, JSON.stringify(book), { mode: 0o600 });
    }
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
// 계정별 마지막 관측(현재 계정 먼저, 나머지는 최근 관측 순)
// 유효 잔량: 리셋 시각이 지났으면 100%로 복구된 것으로 간주
const effRemain = (w) => {
  if (!w) return null;
  if (w.resetsAt && w.resetsAt < now) return 100;
  return Math.max(0, 100 - (w.pct ?? 0));
};
out.accounts = Object.entries(book)
  .map(([em, v]) => {
    const a = { email: em, current: em === email, ...v };
    // 종합 여유 = 세 창 중 최소(병목 창 기준 보수 판정)
    const vals = [effRemain(a.fiveHour), effRemain(a.weekly), effRemain(a.fable)].filter((x) => x !== null);
    a.score = vals.length ? Math.min(...vals) : null;
    return a;
  })
  .sort((a, b) => (b.current === a.current ? b.at - a.at : b.current ? 1 : -1));
// 다음 켤 계정 추천 = 종합 여유 최대 계정
const scored = out.accounts.filter((a) => a.score !== null).sort((a, b) => b.score - a.score);
out.recommend = scored.length ? { email: scored[0].email, score: scored[0].score } : null;

// --next: 사람용 요약 출력 (터미널에서 "다음 어떤 계정 켜지?" 즉답)
if (process.argv.includes("--next")) {
  const fmtDur = (s) => {
    if (s <= 0) return "0m";
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
    if (h >= 24) return `${Math.floor(h / 24)}d ${h % 24}h`;
    return h > 0 ? `${h}h ${m}m` : `${m}m`;
  };
  const fmtWin = (name, w) => {
    if (!w) return null;
    if (w.resetsAt && w.resetsAt < now) return `${name} 리셋됨→100%`;
    const r = w.resetsAt ? `·리셋 ${fmtDur(w.resetsAt - now)} 후` : "";
    return `${name} ${Math.round(Math.max(0, 100 - (w.pct ?? 0)))}%${r}`;
  };
  for (const a of scored) {
    const mark = a.current ? "▶" : " ";
    const when = a.current ? "현재 로그인" : `${fmtDur(now - a.at)} 전 관측`;
    const wins = [fmtWin("5h", a.fiveHour), fmtWin("주간", a.weekly), a.fable ? fmtWin(a.fable.model || "Fable", a.fable) : null]
      .filter(Boolean).join(" | ");
    console.log(`${mark} ${a.email}  종합여유 ${a.score}%  (${when})`);
    console.log(`    ${wins}`);
  }
  if (out.recommend) console.log(`\n★ 다음 추천: ${out.recommend.email} (종합여유 ${out.recommend.score}%)`);
} else {
  console.log(JSON.stringify(out));
}
