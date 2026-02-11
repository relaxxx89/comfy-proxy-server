# Architecture Overview

## Компоненты

- `mihomo` (container): основной прокси-движок, слушает LAN-порт, держит proxy groups.
- `subscription-sync` (container worker): периодически запускает `scripts/sync-subscription.sh`.
- `scripts/*.sh` (host): orchestration, рендер конфига, валидация и ops-команды.
- `runtime/*`: рабочие артефакты (config/provider/status).

## Поток данных

1. `scripts/render-config.sh`
   - читает `.env`
   - рендерит `config/mihomo.template.yaml` -> `runtime/config.yaml`

2. `scripts/sync-subscription.sh`
   - загружает источники (`SUBSCRIPTION_URLS` или fallback `SUBSCRIPTION_URL`)
   - нормализует и объединяет URI-линии
   - фильтрует по протоколам (`SANITIZE_ALLOW_PROTOCOLS`)
   - удаляет страны из `EXCLUDE_COUNTRIES`
   - удаляет битые узлы через валидацию Mihomo
   - сохраняет валидный provider в `runtime/proxy_providers/main-subscription.yaml`
   - запускает `scripts/rank-throughput.sh` (если включено) и пишет ranked provider
   - обновляет `runtime/status.json`

3. `scripts/rank-throughput.sh`
   - берет кандидатов по ping history (`TOP_N`)
   - переключает `PROXY` на `BENCH`
   - меряет `speed_download` через локальный proxy port
   - сортирует по throughput и перестраивает порядок в
     `runtime/proxy_providers/main-subscription-ranked.yaml`

## Группы в Mihomo

- `AUTO_SPEED` (`url-test`): выбирает лучший узел по задержке.
- `AUTO_FAILSAFE` (`fallback`): быстрый failover при проблемах с текущим узлом.
- `BENCH` (`select`): служебная группа для throughput-тестов.
- `PROXY` (`select`): верхнеуровневая группа для клиентского трафика.

## Деградация и отказоустойчивость

- Если новый sync невалиден, текущий рабочий provider не затирается.
- При полном провале источников фиксируется `status=degraded_direct`.
- Failover в рантайме обрабатывается `AUTO_FAILSAFE`.

## Пути и переносимость

- Локальные пути в репозитории только относительные.
- Абсолютные пути вида `/root/.config/mihomo` используются только внутри контейнеров.
- Проверка на user-specific пути: `./scripts/check-portability.sh`.
