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
| `MIHOMO_IMAGE` | нет | `docker.io/metacubex/mihomo:latest` | образ Mihomo (рекомендуется pin по digest) |
| `DOCKER_CLI_IMAGE` | нет | `docker.io/docker:27-cli` | базовый image для sync worker |
| `DOCKER_SOCKET_PROXY_IMAGE` | нет | `docker.io/tecnativa/docker-socket-proxy:0.3.0` | image socket-proxy для ограниченного Docker API |
| `SYNC_WORKER_IMAGE` | нет | `proxy-server/subscription-sync:local` | локальный тег собранного sync worker image |
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
| `WORKER_INTERRUPT_GRACE_SEC` | нет | `15` | grace period (сек) перед принудительным завершением текущего sync при остановке worker |
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
| `THROUGHPUT_ISOLATED` | нет | `true` | запускать speed-тесты в изолированном временном Mihomo runtime (без переключения боевого `PROXY`) |
| `THROUGHPUT_TOP_N` | нет | `10` | сколько ping-best прокси тестировать по скорости |
| `THROUGHPUT_TEST_URL` | нет | `https://speed.cloudflare.com/__down?bytes=20000000` | URL для speed test |
| `THROUGHPUT_TIMEOUT_SEC` | нет | `18` | timeout speed test на прокси |
| `THROUGHPUT_MIN_KBPS` | нет | `2200` | минимум скорости для попадания в ranked |
| `THROUGHPUT_SAMPLES` | нет | `5` | сколько speed-замеров делать на один прокси |
| `THROUGHPUT_REQUIRED_SUCCESSES` | нет | `4` | минимум успешных замеров (>= `THROUGHPUT_MIN_KBPS`) для включения прокси в ranked |
| `THROUGHPUT_BENCH_PROXY_PORT` | нет | `17890` | mixed-port изолированного bench-runtime для speed-тестов |
| `THROUGHPUT_BENCH_API_PORT` | нет | `19090` | controller API порт изолированного bench-runtime |
| `THROUGHPUT_BENCH_DOCKER_TIMEOUT_SEC` | нет | `20` | timeout docker-операций bench-runtime |

## Команды эксплуатации

```bash
./scripts/up.sh                 # рендер + запуск mihomo/socket-proxy + initial sync/ranking + запуск worker
./scripts/up.sh --allow-degraded-start  # запуск даже при ошибке initial sync/ranking
./scripts/down.sh               # остановка контейнеров
./scripts/logs.sh               # логи mihomo и sync worker
./scripts/status.sh             # краткий статус последнего sync
./scripts/sync-subscription.sh  # форсированный sync прямо сейчас
./scripts/test-proxy.sh         # smoke test выхода через прокси
./scripts/validate-config.sh    # полная проверка конфигурации
./scripts/cleanup-runtime.sh    # очистка stale runtime/sync.* и runtime/rank.*
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
- `runtime/metrics.json` — метрики worker (`consecutive_failures`, последние успех/ошибка)

## Troubleshooting

- `reason=all_sources_failed`: источники не скачались, проверь URL/доступ к GitHub.
- `reason=validation_failed_or_not_enough_proxies`: после санитизации не осталось валидного минимума.
- `reason=validation_timeout`: валидация прокси превысила `SANITIZE_VALIDATE_TIMEOUT_SEC`.
- `reason=validation_iteration_limit`: достигнут лимит `SANITIZE_VALIDATE_MAX_ITERATIONS` в цикле санитизации.
- `reason=no_quality_proxies`: quality filter отфильтровал все узлы, проверь `SANITIZE_EXCLUDE_HOST_PATTERNS` и качество источника.
- `throughput_reason=api_unreachable`: Mihomo controller недоступен на `API_BIND`.
- `throughput_reason=tools_missing`: в sync-окружении нет `curl/jq`.
- `throughput_reason=bench_runtime_unavailable`: не удалось поднять изолированный bench-runtime (docker/порт/контейнер).
- `throughput_reason=bench_unavailable`: (обычно при `THROUGHPUT_ISOLATED=false`) в текущем runtime-конфиге группа `PROXY` не содержит `BENCH`; перерендери конфиг (`./scripts/validate-config.sh` или `./scripts/up.sh`).
- `status=degraded_direct`: актуальный валидный provider недоступен, используется safe-degraded режим.
- Если initial sync падает при старте, используй `./scripts/up.sh --allow-degraded-start` (временный fallback-режим).
- Для удаления stale временных директорий выполни `./scripts/cleanup-runtime.sh`.
- `BENCH` — служебная группа для ranking; пользовательский трафик должен идти через `AUTO_FAILSAFE`/`AUTO_SPEED`.
- Если в логах много `dial PROXY ... context deadline exceeded`, проверь текущую группу через controller API (обязательно без прокси-переменных):
```bash
API_SECRET="$(awk -F= '/^API_SECRET=/{print $2}' .env)"
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
  curl --noproxy '*' --silent --show-error --fail \
  -H "Authorization: Bearer ${API_SECRET}" \
  http://127.0.0.1:9090/proxies/PROXY | jq -r '.now'
```
- Если вернулось `BENCH`, восстанови `AUTO_FAILSAFE` вручную:
```bash
API_SECRET="$(awk -F= '/^API_SECRET=/{print $2}' .env)"
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
  curl --noproxy '*' --silent --show-error --fail \
  -X PUT \
  -H "Authorization: Bearer ${API_SECRET}" \
  -H "Content-Type: application/json" \
  -d '{"name":"AUTO_FAILSAFE"}' \
  http://127.0.0.1:9090/proxies/PROXY
```
- Сериализация sync теперь через `flock`: lock-file `runtime/.sync.lock.flock`, метаданные владельца — `runtime/.sync.lock.meta`.
- Если в логах есть `flock is unavailable; using legacy PID lock`, lock-каталог fallback: `runtime/.sync.lock`.
- В `subscription-sync` используется BusyBox `ps`: для диагностики запускай `ps -o pid,ppid,etime,cmd` (без `-ax`).

## Архитектура

Подробный поток данных и логика переключений описаны в `docs/ARCHITECTURE.md`.
