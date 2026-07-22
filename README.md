# claude-codex-battery-win

**Claude Code / Codex 사용량 한도를 Windows 작업표시줄 트레이에 배터리로 상시 표시** — WSL 환경용.

[dennykim123/claude-codex-battery](https://github.com/dennykim123/claude-codex-battery) (macOS SwiftBar 위젯)의 Windows/WSL 포트입니다.

*Windows tray port of the macOS SwiftBar widget — shows your Claude Code (and Codex) rate-limit headroom as battery icons in the system tray. Requires Claude Code running inside WSL.*

![tray](docs/tray.png)

- **C5** = Claude 5시간 세션 남은 %
- **CW** = Claude 주간 전체 남은 %
- **CF** = 최상위 모델(Fable 등) 전용 주간 한도 남은 %
- **X5 / XW** = Codex 5시간·주간 — `~/.codex/sessions`가 있으면 자동 표시

색: 초록(≥50%) / 노랑(<50%) / 빨강(≤20%). 캡슐 안 숫자 = 남은 %.
마우스 오버 = 리셋까지 남은 시간 · **클릭 = 상세(계정별 포함)** · 우클릭 = 새로고침/종료. 2분마다 갱신.

### 멀티 계정

Claude 계정을 여러 개 번갈아 쓰는 경우, 아이콘을 클릭하면 **계정별 마지막 관측값**이 함께 표시됩니다:

- 계정마다 마지막으로 측정된 5시간/주간/최상위모델 잔량 %와 리셋까지 남은 시간
- 리셋 시각이 이미 지난 창은 `리셋됨 → 100%`로 표시
- `▶` = 현재 로그인 계정(실시간), 나머지 = 전환 직전 마지막 스냅샷

별도 설정 없이, 각 계정으로 로그인한 상태에서 위젯이 한 번이라도 측정하면 그 계정이 목록에 등록됩니다. 계정을 전환(`/login`)해도 이전 계정의 마지막 잔량이 보존됩니다.

## 요구사항

- Windows 10/11 + WSL2 (아무 배포판)
- WSL 안에 Node.js 18+ (`node` 명령)
- WSL 안에서 Claude Code 로그인 상태 (`~/.claude/.credentials.json` 존재)

## 설치

WSL 터미널에서:

```bash
git clone https://github.com/alibabagini-cyber/claude-codex-battery-win.git
cd claude-codex-battery-win
./install.sh
```

끝. 트레이에 배터리가 뜨고(~20초), 로그인 시 자동 시작이 등록됩니다.
아이콘이 안 보이면 트레이 ∧(오버플로)를 확인하세요 — 다음 재시작부터는 자동으로 표시줄에 고정됩니다(Win11).

## 동작 원리

```
[Windows 트레이]  tray.ps1 (PowerShell, NotifyIcon + 픽셀 렌더)
      │  2분마다: wsl.exe -d <distro> node collector.mjs
      ▼
[WSL]  collector.mjs
      ├─ Claude: ~/.claude/.credentials.json 의 OAuth 토큰으로
      │          Anthropic 공식 usage API(https://api.anthropic.com) 1콜
      └─ Codex : ~/.codex/sessions/**.jsonl 의 rate_limits 파싱 (로컬 파일만)
```

## 보안 / 프라이버시

- **네트워크는 `api.anthropic.com`(HTTPS) 단 한 곳** — Claude 한도 조회용. 그 외 어떤 서버로도 아무것도 보내지 않습니다. 자동 업데이트/텔레메트리 없음.
- OAuth 토큰은 collector 프로세스 안에서만 사용되며 **출력·로그·캐시에 절대 남지 않습니다**. 토큰 갱신도 하지 않습니다(읽기 전용) — 토큰이 만료되면 Claude Code를 쓰는 순간 자동으로 신선해집니다.
- 폴백 캐시 `~/.claude/usage-widget/usage-cache.json`(권한 600)에는 퍼센트·리셋시각만 저장됩니다. 계정별 장부 `accounts.json`(권한 600)에도 이메일 + 퍼센트·리셋시각·측정시각만 저장되며 **토큰은 저장하지 않습니다**.
- 레지스트리 쓰기는 트레이 아이콘 고정용 `HKCU\Control Panel\NotifyIconSettings\*\IsPromoted` 한 곳뿐입니다.
- 관리자 권한 불필요. 설치 산출물은 `%USERPROFILE%\claude-codex-battery\launch.vbs` + 시작프로그램 바로가기 2개가 전부입니다.

## 문제 해결

| 증상 | 확인 |
|---|---|
| 아이콘에 `?` | WSL에서 `node collector.mjs` 직접 실행 → `claudeError` 값 확인 |
| `http-401` | Claude Code를 한 번 실행해 토큰 갱신 |
| 아이콘이 안 뜸 | `powershell -ExecutionPolicy Bypass -File tray.ps1 -Once` (디버그 모드: 데이터·에러 출력) |
| 상세창 ⚠ 표시 | API 일시 실패 → 마지막 캐시값 표시 중이라는 뜻 |

## 제거

1. 트레이 아이콘 우클릭 → 종료
2. 시작프로그램에서 `Claude Codex Battery.lnk` 삭제 (`Win+R` → `shell:startup`)
3. `%USERPROFILE%\claude-codex-battery\` 폴더와 클론한 repo 삭제

## 라이선스

MIT. 원작 [dennykim123/claude-codex-battery](https://github.com/dennykim123/claude-codex-battery) © Denny Kim — 배터리 렌더링 컨셉·Codex rate_limits 파싱 로직을 포팅했습니다.
