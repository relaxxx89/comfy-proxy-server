# Mihomo LAN Proxy Gateway

Локальный прокси-шлюз на базе Mihomo с авто-синхронизацией подписок, фильтрацией, автофейловером и ранжированием по скорости.

## Что умеет

- синхронизация подписок из GitHub/raw URL
- поддержка нескольких подписок (`SUBSCRIPTION_URLS`)
- строгая санитизация и валидация прокси-листа
- исключение стран (например, `EXCLUDE_COUNTRIES=RU`)
- авто-выбор по задержке (`AUTO_SPEED`, `url-test`)
- авто-переключение при падении (`AUTO_FAILSAFE`, `fallback`)
- ранжирование по throughput после успешного sync
- единая LAN-точка для клиентов (`http/socks5` на одном порту)

## Требования

- Linux хост
- Docker + Docker Compose plugin
- `curl` на хосте (для `scripts/test-proxy.sh`)
- `systemd` (опционально, только если нужен автозапуск как сервис)

## Быстрый старт

```bash
git clone https://github.com/relaxxx89/comfy-proxy-server
cd comfy-proxy-server
cp .env.example .env
```

1. Отредактируй `.env`.
2. Проверь конфиг:

```bash
./scripts/validate-config.sh
```

3. Запусти сервис:

```bash
./scripts/up.sh
```

4. Проверь статус:

```bash
./scripts/status.sh
```

## Настройка `.env`

| Переменная | Обязательна | Пример | Назначение |
|---|---|---|---|
| `SUBSCRIPTION_URLS` | нет | `https://.../a.txt,https://.../b.txt` | CSV список источников (предпочтительно) |
| `SUBSCRIPTION_URL` | да | `https://.../single.txt` | fallback-источник, если `SUBSCRIPTION_URLS` пуст |
| `LAN_BIND_IP` | да | `0.0.0.0` | bind адрес прокси на хосте |
| `PROXY_PORT` | да | `7890` | порт HTTP/SOCKS прокси |
| `PROXY_AUTH` | да | `user:pass` | авторизация на прокси |
| `API_BIND` | да | `127.0.0.1:9090` | bind address контроллера Mihomo |
| `API_SECRET` | да | `change_me` | секрет контроллера |
| `MIHOMO_LOG_LEVEL` | да | `info` | уровень логирования |
| `HEALTHCHECK_URL` | да | `https://www.gstatic.com/generate_204` | URL для health-check |
| `HEALTHCHECK_INTERVAL` | да | `180` | интервал health-check провайдеров |
| `HEALTHCHECK_TIMEOUT` | да | `5000` | timeout health-check (ms) |
| `URL_TEST_INTERVAL` | да | `180` | интервал `AUTO_SPEED` |
| `URL_TEST_TOLERANCE` | да | `50` | tolerance для `AUTO_SPEED` |
| `FALLBACK_INTERVAL` | да | `90` | интервал `AUTO_FAILSAFE` |
| `SANITIZE_INTERVAL` | нет | `300` | период sync worker (сек) |
| `MIN_VALID_PROXIES` | нет | `1` | минимум валидных прокси для принятия листа |
| `SANITIZE_ALLOW_PROTOCOLS` | нет | `vless,trojan,ss,vmess` | разрешённые протоколы |
| `EXCLUDE_COUNTRIES` | нет | `RU,BY` | исключаемые страны (ISO2) |
| `SANITIZE_LOG_JSON` | нет | `true` | печатать JSON статуса в лог sync |
| `SANITIZE_VALIDATE_TIMEOUT_SEC` | нет | `10` | timeout (сек) на один docker-шаг валидации провайдера |
| `SANITIZE_VALIDATE_MAX_ITERATIONS` | нет | `80` | максимум итераций удаления битых прокси в одном sync |
| `SANITIZE_EXCLUDE_HOST_PATTERNS` | нет | `boot-lee.ru,openproxylist.com` | blacklist паттернов host/URI на этапе quality filter |
| `SANITIZE_DROP_ANONYMOUS_FLAGGED` | нет | `true` | отбрасывать узлы с `🏳` и пустыми суффиксами (`vless-`, `ss-`, ...) |
| `SANITIZE_REQUIRE_TLS_HOST` | нет | `true` | требовать валидный host для `vless/vmess/trojan` |
| `THROUGHPUT_ENABLE` | нет | `true` | включить throughput ranking |
| `THROUGHPUT_TOP_N` | нет | `50` | сколько ping-best прокси тестировать по скорости |
| `THROUGHPUT_TEST_URL` | нет | `https://speed.cloudflare.com/__down?bytes=5000000` | URL для speed test |
| `THROUGHPUT_TIMEOUT_SEC` | нет | `12` | timeout speed test на прокси |
| `THROUGHPUT_MIN_KBPS` | нет | `50` | минимум скорости для попадания в ranked |

## Команды эксплуатации

```bash
./scripts/up.sh                 # рендер + sync + запуск контейнеров
./scripts/down.sh               # остановка контейнеров
./scripts/logs.sh               # логи mihomo и sync worker
./scripts/status.sh             # краткий статус последнего sync
./scripts/sync-subscription.sh  # форсированный sync прямо сейчас
./scripts/test-proxy.sh         # smoke test выхода через прокси
./scripts/validate-config.sh    # полная проверка конфигурации
./scripts/check-portability.sh  # проверка на user-specific absolute paths
```

## Подключение клиентов

Настрой клиентские устройства на:

- HTTP proxy: `http://<server-ip>:<PROXY_PORT>`
- SOCKS5 proxy: `<server-ip>:<PROXY_PORT>`
- auth: `PROXY_AUTH`

## Systemd автозапуск

Используй установщик, который сам подставит актуальный путь проекта:

```bash
./scripts/install-systemd.sh
```

Скрипт:

1. генерирует `/etc/systemd/system/mihomo-gateway.service` из `systemd/mihomo-gateway.service.template`
2. выполняет `systemctl daemon-reload`
3. включает и запускает `mihomo-gateway.service`

Проверка:

```bash
systemctl status mihomo-gateway.service
journalctl -u mihomo-gateway.service -n 100 --no-pager
```

## Где лежат артефакты runtime

- `runtime/config.yaml` — сгенерированный рабочий конфиг Mihomo
- `runtime/proxy_providers/main-subscription.yaml` — валидированный список после sync/sanitize
- `runtime/proxy_providers/main-subscription-ranked.yaml` — список после ранжирования throughput
- `runtime/status.json` — последний статус sync/валидации/ranking

## Troubleshooting

- `reason=all_sources_failed`: источники не скачались, проверь URL/доступ к GitHub.
- `reason=validation_failed_or_not_enough_proxies`: после санитизации не осталось валидного минимума.
- `reason=validation_timeout`: валидация прокси превысила `SANITIZE_VALIDATE_TIMEOUT_SEC`.
- `reason=validation_iteration_limit`: достигнут лимит `SANITIZE_VALIDATE_MAX_ITERATIONS` в цикле санитизации.
- `reason=no_quality_proxies`: quality filter отфильтровал все узлы, проверь `SANITIZE_EXCLUDE_HOST_PATTERNS` и качество источника.
- `throughput_reason=api_unreachable`: Mihomo controller недоступен на `API_BIND`.
- `throughput_reason=tools_missing`: в sync-окружении нет `curl/jq`.
- `status=degraded_direct`: актуальный валидный provider недоступен, используется safe-degraded режим.
- `BENCH` — служебная группа для ranking; пользовательский трафик должен идти через `AUTO_FAILSAFE`/`AUTO_SPEED`.
- При `Ctrl+C` в `./scripts/validate-config.sh` или `./scripts/up.sh` sync-lock чистится автоматически.
- Если lock был создан другим UID (например, root), очисти его тем же пользователем: `sudo rm -rf runtime/.sync.lock`.

## Архитектура

Подробный поток данных и логика переключений описаны в `docs/ARCHITECTURE.md`.
