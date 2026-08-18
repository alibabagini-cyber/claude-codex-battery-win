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

async function fetchClaudeUsage(tokenOverride) {
  let token = tokenOverride;
  if (!token)
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

// ── 2b. 계정 프로필 스캔 (~/.claude-profiles/<계정>/ — ccswitch 방식 멀티 프로필) ──
// 각 프로필의 토큰으로 그 계정 한도를 병렬 관측해 장부를 갱신한다.
// 만료 토큰은 조용히 스킵(장부엔 마지막 관측이 남음). 토큰 갱신·저장은 하지 않는다(읽기 전용).
async function scanProfiles(book, mainEmail) {
  const root = join(HOME, ".claude-profiles");
  let dirs;
  try {
    dirs = readdirSync(root, { withFileTypes: true }).filter((e) => e.isDirectory());
  } catch {
    return;
  }
  await Promise.all(
    dirs.map(async (e) => {
      try {
        const dir = join(root, e.name);
        const cred = JSON.parse(readFileSync(join(dir, ".credentials.json"), "utf8"));
        const token = cred.claudeAiOauth?.accessToken ?? cred.accessToken;
        if (!token) return;
        let em = null;
        try {
          em = JSON.parse(readFileSync(join(dir, ".claude.json"), "utf8")).oauthAccount?.emailAddress;
        } catch {}
        em = em || e.name;
        if (em === mainEmail) return; // 메인 로그인 계정은 본 루프가 이미 관측
        const r = await fetchClaudeUsage(token);
        if (!r.data) return;
        const n = normalizeClaude(r.data);
        book[em] = { at: now, fiveHour: n.fiveHour, weekly: n.weekly, fable: n.fable };
      } catch {}
    })
  );
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
await scanProfiles(book, email);
try {
  mkdirSync(CACHE_DIR, { recursive: true });
  writeFileSync(ACCOUNTS, JSON.stringify(book), { mode: 0o600 });
} catch {}
// 계정별 마지막 관측 — 티어 랭킹
// 유효 잔량: 리셋 시각이 지났으면 100%로 복구된 것으로 간주
const effRemain = (w) => {
  if (!w) return null;
  if (w.resetsAt && w.resetsAt < now) return 100;
  return Math.max(0, 100 - (w.pct ?? 0));
};
// 잔량이 이 미만인 창은 "사실상 소진" — 그거 쓰려고 로그인할 가치 없음(가치 계산·추천 제외)
const WORTH_MIN = 10;
// 티어: fable=최상위모델 가용 / opus=Fable 소진·Opus/Sonnet 전용 / skip=주간 소진, 로그인 비효율
out.accounts = Object.entries(book).map(([em, v]) => {
  const a = { email: em, current: em === email, ...v };
  const w5 = effRemain(a.fiveHour), wk = effRemain(a.weekly), fb = effRemain(a.fable);
  // 종합 여유 = 계정 사용성(5h·주간 중 최소). Fable은 별도 축(fableRemain)으로 분리.
  const vals = [w5, wk].filter((x) => x !== null);
  a.score = vals.length ? Math.min(...vals) : null;
  a.fableRemain = fb;
  a.tier = wk !== null && wk < WORTH_MIN ? "skip" : fb === null || fb >= WORTH_MIN ? "fable" : "opus";
  return a;
});
const wkOf = (a) => effRemain(a.weekly) ?? -1;
const fableTier = out.accounts.filter((a) => a.tier === "fable")
  .sort((x, y) => (y.fableRemain ?? wkOf(y)) - (x.fableRemain ?? wkOf(x)) || wkOf(y) - wkOf(x));
const opusTier = out.accounts.filter((a) => a.tier === "opus").sort((x, y) => wkOf(y) - wkOf(x));
const skipTier = out.accounts.filter((a) => a.tier === "skip").sort((x, y) => wkOf(y) - wkOf(x));
out.accounts = [...fableTier, ...opusTier, ...skipTier];
{
  let rank = 1;
  for (const a of out.accounts) if (a.tier !== "skip") a.rank = rank++;
}
// 다음 켤 계정 추천 — 2단 우선순위:
// ① 리셋 임박 소진(use-it-or-lose-it): 주간/최상위모델 창이 24h 내 리셋인데 잔량이 15% 이상
//    남은 계정 — 안 쓰면 증발하므로 최우선, 리셋 빠른 순. 단 지금 쓸 수 있어야(5h 잔량>5%)
//    하고 skip 티어(주간 소진)는 제외. Fable이 소진된 계정이면 그 사실을 사유에 명시.
// ② 그 외: fable 티어 1순위 → 없으면 opus 티어 1순위.
const fmtDur = (s) => {
  if (s <= 0) return "0m";
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
  if (h >= 24) return `${Math.floor(h / 24)}d ${h % 24}h`;
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
};
const URGENT_SEC = 24 * 3600;
const urgentInfo = (a) => {
  let best = null;
  for (const [name, w] of [["주간", a.weekly], [a.fable?.model || "Fable", a.fable]]) {
    if (!w?.resetsAt) continue;
    const left = w.resetsAt - now;
    if (left <= 0 || left > URGENT_SEC) continue;
    const rem = effRemain(w);
    if (rem === null || rem < 15) continue;
    if (!best || w.resetsAt < best.resetsAt) best = { name, remain: rem, resetsAt: w.resetsAt };
  }
  return best;
};
for (const a of out.accounts) a.urgent = a.tier !== "skip" ? urgentInfo(a) : null; // 트레이 팝업용
const urgent = out.accounts
  .filter((a) => a.tier !== "skip" && (effRemain(a.fiveHour) ?? 100) > 5)
  .map((a) => ({ a, u: urgentInfo(a) }))
  .filter((x) => x.u)
  .sort((x, y) => x.u.resetsAt - y.u.resetsAt);
if (urgent.length) {
  const { a, u } = urgent[0];
  const fbTag = a.tier === "opus" ? ` — Fable은 ${Math.round(a.fableRemain ?? 0)}%뿐, Opus/Sonnet용` : "";
  out.recommend = {
    email: a.email,
    score: a.score,
    urgent: true,
    key: `${a.email}:${u.resetsAt}`, // 트레이 알림 dedup용 (같은 리셋 창 = 같은 키)
    reason: `리셋임박 소진: ${u.name} ${Math.round(u.remain)}% 남음·리셋 ${fmtDur(u.resetsAt - now)} 후${fbTag}`,
  };
} else {
  const best = fableTier[0] || opusTier[0];
  out.recommend = best
    ? {
        email: best.email,
        score: best.score,
        reason:
          best.tier === "fable"
            ? `1순위: ${best.fable?.model || "Fable"} ${Math.round(best.fableRemain ?? 100)}%·주간 ${Math.round(wkOf(best))}%`
            : `Fable 가용 계정 없음 — Opus/Sonnet용, 주간 ${Math.round(wkOf(best))}%`,
      }
    : null;
}

// 옵션: grok 영상 주간한도(GV) — 외부 수집기가 쓴 grok-usage.json 이 있을 때만 표시.
// (공개 repo/친구 환경엔 파일 없어 미표시. 6시간 이상 stale이면 무시.)
try {
  const GROK = join(CACHE_DIR, "grok-usage.json");
  if (existsSync(GROK)) {
    const g = JSON.parse(readFileSync(GROK, "utf8"));
    if (g && typeof g.remaining_pct === "number" && now - (g.at || 0) < 21600) {
      out.grok = { pct: Math.max(0, 100 - g.remaining_pct), available: g.available, note: g.note || "" };
    }
  }
} catch {}

// ── 2D 라인업: 계정 우선순위를 배터리 캐릭터 줄세우기로 렌더 (로컬 HTML, 매 수집마다 갱신) ──
const LINEUP = join(CACHE_DIR, "lineup.html");
try {
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const heat = (v) => (v >= 50 ? "#3ecf6a" : v >= 20 ? "#ffc832" : "#ff5a4e");
  const face = (v, tier) =>
    tier === "skip" ? "✕﹏✕" : v >= 70 ? "◕‿◕" : v >= 40 ? "•‿•" : v >= WORTH_MIN ? "•﹏•" : "✕_✕";
  const resetStr = (w) => {
    if (!w?.resetsAt) return "";
    if (w.resetsAt < now) return "리셋됨";
    return fmtDur(w.resetsAt - now);
  };
  const bar = (label, v, w, color) => {
    if (v === null) return "";
    const r = resetStr(w);
    return `<div class="bar"><span class="bl">${esc(label)}</span><span class="bt"><i style="width:${Math.round(v)}%;background:${color}"></i></span><span class="bv">${Math.round(v)}%</span><span class="br">${esc(r)}</span></div>`;
  };
  const card = (a) => {
    const w5 = effRemain(a.fiveHour), wk = effRemain(a.weekly), fb = a.fableRemain;
    const fillVal = a.tier === "fable" ? (fb ?? a.score ?? 0) : wk ?? 0;
    const fillCol = a.tier === "skip" ? "#c2c2c9" : a.tier === "opus" ? "#8e8ef5" : heat(fillVal);
    const fName = a.fable?.model || "Fable";
    const u = a.tier !== "skip" ? urgentInfo(a) : null;
    const badge =
      a.tier === "skip"
        ? `<span class="badge skip">제외</span>`
        : a.tier === "opus"
          ? `<span class="badge opus">${a.rank}순위 · Opus용</span>`
          : `<span class="badge">${a.rank}순위</span>`;
    const crown = out.recommend?.email === a.email ? `<div class="crown">👑</div>` : "";
    const bubble = u
      ? `<div class="bubble">⏰ ${esc(u.name)} ${Math.round(u.remain)}%<br>${esc(fmtDur(u.resetsAt - now))} 뒤 증발!</div>`
      : "";
    const here = a.current ? `<div class="here">▶ 지금 켜짐</div>` : "";
    const note =
      a.tier === "skip"
        ? `주간 ${Math.round(wk ?? 0)}% — 로그인 비효율`
        : a.tier === "opus"
          ? `${esc(fName)} 소진(${Math.round(fb ?? 0)}%)`
          : `${esc(fName)} ${Math.round(fb ?? 100)}%`;
    return `<div class="acct ${a.tier}${a.current ? " cur" : ""}">
  ${crown}${bubble}
  <div class="batwrap"><div class="bat"><div class="fill" style="height:${Math.round(Math.max(4, Math.min(100, fillVal)))}%;background:${fillCol}"></div><div class="face">${face(fillVal, a.tier)}</div></div></div>
  <div class="shadow"></div>
  ${badge}
  <div class="name">${esc(a.email.split("@")[0])}</div>
  <div class="note">${note}</div>
  <div class="bars">${bar(fName[0], fb, a.fable, "#ff8ab3")}${bar("주", wk, a.weekly, "#7cc4ff")}${bar("5h", w5, a.fiveHour, "#b7e07c")}</div>
  <div class="ago">${a.current ? "현재 로그인" : esc(fmtDur(now - a.at)) + " 전 관측"}</div>
  ${here}
</div>`;
  };
  const live = [...fableTier, ...opusTier];
  const html = `<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>클로드 배터리 줄세우기</title>
<style>
  body{margin:0;min-height:100vh;background:linear-gradient(180deg,#fdf3f7 0%,#eef3ff 60%,#e7f6ee 100%);font-family:"Segoe UI","Malgun Gothic",sans-serif;color:#3b3b46;display:flex;flex-direction:column;align-items:center;padding:28px 16px 48px}
  h1{font-size:22px;margin:0 0 4px}
  .sub{font-size:12px;color:#8a8a96;margin-bottom:26px}
  .row{display:flex;flex-wrap:wrap;justify-content:center;gap:22px;max-width:1100px}
  .acct{position:relative;width:150px;display:flex;flex-direction:column;align-items:center;padding-top:34px}
  .acct.skip{filter:saturate(.35);opacity:.75}
  .batwrap{position:relative}
  .acct.skip .batwrap{transform:rotate(90deg) translateX(6px)}
  .bat{position:relative;width:76px;height:106px;border:4px solid #43434e;border-radius:16px;background:#fff;overflow:hidden;box-shadow:0 3px 0 rgba(67,67,78,.15)}
  .batwrap::before{content:"";position:absolute;left:50%;top:-11px;transform:translateX(-50%);width:26px;height:8px;background:#43434e;border-radius:4px 4px 0 0}
  .fill{position:absolute;left:0;right:0;bottom:0;border-radius:0 0 12px 12px;transition:height .4s}
  .face{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:19px;font-weight:600;color:#43434e;text-shadow:0 1px 0 rgba(255,255,255,.6)}
  .shadow{width:70px;height:10px;border-radius:50%;background:rgba(67,67,78,.12);margin-top:6px}
  .crown{position:absolute;top:10px;left:24px;transform:rotate(-18deg);font-size:26px;z-index:4}
  .bubble{position:absolute;top:-6px;right:-8px;background:#fff;border:2px solid #ff9c3f;border-radius:10px;padding:4px 7px;font-size:10px;line-height:1.35;color:#c05600;z-index:3;box-shadow:0 2px 5px rgba(0,0,0,.08)}
  .here{margin-top:5px;font-size:10px;font-weight:700;color:#0a84ff}
  .badge{margin-top:9px;background:#43434e;color:#fff;font-size:11px;font-weight:700;padding:2px 10px;border-radius:99px}
  .badge.opus{background:#8e8ef5}
  .badge.skip{background:#b0b0b8}
  .name{margin-top:6px;font-size:12px;font-weight:700;max-width:145px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .note{font-size:10.5px;color:#8a8a96;margin-top:1px}
  .bars{width:138px;margin-top:7px;display:flex;flex-direction:column;gap:3px}
  .bar{display:flex;align-items:center;gap:4px;font-size:9.5px;color:#6b6b76}
  .bl{width:12px;text-align:right;font-weight:700}
  .bt{flex:1;height:7px;background:#e4e4ec;border-radius:99px;overflow:hidden;display:block}
  .bt i{display:block;height:100%;border-radius:99px}
  .bv{width:28px;text-align:right;font-variant-numeric:tabular-nums}
  .br{width:44px;text-align:right;color:#a5a5b0}
  .ago{font-size:9.5px;color:#a5a5b0;margin-top:5px}
  .divider{width:100%;max-width:900px;display:flex;align-items:center;gap:10px;color:#a5a5b0;font-size:11px;margin:26px 0 14px}
  .divider::before,.divider::after{content:"";flex:1;border-top:1.5px dashed #d4d4de}
  .reco{margin-top:24px;background:#fff;border:2px solid #ffd166;border-radius:12px;padding:8px 16px;font-size:13px;box-shadow:0 2px 6px rgba(0,0,0,.06)}
</style>
<h1>🔋 클로드 배터리 줄세우기</h1>
<div class="sub">측정 ${esc(new Date(now * 1000).toLocaleString("ko-KR", { hour12: false }))} · 잔량 ${WORTH_MIN}% 미만 창은 소진 취급</div>
<div class="row">${live.map(card).join("")}</div>
${skipTier.length ? `<div class="divider">여기부터는 로그인 비효율 🙅</div><div class="row">${skipTier.map(card).join("")}</div>` : ""}
${out.recommend ? `<div class="reco">👑 다음 추천: <b>${esc(out.recommend.email)}</b> — ${esc(out.recommend.reason)}</div>` : ""}
`;
  mkdirSync(CACHE_DIR, { recursive: true });
  writeFileSync(LINEUP, html, { mode: 0o600 });
  out.lineupPath = LINEUP;
} catch {}

// --next: 사람용 요약 출력 (터미널에서 "다음 어떤 계정 켜지?" 즉답)
if (process.argv.includes("--next")) {
  const fmtWin = (name, w) => {
    if (!w) return null;
    if (w.resetsAt && w.resetsAt < now) return `${name} 리셋됨→100%`;
    const r = w.resetsAt ? `·리셋 ${fmtDur(w.resetsAt - now)} 후` : "";
    return `${name} ${Math.round(Math.max(0, 100 - (w.pct ?? 0)))}%${r}`;
  };
  const printAcct = (a) => {
    const mark = a.current ? "▶" : " ";
    const when = a.current ? "현재 로그인" : `${fmtDur(now - a.at)} 전 관측`;
    const u = a.tier !== "skip" ? urgentInfo(a) : null;
    const tag = u ? `  ⏳${u.name} ${Math.round(u.remain)}% 소멸임박(${fmtDur(u.resetsAt - now)})` : "";
    const rk = a.rank ? `${a.rank}. ` : "";
    const wins = [fmtWin("5h", a.fiveHour), fmtWin("주간", a.weekly), a.fable ? fmtWin(a.fable.model || "Fable", a.fable) : null]
      .filter(Boolean).join(" | ");
    console.log(`${mark} ${rk}${a.email}  (${when})${tag}`);
    console.log(`    ${wins}`);
  };
  const groups = [
    [`Fable 가능 — 이 순서로`, fableTier],
    [`Fable 소진(<${WORTH_MIN}%) — Opus/Sonnet 전용`, opusTier],
    [`제외 — 주간 잔량 <${WORTH_MIN}%, 로그인 비효율`, skipTier],
  ];
  for (const [title, list] of groups) {
    if (!list.length) continue;
    console.log(`[${title}]`);
    for (const a of list) printAcct(a);
  }
  if (out.recommend) console.log(`\n★ 다음 추천: ${out.recommend.email} (${out.recommend.reason})`);
  if (out.codex) {
    const winName = (w) =>
      !w?.window_minutes ? "?" : w.window_minutes <= 300 ? "5h" : w.window_minutes >= 10080 ? "주간" : `${Math.round(w.window_minutes / 60)}h`;
    const cw = (w) => {
      if (!w) return null;
      const rem = Math.round(Math.max(0, 100 - (w.used_percent ?? 0)));
      const r = w.resets_at ? `·리셋 ${fmtDur(w.resets_at - now)} 후` : "";
      return `${winName(w)} ${rem}%${r}`;
    };
    const parts = [cw(out.codex.primary), cw(out.codex.secondary)].filter(Boolean).join(" | ");
    if (parts) console.log(`Codex(${out.codex.plan || "?"}): ${parts}`);
  }
} else {
  console.log(JSON.stringify(out));
}
