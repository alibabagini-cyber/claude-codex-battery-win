#!/usr/bin/env bash
# claude-codex-battery-win 토큰 keep-warm + 세션 만료 워치독
#   목적 1: 각 계정(메인 ~/.claude + ~/.claude-profiles/*) 액세스 토큰을 가볍게 refresh해
#           collector가 전 계정 live usage를 읽을 수 있게 유지(= ccnext 우선순위 정확도).
#   목적 2: loginExpiresAt(세션 만료, 약 한 달 고정 — 일반 사용으론 연장 안 됨)을 점검해
#           만료 임박(기본 7일)이면 TG 경고. 세션 연장은 재로그인(브라우저 OAuth)만 가능.
#   설치 시 등록되는 태스크(ClaudeCodexBatteryRefresh)가 2일마다 호출.
set -uo pipefail

PROFILES="$HOME/.claude-profiles"
LOG="$HOME/.claude/usage-widget/refresh.log"
mkdir -p "$(dirname "$LOG")"
WARN_DAYS="${WARN_DAYS:-7}"
TG="$HOME/.claude/notify_tg.sh"
now=$(date +%s)
ts() { date '+%F %T'; }

# 대상: 메인 + 각 프로필 디렉토리
dirs=("$HOME/.claude")
for d in "$PROFILES"/*/; do [ -d "$d" ] && dirs+=("${d%/}"); done

for d in "${dirs[@]}"; do
  js="$(CLAUDE_CONFIG_DIR="$d" claude auth status --json 2>/dev/null)"
  [ -z "$js" ] && { echo "$(ts) [$d] status 없음" >>"$LOG"; continue; }
  loggedin="$(printf '%s' "$js" | python3 -c 'import json,sys;print("1" if json.load(sys.stdin).get("loggedIn") else "")' 2>/dev/null)"
  [ -z "$loggedin" ] && { echo "$(ts) [$d] 미로그인 — 재로그인 필요" >>"$LOG"; continue; }
  email="$(printf '%s' "$js" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("email") or "")' 2>/dev/null)"
  # 메인(~/.claude)은 status email이 null일 수 있어 .claude.json 에서 보완
  if [ -z "$email" ] && [ -f "$d/.claude.json" ]; then
    email="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("oauthAccount",{}).get("emailAddress") or "main")' "$d/.claude.json" 2>/dev/null)"
  fi
  [ -z "$email" ] && email="(main)"

  # keep-warm: 최소 프롬프트 1회로 액세스 토큰 refresh (collector가 읽을 수 있게)
  CLAUDE_CONFIG_DIR="$d" timeout 90 claude -p "ok" --max-turns 1 >/dev/null 2>&1
  warm=$?

  # 세션 만료 점검
  exp="$(CLAUDE_CONFIG_DIR="$d" claude auth status --json 2>/dev/null | python3 -c '
import json,sys,datetime
try:
    e=json.load(sys.stdin).get("loginExpiresAt")
    print(int(datetime.datetime.fromisoformat(e.replace("Z","+00:00")).timestamp()) if e else 0)
except Exception:
    print(0)')"
  if [ "${exp:-0}" -gt 0 ]; then
    days=$(( (exp - now) / 86400 ))
    echo "$(ts) $email keep-warm=$warm 세션만료 D-$days" >>"$LOG"
    if [ "$days" -le "$WARN_DAYS" ] && [ -x "$TG" ]; then
      "$TG" "⚠ Claude 재로그인 필요: $email (세션 D-$days 만료 임박). 재로그인 안 하면 ccnext 자동추천에서 이 계정이 빠집니다." >/dev/null 2>&1 || true
    fi
  else
    echo "$(ts) $email keep-warm=$warm 만료정보없음" >>"$LOG"
  fi
done
