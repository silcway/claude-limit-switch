---
description: LimitPilot — порог переключения на бесплатные модели, % лимита подписки (пример — /porog 80 или /porog 70 90)
argument-hint: "[порог 5ч] [порог недели]"
allowed-tools: Bash(powershell:*)
---
!`powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/pilot.ps1" threshold $ARGUMENTS`

Передай пользователю результат выше одной фразой по-русски.
