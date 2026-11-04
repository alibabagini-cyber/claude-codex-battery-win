#!/usr/bin/env bash
# claude-codex-battery-win 자동 업데이트
#   GitHub(origin/main)에서 fast-forward pull → 코드가 바뀌었으면 트레이 재시작.
#   로컬 변경/분기가 있으면 건드리지 않고 건너뜀(ff-only). 설치 시 등록되는
#   작업 스케줄러 태스크(ClaudeCodexBatteryUpdate)가 하루 1회 호출한다.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/.claude/usage-widget/update.log"
mkdir -p "$(dirname "$LOG")"
ts() { date '+%F %T'; }

cd "$REPO_DIR" 2>/dev/null || { echo "$(ts) repo 없음: $REPO_DIR" >>"$LOG"; exit 0; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "$(ts) git repo 아님, 건너뜀" >>"$LOG"; exit 0; }

before="$(git rev-parse HEAD 2>/dev/null)"
if ! git fetch --quiet origin main 2>>"$LOG"; then
  echo "$(ts) fetch 실패(네트워크?), 건너뜀" >>"$LOG"; exit 0
fi
# 로컬 변경이 있으면 ff-only가 실패 → 덮어쓰지 않고 그대로 둠
if ! git merge --ff-only origin/main >>"$LOG" 2>&1; then
  echo "$(ts) fast-forward 불가(로컬 변경/분기) — 자동 갱신 보류" >>"$LOG"; exit 0
fi
after="$(git rev-parse HEAD 2>/dev/null)"

if [ "$before" = "$after" ]; then
  echo "$(ts) 최신 ($after)" >>"$LOG"; exit 0
fi

echo "$(ts) 갱신 $before -> $after, 트레이 재시작" >>"$LOG"

# 트레이 재시작: 기존 인스턴스 종료 후 작업 스케줄러 kick 태스크 재실행(세션과 분리)
powershell.exe -NoProfile -Command "
  Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" |
    Where-Object { \$_.CommandLine -like '*-File*' -and \$_.CommandLine -like '*tray.ps1*' } |
    ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 1
  schtasks /Run /TN ClaudeCodexBatteryKick 2>\$null | Out-Null
" >>"$LOG" 2>&1 || true
echo "$(ts) 재시작 요청 완료" >>"$LOG"
