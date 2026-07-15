# searfront

[English](README.en.md)

このリポジトリは ChatGPT + Codex を使って作成しています。

searfront は SearXNG の前段に配置する独立型の検索ゲートウェイです。
検索要求を正規化し、Redis キャッシュで同一検索を再利用し、同時 miss を
single-flight で集約します。通常経路は SearXNG とし、結果不足・429・
CAPTCHA 検出時だけ Exa を試し、それでも不足する場合に Sidekiq 管理下の
Browser Search Worker / Browserless 検索へ低速フォールバックします。

目的は CAPTCHA やアクセス制限の突破ではありません。外部検索の回数を
必要最小限に抑え、既存 Rails アプリ、ローカル AI エージェント、テスト
クライアントからの反復検索を安定して扱えるようにすることです。

このリポジトリは
[`docs/searfront_design_v0.1.md`](docs/searfront_design_v0.1.md)
を元にした実装スケルトンです。初期アーキテクチャと受入条件の詳細は
設計書を正本とします。

## 目的

- 同一検索条件の結果を fresh TTL 中は外部通信なしで再利用する。
- SearXNG を高速な通常経路として維持する。
- fresh 結果がなくても stale 結果があれば明示的に返す。
- Browser 検索は Sidekiq で直列化し、最低実行間隔を Redis で共有する。
- Exa 検索は Browser fallback の前段で使い、UTC日付ごとに最大500件までに制限する。
- CAPTCHA、429、Access Denied を正常結果として保存しない。
- `cache.status`、`sources`、`generated_at`、`warnings` を含む一貫した JSON API を提供する。

## アーキテクチャ

想定するプロセス構成は次の通りです。

- `searfront-web`: Rails API-only の HTTP API。
- `searfront-worker`: `cache_refresh` や `maintenance` 用の Sidekiq worker。
- `searfront-browser-worker`: browser fallback 専用の Sidekiq worker。初期並列数は 1。
- `Redis`: 検索キャッシュ、lock、request status、engine state、Sidekiq 用途で利用。
- `SearXNG`: 通常の同期検索経路。
- `Browser Search Worker`: Node.js/TypeScript 製の Google 検索アダプター。
- `Browserless`: Browser Search Worker から使う self-hosted headless browser 基盤。

公開するのは searfront の HTTP API のみです。Redis、SearXNG、Browser
Search Worker、Browserless は内部ネットワークに閉じます。

## API

設計上の API base path は `/v1` です。

### `GET /v1/search`

検索クエリを受け取り、cache、SearXNG、Exa、browser fallback の順に利用して
統一形式の検索結果を返します。利用可能な結果がまだない場合は
`202 Accepted` と `request_id` を返します。

| パラメータ | 必須 | 初期値 | 説明 |
| --- | --- | --- | --- |
| `q` | Yes | | 検索クエリ。1 から 500 文字。 |
| `language` | No | `ja-JP` | 検索言語・ロケール。 |
| `limit` | No | `10` | 返却件数。1 から 20。 |
| `categories` | No | `general` | SearXNG category。 |
| `time_range` | No | | `day`、`week`、`month`、`year`。 |
| `mode` | No | `auto` | `auto`、`cache`、`searxng`、`browser`。`browser` は管理権限のみ。 |
| `refresh` | No | `false` | fresh cache を無視する。rate limit と single-flight は維持する。 |
| `wait_seconds` | No | `0` | browser job の完了を待つ秒数。0 から 30。 |

```sh
curl -H "Authorization: Bearer $SEARFRONT_TOKEN" \
  "http://localhost:3000/v1/search?q=llama.cpp%20Vulkan&limit=10"
```

### `GET /v1/search_requests/{request_id}`

非同期 browser fallback の状態を照会します。

- `202`: 処理中。
- `200`: 完了。`GET /v1/search` と同じ結果形式を返す。
- `502` または `503`: 上流検索または必須依存が失敗。
- `404`: `request_id` が不明または期限切れ。

### 診断 API

- `GET /healthz`: Rails プロセスの応答確認。
- `GET /readyz`: Redis、SearXNG、Sidekiq enqueue 可否の確認。
- `GET /v1/engines`: engine ごとの `healthy` / `suspended` 状態。
- `POST /v1/engines/{name}/resume`: engine 停止状態の手動解除。
- `DELETE /v1/cache`: 条件付きキャッシュ削除。管理用途。
- `GET /metrics`: Prometheus 互換 metrics。

Rails 生成時の health check route として `/up` も残しています。

### Browser Search Worker API

Rails から内部ネットワーク経由で呼び出す API です。ホストへ公開しない前提です。

- `GET /health`: Browserless 接続確認を含む worker health check。
- `POST /v1/search/google`: Google検索1ページ目を取得し、正規化済みJSONを返す。

手動確認例:

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

CAPTCHA、同意画面、automated queries / rate limit を検出した場合は、突破や自動同意を行わず `blocked` と機械判定可能な `error.code` を返します。

## レスポンス例

検索完了時は、結果本体に加えて cache 状態、取得元、警告、処理時間を返します。

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

利用可能な結果がまだない場合は `202 Accepted` を返します。

```json
{
  "request_id": "01J...",
  "status": "pending",
  "poll_after_seconds": 3,
  "expires_at": "2026-07-15T00:12:00Z",
  "warnings": ["browser_fallback_queued"]
}
```

## 設定

主要な環境変数は次の通りです。

| 変数 | 必須 | 初期値 | 説明 |
| --- | --- | --- | --- |
| `SEARFRONT_API_TOKENS` | Yes | | token id、secret、role。secret manager 利用を推奨。 |
| `SEARXNG_BASE_URL` | Yes | | 例: `http://searxng:8080`。 |
| `EXA_SEARCH_ENABLED` | No | `true` | Exa検索を有効化する。`EXA_API_KEY` 未設定時は呼び出さない。 |
| `EXA_API_KEY` | No | | 設定時はBrowser fallback前にExa検索を試す。 |
| `EXA_BASE_URL` | No | `https://api.exa.ai/search` | Exa Search API endpoint。 |
| `EXA_DAILY_LIMIT` | No | `500` | Exa検索の日次上限。UTC日付ごとにRedisで制御する。 |
| `EXA_SEARCH_TYPE` | No | `auto` | Exa Search APIのsearch type。 |
| `EXA_USER_LOCATION` | No | `JP` | Exa Search APIへ渡す国コード。 |
| `BROWSER_SEARCH_WORKER_URL` | Yes | | 例: `http://browser-search-worker:3000`。 |
| `BROWSER_SEARCH_WORKER_TOKEN` | Yes | | Rails から Browser Search Worker へ渡す内部 Bearer token。 |
| `BROWSER_SEARCH_COUNTRY` | No | `JP` | Browser Search Worker へ渡す検索国。 |
| `CACHE_REDIS_URL` | Yes | | 検索結果キャッシュ用 Redis。 |
| `STATE_REDIS_URL` | Yes | | lock、engine state、request status 用 Redis。 |
| `SIDEKIQ_REDIS_URL` | Yes | | Sidekiq 用 Redis。 |
| `SEARCH_RESULT_TTL_SECONDS` | No | `1800` | fresh 結果 TTL。 |
| `SEARCH_STALE_TTL_SECONDS` | No | `43200` | stale 結果 TTL。 |
| `BROWSER_MIN_INTERVAL_SECONDS` | No | `15` | browser 検索の最低実行間隔。 |
| `BROWSER_JITTER_SECONDS` | No | `5` | browser 検索の追加待機幅。 |
| `CAPTCHA_SUSPEND_SECONDS` | No | `86400` | CAPTCHA 検出時の engine 停止時間。 |
| `RATE_LIMIT_SUSPEND_SECONDS` | No | `7200` | 429 検出時の engine 停止時間。 |
| `LOG_QUERY_TEXT` | No | `false` | raw query text をログに含めるか。 |
| `SEARFRONT_RATE_LIMIT_PER_MINUTE` | No | `60` | Bearer token または送信元 IP 単位の rate limit。 |

Browser Search Worker 側の主要な環境変数:

| 変数 | 必須 | 初期値 | 説明 |
| --- | --- | --- | --- |
| `BROWSER_WORKER_TOKEN` | Production | | Worker API の Bearer token。 |
| `BROWSERLESS_WS_ENDPOINT` | Yes | `ws://browserless:3000/chromium` | Browserless WebSocket endpoint。 |
| `BROWSERLESS_TOKEN` | No | | Browserless token。 |
| `GOOGLE_MIN_INTERVAL_MS` | No | `15000` | Worker内のGoogle検索最低間隔。 |
| `GOOGLE_INTERVAL_JITTER_MS` | No | `5000` | Worker内の追加jitter。 |
| `GOOGLE_NAVIGATION_TIMEOUT_MS` | No | `30000` | Google検索ページ遷移timeout。 |
| `GOOGLE_RESULT_TIMEOUT_MS` | No | `10000` | 検索結果DOM待機timeout。 |
| `DEBUG_ARTIFACTS_ENABLED` | No | `false` | 失敗時debug artifact保存を有効化する。 |
| `DEBUG_ARTIFACTS_DIR` | No | `./debug` | artifact保存先。 |

## 開発

前提:

- [`.ruby-version`](.ruby-version) に記載された Ruby。
- Bundler。
- Redis。
- SearXNG。
- 任意: Exa Search API key。
- Browser Search Worker と Browserless。

依存関係をインストールします。

```sh
bundle install
```

開発環境では `.env.development` を用意すると、`bin/dev` が起動時に読み込みます。
このファイルは `.gitignore` 対象です。設定値の雛形は
[`config/searfront.env.example`](config/searfront.env.example) を参照してください。

Web server と worker をまとめて起動します。

```sh
bin/dev
```

`bin/dev` は次の3プロセスを起動します。

- `./bin/rails server`
- `bundle exec sidekiq -C config/sidekiq.yml`
- `bundle exec sidekiq -C config/sidekiq_browser.yml`

Browser Search Worker と Browserless をコンテナで起動する場合:

```sh
BROWSER_WORKER_TOKEN=change-me \
BROWSERLESS_TOKEN=change-me-browserless \
docker compose up --build browserless browser-search-worker
```

`compose.yaml` は Browserless と Browser Search Worker のみを定義しています。Rails API、Redis、SearXNG は既存のローカル環境または運用構成に合わせて起動してください。初期状態では Browserless / Browser Search Worker のポートをホスト公開せず、Docker内部ネットワークで使います。

Docker bridge network から `registry.npmjs.org` の名前解決が失敗する環境があるため、`compose.yaml` では Browser Search Worker の build network を `host` にしています。直接 `docker build` する場合も、同じ症状が出る環境では `docker build --network host ./browser-search-worker` を使ってください。

Browser Search Workerを単体開発する場合:

```sh
cd browser-search-worker
npm install
npm run dev
```

テストを実行します。

```sh
bin/rails test
```

Browser Search Workerのテストを実行します。

```sh
cd browser-search-worker
npm test
npm run build
npm run lint
```

CI 相当のローカルチェックを実行します。

```sh
bin/ci
```

移行手順と運用確認は [`docs/migration.md`](docs/migration.md) を参照してください。

このアプリケーションは Rails API-only かつ Active Record なしで生成しているため、
初期構成では database setup は不要です。

## 実装フェーズ

1. 基盤: 認証、healthz、readyz、Redis 接続、構造化ログ。
2. SearXNG + cache: query 正規化、cache key、fresh/stale、single-flight、結果統合。
3. Sidekiq fallback: request status、`BrowserSearchJob`、Browser Search Worker API、interval 制御。
4. 運用強化: metrics、engine 管理 API、rate limit、障害試験。
5. 移行: 既存 Rails アプリやローカル AI エージェントの検索先を searfront に変更。

## セキュリティ

- LAN 内運用でも Bearer token または reverse proxy 認証を使う。
- Redis、SearXNG、Browser Search Worker、Browserless は外部公開しない。
- CAPTCHA 自動解決や bot 回避を実装しない。
- Browser Search Worker は stealth plugin、proxy rotation、Googleログイン、CAPTCHA solver を使わない。
- 既定では raw query text をログへ出さない。
- debug artifact は既定OFF。保存時も `metadata.json` には検索語本文を保存せず SHA-256 digest のみを記録する。
- browser fallback は低頻度の最後の手段として扱い、検索エンジンの利用規約とアクセス制限を尊重する。

## License

searfront is released under the MIT License. See [LICENSE](LICENSE).
