# searfront 移行手順

この手順は、既存 Rails アプリやローカル AI Agent の検索先を SearXNG 直呼びから
searfront へ切り替えるためのチェックリストです。

## 前提

- searfront Web process が起動している。
- `searfront-worker` と `searfront-browser-worker` が起動している。
- Redis、SearXNG、Browser Worker、Browserless は searfront と同じ内部 network から到達できる。
- クライアントには searfront の Bearer token だけを配布し、SearXNG は直接公開しない。

## 起動プロセス

開発環境では `.env.development` を読み込んだ上で、次をまとめて起動できる。

```sh
bin/dev
```

`bin/dev` は Web、通常 worker、Browser fallback 専用 worker を同時に起動する。
本番や process manager 配下では、次のようにプロセスを分けて起動する。

Web:

```sh
bundle exec puma -C config/puma.rb
```

通常 worker:

```sh
bundle exec sidekiq -C config/sidekiq.yml
```

Browser fallback 専用 worker:

```sh
bundle exec sidekiq -C config/sidekiq_browser.yml
```

`browser_search` queue は concurrency 1 の専用 process で動かす。

## 環境変数

サンプルは `config/searfront.env.example` を参照する。

必須:

- `SEARFRONT_API_TOKENS`
- `SEARXNG_BASE_URL`
- `BROWSER_WORKER_BASE_URL`
- `CACHE_REDIS_URL`
- `STATE_REDIS_URL`
- `SIDEKIQ_REDIS_URL`
- `RAILS_MASTER_KEY`

本番では token と Redis URL を secret manager または deployment secret として管理する。

## クライアント移行

1. 既存クライアントの SearXNG URL を探す。
2. 直接 SearXNG へ送っている検索呼び出しを searfront `/v1/search` に変更する。
3. `Authorization: Bearer <token>` を付与する。
4. `202 Accepted` の場合は `request_id` を使って `/v1/search_requests/{request_id}` を poll する。
5. `cache.status`、`sources`、`warnings` をログに残す。
6. クライアントから SearXNG への直接到達経路を閉じる。

curl 例:

```sh
curl -sS \
  -H "Authorization: Bearer $SEARFRONT_TOKEN" \
  "$SEARFRONT_BASE_URL/v1/search?q=llama.cpp%20Vulkan&limit=10"
```

## 移行後の確認

移行直後に確認する指標:

- `/readyz` が `ready` を返す。
- `/metrics` に `searfront_requests_total` が出る。
- 同一 query の2回目以降で `cache.status=fresh` が返る。
- SearXNG 停止時に stale があれば `cache.status=stale` が返る。
- 結果不足時に `202 Accepted` となり、poll 後に完了結果を取得できる。
- `GET /v1/engines` で CAPTCHA / 429 による suspension を確認できる。

smoke script:

```sh
ruby script/smoke_search.rb
```

必要な環境変数:

- `SEARFRONT_BASE_URL`
- `SEARFRONT_TOKEN`
- `SEARFRONT_QUERY`

## ロールバック

問題が出た場合は次の順で切り戻す。

1. クライアントの検索先を一時的に旧 SearXNG URL へ戻す。
2. searfront の `/readyz`、Sidekiq queue、Redis 接続を確認する。
3. `GET /v1/engines` で suspension が過剰に発生していないか確認する。
4. 原因を修正後、低頻度クライアントから searfront へ戻す。

直接 SearXNG へ戻すのは一時対応に限定し、長期運用では searfront 経由に戻す。
