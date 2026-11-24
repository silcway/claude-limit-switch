# LimitPilot - limits of the Claude subscription and of free OmniRoute models inside Claude Code.
#
#   statusline        status line: saves Claude rate_limits, shows limits + forecast
#   start             SessionStart hook: warnings, "subscription is back" notice
#   prompt            UserPromptSubmit hook: over the threshold -> copy prompt, open free window, block here
#   ratelimit         StopFailure(rate_limit) hook: real limit -> open free window; short throttling -> ignore
#   manual [id]       /besplatno
#   show              /limity
#   models            /modeli
#   threshold A [B]   /porog  (A = 5-hour window, B = week; one number sets both)
#   picker OUT [nogodmode]   writes a --settings file whose /model menu shows every free model with its limit
#   setup ROOT        /limit-pilot:nastroit - points the Claude Code status line at this script
#
# Windows PowerShell 5.1. Settings can be overridden with LIMITPILOT_* environment variables (see README).
param([string]$Mode = 'show', [string]$Arg1 = '', [string]$Arg2 = '')
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Cfg($name, $default) { $v = [Environment]::GetEnvironmentVariable($name); if ($v) { $v } else { $default } }
$DataDir  = Cfg 'LIMITPILOT_DATA_DIR'       'D:\clod\Programs\omniroute\data'
$OrUrl    = Cfg 'LIMITPILOT_OMNIROUTE_URL'  'http://localhost:20128'
$OrData   = Cfg 'LIMITPILOT_OMNIROUTE_DATA' 'D:\clod\Programs\omniroute\data'
$Combo    = Cfg 'LIMITPILOT_COMBO'          'ochered'
$FreeCmd  = Cfg 'LIMITPILOT_FREE_CMD'       'D:\clod\Programs\omniroute\Claude-Continue-Free.cmd'
$WorkDir  = Cfg 'LIMITPILOT_WORKDIR'        'D:\clod\work'
$DryRun   = $env:LIMITPILOT_DRYRUN -eq '1'

$LimitsF  = Join-Path $DataDir 'claude-limits.json'      # last known Claude rate_limits
$HistF    = Join-Path $DataDir 'claude-history.jsonl'    # samples for the burn-rate forecast
$HitF     = Join-Path $DataDir 'claude-limit-hit.json'   # set when the limit was really hit
$CfgF     = Join-Path $DataDir 'limitpilot.json'         # thresholds
$LockF    = Join-Path $DataDir 'limitpilot.lock'
$OrCacheF = Join-Path $DataDir 'limitpilot-providers.json'
New-Item -ItemType Directory -Force $DataDir | Out-Null

$in = $null
if ($Mode -in 'start','prompt','ratelimit','statusline' -and [Console]::IsInputRedirected) {
  $raw = [Console]::In.ReadToEnd(); if ($raw) { $in = $raw | ConvertFrom-Json }
}
$Sid = $Arg1; if (-not $Sid -and $in.session_id) { $Sid = "$($in.session_id)" }
$orHostPort = ([uri]$OrUrl).Authority
$IsFree = ("$env:ANTHROPIC_BASE_URL" -like "*$orHostPort*") -or ("$env:ANTHROPIC_BASE_URL" -like "*127.0.0.1:$(([uri]$OrUrl).Port)*")
$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# ---------------------------------------------------------------- helpers
function Out-Json($o) { $o | ConvertTo-Json -Compress -Depth 8 }
function Dur([double]$h) {
  if ($h -lt 0) { return '—' }
  $m = [int][math]::Round($h * 60)
  if ($m -lt 60) { return "$m мин" }
  if ($m -lt 1440) { return "$([int][math]::Floor($m / 60))ч $($m % 60)м" }
  return "$([int][math]::Floor($m / 1440))д $([int][math]::Floor(($m % 1440) / 60))ч"
}
function LocalTime([int64]$epoch) { [DateTimeOffset]::FromUnixTimeSeconds($epoch).LocalDateTime.ToString('dd.MM HH:mm') }

function Get-Config {
  $c = @{ five = 70; week = 70 }
  if (Test-Path $CfgF) { $j = Get-Content $CfgF -Raw | ConvertFrom-Json; if ($j.five) { $c.five = [double]$j.five }; if ($j.week) { $c.week = [double]$j.week } }
  return $c
}

# ---------------------------------------------------------------- Claude subscription
function Save-Limits($rl) {
  if (-not $rl -or -not ($rl.five_hour -or $rl.seven_day)) { return }
  @{ saved = $Now; five_hour = $rl.five_hour; seven_day = $rl.seven_day } | ConvertTo-Json -Depth 4 | Set-Content $LimitsF -Encoding UTF8
  $f = [double]$rl.five_hour.used_percentage; $w = [double]$rl.seven_day.used_percentage
  $last = $null; if (Test-Path $HistF) { $last = Get-Content $HistF -Tail 1 | ConvertFrom-Json }
  if (-not $last -or $last.f -ne $f -or $last.w -ne $w) {
    Add-Content $HistF (Out-Json @{ t = $Now; f = $f; fr = [int64]$rl.five_hour.resets_at; w = $w; wr = [int64]$rl.seven_day.resets_at }) -Encoding UTF8
  }
  # keep the history small
  if ((Get-Item $HistF).Length -gt 200KB) { Get-Content $HistF -Tail 1000 | Set-Content "$HistF.tmp" -Encoding UTF8; Move-Item "$HistF.tmp" $HistF -Force }
}

function Get-Claude {
  $cfg = Get-Config
  $r = @{ has = $false; over = $false; max = 0; windows = @(); stale = 0; hitAge = -1; cfg = $cfg }
  if (Test-Path $HitF) { $r.hitAge = ((Get-Date) - [datetime]((Get-Content $HitF -Raw | ConvertFrom-Json).at)).TotalMinutes }
  if (-not (Test-Path $LimitsF)) { if ($r.hitAge -ge 0 -and $r.hitAge -lt 60) { $r.over = $true; $r.max = 100 }; return $r }
  $j = Get-Content $LimitsF -Raw | ConvertFrom-Json
  $r.has = $true; $r.stale = ($Now - [int64]$j.saved) / 60
  $hist = @(); if (Test-Path $HistF) { $hist = @(Get-Content $HistF -Tail 400 | % { $_ | ConvertFrom-Json }) }
  foreach ($d in @(@('five_hour', '5 ч', 5, 'f', 'fr', 'five'), @('seven_day', 'неделя', 168, 'w', 'wr', 'week'))) {
    $x = $j.($d[0]); if (-not $x) { continue }
    $win = @{ key = $d[0]; name = $d[1]; thr = $cfg[$d[5]]; resets = [int64]$x.resets_at; used = [double]$x.used_percentage; reset = $false
              rate = $null; eta100 = $null; etaThr = $null; pace = $null }
    if ($win.resets -le $Now) { $win.reset = $true; $win.used = 0 }
    else {
      # budget pace: how much "should" be used by now if spent evenly over the window
      $lenS = $d[2] * 3600; $elapsed = $lenS - ($win.resets - $Now)
      if ($elapsed -gt 0) { $win.pace = [math]::Round(100 * $elapsed / $lenS) }
      # burn rate: % per hour over the last 90 minutes of this window
      $smp = @($hist | ? { $_.($d[4]) -eq $win.resets -and $_.t -ge ($Now - 5400) })
      if ($smp.Count -ge 2) {
        $a = $smp[0]; $b = $smp[-1]; $hrs = ($b.t - $a.t) / 3600
        if ($hrs -ge 0.08) {
          $win.rate = ($b.($d[3]) - $a.($d[3])) / $hrs
          if ($win.rate -gt 0.1) {
            $win.eta100 = (100 - $win.used) / $win.rate
            if ($win.used -lt $win.thr) { $win.etaThr = ($win.thr - $win.used) / $win.rate }
          }
        }
      }
      if ($win.used -ge $win.thr) { $r.over = $true }
      if ($win.used -gt $r.max) { $r.max = $win.used }
    }
    $r.windows += $win
  }
  if ($r.hitAge -ge 0 -and $r.hitAge -lt 60) { $r.over = $true; $r.max = 100 }
  return $r
}

function Claude-Lines($c) {
  $out = @()
  if (-not $c.has) { $out += 'Claude: данных пока нет — появятся после первого ответа по подписке'; return $out }
  foreach ($w in $c.windows) {
    if ($w.reset) { $out += "Claude $($w.name): окно обнулилось — снова 100%"; continue }
    $s = "Claude $($w.name): потрачено $([int]$w.used)% (осталось $([int](100 - $w.used))%), сброс $(LocalTime $w.resets), порог $([int]$w.thr)%"
    if ($null -ne $w.pace) {
      $d = [int]($w.used - $w.pace)
      if ($d -gt 5) { $s += "; тратишь быстрее нормы на $d%" } elseif ($d -lt -5) { $s += "; идёшь с запасом $(-$d)%" } else { $s += '; темп в норме' }
    }
    if ($w.eta100) {
      $s += "; при текущем темпе ($([math]::Round($w.rate, 1))%/ч) кончится через $(Dur $w.eta100)"
      if ($w.etaThr) { $s += ", порог через $(Dur $w.etaThr)" }
      if ($w.eta100 * 3600 -gt ($w.resets - $Now)) { $s += ' — до сброса хватит' }
    }
    $out += $s
  }
  if ($c.stale -gt 30) { $out += "(данные Claude от $(LocalTime ($Now - [int64]($c.stale * 60))) — обновятся в следующей сессии по подписке)" }
  if ($c.hitAge -ge 0 -and $c.hitAge -lt 60) { $out += "Лимит подписки был исчерпан $([int]$c.hitAge) мин назад" }
  return $out
}

# ---------------------------------------------------------------- OmniRoute (free providers)
$Names = @{ 'grok-cli'='Grok'; 'gemini'='Gemini'; 'openrouter'='OpenRouter'; 'moonshot'='Kimi'; 'zai'='Z.AI'; 'groq'='Groq'; 'cerebras'='Cerebras'; 'mistral'='Mistral'; 'nvidia'='NVIDIA'; 'claude'='Claude' }
$Periods = @{ weekly='на неделю'; free_daily='на день'; daily='на день'; monthly='на месяц'; free_rpm='в минуту'; credits='кредитов'; session='на 5 ч' }

function Or-Token {
  $saltF = Join-Path $OrData 'cli-token-salt.json'; if (-not (Test-Path $saltF)) { return $null }
  $g = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
  $salt = (Get-Content $saltF -Raw | ConvertFrom-Json).salt
  $hm = New-Object Security.Cryptography.HMACSHA256 (,[Text.Encoding]::UTF8.GetBytes($g))
  -join ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($salt)) | % { $_.ToString('x2') })
}
$script:OrTok = $null
function Or-Api($p, $timeout = 8) {
  if (-not $script:OrTok) { $script:OrTok = Or-Token }
  try {
    $r = Invoke-WebRequest "$OrUrl$p" -Headers @{ 'x-omniroute-cli-token' = $script:OrTok } -TimeoutSec $timeout -UseBasicParsing
    [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
  } catch { $null }
}

function Get-Providers([int]$maxAgeSec = 60) {
  if ((Test-Path $OrCacheF) -and ((Get-Date) - (Get-Item $OrCacheF).LastWriteTime).TotalSeconds -lt $maxAgeSec) {
    return (Get-Content $OrCacheF -Raw -Encoding UTF8 | ConvertFrom-Json)
  }
  $res = @{ ok = $false; at = $Now; providers = @(); combo = @(); last = '' }
  $conns = Or-Api '/api/rate-limits' 15
  if ($conns) {
    $res.ok = $true
    $today = (Get-Date).Date.ToUniversalTime()
    $logs = @(); foreach ($a in (Or-Api '/api/usage/call-logs?limit=200')) { foreach ($x in $a) { if ($x.timestamp -and $x.model -notin 'connection-test','model-sync' -and $x.path -like '*/v1/*' -and ([datetime]$x.timestamp).ToUniversalTime() -ge $today) { $logs += $x } } }
    if ($logs.Count) { $res.last = "$($logs[0].provider)/$($logs[0].model)" }
    foreach ($c in $conns.connections) {
      $nm = $Names[$c.provider]; if (-not $nm) { $nm = $c.provider }
      $p = @{ id = $c.provider; name = $nm; pct = $null; text = ''; state = 'unknown'; today = @($logs | ? { $_.provider -eq $c.provider }).Count }
      $u = Or-Api "/api/usage/$($c.connectionId)" 12
      $q = $null; $qk = ''
      if ($u.quotas) { foreach ($pp in $u.quotas.PSObject.Properties) { if ($pp.Value.total -gt 0 -or $pp.Value.isPercentageOnly) { $q = $pp.Value; $qk = $pp.Name; break } } }
      if ($u.limitReached) { $p.pct = 0; $p.state = 'empty'; $p.text = 'баланс 0$ — не ответит' }
      elseif ($q) {
        $p.pct = [double]$q.remainingPercentage; $p.state = 'known'
        $per = $Periods[$qk]; if (-not $per) { $per = $qk }
        if ($q.isPercentageOnly) { $p.text = "осталось $([int]$p.pct)% $per" } else { $p.text = "осталось $([math]::Round($q.remaining, 2)) из $([math]::Round($q.total, 2)) $per" }
        if ($q.resetAt) { $p.text += ", сброс $(([datetime]$q.resetAt).ToLocalTime().ToString('dd.MM HH:mm'))" }
      } else { $p.text = "лимит не сообщает, сегодня $($p.today) запросов" }
      $mine = @($logs | ? { $_.provider -eq $c.provider })
      if ($mine.Count -and $mine[0].status -in 429, 402 -and ((Get-Date).ToUniversalTime() - ([datetime]$mine[0].timestamp).ToUniversalTime()).TotalMinutes -lt 30) {
        if ($mine[0].status -eq 429) { $p.text += ' · ⚠ сейчас упёрся в лимит' } else { $p.text += ' · ⚠ просит оплату' }
        if ($p.state -ne 'known') { $p.state = 'hit' }
      }
      $res.providers += $p
    }
    $combos = Or-Api '/api/combos'
    $cb = @($combos.combos | ? { $_.name -eq $Combo }) | Select -First 1
    if ($cb) { $res.combo = @($cb.models | % { "$($_.model)" }) }
  }
  # cache only a good answer: a failed one must not hide the models for the next minute
  if (-not $res.ok) { return ((Out-Json $res) | ConvertFrom-Json) }
  Out-Json $res | Set-Content $OrCacheF -Encoding UTF8
  return (Get-Content $OrCacheF -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Prov-Of($model) { ($model -split '/')[0] }
function Pretty($model) {
  $prov = Prov-Of $model; $pn = $Names[$prov]; if (-not $pn) { $pn = $prov }
  $last = ($model -split '/')[-1]; $free = $last -like '*:free'; $last = $last -replace ':free$', ''
  $words = ($last -split '-') | % { if ($_ -match '^\d') { $_ } else { $_.Substring(0,1).ToUpper() + $_.Substring(1) } }
  $label = ($words -join ' ')
  if ($label -notlike "*$pn*") { $label = "$pn · $label" }
  if ($free) { $label += ' (free)' }
  return $label
}
function Prov-Text($pv, $model) {
  $p = @($pv.providers | ? { $_.id -eq (Prov-Of $model) }) | Select -First 1
  if ($p) { return "$($p.name): $($p.text)" } else { return 'нет данных о лимите' }
}

function Picker-Rows($pv) {
  $models = @($pv.combo); if (-not $models.Count) { $models = @($pv.providers | % { $null }) }
  $order = (@($models | % { (Pretty $_) -replace ' · .*$', '' } | Select -Unique) -join ' → ')
  $first = @($pv.providers | ? { $_.id -eq (Prov-Of $models[0]) }) | Select -First 1
  $rows = @(@{ model = $Combo; label = "★ Авто-очередь ($Combo)"; description = "сама берёт первую свободную модель: $order. Сейчас: $(Prov-Text $pv $models[0])" })
  foreach ($m in $models) { if ($m) { $rows += @{ model = $m; label = (Pretty $m); description = (Prov-Text $pv $m) } } }
  return $rows
}

# ---------------------------------------------------------------- switching
function Open-Free([string]$id) {
  if ((Test-Path $LockF) -and ((Get-Date) - (Get-Item $LockF).LastWriteTime).TotalSeconds -lt 120) { return $false }
  Set-Content $LockF (Get-Date).ToString('o')
  if ($DryRun) { return $true }
  Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', "`"$FreeCmd`" $id" -WorkingDirectory $WorkDir
  return $true
}

# ---------------------------------------------------------------- modes
switch ($Mode) {
  'statusline' {
    Save-Limits $in.rate_limits
    $c = Get-Claude
    $parts = @()
    if (-not $IsFree -and $c.has) {
      $s = @(); foreach ($w in $c.windows) {
        if ($w.reset) { $s += "$($w.name) 100%"; continue }
        $t = "$($w.name) осталось $([int](100 - $w.used))%"; if ($w.eta100 -and $w.eta100 * 3600 -lt ($w.resets - $Now)) { $t += " (~$(Dur $w.eta100))" }
        $s += $t
      }
      $parts += 'Claude ' + ($s -join ', ')
      if ($c.over) { $parts = @("⚠ порог $([int]$c.cfg.five)% — /besplatno") + $parts }
    }
    if ($IsFree) {
      $pv = Get-Providers 45
      $parts += '[бесплатно]'
      if ($pv.last) { $parts += "сейчас $($pv.last)" }
      $parts += (@($pv.providers | ? { $_.state -eq 'known' } | % { "$($_.name) $([int]$_.pct)%" }) -join ' · ')
      if ($c.has -and -not $c.over -and @($c.windows | ? { $_.reset -or $_.used -lt $_.thr }).Count -eq $c.windows.Count) { $parts += 'подписка Claude снова доступна' }
    }
    $line = ($parts | ? { $_ }) -join ' | '
    if ($in.model.display_name) { $line = "[$($in.model.display_name)] $line" }
    Write-Output $line
    exit 0
  }
  'start' {
    $c = Get-Claude
    if ($IsFree) {
      # "auto-revert" notice: the subscription is usable again
      if ($c.has -and ($c.hitAge -lt 0 -or $c.hitAge -ge 60) -and -not $c.over) {
        Out-Json @{ systemMessage = 'LimitPilot: подписка Claude снова доступна (лимит ниже порога). Можно вернуться — ярлык «Claude Code - подписка». Модели и их лимиты: /model или /modeli.' }
      } else { Out-Json @{ systemMessage = 'LimitPilot: бесплатный режим. Выбор модели с лимитами — /model, подробно — /limity.' } }
      exit 0
    }
    if ($c.over) {
      Out-Json @{ systemMessage = "⚠ LimitPilot: лимит подписки Claude потрачен на $([int]$c.max)% (порог $([int]$c.cfg.five)%/$([int]$c.cfg.week)%). Чтобы не тратить его, введи /besplatno — разговор продолжится в бесплатном режиме." }
    } else {
      $soon = @($c.windows | ? { $_.etaThr -and $_.etaThr -lt 1 })
      if ($soon.Count) { Out-Json @{ systemMessage = "LimitPilot: при текущем темпе порог $([int]$soon[0].thr)% будет через $(Dur $soon[0].etaThr). Подробно — /limity." } }
    }
    exit 0
  }
  'prompt' {
    if ($IsFree) { exit 0 }
    $c = Get-Claude
    if (-not $c.over) { exit 0 }
    if ("$($in.prompt)" -match '^\s*/') { exit 0 }      # slash commands go through
    if ($in.prompt) { Set-Clipboard -Value "$($in.prompt)" }
    $opened = Open-Free $Sid
    $msg = "LimitPilot: лимит подписки Claude потрачен на $([int]$c.max)% (порог $([int]$c.cfg.five)%). Запрос НЕ отправлен в подписку. "
    if ($opened) { $msg += 'Открыл новое окно бесплатного режима с этим же разговором. ' }
    $msg += 'Запрос скопирован в буфер — вставь его там (Ctrl+V). Это окно можно закрыть. Изменить порог: /porog 80'
    Out-Json @{ decision = 'block'; reason = $msg }
    exit 0
  }
  'ratelimit' {
    if ($IsFree) { exit 0 }
    # short throttling is not the end of the quota: fresh data below 90% -> do not switch
    $c = Get-Claude
    if ($c.has -and $c.stale -lt 15 -and $c.max -lt 90) {
      Add-Content (Join-Path $DataDir 'limitpilot-transient.log') "$((Get-Date).ToString('s')) rate_limit at $([int]$c.max)% - treated as short throttling" -Encoding UTF8
      exit 0
    }
    @{ at = (Get-Date).ToString('o'); session = $Sid } | ConvertTo-Json | Set-Content $HitF -Encoding UTF8
    [void](Open-Free $Sid)
    exit 0
  }
  'manual' {
    if ($IsFree) { 'Этот разговор уже идёт в бесплатном режиме (OmniRoute). Сменить модель: /model.'; exit 0 }
    if (Open-Free $Sid) { 'Открыл новое окно бесплатного режима с этим разговором. Продолжай там, это окно можно закрыть.' }
    else { 'Окно бесплатного режима уже открывалось меньше 2 минут назад — проверь панель задач.' }
    exit 0
  }
  'threshold' {
    $a = 0; $b = 0
    if (-not [double]::TryParse($Arg1, [ref]$a) -or $a -lt 10 -or $a -gt 100) { $cur = Get-Config; "Сейчас порог: 5 ч — $([int]$cur.five)%, неделя — $([int]$cur.week)%. Пример: /porog 80  или  /porog 70 90"; exit 0 }
    if (-not [double]::TryParse($Arg2, [ref]$b) -or $b -lt 10 -or $b -gt 100) { $b = $a }
    @{ five = $a; week = $b } | ConvertTo-Json | Set-Content $CfgF -Encoding UTF8
    "Готово: переключение на бесплатный режим при $([int]$a)% (5 ч) и $([int]$b)% (неделя)."
    exit 0
  }
  'models' {
    $pv = Get-Providers 30
    if (-not $pv.ok) { 'OmniRoute не отвечает — запусти его (ярлык «Запустить OmniRoute»).'; exit 0 }
    if ($IsFree) { 'Выбор модели: открой /model — у каждой модели в описании её лимит. Или введи /model <id> из списка:' }
    else { 'Сейчас режим подписки Claude: эти модели доступны в бесплатном режиме (/besplatno), там их видно в /model.' }
    foreach ($r in (Picker-Rows $pv)) { "  $($r.label) — $($r.description)`n      /model $($r.model)" }
    exit 0
  }
  'picker' {
    $pv = Get-Providers 20
    for ($i = 0; $i -lt 3 -and -not $pv.ok; $i++) { Start-Sleep 3; $pv = Get-Providers 0 }   # OmniRoute may still be starting
    $o = @{}
    if ($pv.ok) { $o.modelPicker = @{ replaceBuiltInOptions = $true; options = @(Picker-Rows $pv) } }
    if ($Arg2 -eq 'nogodmode') { $o.enabledPlugins = @{ 'godmode@godmode' = $false } }
    [IO.File]::WriteAllText($Arg1, (Out-Json $o), (New-Object Text.UTF8Encoding $false))
    exit 0
  }
  'setup' {
    $root = ($Arg1 -replace '\\', '/').TrimEnd('/')
    $sf = Join-Path $env:USERPROFILE '.claude\settings.json'
    Copy-Item $sf "$sf.bak-limitpilot" -Force
    $s = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
    $sl = [pscustomobject]@{ type = 'command'; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$root/scripts/pilot.ps1`" statusline"; padding = 0 }
    if ($s.PSObject.Properties['statusLine']) { $s.statusLine = $sl } else { $s | Add-Member -NotePropertyName statusLine -NotePropertyValue $sl }
    [IO.File]::WriteAllText($sf, ($s | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding $false))
    "Строка состояния LimitPilot включена (копия старых настроек: settings.json.bak-limitpilot). Перезапусти Claude Code."
    exit 0
  }
  default {
    $c = Get-Claude
    if ($IsFree) { 'Режим: бесплатный (OmniRoute).' } else { 'Режим: подписка Claude.' }
    Claude-Lines $c
    if ($c.over) { "Порог достигнут — работай в бесплатном режиме: /besplatno" }
    $pv = Get-Providers 30
    if ($pv.ok) {
      'Бесплатные модели (OmniRoute):'
      foreach ($p in $pv.providers) { "  $($p.name): $($p.text)" }
      if ($pv.combo.Count) { "Очередь $Combo`: " + ((@($pv.combo) | % { Pretty $_ }) -join ' → ') }
    } else { 'OmniRoute не отвечает.' }
    "Порог переключения: /porog   Модели: /modeli"
    exit 0
  }
}
