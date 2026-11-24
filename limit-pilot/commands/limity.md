---
description: LimitPilot — лимиты подписки Claude (с прогнозом расхода) и всех бесплатных моделей
allowed-tools: Bash(powershell:*)
---
Состояние лимитов:

!`powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/pilot.ps1" show`

Покажи пользователю эти строки по-русски, сохранив цифры, без лишних слов. Можно оформить списком.
