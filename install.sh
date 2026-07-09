#!/usr/bin/env bash
# claude-codex-battery-win installer — WSL 안에서 실행하세요:
#   git clone <repo> && cd claude-codex-battery-win && ./install.sh
# 하는 일: 경로 자동 감지 → Windows 쪽 숨김 런처(launch.vbs) 생성 →
#          시작프로그램 등록 → 즉시 실행. 관리자 권한 불필요.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DISTRO="${WSL_DISTRO_NAME:-}"
if [ -z "$DISTRO" ]; then
  echo "오류: WSL 환경이 아닙니다. WSL 터미널에서 실행하세요." >&2
  exit 1
fi

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  echo "오류: node가 필요합니다. https://nodejs.org 또는 nvm으로 설치 후 다시 실행하세요." >&2
  exit 1
fi

if [ ! -f "$HOME/.claude/.credentials.json" ]; then
  echo "경고: ~/.claude/.credentials.json 이 없습니다. Claude Code에 로그인돼 있어야 한도가 표시됩니다." >&2
fi

WINPROFILE="$(powershell.exe -NoProfile -Command '$env:USERPROFILE' 2>/dev/null | tr -d '\r')"
APP_DIR_WIN="${WINPROFILE}\\claude-codex-battery"
APP_DIR_WSL="$(wslpath "$APP_DIR_WIN")"
mkdir -p "$APP_DIR_WSL"

REPO_WIN_TAIL="$(echo "$REPO_DIR" | sed 's|/|\\|g')"
TRAY_UNC="\\\\wsl.localhost\\${DISTRO}${REPO_WIN_TAIL}\\tray.ps1"

cat > "$APP_DIR_WSL/launch.vbs" <<EOF
' claude-codex-battery tray launcher (install.sh 가 자동 생성)
Set sh = CreateObject("WScript.Shell")
' 로그인 직후 WSL 부팅 대기
sh.Run "wsl.exe -d ${DISTRO} -e true", 0, True
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""${TRAY_UNC}"" -Distro ""${DISTRO}"" -NodePath ""${NODE_BIN}"" -CollectorPath ""${REPO_DIR}/collector.mjs""", 0, False
EOF

powershell.exe -NoProfile -Command "
# 이미 떠 있는 인스턴스 정리 후 재시작
Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.ProcessId -ne \$PID -and \$_.CommandLine -like '*tray.ps1*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }
\$ws = New-Object -ComObject WScript.Shell
\$lnk = \$ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Codex Battery.lnk'))
\$lnk.TargetPath = 'C:\Windows\System32\wscript.exe'
\$lnk.Arguments = '\"${APP_DIR_WIN}\launch.vbs\"'
\$lnk.Description = 'Claude/Codex usage battery tray'
\$lnk.Save()
Start-Process wscript.exe -ArgumentList '\"${APP_DIR_WIN}\launch.vbs\"'
Write-Output 'OK'
" | tr -d '\r'

echo "설치 완료 — 작업표시줄 트레이에 배터리 아이콘이 뜹니다(첫 표시까지 ~20초)."
echo "  · 로그인 시 자동 시작: 시작프로그램 'Claude Codex Battery'"
echo "  · 제거: README.md 의 '제거' 섹션 참조"
