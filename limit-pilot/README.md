# LimitPilot

Плагин для **Claude Code** (Windows), который показывает лимиты подписки Claude и бесплатных моделей прямо в Claude Code и сам переводит работу на бесплатные модели **[OmniRoute](https://github.com/diegosouzapw/OmniRoute)**, когда подписка заканчивается — продолжая **тот же разговор**.

## Возможности

**Лимиты в меню `/model`.** В бесплатном режиме меню `/model` показывает каждую модель очереди с её лимитом прямо в описании: «Grok · осталось 100% на неделю, сброс 29.11», «OpenRouter · осталось 30 из 50 на день», «Kimi · баланс 0$ — не ответит». Первой строкой — авто-очередь, которая сама берёт первую свободную модель.

**Прогноз расхода подписки Claude.** По истории замеров LimitPilot считает темп (% в час), время до порога и до 100%, и сравнивает с «нормой» — сколько должно быть потрачено к этому моменту окна, если тратить равномерно.

**Переключение по порогу.** Когда 5-часовое окно или неделя подписки потрачены на порог (по умолчанию 70%), запрос не уходит в подписку: он копируется в буфер обмена, и открывается окно бесплатного режима с этим же разговором (`--resume`).

**Перехват исчерпанного лимита.** Хук `StopFailure: rate_limit` открывает бесплатное окно сразу. Короткий «троттлинг» при свежих данных ниже 90% не считается концом лимита и переключения не вызывает.

**«Подписка снова доступна».** В бесплатном режиме LimitPilot сообщает, когда окно подписки обнулилось и можно вернуться.

## Команды

| Команда | Что делает |
|---|---|
| `/limity` | Лимиты подписки (с темпом и прогнозом) и всех бесплатных провайдеров, порядок очереди |
| `/modeli` | Бесплатные модели с лимитами и командой `/model <id>` для каждой |
| `/porog 80` / `/porog 70 90` | Порог переключения: один для обоих окон или отдельно для 5 ч и недели |
| `/besplatno` | Переключиться на бесплатный режим вручную |
| `/limit-pilot:nastroit` | Включить строку состояния LimitPilot (один раз после установки/обновления) |

## Установка

```
/plugin marketplace add silcway/claude-limit-switch
/plugin install limit-pilot@limit-pilot
/limit-pilot:nastroit
```

Перезапустите Claude Code. Для меню `/model` с лимитами запускайте бесплатный режим через ярлык из `extras/` (он собирает меню перед стартом и передаёт его через `--settings`).

## Что нужно рядом

1. **OmniRoute** с очередью (combo), по умолчанию `ochered`.
2. **Ярлыки** из папки `extras/`: `Claude-Free.cmd` (новый разговор) и `Claude-Continue-Free.cmd` (продолжить, принимает id сессии). Поправьте в них пути.

Лимиты подписки Claude передаёт сам Claude Code в строку состояния (`rate_limits`, только Pro/Max, после первого ответа в сессии) — LimitPilot сохраняет их и ведёт историю для прогноза. Токены входа плагин не читает.

## Настройка (переменные окружения)

| Переменная | По умолчанию |
|---|---|
| `LIMITPILOT_DATA_DIR` | `D:\clod\Programs\omniroute\data` |
| `LIMITPILOT_OMNIROUTE_URL` | `http://localhost:20128` |
| `LIMITPILOT_OMNIROUTE_DATA` | `D:\clod\Programs\omniroute\data` (папка данных OmniRoute) |
| `LIMITPILOT_COMBO` | `ochered` |
| `LIMITPILOT_FREE_CMD` | `D:\clod\Programs\omniroute\Claude-Continue-Free.cmd` |
| `LIMITPILOT_WORKDIR` | `D:\clod\work` |
| `LIMITPILOT_DRYRUN` | `1` — не открывать окна (для проверки) |

Порог хранится в `limitpilot.json` в папке данных и меняется командой `/porog`.

## Идеи взяты из

[ccburn](https://github.com/mscharley/ccburn) и [Claude Code Usage Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) — темп и прогноз; [claude-swap](https://github.com/realiti4/claude-swap) — отдельные пороги; [opencode-quota-failover](https://github.com/linuxdynasty/opencode-quota-failover) — отличать троттлинг от конца квоты; [claude-code-router](https://github.com/musistudio/claude-code-router) — смена модели через `/model`.

## Лицензия

MIT
