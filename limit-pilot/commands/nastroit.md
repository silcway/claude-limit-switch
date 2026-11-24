---
description: LimitPilot — включить строку состояния с лимитами Claude и прогнозом (нужно один раз после установки или обновления)
allowed-tools: Bash(powershell:*)
---
!`powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/pilot.ps1" setup "${CLAUDE_PLUGIN_ROOT}"`

Передай пользователю результат выше одной фразой по-русски.
