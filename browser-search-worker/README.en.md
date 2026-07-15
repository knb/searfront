# searfront Browser Search Worker

[日本語](README.md)

Internal worker that fetches the first page of Google search results through
Browserless Chromium.

Up to Phase 3, this worker implements the foundation for Google search through
Browserless from an internal API.

- Fastify server
- `GET /health`
- Bearer token authentication components
- Browserless connectivity check
- `POST /v1/search/google`
- Google search URL generation
- CAPTCHA / consent page / rate limit detection
- Google search result parser
- Dockerfile
- TypeScript / Vitest / ESLint setup

The worker does not implement CAPTCHA bypass, stealth plugins, proxy rotation,
or Google login.

## Development

```sh
npm install
npm run dev
```

## Tests

```sh
npm test
npm run build
npm run lint
```

## Environment Variables

See `.env.example`. `BROWSER_WORKER_TOKEN` is required in production.

For Browserless v2, use `BROWSERLESS_WS_ENDPOINT=ws://browserless:3000/chromium`.
The token from `BROWSERLESS_TOKEN` is appended as a query parameter.

When `DEBUG_ARTIFACTS_ENABLED=true`, the worker writes `metadata.json`,
`page.html`, and `screenshot.png` under `DEBUG_ARTIFACTS_DIR` for CAPTCHA,
consent pages, rate limits, zero results, DOM parse failures, and unexpected
exceptions. `metadata.json` stores only the SHA-256 query digest, not raw query text.

## Health

```sh
curl http://localhost:3000/health
```

When Browserless is reachable:

```json
{
  "status": "ok",
  "browserless": "reachable"
}
```

When Browserless is unreachable, the endpoint returns `503` with `degraded`.

## Google Search

```sh
curl -X POST http://localhost:3000/v1/search/google \
  -H "Authorization: Bearer $BROWSER_WORKER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query":"llama.cpp Vulkan","language":"ja","country":"JP","limit":10}'
```

When CAPTCHA, consent pages, or rate limits are detected, the worker does not
bypass CAPTCHA or auto-consent. It returns a machine-readable error instead.
