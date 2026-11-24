# limit-switch: moves work from the Claude subscription to the free OmniRoute queue.
#   start      - SessionStart hook: warn if the subscription is 70%+ used
#   prompt     - UserPromptSubmit hook: at 70%+ copy the prompt, open the free window, block the prompt here
#   ratelimit  - StopFailure(rate_limit) hook: limit hit -> remember it and open the free window
#   manual ID  - /besplatno command
#   show       - /limity command
# Settings can be overridden with environment variables (see README).
param([string]$Mode = 'show', [string]$Sid = '')
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Cfg($name, $default) { $v = [Environment]::GetEnvironmentVariable($name); if ($v) { $v } else { $default } }
$Limit    = [double](Cfg 'LIMIT_SWITCH_THRESHOLD' 70)                                  # switch threshold, % used
$DataDir  = Cfg 'LIMIT_SWITCH_DATA_DIR' 'D:\clod\Programs\omniroute\data'
$FreeCmd  = Cfg 'LIMIT_SWITCH_FREE_CMD' 'D:\clod\Programs\omniroute\Claude-Continue-Free.cmd'
$WorkDir  = Cfg 'LIMIT_SWITCH_WORKDIR'  'D:\clod\work'
$FreePort = Cfg 'LIMIT_SWITCH_FREE_PORT' '20128'                                       # OmniRoute port
$Limits   = "$DataDir\claude-limits.json"                         # written by the status line
$HitFile  = "$DataDir\claude-limit-hit.json"                      # written here on a rate_limit error
$LockFile = "$DataDir\limit-switch.lock"
$DryRun   = $env:LIMIT_SWITCH_DRYRUN -eq '1'

# hook input (JSON on stdin) - only hooks get it; commands must not wait on stdin
$in = $null
if ($Mode -in 'start','prompt','ratelimit' -and [Console]::IsInputRedirected) { $raw = [Console]::In.ReadToEnd(); if ($raw) { $in = $raw | ConvertFrom-Json } }
if (-not $Sid -and $in.session_id) { $Sid = "$($in.session_id)" }

# this session already runs through OmniRoute -> nothing to do
$IsFree = "$env:ANTHROPIC_BASE_URL" -match "localhost:$FreePort|127\.0\.0\.1:$FreePort"

function Get-Usage {
  $r = @{ over = $false; lines = @(); max = 0 }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if (Test-Path $Limits) {
    $j = Get-Content $Limits -Raw | ConvertFrom-Json
    foreach ($w in @(@('five_hour', '5 часов'), @('seven_day', 'неделя'))) {
      $x = $j.($w[0]); if (-not $x) { continue }
      $rt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$x.resets_at).LocalDateTime
      if ([int64]$x.resets_at -le $now) { $r.lines += "Claude $($w[1]): окно обнулилось, осталось 100%"; continue }
      $used = [double]$x.used_percentage
      $r.lines += "Claude $($w[1]): потрачено $([int]$used)%, осталось $([int](100 - $used))% (сброс $($rt.ToString('dd.MM HH:mm')))"
      if ($used -gt $r.max) { $r.max = $used }
      if ($used -ge $Limit) { $r.over = $true }
    }
  } else { $r.lines += 'Claude: данных пока нет (появятся после первого ответа по подписке)' }
  if (Test-Path $HitFile) {
    $h = Get-Content $HitFile -Raw | ConvertFrom-Json
    $age = ((Get-Date) - [datetime]$h.at).TotalMinutes
    if ($age -lt 60) { $r.over = $true; $r.max = 100; $r.lines += "Лимит подписки был исчерпан $([int]$age) мин назад" }
  }
  return $r
}

function Open-Free([string]$id) {
  # one window per 2 minutes, so several hooks do not open several windows
  if ((Test-Path $LockFile) -and ((Get-Date) - (Get-Item $LockFile).LastWriteTime).TotalSeconds -lt 120) { return $false }
  Set-Content $LockFile (Get-Date).ToString('o')
  if ($DryRun) { return $true }
  Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', "`"$FreeCmd`" $id" -WorkingDirectory $WorkDir
  return $true
}

function Out-Json($o) { $o | ConvertTo-Json -Compress -Depth 5 }

switch ($Mode) {
  'start' {
    if ($IsFree) { exit 0 }
    $u = Get-Usage
    if ($u.over) {
      Out-Json @{ systemMessage = "⚠ Лимит подписки Claude потрачен на $([int]$u.max)%. Чтобы не тратить его, введи /besplatno — разговор продолжится в бесплатном режиме." }
    }
    exit 0
  }
  'prompt' {
    if ($IsFree) { exit 0 }
    $u = Get-Usage
    if (-not $u.over) { exit 0 }
    if ("$($in.prompt)" -match '^\s*/') { exit 0 }      # let slash commands (/besplatno, /limity, ...) through
    if ($in.prompt) { Set-Clipboard -Value "$($in.prompt)" }
    $opened = Open-Free $Sid
    $msg = "Лимит подписки Claude потрачен на $([int]$u.max)% (порог $Limit%). Запрос НЕ отправлен в подписку. "
    if ($opened) { $msg += 'Открыл новое окно бесплатного режима с этим же разговором. ' }
    $msg += 'Твой запрос скопирован в буфер — вставь его там (Ctrl+V). Это окно можно закрыть.'
    Out-Json @{ decision = 'block'; reason = $msg }
    exit 0
  }
  'ratelimit' {
    if ($IsFree) { exit 0 }
    @{ at = (Get-Date).ToString('o'); session = $Sid } | ConvertTo-Json | Set-Content $HitFile -Encoding UTF8
    [void](Open-Free $Sid)
    exit 0
  }
  'manual' {
    if ($IsFree) { 'Этот разговор уже идёт через бесплатный режим (OmniRoute).'; exit 0 }
    if (Open-Free $Sid) { 'Открыл новое окно бесплатного режима с этим разговором. Продолжай там, это окно можно закрыть.' }
    else { 'Окно бесплатного режима уже открывалось меньше 2 минут назад — проверь панель задач.' }
    exit 0
  }
  default {
    $u = Get-Usage
    if ($IsFree) { 'Режим: бесплатный (OmniRoute).' } else { 'Режим: подписка Claude.' }
    $u.lines
    if ($u.over) { "Порог $Limit% достигнут — работай в бесплатном режиме (/besplatno)." }
    exit 0
  }
}
