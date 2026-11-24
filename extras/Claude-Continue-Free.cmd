@echo off
rem LimitPilot: continue a conversation in the free OmniRoute queue.
rem %1 = session id (passed by LimitPilot) -> resume exactly that conversation; empty -> the last one in the work folder.
chcp 65001 >nul
title Claude Code - prodolzhit besplatno (LimitPilot)
set DATA_DIR=D:\clod\Programs\omniroute\data
set DISABLE_AUTOUPDATER=1
set PILOT=D:\clod\Programs\claude-plugins\limit-pilot\scripts\pilot.ps1
set PICKER=%DATA_DIR%\limitpilot-continue-settings.json
set PATH=D:\clod\Programs\claude-code;D:\clod\Programs\bun;D:\clod\Programs\omniroute;%PATH%

powershell -NoProfile -Command "if (-not (Get-NetTCPConnection -LocalPort 20128 -State Listen -ErrorAction SilentlyContinue)) { Start-Process 'D:\clod\Programs\omniroute\Start-OmniRoute.cmd' -WindowStyle Minimized; Write-Host 'Starting OmniRoute...'; for ($i=0; $i -lt 60; $i++) { Start-Sleep 2; if (Get-NetTCPConnection -LocalPort 20128 -State Listen -ErrorAction SilentlyContinue) { break } } }"

rem /model menu with limits; godmode's SessionStart hook hangs on resume, so it is off here
powershell -NoProfile -ExecutionPolicy Bypass -File "%PILOT%" picker "%PICKER%" nogodmode

cd /d D:\clod\work
if "%~1"=="" (
  call omniroute.cmd launch --token %OMNIROUTE_API_KEY% -- --continue --settings "%PICKER%" --model ochered
) else (
  call omniroute.cmd launch --token %OMNIROUTE_API_KEY% -- --resume %~1 --settings "%PICKER%" --model ochered
)
pause
