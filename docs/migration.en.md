# searfront Migration Guide

[日本語](migration.md)

This checklist migrates existing Rails apps or local AI agents from direct
SearXNG calls to searfront.

## Prerequisites

- The searfront web process is running.
- `searfront-worker` and `searfront-browser-worker` are running.
- Redis, SearXNG, Browser Search Worker, and Browserless are reachable from the same private network as searfront.
- If Exa fallback is used, `EXA_API_KEY` is configured as a secret.
- Clients receive only the searfront Bearer token. SearXNG is not exposed directly.

## Processes

In development, `bin/dev` loads `.env.development` and starts the required processes together.

```sh
bin/dev
```

`bin/dev` starts the web process, the normal worker, and the browser fallback worker.
In production or under a process manager, run them separately.

Web:

```sh
bundle exec puma -C config/puma.rb
```

Normal worker:

```sh
bundle exec sidekiq -C config/sidekiq.yml
```

Browser fallback worker:

```sh
bundle exec sidekiq -C config/sidekiq_browser.yml
```

Run the `browser_search` queue in a dedicated process with concurrency 1.

## Environment Variables

See `config/searfront.env.example` for a template.

Required:

- `SEARFRONT_API_TOKENS`
- `SEARXNG_BASE_URL`
- `BROWSER_SEARCH_WORKER_URL`
- `BROWSER_SEARCH_WORKER_TOKEN`
- `CACHE_REDIS_URL`
- `STATE_REDIS_URL`
- `SIDEKIQ_REDIS_URL`
- `RAILS_MASTER_KEY`

Optional:

- `EXA_SEARCH_ENABLED`
- `EXA_API_KEY`
- `EXA_DAILY_LIMIT`
- `EXA_SEARCH_TYPE`
- `EXA_USER_LOCATION`

In production, manage tokens and Redis URLs through a secret manager or
deployment secrets. Treat `EXA_API_KEY` the same way.

## Client Migration

1. Find existing SearXNG URLs in clients.
2. Replace direct SearXNG search calls with searfront `/v1/search`.
3. Add `Authorization: Bearer <token>`.
4. If the response is `202 Accepted`, poll `/v1/search_requests/{request_id}`.
5. Log `cache.status`, `sources`, and `warnings`.
6. Close any direct client-to-SearXNG network path.

Example:

```sh
curl -sS \
  -H "Authorization: Bearer $SEARFRONT_TOKEN" \
  "$SEARFRONT_BASE_URL/v1/search?q=llama.cpp%20Vulkan&limit=10"
```

## Post-Migration Checks

Check these immediately after migration:

- `/readyz` returns `ready`.
- `/metrics` includes `searfront_requests_total`.
- The second identical query returns `cache.status=fresh`.
- If SearXNG is down and stale data exists, searfront returns `cache.status=stale`.
- If SearXNG returns too few results and `EXA_API_KEY` is configured, Exa is tried before browser fallback.
- If results are still insufficient, the API returns `202 Accepted` and polling later returns completed results.
- `GET /v1/engines` shows CAPTCHA / 429 suspensions when detected.

Smoke script:

```sh
ruby script/smoke_search.rb
```

Required variables:

- `SEARFRONT_BASE_URL`
- `SEARFRONT_TOKEN`
- `SEARFRONT_QUERY`

## Rollback

If issues occur:

1. Temporarily point clients back to the old SearXNG URL.
2. Check searfront `/readyz`, Sidekiq queues, and Redis connectivity.
3. Check `GET /v1/engines` for excessive suspensions.
4. Fix the cause, then migrate low-frequency clients back to searfront first.

Direct SearXNG fallback should be temporary. Long-term operation should return
to searfront.
