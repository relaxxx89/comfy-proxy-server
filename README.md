# Mihomo LAN Proxy Gateway

Local proxy gateway with:
- GitHub subscription sync with strict sanitization
- multi-source subscriptions merge (best-effort)
- country exclusion filter (for example `RU`)
- automatic speed-based selection (`url-test`)
- throughput-based re-ranking after sync (`top-N` by ping then Mbps test)
- automatic failover (`fallback`)
- one stable LAN endpoint for all client devices
- degradation mode to `DIRECT` when subscription is broken (with explicit status)

## 1. Configure

```bash
cd /home/stepan/Documents/proxy-server
cp .env.example .env
```

Edit `.env`:
- `SUBSCRIPTION_URLS`: CSV list of GitHub/raw URLs (preferred)
- `SUBSCRIPTION_URL`: legacy single URL fallback when `SUBSCRIPTION_URLS` is empty
- `PROXY_AUTH`: proxy credentials (`username:password`)
- `LAN_BIND_IP`: use host LAN IP for tighter exposure, or `0.0.0.0`
- `API_SECRET`: controller API secret
- `SANITIZE_ALLOW_PROTOCOLS`: default `vless,trojan,ss,vmess`
- `EXCLUDE_COUNTRIES`: CSV ISO2 list to remove countries (example: `RU,BY`)
- `SANITIZE_INTERVAL`: periodic sync interval for worker container
- `THROUGHPUT_ENABLE`: enable/disable throughput ranking
- `THROUGHPUT_TOP_N`: how many ping-best proxies are throughput tested (default `50`)
- `THROUGHPUT_TEST_URL`: download URL used for speed test
- `THROUGHPUT_TIMEOUT_SEC`: per-proxy speed test timeout
- `THROUGHPUT_MIN_KBPS`: minimum speed to be considered ranked

## 2. Validate config

```bash
./scripts/validate-config.sh
```

This runs:
1. render `runtime/config.yaml`
2. sync and sanitize subscription into `runtime/proxy_providers/main-subscription.yaml`
3. test final Mihomo config with `mihomo -t`

## 3. Start

```bash
./scripts/up.sh
```

This starts two services:
- `mihomo`: LAN proxy gateway
- `subscription-sync`: background sync/cleanup worker

## 4. Client setup

Point devices to:
- HTTP proxy: `http://<server-lan-ip>:7890`
- SOCKS5 proxy: `<server-lan-ip>:7890`
- auth: value from `PROXY_AUTH`

## 5. Verify traffic goes through proxy

```bash
./scripts/test-proxy.sh
```

You should see external IP printed.

## 6. Operations

```bash
./scripts/status.sh           # last subscription sync status
./scripts/sync-subscription.sh # force sync now
./scripts/logs.sh             # follow logs for mihomo + subscription worker
./scripts/down.sh             # stop all services
```

## Optional: autostart via systemd

```bash
sudo cp systemd/mihomo-gateway.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mihomo-gateway.service
```

## Notes

- `runtime/config.yaml` is generated from `config/mihomo.template.yaml`.
- Sanitized provider is stored at `runtime/proxy_providers/main-subscription.yaml`.
- Ranked provider is stored at `runtime/proxy_providers/main-subscription-ranked.yaml`.
- Subscription refresh is controlled by `SANITIZE_INTERVAL`.
- If several sources are configured, sync is best-effort:
  failed sources are skipped, successful ones are merged.
- Throughput ranking runs after a successful sync (if enabled).
- Health checks and switching behavior are tuned by:
  `HEALTHCHECK_INTERVAL`, `HEALTHCHECK_TIMEOUT`,
  `URL_TEST_INTERVAL`, `URL_TEST_TOLERANCE`, `FALLBACK_INTERVAL`.
- If sync fails, previous provider is kept; if no valid provider exists, status is `degraded_direct`.
