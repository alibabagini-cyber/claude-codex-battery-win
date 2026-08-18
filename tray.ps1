# claude-codex-battery — Windows tray port (PowerShell 5.1 호환)
# 원본: https://github.com/dennykim123/claude-codex-battery (macOS SwiftBar)
# 트레이 아이콘 = 배터리 캡슐(잔량 % 숫자 포함), 2분마다 WSL collector.mjs 호출.
# C5=Claude 5시간 · CW=주간 · CF=Fable 주간 · X5/XW=Codex(있을 때만)
# 인자 없이 실행하면 배포판(-Distro/-NodePath/-CollectorPath는 install.sh가 채움)도
# 자동 감지로 동작한다. -Once = 아이콘 없이 데이터·에러만 출력(디버그).
param(
  [switch]$Once,
  [string]$DumpLineup = '',
  [string]$Distro = '',
  [string]$NodePath = '',
  [string]$CollectorPath = ''
)

$ErrorActionPreference = if ($Once) { 'Continue' } else { 'SilentlyContinue' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace CCB -Name Win32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:WSL_UTF8 = '1'

# 단일 인스턴스
$script:mtx = New-Object System.Threading.Mutex($false, 'ClaudeCodexBatteryTray')
if (-not $Once -and -not $script:mtx.WaitOne(0, $false)) { exit }  # -Once(디버그)는 실행 중 트레이와 공존

# ── 경로 자동 감지 (install.sh가 인자로 넘기면 그대로 사용) ──
if (-not $Distro) {
  $Distro = (& wsl.exe -l -q 2>$null | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
  if ($Distro) { $Distro = $Distro.Trim() }
}
if (-not $CollectorPath) {
  # 이 스크립트가 \\wsl.localhost\<distro>\... 에서 실행되면 그 WSL 경로에서 collector를 찾는다
  $m = [regex]::Match($PSScriptRoot, '^\\\\wsl(\.localhost)?\$?\\[^\\]+(?<rest>\\.*)$')
  if ($m.Success) { $CollectorPath = ($m.Groups['rest'].Value -replace '\\', '/') + '/collector.mjs' }
}
if (-not $NodePath) {
  $NodePath = (& wsl.exe -d $Distro -- bash -lc 'command -v node' 2>$null | Where-Object { $_ } | Select-Object -First 1)
}
$WSL_DISTRO = $Distro
$COLLECTOR = $CollectorPath
$NODE = $NodePath

# ── 3x5 픽셀 폰트 (원본 5x7 폰트의 축소판) ─────────────────
$FONT = @{
  '0' = '111','101','101','101','111'
  '1' = '010','110','010','010','111'
  '2' = '111','001','111','100','111'
  '3' = '111','001','011','001','111'
  '4' = '101','101','111','001','001'
  '5' = '111','100','111','001','111'
  '6' = '111','100','111','101','111'
  '7' = '111','001','001','010','010'
  '8' = '111','101','111','101','111'
  '9' = '111','101','111','001','111'
  'C' = '011','100','100','100','011'
  'W' = '101','101','101','111','101'
  'F' = '111','100','110','100','100'
  'X' = '101','101','010','101','101'
  '?' = '111','001','010','000','010'
}

function Get-DarkTaskbar {
  $v = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -ErrorAction SilentlyContinue
  if ($null -eq $v) { return $true }
  return ($v.SystemUsesLightTheme -eq 0)
}

# 잔량 % → 채움 색 (원본 macOS system colors)
function Get-HeatColor([double]$remain) {
  if ($remain -le 20) { return [System.Drawing.Color]::FromArgb(255, 69, 58) }
  if ($remain -lt 50) { return [System.Drawing.Color]::FromArgb(255, 214, 10) }
  return [System.Drawing.Color]::FromArgb(48, 209, 88)
}

# 배터리 아이콘 렌더: 논리 16x16, SCALE=2 → 32x32 비트맵
# 상단=라벨(C5 등), 하단=캡슐(테두리+채움+잔량숫자)
function New-BatteryIcon([string]$label, $remain, [bool]$dark) {
  $scalePx = 2
  $bmp = New-Object System.Drawing.Bitmap(32, 32)
  $ink = if ($dark) { [System.Drawing.Color]::FromArgb(235, 235, 235) } else { [System.Drawing.Color]::FromArgb(45, 45, 45) }
  $darkNum = [System.Drawing.Color]::FromArgb(30, 30, 30)

  function Set-Px([int]$x, [int]$y, $col) {
    if ($x -lt 0 -or $y -lt 0 -or $x -ge 16 -or $y -ge 16) { return }
    for ($dy = 0; $dy -lt $scalePx; $dy++) { for ($dx = 0; $dx -lt $scalePx; $dx++) {
      $bmp.SetPixel($x * $scalePx + $dx, $y * $scalePx + $dy, $col)
    } }
  }
  function Draw-Str([int]$x, [int]$y, [string]$s, $col, $altCol, [int]$boundaryX) {
    $cx = $x
    foreach ($ch in $s.ToCharArray()) {
      $g = $FONT[[string]$ch]
      if ($g) {
        for ($r = 0; $r -lt 5; $r++) { for ($c = 0; $c -lt 3; $c++) {
          if ($g[$r][$c] -eq '1') {
            $px = $cx + $c
            if ($null -ne $altCol -and $px -lt $boundaryX) { Set-Px $px ($y + $r) $altCol }
            else { Set-Px $px ($y + $r) $col }
          }
        } }
      }
      $cx += 4
    }
  }

  # 라벨 (상단 좌측)
  Draw-Str 0 0 $label $ink $null 0

  # 캡슐: 몸통 x0..12 y6..15, 단자 x13..14 y9..12
  $bx = 0; $by = 6; $bw = 13; $bh = 10
  for ($i = 1; $i -lt $bw - 1; $i++) { Set-Px ($bx + $i) $by $ink; Set-Px ($bx + $i) ($by + $bh - 1) $ink }
  for ($j = 1; $j -lt $bh - 1; $j++) { Set-Px $bx ($by + $j) $ink; Set-Px ($bx + $bw - 1) ($by + $j) $ink }
  for ($j = 9; $j -le 12; $j++) { Set-Px 13 $j $ink; Set-Px 14 $j $ink }

  if ($null -ne $remain) {
    $v = [Math]::Max(0, [Math]::Min(100, [double]$remain))
    $innerW = $bw - 2
    $fw = [int][Math]::Round($v / 100 * $innerW)
    if ($fw -gt 0) {
      $fc = Get-HeatColor $v
      for ($j = 1; $j -lt $bh - 1; $j++) { for ($i = 0; $i -lt $fw; $i++) { Set-Px ($bx + 1 + $i) ($by + $j) $fc } }
    }
    $s = [string][int][Math]::Round($v)
    $numw = $s.Length * 4 - 1
    $tx = $bx + [int][Math]::Floor(($bw - $numw) / 2)
    if ($tx -lt $bx + 1) { $tx = $bx + 1 }
    Draw-Str $tx ($by + 2) $s $ink $darkNum ($bx + 1 + $fw)
  } else {
    Draw-Str 5 8 '?' $ink $null 0
  }

  $h = $bmp.GetHicon()
  $icon = [System.Drawing.Icon]::FromHandle($h)
  $bmp.Dispose()
  return @{ Icon = $icon; Handle = $h }
}

# ── 데이터 수집 ────────────────────────────────────────────
function Format-Dur([long]$secs) {
  if ($secs -le 0) { return '0m' }
  $h = [Math]::Floor($secs / 3600); $m = [Math]::Floor(($secs % 3600) / 60)
  if ($h -ge 24) { return ('{0}d {1}h' -f [Math]::Floor($h / 24), ($h % 24)) }
  if ($h -gt 0) { return ('{0}h {1}m' -f $h, $m) }
  return ('{0}m' -f $m)
}

function Get-UsageItems {
  $raw = & wsl.exe -d $WSL_DISTRO -- $NODE $COLLECTOR 2>$null
  if (-not $raw) { return $null }
  $d = ($raw -join '') | ConvertFrom-Json
  if (-not $d) { return $null }
  $now = [long]$d.at
  $items = New-Object System.Collections.ArrayList

  function Add-Win([string]$label, [string]$name, $w) {
    if ($null -eq $w) { return }
    $remain = [Math]::Max(0, 100 - [double]$w.pct)
    $reset = ''
    if ($w.resetsAt) {
      if ([long]$w.resetsAt -lt $now) { $reset = ' · 리셋됨' }
      else { $reset = ' · 리셋 ' + (Format-Dur ([long]$w.resetsAt - $now)) }
    }
    [void]$items.Add(@{
      Label = $label
      Remain = $remain
      Tip = ('{0} 남음 {1}%{2}' -f $name, [int][Math]::Round($remain), $reset)
      Detail = ('{0,-12} 남음 {1,3}%  (사용 {2}%){3}' -f $name, [int][Math]::Round($remain), [int][Math]::Round([double]$w.pct), $reset)
    })
  }

  if ($d.claude) {
    Add-Win 'C5' 'Claude 5시간' $d.claude.fiveHour
    Add-Win 'CW' 'Claude 주간' $d.claude.weekly
    if ($d.claude.fable) {
      $fName = if ($d.claude.fable.model) { [string]$d.claude.fable.model + ' 주간' } else { 'Fable 주간' }
      Add-Win 'CF' $fName $d.claude.fable
    }
    $script:measuredAgo = $now - [long]$d.claude.measuredAt
  }
  $script:lastAccounts = $d.accounts
  $script:lastRecommend = $d.recommend
  $script:lastLineup = [string]$d.lineupPath
  $script:lastNow = $now
  if ($d.codex) {
    # 창 길이(window_minutes)로 5시간/주간 판별 — primary가 주간일 수도 있음(실측: plan=pro는 primary=10080분)
    function Add-CodexWin($w, [string]$fallbackLabel, [string]$fallbackName) {
      if ($null -eq $w) { return }
      $label = $fallbackLabel; $name = $fallbackName
      if ($w.window_minutes) {
        if ([long]$w.window_minutes -ge 10080) { $label = 'XW'; $name = 'Codex 주간' }
        elseif ([long]$w.window_minutes -le 300) { $label = 'X5'; $name = 'Codex 5시간' }
      }
      Add-Win $label $name @{ pct = $w.used_percent; resetsAt = $w.resets_at }
    }
    Add-CodexWin $d.codex.primary 'X5' 'Codex 5시간'
    Add-CodexWin $d.codex.secondary 'XW' 'Codex 주간'
  }
  # 옵션: Grok 영상 주간한도(GV) — grok-usage.json 있을 때만. grok은 정확%가 한계 근처만 노출되어
  # 대개 여유(100%)/소진(0%) 이진에 가깝다(사용자 인지).
  if ($d.grok) {
    Add-Win 'GV' 'Grok 영상주간' @{ pct = $d.grok.pct; resetsAt = $null }
  }
  $script:lastError = [string]$d.claudeError
  return $items
}

# ── 트레이 아이콘 관리 ─────────────────────────────────────
$script:notifyIcons = @{}
$script:iconHandles = @{}
$script:curLabels = @()
$script:lastItems = $null
$script:lastAccounts = $null
$script:lastRecommend = $null
$script:lastLineup = ''
$script:lastUrgentKey = ''
$script:lastNow = 0
$script:measuredAgo = 0
$script:lastError = ''

# 계정 상세용 한 줄 포맷: 리셋 시각이 지났으면 한도 복구로 표시
function Format-AcctWin([string]$name, $w, [long]$now) {
  if ($null -eq $w) { return $null }
  if ($w.resetsAt -and [long]$w.resetsAt -lt $now) {
    return ('    {0}  리셋됨 → 100%' -f $name)
  }
  $remain = [Math]::Max(0, 100 - [double]$w.pct)
  $reset = if ($w.resetsAt) { ' · 리셋 ' + (Format-Dur ([long]$w.resetsAt - $now)) + ' 후' } else { '' }
  return ('    {0}  남음 {1}%{2}' -f $name, [int][Math]::Round($remain), $reset)
}

function Show-Details {
  if (-not $script:lastItems) {
    [System.Windows.Forms.MessageBox]::Show('아직 데이터가 없습니다.', 'Claude & Codex Usage') | Out-Null
    return
  }
  $lines = New-Object System.Collections.ArrayList
  foreach ($it in $script:lastItems) { [void]$lines.Add($it.Detail) }
  [void]$lines.Add('')
  $stale = if ($script:lastError) { ('  ⚠ API 오류({0}) — 캐시값' -f $script:lastError) } else { '' }
  [void]$lines.Add(('측정 ' + (Format-Dur $script:measuredAgo) + ' 전' + $stale))

  # ── 계정별 마지막 관측 (멀티 계정: 전환 직전 잔량 + 리셋 시각) ──
  $accts = @($script:lastAccounts)
  if ($accts.Count -gt 0) {
    $now = $script:lastNow
    [void]$lines.Add('')
    if ($script:lastRecommend -and $accts.Count -gt 1) {
      $why = if ($script:lastRecommend.reason) { $script:lastRecommend.reason } else { '종합여유 ' + $script:lastRecommend.score + '%' }
      [void]$lines.Add(('★ 다음 추천 계정: {0} ({1})' -f $script:lastRecommend.email, $why))
    }
    [void]$lines.Add(('── 계정 우선순위 ({0}) ──' -f $accts.Count))
    foreach ($a in $accts) {
      $mark = if ($a.current) { '▶ ' } else { '   ' }
      $when = if ($a.current) { '현재 로그인' } else { (Format-Dur ($now - [long]$a.at)) + ' 전 관측' }
      $rk = if ($a.rank) { [string]$a.rank + '. ' } else { '' }
      $tag = ''
      if ($a.tier -eq 'skip') { $tag = ' [제외: 주간 소진, 로그인 비효율]' }
      elseif ($a.tier -eq 'opus') { $tag = ' [Fable 소진, Opus/Sonnet용]' }
      [void]$lines.Add(('{0}{1}{2}  ({3}){4}' -f $mark, $rk, $a.email, $when, $tag))
      $l = Format-AcctWin '5시간' $a.fiveHour $now;  if ($l) { [void]$lines.Add($l) }
      $l = Format-AcctWin '주간 ' $a.weekly $now;   if ($l) { [void]$lines.Add($l) }
      if ($a.fable) {
        $fn = if ($a.fable.model) { [string]$a.fable.model } else { 'Fable' }
        $l = Format-AcctWin $fn $a.fable $now; if ($l) { [void]$lines.Add($l) }
      }
    }
  }
  [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), 'Claude & Codex Usage — 남은 한도') | Out-Null
}

function Open-Lineup {
  if (-not $script:lastLineup) {
    [System.Windows.Forms.MessageBox]::Show('라인업 데이터가 아직 없습니다. 새로고침 후 다시 시도하세요.', 'Claude & Codex Usage') | Out-Null
    return
  }
  $p = '\\wsl.localhost\' + $WSL_DISTRO + ($script:lastLineup -replace '/', '\')
  Start-Process $p
}

# ── 캐릭터 줄세우기 팝업 (트레이 왼클릭) ────────────────────
# collector의 accounts(티어·순위·임박)를 배터리 캐릭터로 그린다. GDI+ 직접 렌더, 브라우저 불필요.
$script:lineupForm = $null
$LU = @{ CardW = 132; Pad = 18; Top = 66; Foot = 46; H = 372 }

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}
function Get-EffRemain($w, [long]$now) {
  if ($null -eq $w) { return $null }
  if ($w.resetsAt -and [long]$w.resetsAt -lt $now) { return 100 }
  return [Math]::Max(0, 100 - [double]$w.pct)
}
function Get-ResetShort($w, [long]$now) {
  if ($null -eq $w -or -not $w.resetsAt) { return '' }
  if ([long]$w.resetsAt -lt $now) { return '리셋됨' }
  return (Format-Dur ([long]$w.resetsAt - $now))
}
function Get-Face([double]$v, [string]$tier) {
  if ($tier -eq 'skip') { return 'x_x' }
  if ($v -ge 70) { return '^‿^' }
  if ($v -ge 40) { return '•‿•' }
  if ($v -ge 10) { return '•_•' }
  return 'x_x'
}
function Get-LineupWidth {
  $n = [Math]::Max(1, @($script:lastAccounts).Count)
  return $n * $LU.CardW + $LU.Pad * 2
}

# ── 크루원 캐릭터 (Among Us 풍) ─────────────────────────────
# 계정마다 고정 색(이메일 정렬 순서로 팔레트 배정 → 계정 집합이 같으면 색 불변).
$CREW_PALETTE = @(
  @(197, 17, 17), @(19, 46, 209), @(17, 127, 45), @(237, 84, 189), @(240, 125, 16), @(246, 246, 87),
  @(107, 47, 187), @(56, 255, 221), @(80, 239, 57), @(113, 73, 30), @(214, 224, 240), @(63, 71, 78)
)
function Get-CrewColor([string]$email) {
  $all = @(@($script:lastAccounts) | ForEach-Object { [string]$_.email } | Sort-Object)
  $i = [Array]::IndexOf($all, $email); if ($i -lt 0) { $i = 0 }
  $c = $CREW_PALETTE[$i % $CREW_PALETTE.Count]
  return [System.Drawing.Color]::FromArgb($c[0], $c[1], $c[2])
}
function Get-Darker([System.Drawing.Color]$c, [double]$f) {
  return [System.Drawing.Color]::FromArgb($c.A, [int]($c.R * $f), [int]($c.G * $f), [int]($c.B * $f))
}
# 크루원 1명: (cx, top) 기준 폭 ~64·높이 ~84. fillPct=몸 채움 비율, mode=live|ghost|dead
function Draw-Crewmate($g, [float]$cx, [float]$top, [System.Drawing.Color]$col, [double]$fillPct, [string]$mode) {
  $alpha = if ($mode -eq 'ghost') { 130 } else { 255 }
  $ink = [System.Drawing.Color]::FromArgb($alpha, 40, 40, 52)
  $pen = New-Object System.Drawing.Pen $ink, 2.5
  $pen.LineJoin = 'Round'
  $body = [System.Drawing.Color]::FromArgb($alpha, $col.R, $col.G, $col.B)
  $shade = Get-Darker $body 0.72
  $empty = [System.Drawing.Color]::FromArgb($alpha, 226, 226, 234)
  $st = $g.Save()
  if ($mode -eq 'dead') {
    # 눕힌다 (머리가 왼쪽)
    $g.TranslateTransform($cx, $top + 42); $g.RotateTransform(-90); $g.TranslateTransform(-$cx, -($top + 42))
  }
  $bx = $cx - 20; $by = $top; $bw = 40; $bh = 60           # 몸통 캡슐
  # 다리 (유령·시체는 없음)
  if ($mode -eq 'live') {
    foreach ($lx in @(($bx + 3), ($bx + 22))) {
      $leg = New-RoundRect $lx ($by + $bh - 12) 15 24 6
      $g.FillPath((New-Object System.Drawing.SolidBrush $body), $leg); $g.DrawPath($pen, $leg)
    }
  }
  # 배낭
  $pack = New-RoundRect ($bx - 12) ($by + 16) 16 30 6
  $g.FillPath((New-Object System.Drawing.SolidBrush $shade), $pack); $g.DrawPath($pen, $pack)
  # 몸통: 빈 회색 → 잔량만큼 아래서 색 채움 → 테두리
  $bodyPath = New-RoundRect $bx $by $bw $bh 19
  $g.FillPath((New-Object System.Drawing.SolidBrush $empty), $bodyPath)
  $fh = [Math]::Round($bh * [Math]::Max(0, [Math]::Min(100, $fillPct)) / 100)
  if ($fh -gt 0) {
    $g.SetClip($bodyPath)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush $body), [float]($bx - 1), [float]($by + $bh - $fh), [float]($bw + 2), [float]($fh + 1))
    $g.ResetClip()
  }
  if ($mode -eq 'ghost') {
    # 유령 꼬리: 몸통 아래 물결
    $tail = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tail.AddLine([float]$bx, [float]($by + $bh - 8), [float]$bx, [float]($by + $bh + 8))
    $tail.AddLine([float]$bx, [float]($by + $bh + 8), [float]($bx + 10), [float]($by + $bh - 2))
    $tail.AddLine([float]($bx + 10), [float]($by + $bh - 2), [float]($bx + 20), [float]($by + $bh + 8))
    $tail.AddLine([float]($bx + 20), [float]($by + $bh + 8), [float]($bx + 30), [float]($by + $bh - 2))
    $tail.AddLine([float]($bx + 30), [float]($by + $bh - 2), [float]($bx + 40), [float]($by + $bh + 8))
    $tail.AddLine([float]($bx + 40), [float]($by + $bh + 8), [float]($bx + 40), [float]($by + $bh - 8))
    $tail.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ($(if ($fh -gt 8) { $body } else { $empty }))), $tail)
    $g.DrawPath($pen, $tail)
  }
  $g.DrawPath($pen, $bodyPath)
  # 바이저
  $vis = New-RoundRect ($bx + 12) ($by + 12) 30 17 8
  $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($alpha, 150, 210, 240))), $vis)
  $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($alpha, 235, 250, 255))), (New-RoundRect ($bx + 16) ($by + 15) 14 6 3))
  $g.DrawPath($pen, $vis)
  # 표정 오버레이: 고잔량=반짝, 저잔량=땀방울, dead=뼈다귀
  $fSym = [System.Drawing.Font]::new('Segoe UI Symbol', ([float]8), [System.Drawing.FontStyle]::Bold)
  if ($mode -eq 'dead') {
    # 절단면(몸통 아래=눕힌 뒤 오른쪽)에서 삐져나온 뼈: 흰 막대+양끝 관절
    $bone = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 250, 250, 250)), 4
    $bone.StartCap = 'Round'; $bone.EndCap = 'Round'
    $bxm = $bx + 20; $y0 = $by + $bh - 4; $y1 = $by + $bh + 16
    $g.DrawLine($bone, [float]$bxm, [float]$y0, [float]$bxm, [float]$y1)
    $g.DrawLine((New-Object System.Drawing.Pen $ink, 1.5), [float]($bxm - 2), [float]$y0, [float]($bxm - 2), [float]$y1)
    $g.DrawLine((New-Object System.Drawing.Pen $ink, 1.5), [float]($bxm + 2), [float]$y0, [float]($bxm + 2), [float]$y1)
    foreach ($o in @(-4, 4)) {
      $g.FillEllipse([System.Drawing.Brushes]::White, [float]($bxm + $o - 4), [float]($y1 - 4), 8, 8)
      $g.DrawEllipse((New-Object System.Drawing.Pen $ink, 1.5), [float]($bxm + $o - 4), [float]($y1 - 4), 8, 8)
    }
    $g.FillRectangle([System.Drawing.Brushes]::White, [float]($bxm - 2), [float]($y0 + 2), 4, [float]($y1 - $y0 - 6))
  } elseif ($fillPct -ge 70) {
    $g.DrawString('✦', $fSym, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($alpha, 255, 220, 60))), [float]($bx + 34), [float]($by - 2))
  } elseif ($fillPct -lt 40) {
    $drop = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($alpha, 100, 180, 255))
    $g.FillEllipse($drop, [float]($bx + 41), [float]($by + 8), 5, 8)
  }
  $g.Restore($st)
}

# 한 계정 카드를 (x0, 카드폭) 안에 그린다
function Draw-AcctCard($g, $a, [float]$x0, [long]$now, [string]$recoEmail) {
  $cw = $LU.CardW; $cx = $x0 + $cw / 2
  $tier = [string]$a.tier
  $w5 = Get-EffRemain $a.fiveHour $now; $wk = Get-EffRemain $a.weekly $now
  $fb = if ($null -ne $a.fableRemain) { [double]$a.fableRemain } else { $null }
  $fName = if ($a.fable -and $a.fable.model) { [string]$a.fable.model } else { 'Fable' }
  $fillVal = if ($tier -eq 'fable') { if ($null -ne $fb) { $fb } elseif ($null -ne $a.score) { [double]$a.score } else { 0 } } elseif ($null -ne $wk) { $wk } else { 0 }
  $fillVal = [Math]::Max(0, [Math]::Min(100, $fillVal))
  $fillCol = if ($tier -eq 'skip') { [System.Drawing.Color]::FromArgb(194, 194, 201) }
             elseif ($tier -eq 'opus') { [System.Drawing.Color]::FromArgb(142, 142, 245) }
             elseif ($fillVal -ge 50) { [System.Drawing.Color]::FromArgb(62, 207, 106) }
             elseif ($fillVal -ge 20) { [System.Drawing.Color]::FromArgb(255, 200, 50) }
             else { [System.Drawing.Color]::FromArgb(255, 90, 78) }
  $ink = [System.Drawing.Color]::FromArgb(67, 67, 78)
  $gray = [System.Drawing.Color]::FromArgb(138, 138, 150)
  $inkBrush = New-Object System.Drawing.SolidBrush $ink
  $grayBrush = New-Object System.Drawing.SolidBrush $gray
  $inkPen = New-Object System.Drawing.Pen $ink, 3
  $fBold = [System.Drawing.Font]::new('Malgun Gothic', ([float]8.5), [System.Drawing.FontStyle]::Bold)
  $fSmall = [System.Drawing.Font]::new('Malgun Gothic', ([float]7))
  $fTiny = [System.Drawing.Font]::new('Malgun Gothic', ([float]6.5))
  $fFace = [System.Drawing.Font]::new('Segoe UI Symbol', ([float]11), [System.Drawing.FontStyle]::Bold)
  $center = New-Object System.Drawing.StringFormat; $center.Alignment = 'Center'; $center.LineAlignment = 'Center'
  $centerTop = New-Object System.Drawing.StringFormat; $centerTop.Alignment = 'Center'

  # 크루원 캐릭터 (live=크루원 / opus=유령 / skip=시체)
  $bw = 64; $bh = 82; $bx = $cx - $bw / 2; $by = $LU.Top + 14
  $mode = if ($tier -eq 'skip') { 'dead' } elseif ($tier -eq 'opus') { 'ghost' } else { 'live' }
  Draw-Crewmate $g $cx ($by + 4) (Get-CrewColor ([string]$a.email)) $fillVal $mode
  # 그림자
  $shBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(30, 67, 67, 78))
  $g.FillEllipse($shBrush, [float]($cx - 30), [float]($by + $bh + 5), 60, 9)

  # 왕관(추천) — 배터리 좌상단
  if ($recoEmail -and $a.email -eq $recoEmail) {
    $gold = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 196, 40))
    $goldPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(200, 140, 0)), 1.5
    $kx = $bx - 6; $ky = $by - 18
    $pts = @(
      (New-Object System.Drawing.PointF ($kx), ($ky + 14)), (New-Object System.Drawing.PointF ($kx), ($ky + 3)),
      (New-Object System.Drawing.PointF ($kx + 6), ($ky + 8)), (New-Object System.Drawing.PointF ($kx + 11), ($ky)),
      (New-Object System.Drawing.PointF ($kx + 16), ($ky + 8)), (New-Object System.Drawing.PointF ($kx + 22), ($ky + 3)),
      (New-Object System.Drawing.PointF ($kx + 22), ($ky + 14))
    )
    $g.FillPolygon($gold, $pts); $g.DrawPolygon($goldPen, $pts)
  }
  # 임박 말풍선 — 배터리 우상단
  if ($a.urgent) {
    $u = $a.urgent
    $txt = ('⏰ {0} {1}%' -f $u.name, [int][Math]::Round([double]$u.remain)) + "`n" + (Format-Dur ([long]$u.resetsAt - $now)) + ' 뒤 증발!'
    $sz = $g.MeasureString($txt, $fTiny)
    $ux = $bx + $bw - 22; $uy = $by - 30
    $bub = New-RoundRect $ux $uy ($sz.Width + 10) ($sz.Height + 6) 6
    $g.FillPath([System.Drawing.Brushes]::White, $bub)
    $g.DrawPath((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 156, 63)), 1.5), $bub)
    $g.DrawString($txt, $fTiny, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(192, 86, 0))), [float]($ux + 5), [float]($uy + 3))
  }

  # 순위 배지
  $y = $by + $bh + 18
  $badge = if ($tier -eq 'skip') { '제외' } elseif ($tier -eq 'opus') { ('{0}순위·Opus용' -f $a.rank) } else { ('{0}순위' -f $a.rank) }
  $bcol = if ($tier -eq 'skip') { [System.Drawing.Color]::FromArgb(176, 176, 184) } elseif ($tier -eq 'opus') { [System.Drawing.Color]::FromArgb(142, 142, 245) } else { $ink }
  $bsz = $g.MeasureString($badge, $fSmall)
  $pill = New-RoundRect ($cx - $bsz.Width / 2 - 7) $y ($bsz.Width + 14) 16 8
  $g.FillPath((New-Object System.Drawing.SolidBrush $bcol), $pill)
  $g.DrawString($badge, $fSmall, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF ($cx - 60), $y, 120, 16), $center)
  $y += 20
  # 이름·노트
  $nm = ([string]$a.email).Split('@')[0]
  $g.DrawString($nm, $fBold, $inkBrush, (New-Object System.Drawing.RectangleF ($x0 + 2), $y, ($cw - 4), 14), $centerTop)
  $y += 14
  $note = if ($tier -eq 'skip') { ('주간 {0}% — 비효율' -f [int][Math]::Round($wk)) } elseif ($tier -eq 'opus') { ('{0} 소진({1}%)' -f $fName, [int][Math]::Round($fb)) } else { ('{0} {1}%' -f $fName, [int][Math]::Round($(if ($null -ne $fb) { $fb } else { 100 }))) }
  $g.DrawString($note, $fSmall, $grayBrush, (New-Object System.Drawing.RectangleF ($x0 + 2), $y, ($cw - 4), 12), $centerTop)
  $y += 16
  # 미니 바 3줄: F / 주 / 5h
  $rows = @(
    @{ L = $fName.Substring(0, 1); V = $fb; W = $a.fable; C = [System.Drawing.Color]::FromArgb(255, 138, 179) },
    @{ L = '주'; V = $wk; W = $a.weekly; C = [System.Drawing.Color]::FromArgb(124, 196, 255) },
    @{ L = '5h'; V = $w5; W = $a.fiveHour; C = [System.Drawing.Color]::FromArgb(183, 224, 124) }
  )
  $right = New-Object System.Drawing.StringFormat; $right.Alignment = 'Far'
  $trackBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(228, 228, 236))
  foreach ($r in $rows) {
    if ($null -eq $r.V) { continue }
    $lx = $x0 + 4
    $g.DrawString($r.L, $fTiny, $grayBrush, (New-Object System.Drawing.RectangleF $lx, $y, 14, 10), $right)
    $tx = $lx + 17; $tw = 44
    $g.FillPath($trackBrush, (New-RoundRect $tx ($y + 3) $tw 5 2.5))
    $fw = [Math]::Round($tw * [double]$r.V / 100)
    if ($fw -gt 0) { $g.FillPath((New-Object System.Drawing.SolidBrush $r.C), (New-RoundRect $tx ($y + 3) $fw 5 2.5)) }
    $g.DrawString(('{0}%' -f [int][Math]::Round([double]$r.V)), $fTiny, $grayBrush, (New-Object System.Drawing.RectangleF ($tx + $tw + 2), $y, 30, 10), $right)
    $g.DrawString((Get-ResetShort $r.W $now), $fTiny, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(165, 165, 176))), (New-Object System.Drawing.RectangleF ($tx + $tw + 32), $y, 34, 10), $right)
    $y += 11
  }
  $y += 3
  $ago = if ($a.current) { '현재 로그인' } else { (Format-Dur ($now - [long]$a.at)) + ' 전 관측' }
  $g.DrawString($ago, $fTiny, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(165, 165, 176))), (New-Object System.Drawing.RectangleF ($x0 + 2), $y, ($cw - 4), 10), $centerTop)
  if ($a.current) {
    $y += 11
    $g.DrawString('▶ 지금 켜짐', $fSmall, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(10, 132, 255))), (New-Object System.Drawing.RectangleF ($x0 + 2), $y, ($cw - 4), 12), $centerTop)
  }
}

function Draw-Lineup($g, [int]$W, [int]$H) {
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'AntiAliasGridFit'
  # 파스텔 배경
  $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Point 0, 0), (New-Object System.Drawing.Point 0, $H), ([System.Drawing.Color]::FromArgb(253, 243, 247)), ([System.Drawing.Color]::FromArgb(231, 246, 238))
  $g.FillRectangle($bg, 0, 0, $W, $H)
  $g.DrawRectangle((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(210, 210, 220)), 1), 0, 0, $W - 1, $H - 1)
  $ink = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(59, 59, 70))
  $gray = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(138, 138, 150))
  $center = New-Object System.Drawing.StringFormat; $center.Alignment = 'Center'
  $g.DrawString('클로드 크루원 줄세우기', ([System.Drawing.Font]::new('Malgun Gothic', ([float]12), [System.Drawing.FontStyle]::Bold)), $ink, (New-Object System.Drawing.RectangleF 0, 12, $W, 22), $center)
  $stale = if ($script:lastError) { ' · ⚠ API 오류, 캐시값' } else { '' }
  $g.DrawString(('측정 ' + (Format-Dur $script:measuredAgo) + ' 전 · 잔량 10% 미만 창은 소진 취급' + $stale), ([System.Drawing.Font]::new('Malgun Gothic', ([float]7.5))), $gray, (New-Object System.Drawing.RectangleF 0, 34, $W, 14), $center)
  $accts = @($script:lastAccounts)
  $now = $script:lastNow
  $reco = if ($script:lastRecommend) { [string]$script:lastRecommend.email } else { '' }
  if ($accts.Count -eq 0) {
    $g.DrawString('아직 계정 관측 데이터가 없습니다.', ([System.Drawing.Font]::new('Malgun Gothic', ([float]9))), $gray, (New-Object System.Drawing.RectangleF 0, ($H / 2), $W, 20), $center)
    return
  }
  # 제외 티어 앞에 점선 구분
  $x = $LU.Pad
  $divDrawn = $false
  for ($i = 0; $i -lt $accts.Count; $i++) {
    $a = $accts[$i]
    if (-not $divDrawn -and [string]$a.tier -eq 'skip' -and $i -gt 0) {
      $dp = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(200, 200, 212)), 1.5
      $dp.DashStyle = 'Dash'
      $g.DrawLine($dp, [float]$x, [float]($LU.Top), [float]$x, [float]($H - $LU.Foot - 8))
      $g.DrawString('비효율', ([System.Drawing.Font]::new('Malgun Gothic', ([float]6.5))), $gray, [float]($x - 14), [float]($LU.Top - 14))
      $divDrawn = $true
    }
    Draw-AcctCard $g $a $x $now $reco
    $x += $LU.CardW
  }
  # 추천 푸터
  if ($script:lastRecommend -and $accts.Count -gt 1) {
    $why = if ($script:lastRecommend.reason) { [string]$script:lastRecommend.reason } else { '종합여유 ' + $script:lastRecommend.score + '%' }
    $txt = (('다음 추천: {0} · {1}' -f $script:lastRecommend.email, $why) -replace '—', '-')  # 특수문자(★·—)는 Malgun 폴백으로 서체가 튀므로 본문에서 제외
    $fy = $H - $LU.Foot + 6
    $box = New-RoundRect ($LU.Pad) $fy ($W - $LU.Pad * 2) 30 8
    $g.FillPath([System.Drawing.Brushes]::White, $box)
    $g.DrawPath((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 209, 102)), 2), $box)
    $cf = [System.Drawing.StringFormat]::GenericTypographic.Clone(); $cf.Alignment = 'Center'; $cf.LineAlignment = 'Center'; $cf.Trimming = 'EllipsisCharacter'; $cf.FormatFlags = 'NoWrap'
    $g.DrawString($txt, ([System.Drawing.Font]::new('Malgun Gothic', ([float]8.5))), $ink, (New-Object System.Drawing.RectangleF ($LU.Pad + 24), $fy, ($W - $LU.Pad * 2 - 30), 30), $cf)
    # 별은 별도 폰트(Segoe UI Symbol)로 좌측에 — 본문 서체 오염 방지
    $g.DrawString('★', ([System.Drawing.Font]::new('Segoe UI Symbol', ([float]10))), (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(240, 170, 20))), [float]($LU.Pad + 8), [float]($fy + 6))
  }
}

function Show-Lineup {
  if ($script:lineupForm -and -not $script:lineupForm.IsDisposed) {
    if ($script:lineupForm.Visible) { $script:lineupForm.Hide(); return }
  } else {
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.TopMost = $true; $f.StartPosition = 'Manual'
    $f.Text = 'Claude & Codex Usage — 줄세우기'
    $f.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($f, $true, $null)
    $f.add_Paint({ param($s, $e) try { Draw-Lineup $e.Graphics $s.ClientSize.Width $s.ClientSize.Height } catch {} })
    $f.add_Deactivate({ param($s, $e) $s.Hide() })
    $f.add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $s.Hide() } })
    $f.add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $s.Hide() } })
    $script:lineupForm = $f
  }
  $W = Get-LineupWidth; $H = $LU.H
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $script:lineupForm.Size = New-Object System.Drawing.Size $W, $H
  $script:lineupForm.Location = New-Object System.Drawing.Point ($wa.Right - $W - 10), ($wa.Bottom - $H - 10)
  $script:lineupForm.Show()
  $script:lineupForm.Activate()
  $script:lineupForm.Invalidate()
}

function New-TrayMenu {
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $mi0 = $menu.Items.Add('줄세우기 팝업 🔋'); $mi0.add_Click({ Show-Lineup })
  $mi1 = $menu.Items.Add('상세 정보(텍스트)'); $mi1.add_Click({ Show-Details })
  $miL = $menu.Items.Add('2D 라인업(브라우저)'); $miL.add_Click({ Open-Lineup })
  $mi2 = $menu.Items.Add('지금 새로고침'); $mi2.add_Click({ Update-All })
  [void]$menu.Items.Add('-')
  $mi3 = $menu.Items.Add('종료'); $mi3.add_Click({
    foreach ($ni in $script:notifyIcons.Values) { $ni.Visible = $false; $ni.Dispose() }
    [System.Windows.Forms.Application]::Exit()
  })
  return $menu
}

# 새 트레이 아이콘은 기본적으로 오버플로(∧)에 숨음 → 표시줄로 승격 (Win11)
# 아이콘 재구성 후마다 호출해야 함(레지스트리 엔트리는 아이콘 첫 표시 후 생김)
function Promote-TrayIcons {
  try {
    Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction Stop | ForEach-Object {
      $p = Get-ItemProperty $_.PSPath
      if ($p.ExecutablePath -like '*powershell.exe*' -and $p.IsPromoted -ne 1) {
        Set-ItemProperty $_.PSPath -Name IsPromoted -Value 1 -Type DWord
      }
    }
  } catch {}
}

function Update-All {
  $items = Get-UsageItems
  if ($null -eq $items -or $items.Count -eq 0) {
    foreach ($ni in $script:notifyIcons.Values) { $ni.Text = 'CCB: 수집 실패 (WSL/네트워크 확인)' }
    # 아이콘이 하나도 없는 상태의 실패 = 15초 후 바로 재시도 (2분 공백 방지)
    if ($script:notifyIcons.Count -eq 0 -and $script:timer) { $script:timer.Interval = 15000 }
    return
  }
  if ($script:timer) { $script:timer.Interval = 120000 }
  $script:lastItems = $items
  $dark = Get-DarkTaskbar

  # 라벨 구성이 바뀌면(예: Codex 첫 감지) 아이콘 재구성
  $labels = @($items | ForEach-Object { $_.Label })
  $changed = ($labels -join ',') -ne ($script:curLabels -join ',')
  if ($changed) {
    foreach ($ni in $script:notifyIcons.Values) { $ni.Visible = $false; $ni.Dispose() }
    $script:notifyIcons = @{}
    foreach ($h in $script:iconHandles.Values) { [CCB.Win32]::DestroyIcon($h) | Out-Null }
    $script:iconHandles = @{}
    # 생성 순서 = 왼쪽→오른쪽 표시 순서 (실측)
    for ($i = 0; $i -lt $items.Count; $i++) {
      $it = $items[$i]
      $ni = New-Object System.Windows.Forms.NotifyIcon
      $ni.ContextMenuStrip = New-TrayMenu
      # 왼쪽 클릭 = 캐릭터 줄세우기 팝업(계정 우선순위). 우클릭은 ContextMenuStrip이 처리.
      $ni.add_MouseClick({ param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { try { Show-Lineup } catch {} }
      })
      $ni.Visible = $true
      $script:notifyIcons[$it.Label] = $ni
    }
    $script:curLabels = $labels
  }

  foreach ($it in $items) {
    $ni = $script:notifyIcons[$it.Label]
    if ($null -eq $ni) { continue }
    $r = New-BatteryIcon $it.Label $it.Remain $dark
    $old = $script:iconHandles[$it.Label]
    $ni.Icon = $r.Icon
    $tip = $it.Tip
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $ni.Text = $tip
    if ($old) { [CCB.Win32]::DestroyIcon($old) | Out-Null }
    $script:iconHandles[$it.Label] = $r.Handle
  }
  if ($changed) { Promote-TrayIcons }
  if ($script:lineupForm -and -not $script:lineupForm.IsDisposed -and $script:lineupForm.Visible) { $script:lineupForm.Invalidate() }

  # 한도 소멸 임박 알림 — 리셋임박 소진 추천이 새로 뜨면 풍선 알림 1회 (같은 리셋 창당 1번)
  if ($script:lastRecommend -and $script:lastRecommend.urgent -and $script:lastRecommend.key -ne $script:lastUrgentKey) {
    $script:lastUrgentKey = [string]$script:lastRecommend.key
    $ni = $script:notifyIcons.Values | Select-Object -First 1
    if ($ni) {
      $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
      $ni.BalloonTipTitle = '⏳ Claude 한도 소멸 임박'
      $ni.BalloonTipText = ('{0}' -f $script:lastRecommend.email) + [Environment]::NewLine + $script:lastRecommend.reason + ' — 이 계정부터 소진'
      $ni.ShowBalloonTip(15000)
    }
  }
}

# ── 기동 ───────────────────────────────────────────────────
Update-All
Promote-TrayIcons

if ($Once) {
  if ($DumpLineup) {
    try {
      $W = Get-LineupWidth; $H = $LU.H
      $bmp = New-Object System.Drawing.Bitmap $W, $H
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      Draw-Lineup $g $W $H
      $g.Dispose(); $bmp.Save($DumpLineup, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
      Write-Output ('lineup dumped: ' + $DumpLineup + ' ' + $W + 'x' + $H)
    } catch { Write-Output ('lineup dump ERR: ' + $_.ToString()) }
  }
  Write-Output ('icons=' + $script:notifyIcons.Count + ' labels=' + ($script:curLabels -join ','))
  if ($script:lastItems) { foreach ($it in $script:lastItems) { Write-Output ('item: ' + $it.Label + ' remain=' + $it.Remain + ' tip=' + $it.Tip) } }
  foreach ($a in @($script:lastAccounts)) {
    Write-Output ('acct: ' + $a.email + ' current=' + $a.current)
    $l = Format-AcctWin '5시간' $a.fiveHour $script:lastNow; if ($l) { Write-Output $l }
    $l = Format-AcctWin '주간 ' $a.weekly $script:lastNow;  if ($l) { Write-Output $l }
    if ($a.fable) { $l = Format-AcctWin 'Fable' $a.fable $script:lastNow; if ($l) { Write-Output $l } }
  }
  Write-Output ('errors=' + $Error.Count)
  $Error | Select-Object -First 5 | ForEach-Object { Write-Output ('ERR: ' + $_.ToString() + ' @ ' + $_.InvocationInfo.PositionMessage) }
  foreach ($ni in $script:notifyIcons.Values) { $ni.Visible = $false; $ni.Dispose() }
  exit
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = if ($script:notifyIcons.Count -eq 0) { 15000 } else { 120000 }
# 틱 안 예외가 메시지루프를 죽이지 않게 격리
$script:timer.add_Tick({ try { Update-All } catch {} })
$script:timer.Start()

[System.Windows.Forms.Application]::Run()
$script:mtx.ReleaseMutex()
