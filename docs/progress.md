# searfront 進捗

最終更新: 2026-07-15

このドキュメントは `docs/searfront_design_v0.1.md` の実装進捗を記録する。
設計判断の正本は設計書、実装時の作業指針は `AGENTS.md` とする。

## 現在の状態

Phase 5: 移行準備を実装済み。

実装済み:

- Rails API-only scaffold。
- MIT license と README。
- agent 向け実装ガイド `AGENTS.md`。
- 検索ゲートウェイ用 gem: `redis`、`sidekiq`、`faraday`、`faraday-retry`、
  `rack-attack`、`prometheus-client`、`webmock`。
- `/healthz` process health endpoint。
- `/readyz` dependency readiness endpoint。
- Bearer token 認証。
- Redis 接続 registry。
- Sidekiq Redis 設定 initializer。
- request id 付きの統一 error response。
- raw query text を出さない構造化 request log。
- Phase 1 の controller / service test。
- `/v1/search` search endpoint。
- query 正規化。
- cache key canonical payload と digest。
- Redis result cache。
- fresh / stale response。
- Redis `SET NX PX` による single-flight lock。
- SearXNG JSON client。
- URL canonicalization。
- deterministic な result merge。
- Phase 2 の controller / service test。
- `GET /v1/search_requests/{request_id}` polling endpoint。
- request status Redis payload。
- `BrowserSearchJob`。
- Browser Worker client。
- 結果不足 + stale なしの `202 Accepted` response。
- browser fallback の最低実行間隔制御。
- CAPTCHA / 429 診断時の engine suspension。
- Phase 3 の controller / job test。
- `/metrics` Prometheus text endpoint。
- `GET /v1/engines` engine 状態一覧。
- `POST /v1/engines/{name}/resume` engine 停止解除。
- `DELETE /v1/cache` 条件付き cache 削除。
- Rack::Attack による token / IP 単位の rate limit。
- Phase 4 の controller / rate limit test。
- production Active Job adapter を Sidekiq に設定。
- Sidekiq 通常 worker / browser worker の queue 設定。
- Kamal の web / worker / browser worker process 設定例。
- 追跡可能な環境変数サンプル `config/searfront.env.example`。
- クライアント移行手順 `docs/migration.md`。
- searfront 実環境確認用 smoke script。
- `bin/dev` で `.env.development` を読み込み、Web / worker / browser worker を同時起動。
- Browser Search Worker Phase 1 基盤。
- `browser-search-worker` の Fastify / TypeScript / Vitest / ESLint 設定。
- Browser Search Worker `/health` endpoint と Bearer token 認証部品。
- Browserless 接続確認と Docker / Compose 設定。
- Browser Search Worker Phase 2 Google Parser。
- Google検索結果 fixture parser。
- CAPTCHA / 同意画面 / automated queries detector。
- Google redirect URL正規化、内部URL除外、重複URL除外。
- Browser Search Worker Phase 3 Google Search API。
- Browserless接続、Google検索URL生成、画像ブロック、DOM待機、parser連携。
- Worker APIの入力検証、Bearer認証、SearchError HTTP変換。
- Rails Browser Worker clientを `/v1/search/google` 契約へ更新。
- `mode=browser` を管理者限定で追加し、SearXNGを使わずBrowserSearchJobを投入。
- Browser engine suspended stateを検索投入前・BrowserSearchJob実行前に確認。
- Browser Search Workerのデバッグ成果物保存を追加。
- ルートREADMEにBrowser Search Worker / Browserlessの起動、設定、手動検索、debug artifactを追記。
- Browser fallback前段にExa検索を追加し、Redisで1日500件の上限を制御。

## Phase 進捗

| Phase | 内容 | 状態 |
| --- | --- | --- |
| Phase 1 | Rails API 基盤、認証、healthz、Redis 接続、構造化ログ | 実装済み |
| Phase 2 | SearXNG + cache、query 正規化、cache key、fresh/stale、single-flight、結果統合 | 実装済み |
| Phase 3 | Sidekiq fallback、request status、BrowserSearchJob、Browser Worker API、interval / circuit breaker | 実装済み |
| Phase 4 | metrics、engine 管理 API、Rack::Attack、alert、障害試験 | 実装済み |
| Phase 5 | 既存 Rails / AI Agent の検索先を searfront へ移行 | 準備済み |
| Browser Worker Phase 1 | Worker基盤、health、認証、Browserless接続確認、Docker | 実装済み |
| Browser Worker Phase 2 | Google Parser、page detector、fixture test | 実装済み |
| Browser Worker Phase 3 | Google Search API、Browserless実行、エラー応答 | 実装済み |
| Browser Worker Phase 4 | Rails client契約更新、mode=browser | 実装済み |
| Browser Worker Phase 5 | Rails circuit breaker guard | 実装済み |
| Browser Worker Phase 6 | Debug artifact保存 | 実装済み |
| Browser Worker Phase 7 | README更新 | 実装済み |
| Exa Phase 1 | Exa fallback、日次quota | 実装済み |

## Phase 1 実装メモ

### Endpoints

- `GET /healthz`
  - 認証なし。
  - Rails process が応答可能であることだけを返す。
  - Redis や SearXNG などの依存サービスは確認しない。

- `GET /readyz`
  - Bearer token 必須。
  - `CACHE_REDIS_URL`、`STATE_REDIS_URL`、`SIDEKIQ_REDIS_URL` の Redis ping を確認する。
  - `SEARXNG_BASE_URL` に HTTP GET し、2xx / 3xx を ready とみなす。
  - 全 check が `ok` の場合は `200`、いずれかが失敗した場合は `503`。

### Environment

- `SEARFRONT_API_TOKENS`
  - 形式: `id:secret:role,id2:secret2:role2`
  - role 未指定時は `user`。

- `CACHE_REDIS_URL`
  - 検索結果 cache 用 Redis。

- `STATE_REDIS_URL`
  - lock、engine state、request status 用 Redis。

- `SIDEKIQ_REDIS_URL`
  - Sidekiq 用 Redis。

- `SEARXNG_BASE_URL`
  - readiness で確認する SearXNG base URL。

### Logging

request log は JSON 文字列として `Rails.logger.info` に出す。

含める項目:

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

raw query text は記録しない。

## 検証

Phase 5 実装後に次を実行し、成功を確認済み。

```sh
bin/ci
```

確認済み項目:

- RuboCop: no offenses。
- bundler-audit: no vulnerabilities。
- Brakeman: no warnings。
- Rails test: 43 tests, 145 assertions, 0 failures, 0 errors。
- Browser Search Worker: 20 tests, 0 failures。

## 次の作業

残作業は実環境での移行作業。

- 既存 Rails アプリやローカル AI Agent の検索先を searfront に変更する。
- 直接 SearXNG 呼び出しを停止する。
- cache hit 率、CAPTCHA / 429 回数、browser fallback 件数を計測する。
- 実運用環境の Redis / SearXNG / Browser Search Worker / Browserless URL と token を設定する。
- Kamal / Docker network 上で内部サービスを外部公開しない構成を確認する。
