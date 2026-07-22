# claude-codex-battery — Windows tray port (PowerShell 5.1 호환)
# 원본: https://github.com/dennykim123/claude-codex-battery (macOS SwiftBar)
# 트레이 아이콘 = 배터리 캡슐(잔량 % 숫자 포함), 2분마다 WSL collector.mjs 호출.
# C5=Claude 5시간 · CW=주간 · CF=Fable 주간 · X5/XW=Codex(있을 때만)
# 인자 없이 실행하면 배포판(-Distro/-NodePath/-CollectorPath는 install.sh가 채움)도
# 자동 감지로 동작한다. -Once = 아이콘 없이 데이터·에러만 출력(디버그).
param(
  [switch]$Once,
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
if (-not $script:mtx.WaitOne(0, $false)) { exit }

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
  $script:lastNow = $now
  if ($d.codex) {
    if ($d.codex.primary) {
      Add-Win 'X5' 'Codex 5시간' @{ pct = $d.codex.primary.used_percent; resetsAt = $d.codex.primary.resets_at }
    }
    if ($d.codex.secondary) {
      Add-Win 'XW' 'Codex 주간' @{ pct = $d.codex.secondary.used_percent; resetsAt = $d.codex.secondary.resets_at }
    }
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
      [void]$lines.Add(('★ 다음 추천 계정: {0} (종합여유 {1}%)' -f $script:lastRecommend.email, $script:lastRecommend.score))
    }
    [void]$lines.Add(('── 계정별 마지막 관측 ({0}) ──' -f $accts.Count))
    foreach ($a in $accts) {
      $mark = if ($a.current) { '▶ ' } else { '   ' }
      $when = if ($a.current) { '현재 로그인' } else { (Format-Dur ($now - [long]$a.at)) + ' 전 관측' }
      $sc = if ($null -ne $a.score) { ', 여유 ' + $a.score + '%' } else { '' }
      [void]$lines.Add(('{0}{1}  ({2}{3})' -f $mark, $a.email, $when, $sc))
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

function New-TrayMenu {
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $mi1 = $menu.Items.Add('상세 정보'); $mi1.add_Click({ Show-Details })
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
      # 왼쪽 클릭 = 상세(계정별 포함). 우클릭은 ContextMenuStrip이 처리.
      $ni.add_MouseClick({ param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { try { Show-Details } catch {} }
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
}

# ── 기동 ───────────────────────────────────────────────────
Update-All
Promote-TrayIcons

if ($Once) {
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
