# searfront Progress

[日本語](progress.md)

Last updated: 2026-07-15

This document records implementation progress. Japanese design documents remain
the canonical design references; this English file summarizes current status and
operational progress.

## Current Status

Phase 5 migration preparation is implemented.

Implemented:

- Rails API-only scaffold.
- MIT license and README.
- Agent implementation guide in `AGENTS.md`.
- Search gateway gems: `redis`, `sidekiq`, `faraday`, `faraday-retry`,
  `rack-attack`, `prometheus-client`, and `webmock`.
- `/healthz` process health endpoint.
- `/readyz` dependency readiness endpoint.
- Bearer token authentication.
- Redis connection registry.
- Sidekiq Redis initializer.
- Unified error responses with request ids.
- Structured request logs without raw query text.
- Phase 1 controller / service tests.
- `/v1/search` endpoint.
- Query normalization.
- Canonical cache-key payload and digest.
- Redis result cache.
- Fresh / stale responses.
- Redis `SET NX PX` single-flight lock.
- SearXNG JSON client.
- URL canonicalization.
- Deterministic result merge.
- Phase 2 controller / service tests.
- `GET /v1/search_requests/{request_id}` polling endpoint.
- Request status Redis payload.
- `BrowserSearchJob`.
- Browser Worker client.
- `202 Accepted` response for insufficient results with no stale data.
- Minimum interval control for browser fallback.
- Engine suspension after CAPTCHA / 429 diagnostics.
- Phase 3 controller / job tests.
- `/metrics` Prometheus text endpoint.
- `GET /v1/engines` engine state list.
- `POST /v1/engines/{name}/resume` suspension reset.
- `DELETE /v1/cache` conditional cache deletion.
- Rack::Attack rate limiting by token / IP.
- Phase 4 controller / rate limit tests.
- Production Active Job adapter configured to Sidekiq.
- Sidekiq queue configuration for normal and browser workers.
- Kamal process examples for web, worker, and browser worker.
- Traceable environment variable sample in `config/searfront.env.example`.
- Client migration guide in `docs/migration.md` and `docs/migration.en.md`.
- Smoke script for real environment checks.
- `bin/dev` loads `.env.development` and starts web / worker / browser worker.
- Browser Search Worker Phase 1 foundation.
- Fastify / TypeScript / Vitest / ESLint setup under `browser-search-worker`.
- Browser Search Worker `/health` endpoint and Bearer authentication components.
- Browserless connectivity check and Docker / Compose setup.
- Browser Search Worker Phase 2 Google parser.
- Google search result fixture parser.
- CAPTCHA / consent page / automated query detectors.
- Google redirect URL normalization, internal URL exclusion, duplicate URL exclusion.
- Browser Search Worker Phase 3 Google Search API.
- Browserless connection, Google search navigation, image blocking, DOM wait, parser integration.
- Worker API validation, Bearer authentication, SearchError-to-HTTP conversion.
- Rails Browser Worker client updated to `/v1/search/google`.
- Admin-only `mode=browser`, which queues `BrowserSearchJob` without SearXNG.
- Browser engine suspension guards before queuing and executing `BrowserSearchJob`.
- Browser Search Worker debug artifact capture.
- Root README updates for Browser Search Worker / Browserless startup, settings, manual search, and debug artifacts.
- Exa search before browser fallback, capped in Redis at 500 requests per UTC day by default.

## Phase Progress

| Phase | Scope | Status |
| --- | --- | --- |
| Phase 1 | Rails API foundation, authentication, healthz, Redis connection, structured logging | Implemented |
| Phase 2 | SearXNG + cache, query normalization, cache key, fresh/stale, single-flight, result merge | Implemented |
| Phase 3 | Sidekiq fallback, request status, BrowserSearchJob, Browser Worker API, interval / circuit breaker | Implemented |
| Phase 4 | Metrics, engine management API, Rack::Attack, alerts, failure tests | Implemented |
| Phase 5 | Migrate existing Rails apps / AI agents to searfront | Prepared |
| Browser Worker Phase 1 | Worker foundation, health, authentication, Browserless connectivity, Docker | Implemented |
| Browser Worker Phase 2 | Google parser, page detector, fixture tests | Implemented |
| Browser Worker Phase 3 | Google Search API, Browserless execution, error responses | Implemented |
| Browser Worker Phase 4 | Rails client contract update, `mode=browser` | Implemented |
| Browser Worker Phase 5 | Rails circuit breaker guard | Implemented |
| Browser Worker Phase 6 | Debug artifact capture | Implemented |
| Browser Worker Phase 7 | README update | Implemented |
| Exa Phase 1 | Exa fallback and daily quota | Implemented |

## Phase 1 Notes

### Endpoints

- `GET /healthz`
  - No authentication.
  - Verifies only that the Rails process can respond.
  - Does not check dependencies such as Redis or SearXNG.

- `GET /readyz`
  - Requires Bearer token.
  - Pings Redis for `CACHE_REDIS_URL`, `STATE_REDIS_URL`, and `SIDEKIQ_REDIS_URL`.
  - Sends HTTP GET to `SEARXNG_BASE_URL`; 2xx / 3xx is considered ready.
  - Returns `200` when all checks are `ok`, otherwise `503`.

### Environment

- `SEARFRONT_API_TOKENS`
  - Format: `id:secret:role,id2:secret2:role2`
  - Role defaults to `user`.

- `CACHE_REDIS_URL`
  - Redis for search result cache.

- `STATE_REDIS_URL`
  - Redis for locks, engine state, and request status.

- `SIDEKIQ_REDIS_URL`
  - Redis for Sidekiq.

- `SEARXNG_BASE_URL`
  - SearXNG base URL checked by readiness.

### Logging

Request logs are emitted as JSON strings through `Rails.logger.info`.

Fields:

- `event`
- `request_id`
- `method`
- `path`
- `controller`
- `action`
- `status`
- `duration_ms`
- `query_digest`
- `query_length`

Raw query text is not logged.

## Verification

After Phase 5 implementation, this command passed:

```sh
bin/ci
```

Verified:

- RuboCop: no offenses.
- bundler-audit: no vulnerabilities.
- Brakeman: no warnings.
- Rails test: 43 tests, 145 assertions, 0 failures, 0 errors.
- Browser Search Worker: 20 tests, 0 failures.

## Next Work

Remaining work is real-environment migration.

- Point existing Rails apps and local AI agents to searfront.
- Stop direct SearXNG calls.
- Measure cache hit rate, Exa fallback count, CAPTCHA / 429 count, and browser fallback count.
- Configure production Redis / SearXNG / Exa API key / Browser Search Worker / Browserless URLs and tokens.
- Verify that internal services are not exposed through Kamal / Docker networking.
