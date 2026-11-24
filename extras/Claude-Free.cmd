@echo off
rem LimitPilot: Claude Code through the free OmniRoute queue, /model menu shows every model with its limit.
chcp 65001 >nul
title Claude Code - besplatno (LimitPilot)
set DATA_DIR=D:\clod\Programs\omniroute\data
set DISABLE_AUTOUPDATER=1
set PILOT=D:\clod\Programs\claude-plugins\limit-pilot\scripts\pilot.ps1
set PICKER=%DATA_DIR%\limitpilot-free-settings.json
set PATH=D:\clod\Programs\claude-code;D:\clod\Programs\bun;D:\clod\Programs\omniroute;%PATH%

rem --- start OmniRoute if it is not running ---
powershell -NoProfile -Command "if (-not (Get-NetTCPConnection -LocalPort 20128 -State Listen -ErrorAction SilentlyContinue)) { Start-Process 'D:\clod\Programs\omniroute\Start-OmniRoute.cmd' -WindowStyle Minimized; Write-Host 'Starting OmniRoute...'; for ($i=0; $i -lt 60; $i++) { Start-Sleep 2; if (Get-NetTCPConnection -LocalPort 20128 -State Listen -ErrorAction SilentlyContinue) { break } } }"

rem --- build the /model menu with current limits ---
powershell -NoProfile -ExecutionPolicy Bypass -File "%PILOT%" picker "%PICKER%"

cd /d D:\clod\work
call omniroute.cmd launch --token %OMNIROUTE_API_KEY% -- --settings "%PICKER%" --model ochered
pause
