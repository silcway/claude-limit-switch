# claude-limit-switch

Плагин для **Claude Code** (Windows): когда лимит подписки Claude потрачен на **70%** или исчерпан полностью, работа переходит в бесплатную очередь **[OmniRoute](https://github.com/diegosouzapw/OmniRoute)**, продолжая **тот же разговор**.

## Что делает

| Ситуация | Что происходит |
|---|---|
| Потрачено 70%+ (окно 5 ч или неделя) | Запрос **не** уходит в подписку: копируется в буфер обмена, открывается новое окно бесплатного режима с этим же разговором (`--resume <id сессии>`) |
| Лимит исчерпан (ошибка API `rate_limit`) | Хук `StopFailure` сразу открывает бесплатное окно с этим разговором и запоминает это на 60 минут |
| Новая сессия по подписке при 70%+ | Предупреждение при старте |
| `/besplatno` | Переключиться вручную |
| `/limity` | Показать лимиты и текущий режим |

В бесплатном режиме (сессия уже идёт через OmniRoute) плагин ничего не делает.

## Установка

```
/plugin marketplace add silcway/claude-limit-switch
/plugin install limit-switch@claude-limit-switch
```

Затем перезапустите Claude Code.

## Что нужно рядом

1. **OmniRoute** с очередью (combo) бесплатных провайдеров.
2. **Строка состояния**, которая сохраняет `rate_limits` из stdin Claude Code в `claude-limits.json`:
   ```json
   { "saved": 1764000000, "five_hour": { "used_percentage": 35, "resets_at": 1764007200 },
     "seven_day": { "used_percentage": 60, "resets_at": 1764300000 } }
   ```
   Claude Code передаёт `rate_limits` в строку состояния только подписчикам Pro/Max после первого ответа в сессии.
3. **Скрипт запуска бесплатного режима** (`.cmd`), который принимает id сессии первым аргументом и запускает
   `omniroute launch ... -- --resume <id> --model <очередь>`.

## Настройка (переменные окружения)

| Переменная | По умолчанию |
|---|---|
| `LIMIT_SWITCH_THRESHOLD` | `70` |
| `LIMIT_SWITCH_DATA_DIR` | `D:\clod\Programs\omniroute\data` |
| `LIMIT_SWITCH_FREE_CMD` | `D:\clod\Programs\omniroute\Claude-Continue-Free.cmd` |
| `LIMIT_SWITCH_WORKDIR` | `D:\clod\work` |
| `LIMIT_SWITCH_FREE_PORT` | `20128` |
| `LIMIT_SWITCH_DRYRUN` | `1` — не открывать окна (для проверки) |

## Файлы

- `limit-switch/hooks/hooks.json` — когда Claude Code вызывает плагин (`SessionStart`, `UserPromptSubmit`, `StopFailure: rate_limit`)
- `limit-switch/scripts/switch.ps1` — вся логика
- `limit-switch/commands/` — команды `/besplatno` и `/limity`

## Лицензия

MIT
