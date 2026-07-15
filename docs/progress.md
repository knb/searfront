# searfront 進捗

最終更新: 2026-07-15

このドキュメントは `docs/searfront_design_v0.1.md` の実装進捗を記録する。
設計判断の正本は設計書、実装時の作業指針は `AGENTS.md` とする。

## 現在の状態

Phase 4: 運用強化 API と rate limit を実装済み。

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

## Phase 進捗

| Phase | 内容 | 状態 |
| --- | --- | --- |
| Phase 1 | Rails API 基盤、認証、healthz、Redis 接続、構造化ログ | 実装済み |
| Phase 2 | SearXNG + cache、query 正規化、cache key、fresh/stale、single-flight、結果統合 | 実装済み |
| Phase 3 | Sidekiq fallback、request status、BrowserSearchJob、Browser Worker API、interval / circuit breaker | 実装済み |
| Phase 4 | metrics、engine 管理 API、Rack::Attack、alert、障害試験 | 実装済み |
| Phase 5 | 既存 Rails / AI Agent の検索先を searfront へ移行 | 未着手 |

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

Phase 4 実装後に次を実行し、成功を確認済み。

```sh
bin/ci
```

確認済み項目:

- RuboCop: no offenses。
- bundler-audit: no vulnerabilities。
- Brakeman: no warnings。
- Rails test: 32 tests, 104 assertions, 0 failures, 0 errors。

## 次の作業

Phase 5 では次を実施する。

- 既存 Rails アプリやローカル AI Agent の検索先を searfront に変更する。
- 直接 SearXNG 呼び出しを停止する。
- cache hit 率、CAPTCHA / 429 回数、browser fallback 件数を計測する。
- 実運用環境の Redis / SearXNG / Browser Worker / Browserless URL と token を設定する。
- Kamal / Docker network 上で内部サービスを外部公開しない構成を確認する。
