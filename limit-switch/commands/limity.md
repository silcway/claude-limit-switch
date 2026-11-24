---
description: Показать лимит подписки Claude и текущий режим (подписка или бесплатный)
allowed-tools: Bash(powershell:*)
---
Состояние лимитов:

!`powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/switch.ps1" show`

Покажи пользователю эти строки как есть, по-русски, без лишних слов.
