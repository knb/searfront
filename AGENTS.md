# AGENTS.md

このファイルは `docs/searfront_design_v0.1.md` から抽出した、searfront
実装時の作業指針です。詳細仕様や判断に迷う項目は設計書を正本とし、
実装済みの追加差分は `docs/progress.md` も参照します。

## プロジェクトの目的

- searfront は SearXNG の前段に置く独立型検索ゲートウェイ。
- 通常経路は SearXNG。結果不足、429、CAPTCHA、全エンジン失敗時は
  Exa を日次上限付きで試し、それでも不足する場合のみ Sidekiq 管理下の
  Browser Worker / Playwright / Browserless へ fallback する。
- 目的は外部検索回数を減らし、同一検索を再利用し、AI agent やテストの
  反復検索を安定させること。
- CAPTCHA 自動解決、ステルス、bot 回避は実装しない。

## 実装原則

- Rails API-only の標準構成に寄せる。
- 初期版では Active Record / 永続 DB を使わない。cache、lock、request
  status、engine state は TTL 付き Redis で扱う。
- 非同期処理は Sidekiq を使い、Web process から browser 検索や stale
  refresh を分離する。
- Rails 側に browser DOM 解析を持ち込まない。DOM 依存は Browser Worker
  側へ閉じる。
- cache は cache-aside と stale-while-revalidate を基本にする。
- 同一 cache key の同時 miss は Redis `SET NX PX` による single-flight
  lock で集約する。

## スコープ外

- CAPTCHA 自動解決、ステルス、bot 回避。
- 一般公開型の高トラフィック検索 API。
- 検索履歴の長期保存、ユーザー別課金、利用分析用 PostgreSQL。
- 検索結果本文の全文取得、Readability、RAG 登録。
- LLM による reranking。初期版は決定的なルールで統合する。

## レイヤ責務

- Controller: HTTP 変換、認証、params、status/render。Redis や Faraday を
  直接呼ばない。
- Search service: 検索ユースケース全体の orchestration。DOM 解析や HTTP
  transport 詳細を持たない。
- Client: SearXNG / Exa / Browser Worker 通信、timeout、response 変換。cache や
  業務判断を持たない。
- Cache / State: Redis key、serialization、TTL、lock。Controller に依存しない。
- Job: 非同期境界、冪等性確認、service 呼び出し。複雑な統合ロジックを
  直接書かない。

## API 方針

- Base path は `/v1`。
- API は `Authorization: Bearer <token>` を前提にする。
- `X-Request-ID` を受け入れ、未指定時は searfront が生成する。
- 時刻は ISO 8601 / UTC で返す。
- error response は `error.code`、`error.message`、`retryable`、
  `request_id` を揃える。
- `GET /v1/search` は `q`、`language`、`limit`、`categories`、
  `time_range`、`mode`、`refresh`、`wait_seconds` を扱う。
- 結果がまだない fallback は `202 Accepted` と `request_id` を返し、
  `GET /v1/search_requests/{request_id}` で poll する。

## Redis / TTL 初期値

- 正常結果 fresh TTL: 30 分。
- stale TTL: 12 時間。
- empty result TTL: 3 分。
- single-flight lock: 45 秒。
- single-flight wait: 15 秒。
- request status TTL: 10 分。
- max results: 20 件。
- client rate limit 目安: 60 req/min/token。

## Sidekiq / Browser 方針

- browser fallback 専用 queue は concurrency 1 を基本にする。
- browser 検索の最低実行間隔は 15 秒、jitter は 0 から 5 秒。
- browser timeout 目安は 35 秒。
- CAPTCHA、429、Access Denied を検出した response は正常結果として保存しない。
- CAPTCHA 検出時は engine を 24 時間 suspend する。
- 429 検出時は engine を 2 時間 suspend する。
- CAPTCHA や Access Denied を検出した場合は、同一 engine へ即時再試行しない。

## セキュリティ / ログ

- LAN 内運用でも Bearer token または reverse proxy 認証を使う。
- Browser Worker、Browserless、Redis、SearXNG は外部公開しない。
- SSRF 対策として、外部 URL を扱う場合は scheme、host、port、private IP を検証する。
- 既定では raw query text をログへ出さない。`query_digest` と文字数を基本にする。
- 構造化ログには `request_id`、cache hit、upstream、所要時間、結果件数、
  warnings を含める。

## テスト方針

- Minitest を基本にする。
- 外部 HTTP と Browser Worker は差し替え可能にし、WebMock や fixture で
  決定的にテストする。
- 実検索エンジンに対する CI テストは行わない。HTML fixture で adapter をテストする。
- QueryNormalizer は日本語、全角空白、NFKC、長さ制限、語順保持を確認する。
- CacheKey は Hash 順序、categories 順序、version 変更、同一条件の digest
  一致を確認する。
- UrlCanonicalizer は fragment、tracking parameter、host/port、危険 scheme を確認する。
- ResultMerger は重複、複数 engine、順位、同一 domain 抑制を確認する。
- CircuitBreaker は `healthy -> suspended -> half_open -> healthy` を確認する。
- SingleFlight は lock 取得、待機、期限切れ、token 不一致解放を確認する。

## 受入条件

- `GET /v1/search` が日本語 query で正常応答する。
- 同一検索条件は 30 分間 cache される。
- 同時 miss が single-flight で 1 回に集約される。
- SearXNG が失敗しても stale があれば `200` で返せる。
- `BrowserSearchJob` が Sidekiq 専用 queue で直列実行される。
- CAPTCHA / 429 を検出した engine へ即時再試行しない。
- `202` request を poll して完了結果を取得できる。
- query 本文を含めない構造化ログと基本 metrics を出力できる。
- Redis、SearXNG、Browser Worker 停止時の挙動を自動テストで確認する。

## 未決事項の初期推奨

- 初期 Browser Worker 対象は Google 1 engine から始める。
- stale TTL は fresh 30 分 / stale 12 時間から始める。
- 重複 job 制御は `sidekiq-unique-jobs` ではなく Redis `SET NX` の小規模実装から始める。
- Browser Worker の cookie/session は stateless または短寿命 context から始める。
