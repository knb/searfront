# searfront

[日本語](README.md)

This repository is built with ChatGPT + Codex.

searfront is a standalone search gateway placed in front of SearXNG.
It normalizes search requests, reuses identical searches through Redis cache,
and collapses concurrent cache misses with single-flight locking. The normal
path is SearXNG. When results are insufficient or upstream access is blocked,
searfront tries Exa first, then falls back to the Sidekiq-managed Browser Search
Worker / Browserless path only when needed.

searfront is not intended to bypass CAPTCHA or access restrictions. Its goal is
to reduce outbound search traffic and make repeated searches from Rails apps,
local AI agents, and test clients more stable.

This repository is an implementation skeleton based on the Japanese design
documents in `docs/`. The English documents intentionally cover usage,
operation, and progress only.

## Goals

- Reuse identical search results without outbound calls while the fresh TTL is valid.
- Keep SearXNG as the fast default search path.
- Return stale results explicitly when fresh results are unavailable.
- Use Exa before browser fallback, capped at 500 requests per UTC day by default.
- Serialize browser searches through Sidekiq and share the minimum interval through Redis.
- Never store CAPTCHA, 429, or Access Denied pages as successful search results.
- Return a consistent JSON API with `cache.status`, `sources`, `generated_at`, and `warnings`.

## Architecture

The expected process layout is:

- `searfront-web`: Rails API-only HTTP API.
- `searfront-worker`: Sidekiq worker for `cache_refresh` and `maintenance`.
- `searfront-browser-worker`: Sidekiq worker dedicated to browser fallback. Initial concurrency is 1.
- `Redis`: search cache, locks, request status, engine state, and Sidekiq.
- `SearXNG`: normal synchronous search path.
- `Exa`: optional API fallback before browser search.
- `Browser Search Worker`: Node.js/TypeScript Google search adapter.
- `Browserless`: self-hosted headless browser backend used by the Browser Search Worker.

Only the searfront HTTP API should be exposed. Redis, SearXNG, Browser Search
Worker, and Browserless should stay inside the private network.

## API

The API base path is `/v1`.

### `GET /v1/search`

Accepts a search query and uses cache, SearXNG, Exa, and browser fallback in
that order. If no usable result is available yet, it returns `202 Accepted`
with a `request_id`.

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `q` | Yes | | Search query. 1 to 500 characters. |
| `language` | No | `ja-JP` | Search language / locale. |
| `limit` | No | `10` | Number of results. 1 to 20. |
| `categories` | No | `general` | SearXNG category. |
| `time_range` | No | | `day`, `week`, `month`, or `year`. |
| `mode` | No | `auto` | `auto`, `cache`, `searxng`, or `browser`. `browser` requires admin role. |
| `refresh` | No | `false` | Ignore fresh cache while keeping rate limit and single-flight behavior. |
| `wait_seconds` | No | `0` | Seconds to wait for a browser job. 0 to 30. |

```sh
curl -H "Authorization: Bearer $SEARFRONT_TOKEN" \
  "http://localhost:3000/v1/search?q=llama.cpp%20Vulkan&limit=10"
```

### `GET /v1/search_requests/{request_id}`

Polls asynchronous browser fallback status.

- `202`: Still processing.
- `200`: Completed. Returns the same response shape as `GET /v1/search`.
- `502` or `503`: Upstream search or required dependency failed.
- `404`: Unknown or expired `request_id`.

### Diagnostic APIs

- `GET /healthz`: Rails process health.
- `GET /readyz`: Redis, SearXNG, and Sidekiq enqueue readiness.
- `GET /v1/engines`: Per-engine `healthy` / `suspended` state.
- `POST /v1/engines/{name}/resume`: Manually resume a suspended engine.
- `DELETE /v1/cache`: Conditional cache deletion for admin use.
- `GET /metrics`: Prometheus-compatible metrics.

Rails' generated `/up` health route is also kept.

### Browser Search Worker API

This internal API is called by Rails over the private network and should not be
publicly exposed.

- `GET /health`: Worker health check, including Browserless connectivity.
- `POST /v1/search/google`: Fetches and normalizes the first page of Google search results.

Manual check:

```sh
curl -X POST http://localhost:3000/v1/search/google \
  -H "Authorization: Bearer $BROWSER_WORKER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "llama.cpp Vulkan",
    "language": "ja",
    "country": "JP",
    "limit": 10
  }'
```

When CAPTCHA, consent pages, automated-query blocks, or rate limits are
detected, the worker does not bypass them or auto-consent. It returns a
machine-readable blocked response with `error.code`.

## Response Examples

Completed searches include result data plus cache state, sources, warnings, and timing.

```json
{
  "request_id": "01J...",
  "status": "completed",
  "query": "llama.cpp Vulkan",
  "normalized_query": "llama.cpp Vulkan",
  "cache": {
    "status": "fresh",
    "age_seconds": 82,
    "generated_at": "2026-07-15T00:10:00Z"
  },
  "sources": ["searxng"],
  "results": [
    {
      "title": "llama.cpp",
      "url": "https://example.org/llama.cpp",
      "canonical_url": "https://example.org/llama.cpp",
      "snippet": "...",
      "engines": ["google"],
      "rank": 1,
      "published_at": null
    }
  ],
  "warnings": [],
  "timing_ms": {
    "total": 34,
    "cache": 3
  }
}
```

When no usable result is available yet:

```json
{
  "request_id": "01J...",
  "status": "pending",
  "poll_after_seconds": 3,
  "expires_at": "2026-07-15T00:12:00Z",
  "warnings": ["browser_fallback_queued"]
}
```

## Configuration

Main environment variables:

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `SEARFRONT_API_TOKENS` | Yes | | Token id, secret, and role. A secret manager is recommended. |
| `SEARXNG_BASE_URL` | Yes | | Example: `http://searxng:8080`. |
| `EXA_SEARCH_ENABLED` | No | `true` | Enables Exa search. No call is made unless `EXA_API_KEY` is set. |
| `EXA_API_KEY` | No | | Enables Exa fallback before browser fallback. |
| `EXA_BASE_URL` | No | `https://api.exa.ai/search` | Exa Search API endpoint. |
| `EXA_DAILY_LIMIT` | No | `500` | Daily Exa request cap, enforced per UTC day in Redis. |
| `EXA_SEARCH_TYPE` | No | `auto` | Exa Search API search type. |
| `EXA_USER_LOCATION` | No | `JP` | Country code passed to Exa. |
| `BROWSER_SEARCH_WORKER_URL` | Yes | | Example: `http://browser-search-worker:3000`. |
| `BROWSER_SEARCH_WORKER_TOKEN` | Yes | | Internal Bearer token for Rails-to-worker calls. |
| `BROWSER_SEARCH_COUNTRY` | No | `JP` | Search country passed to the Browser Search Worker. |
| `CACHE_REDIS_URL` | Yes | | Redis for search result cache. |
| `STATE_REDIS_URL` | Yes | | Redis for locks, engine state, and request status. |
| `SIDEKIQ_REDIS_URL` | Yes | | Redis for Sidekiq. |
| `SEARCH_RESULT_TTL_SECONDS` | No | `1800` | Fresh result TTL. |
| `SEARCH_STALE_TTL_SECONDS` | No | `43200` | Stale result TTL. |
| `BROWSER_MIN_INTERVAL_SECONDS` | No | `15` | Minimum interval between browser searches. |
| `BROWSER_JITTER_SECONDS` | No | `5` | Additional browser search jitter. |
| `CAPTCHA_SUSPEND_SECONDS` | No | `86400` | Engine suspension duration after CAPTCHA detection. |
| `RATE_LIMIT_SUSPEND_SECONDS` | No | `7200` | Engine suspension duration after 429 detection. |
| `LOG_QUERY_TEXT` | No | `false` | Whether to include raw query text in logs. |
| `SEARFRONT_RATE_LIMIT_PER_MINUTE` | No | `60` | Rate limit per Bearer token or source IP. |

Main Browser Search Worker variables:

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `BROWSER_WORKER_TOKEN` | Production | | Bearer token for the worker API. |
| `BROWSERLESS_WS_ENDPOINT` | Yes | `ws://browserless:3000/chromium` | Browserless WebSocket endpoint. |
| `BROWSERLESS_TOKEN` | No | | Browserless token. |
| `GOOGLE_MIN_INTERVAL_MS` | No | `15000` | Minimum interval between Google searches inside the worker. |
| `GOOGLE_INTERVAL_JITTER_MS` | No | `5000` | Additional worker-side jitter. |
| `GOOGLE_NAVIGATION_TIMEOUT_MS` | No | `30000` | Google page navigation timeout. |
| `GOOGLE_RESULT_TIMEOUT_MS` | No | `10000` | Search result DOM wait timeout. |
| `DEBUG_ARTIFACTS_ENABLED` | No | `false` | Enables debug artifact capture on failures. |
| `DEBUG_ARTIFACTS_DIR` | No | `./debug` | Artifact output directory. |

## Development

Prerequisites:

- Ruby version from `.ruby-version`.
- Bundler.
- Redis.
- SearXNG.
- Optional: Exa Search API key.
- Browser Search Worker and Browserless.

Install dependencies:

```sh
bundle install
```

In development, create `.env.development` to let `bin/dev` load environment
variables at startup. The file is ignored by Git. See `config/searfront.env.example`
for a template.

Start the web server and workers together:

```sh
bin/dev
```

`bin/dev` starts:

- `./bin/rails server`
- `bundle exec sidekiq -C config/sidekiq.yml`
- `bundle exec sidekiq -C config/sidekiq_browser.yml`

Start Browser Search Worker and Browserless with containers:

```sh
BROWSER_WORKER_TOKEN=change-me \
BROWSERLESS_TOKEN=change-me-browserless \
docker compose up --build browserless browser-search-worker
```

`compose.yaml` defines only Browserless and Browser Search Worker. Start Rails
API, Redis, and SearXNG according to your local or production environment.
Browserless and Browser Search Worker are not exposed to the host by default.

If Docker bridge DNS cannot resolve `registry.npmjs.org`, `compose.yaml` builds
the worker with host networking. For direct builds in the same environment, use:

```sh
docker build --network host ./browser-search-worker
```

Develop the Browser Search Worker alone:

```sh
cd browser-search-worker
npm install
npm run dev
```

Run Rails tests:

```sh
bin/rails test
```

Run Browser Search Worker checks:

```sh
cd browser-search-worker
npm test
npm run build
npm run lint
```

Run local CI-equivalent checks:

```sh
bin/ci
```

See `docs/migration.en.md` for migration and operational checks.

This Rails app is API-only and has no Active Record database in the initial
configuration, so database setup is not required.

## Implementation Phases

1. Foundation: authentication, healthz, readyz, Redis connection, structured logging.
2. SearXNG + cache: query normalization, cache key, fresh/stale, single-flight, result merge.
3. Sidekiq fallback: request status, `BrowserSearchJob`, Browser Search Worker API, interval control.
4. Operations: metrics, engine management API, rate limit, failure tests.
5. Migration: point existing Rails apps and local AI agents to searfront.

## Security

- Use Bearer token or reverse-proxy authentication even on LAN.
- Do not expose Redis, SearXNG, Browser Search Worker, or Browserless publicly.
- Do not implement CAPTCHA solving or bot evasion.
- Browser Search Worker must not use stealth plugins, proxy rotation, Google login, or CAPTCHA solvers.
- Raw query text is not logged by default.
- Debug artifacts are disabled by default. When enabled, `metadata.json` stores only the SHA-256 query digest, not raw query text.
- Browser fallback is a low-frequency last resort and must respect search engine terms and access limits.

## License

searfront is released under the MIT License. See `LICENSE`.
