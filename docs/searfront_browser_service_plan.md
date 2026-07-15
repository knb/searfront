# searfront Browser Search Worker 導入計画

## 1. 目的

`searfront` に、SearXNGで十分な検索結果を取得できなかった場合に使用する、Google検索用のheadless browser workerを追加する。

Browser Search Workerは以下の構成とする。

* Node.js
* TypeScript
* Fastify
* `puppeteer-core`
* Browserless Chromium
* Docker / Docker Compose

CAPTCHAの突破や回避を目的とはせず、CAPTCHA、レート制限、同意画面などを検出した場合は、明示的なエラーとして`searfront`へ返す。

## 2. 全体構成

```text
Client / AI Agent
        |
        v
searfront
Rails API-only
        |
        +--> Redis cache
        |
        +--> SearXNG
        |
        +--> Sidekiq BrowserSearchJob
                  |
                  | HTTP
                  v
        browser-search-worker
        Fastify + TypeScript
                  |
                  | WebSocket
                  v
        Browserless Chromium
                  |
                  v
             Google Search
```

責務を以下のように分離する。

### searfront

* 検索クエリの正規化
* Redisキャッシュ
* 同一検索の重複抑止
* SearXNG検索
* Browser Search Workerへのフォールバック判定
* Sidekiqジョブ管理
* CAPTCHAや429発生時のサーキットブレーカー
* 検索結果の統合
* クライアント向けAPI

### Browser Search Worker

* Browserlessへの接続
* Google検索ページの表示
* Google検索結果のDOM解析
* CAPTCHA、レート制限、同意画面の検出
* 検索結果を正規化したJSONで返却
* デバッグ用HTML・スクリーンショットの保存
* Googleへのアクセス間隔制御

### Browserless

* Chromiumプロセス管理
* ブラウザセッション管理
* Browser Search WorkerからのWebSocket接続受付
* Chromiumの再起動とヘルスチェック

## 3. 実装範囲

今回の更新では、Google検索の1ページ目のみを対象とする。

実装対象は以下とする。

* Google通常検索
* 日本語クエリ
* PC向け検索結果
* 最大10件程度の自然検索結果
* タイトル
* URL
* スニペット
* 検索順位
* CAPTCHA検出
* 同意画面検出
* automated queries画面検出
* タイムアウト検出
* DOM変更による解析失敗検出

今回の対象外は以下とする。

* CAPTCHAの自動解決
* Googleアカウントへのログイン
* 検索結果の2ページ目以降
* 広告結果の取得
* Google画像検索
* Googleニュース検索
* 検索結果ページからリンク先本文を取得する処理
* 複数Browser Workerによる並列検索
* プロキシローテーション

## 4. 新規ディレクトリ

リポジトリ内に次のディレクトリを追加する。

```text
browser-search-worker/
├── src/
│   ├── server.ts
│   ├── config.ts
│   ├── browser.ts
│   ├── routes/
│   │   ├── health.ts
│   │   └── google_search.ts
│   ├── services/
│   │   ├── google_search.ts
│   │   ├── google_parser.ts
│   │   ├── page_detector.ts
│   │   └── rate_limiter.ts
│   ├── schemas/
│   │   ├── search_request.ts
│   │   └── search_response.ts
│   ├── errors/
│   │   └── search_error.ts
│   └── debug/
│       └── artifact_writer.ts
├── test/
│   ├── fixtures/
│   │   ├── google_results.html
│   │   ├── google_captcha.html
│   │   ├── google_consent.html
│   │   └── google_empty.html
│   ├── google_parser.test.ts
│   └── page_detector.test.ts
├── debug/
│   └── .gitkeep
├── package.json
├── package-lock.json
├── tsconfig.json
├── eslint.config.js
├── Dockerfile
├── .dockerignore
├── .env.example
└── README.md
```

## 5. Node.jsパッケージ

初期依存関係は以下を基本とする。

```json
{
  "dependencies": {
    "fastify": "^5",
    "pino": "^9",
    "puppeteer-core": "^24",
    "zod": "^4"
  },
  "devDependencies": {
    "@types/node": "^24",
    "eslint": "^9",
    "tsx": "^4",
    "typescript": "^5",
    "vitest": "^3"
  }
}
```

バージョンは実装時点の安定版を確認して固定する。

不要なスクレイピングライブラリは追加しない。

以下は初期段階では採用しない。

* Crawlee
* `puppeteer-cluster`
* `puppeteer-extra`
* stealth plugin
* CAPTCHA solver
* `puppeteer-search-scraper`

Google検索結果の解析は独自実装とする。

## 6. Browser Search Worker API

### 6.1 ヘルスチェック

```http
GET /health
```

正常時レスポンス:

```json
{
  "status": "ok",
  "browserless": "reachable"
}
```

Browserlessに接続できない場合:

```json
{
  "status": "degraded",
  "browserless": "unreachable"
}
```

HTTPステータスは以下とする。

* 正常: `200`
* Browserless接続不可: `503`

### 6.2 Google検索

```http
POST /v1/search/google
Content-Type: application/json
Authorization: Bearer <token>
```

リクエスト:

```json
{
  "query": "llama.cpp Vulkan",
  "language": "ja",
  "country": "JP",
  "limit": 10
}
```

入力制約:

* `query`: 必須
* `query`: 1〜500文字
* `language`: 初期値`ja`
* `country`: 初期値`JP`
* `limit`: 1〜10
* 不明なフィールドは拒否する

正常レスポンス:

```json
{
  "engine": "google-browser",
  "query": "llama.cpp Vulkan",
  "status": "ok",
  "results": [
    {
      "position": 1,
      "title": "llama.cpp",
      "url": "https://github.com/ggml-org/llama.cpp",
      "content": "LLM inference in C/C++..."
    }
  ],
  "detected": {
    "captcha": false,
    "consent_page": false,
    "rate_limited": false
  },
  "elapsed_ms": 2841
}
```

検索結果が0件の場合:

```json
{
  "engine": "google-browser",
  "query": "example",
  "status": "empty",
  "results": [],
  "detected": {
    "captcha": false,
    "consent_page": false,
    "rate_limited": false
  },
  "elapsed_ms": 2400
}
```

CAPTCHA検出時:

```json
{
  "engine": "google-browser",
  "query": "example",
  "status": "blocked",
  "results": [],
  "error": {
    "code": "google_captcha",
    "message": "Google CAPTCHA page was detected.",
    "retryable": false,
    "suspend_seconds": 86400
  },
  "detected": {
    "captcha": true,
    "consent_page": false,
    "rate_limited": false
  },
  "elapsed_ms": 1800
}
```

レート制限またはautomated queries画面の場合:

```json
{
  "engine": "google-browser",
  "query": "example",
  "status": "blocked",
  "results": [],
  "error": {
    "code": "google_rate_limited",
    "message": "Google automated query restriction was detected.",
    "retryable": false,
    "suspend_seconds": 7200
  },
  "detected": {
    "captcha": false,
    "consent_page": false,
    "rate_limited": true
  },
  "elapsed_ms": 1800
}
```

## 7. HTTPステータス設計

| 状況                  | HTTPステータス |
| ------------------- | --------: |
| 正常に検索結果を取得          |       200 |
| 正常だが結果0件            |       200 |
| リクエスト不正             |       400 |
| 認証失敗                |       401 |
| CAPTCHA検出           |       429 |
| automated queries検出 |       429 |
| 検索実行タイムアウト          |       504 |
| Google DOM解析失敗      |       502 |
| Browserless接続失敗     |       503 |
| Worker内部エラー         |       500 |

レスポンスボディには、HTTPステータスに加えて機械判定可能な`error.code`を必ず含める。

## 8. 認証

Browser Search Workerは外部公開しない。

Dockerネットワーク内でのみアクセス可能にする。

さらにBearer Token認証を追加する。

環境変数:

```text
BROWSER_WORKER_TOKEN=<random-secret>
```

認証ヘッダー:

```http
Authorization: Bearer <token>
```

トークンが未設定の場合は、本番環境で起動に失敗させる。

ログには認証トークンを出力しない。

## 9. Browserless接続

`puppeteer-core`からBrowserlessへWebSocket接続する。

環境変数:

```text
BROWSERLESS_WS_ENDPOINT=ws://browserless:3000/chromium
BROWSERLESS_TOKEN=<browserless-token>
```

接続URL例:

```text
ws://browserless:3000/chromium?token=<browserless-token>
```

Browser Search Workerは、リクエストごとにChromiumプロセスを起動しない。

Browserless側のブラウザ実行基盤を利用する。

初期設定では、検索ごとに新しいBrowser Contextを使用する。

Contextは検索終了時に確実に破棄する。

## 10. Google検索URL

検索URLは、文字列連結ではなく`URL`と`URLSearchParams`で生成する。

例:

```text
https://www.google.com/search
  ?q=llama.cpp%20Vulkan
  &hl=ja
  &gl=JP
  &num=10
  &filter=0
```

初期パラメータ:

* `q`: 検索クエリ
* `hl`: 表示言語
* `gl`: 国
* `num`: 最大10
* `filter=0`: 類似結果の自動除外を抑える

Cookie同意画面を避ける目的で、不透明なGoogleパラメータを大量に追加しない。

## 11. Browser Context設定

初期設定:

```text
locale: ja-JP
timezone: Asia/Tokyo
viewport: 1280x900
deviceScaleFactor: 1
```

User-AgentはChromiumの標準値を使用する。

不自然なUser-Agent偽装やstealth化は行わない。

以下のリソースは必要に応じてブロックする。

* image
* media
* font

ただし、Googleのページ表示や検出処理に影響する場合は、初期段階では画像のみをブロックする。

JavaScript、CSS、document、XHRは許可する。

## 12. ナビゲーション

Google検索ページへの移動は以下を基本とする。

```ts
await page.goto(searchUrl, {
  waitUntil: "domcontentloaded",
  timeout: navigationTimeout
});
```

`networkidle0`や`networkidle2`は使用しない。

Google検索ページはバックグラウンド通信が継続する可能性があり、不要に待ち時間が長くなるためである。

ナビゲーション後は以下のいずれかを待つ。

* 検索結果コンテナ
* CAPTCHA要素
* 同意画面要素
* automated queries本文
* タイムアウト

## 13. CAPTCHA・ブロック検出

検索結果解析より前に、ページ状態を判定する。

以下を検出対象とする。

### CAPTCHA

候補条件:

* URLに`/sorry/`が含まれる
* `form[action*="sorry"]`
* `iframe[src*="recaptcha"]`
* `g-recaptcha`
* ページ本文にCAPTCHA関連文言がある

### automated queries

候補文言:

```text
Our systems have detected unusual traffic
automated queries
unusual traffic from your computer network
```

日本語表示も考慮する。

### 同意画面

候補条件:

* URLが`consent.google.com`
* 「同意する」「すべて同意」などのボタン
* consent用フォーム

同意画面が表示された場合、初期版では自動操作を行わない。

`google_consent_required`としてエラーを返す。

## 14. 検索結果解析

GoogleのCSSクラス名は変更される可能性が高いため、一つのセレクターに依存しない。

検索結果候補セレクターを配列として管理する。

```ts
const resultContainerSelectors = [
  "#search .g",
  "#search div.MjjYud",
  "#rso > div"
];
```

各候補要素について以下を確認する。

1. `h3`が存在する
2. `h3`の祖先または近傍に`a[href]`が存在する
3. URLがHTTPまたはHTTPSである
4. Google内部URLではない
5. 広告ではない
6. 関連検索や質問ボックスではない
7. 同一URLが重複していない

URL除外対象の例:

```text
google.com/search
google.com/preferences
google.com/advanced_search
accounts.google.com
support.google.com
webcache.googleusercontent.com
```

GoogleのリダイレクトURLの場合は、実URLへ正規化する。

例:

```text
https://www.google.com/url?q=https://example.com/
```

から、

```text
https://example.com/
```

を取得する。

## 15. スニペット抽出

スニペットは候補セレクターを複数用意する。

取得できない場合は空文字列を許可する。

タイトルとURLが取得できた結果は、スニペットが空でも有効とする。

スニペット内の連続空白、改行、不可視文字を正規化する。

```text
連続する空白 → 半角スペース1文字
前後空白 → 除去
Unicode → NFKC
```

ただし、URL自体にはNFKC正規化を適用しない。

## 16. 重複除外

同じURLが複数回現れた場合は最初の結果だけを残す。

URL正規化では以下を実施する。

* fragment除去
* 末尾スラッシュの統一
* ホスト名の小文字化
* デフォルトポート除去
* Googleリダイレクト解除

初期版では以下は実施しない。

* トラッキングパラメータの包括的除去
* canonical URLの取得
* リンク先への追加アクセス

## 17. アクセス間隔制御

Googleへのアクセスは同時実行数1に制限する。

Browser Search Worker内でも最低アクセス間隔を持つ。

初期値:

```text
GOOGLE_MIN_INTERVAL_MS=15000
GOOGLE_INTERVAL_JITTER_MS=5000
```

実際の待機時間:

```text
15秒 + 0〜5秒のランダム値
```

直前のGoogleアクセス開始時刻をWorker内で管理する。

複数Workerプロセスを立てないことを前提とする。

将来複数プロセス化する場合は、Redisベースの分散レート制御へ移行する。

## 18. タイムアウト

環境変数:

```text
GOOGLE_NAVIGATION_TIMEOUT_MS=30000
GOOGLE_RESULT_TIMEOUT_MS=10000
BROWSERLESS_CONNECT_TIMEOUT_MS=10000
```

最大処理時間は60秒以内とする。

Sidekiq側のHTTPタイムアウトは、Workerの最大処理時間より少し長く設定する。

例:

```text
open_timeout: 5秒
read_timeout: 65秒
```

## 19. デバッグ成果物

以下の場合のみ、デバッグ成果物を保存できるようにする。

* CAPTCHA検出
* 同意画面検出
* DOM解析失敗
* 結果0件
* 想定外例外

環境変数:

```text
DEBUG_ARTIFACTS_ENABLED=false
DEBUG_ARTIFACTS_DIR=/app/debug
DEBUG_ARTIFACT_TTL_HOURS=24
```

保存形式:

```text
debug/
└── 20260715T123456Z-abc123/
    ├── page.html
    ├── screenshot.png
    └── metadata.json
```

`metadata.json`には以下を含める。

```json
{
  "request_id": "abc123",
  "query_digest": "sha256...",
  "url": "https://www.google.com/search?...",
  "status": "parse_error",
  "created_at": "2026-07-15T12:34:56Z"
}
```

検索クエリ本文は、通常ログには記録しない。

デバッグ成果物に保存する場合も設定で無効化可能とする。

## 20. ログ

JSON構造化ログを使用する。

ログ項目:

```text
request_id
event
engine
status
elapsed_ms
result_count
query_digest
captcha
rate_limited
consent_page
error_code
```

ログに出してはいけないもの:

* Bearer Token
* Browserless Token
* Cookie
* 完全なGoogleレスポンスHTML
* Authorizationヘッダー
* 検索クエリ全文

検索クエリはSHA-256 digestで識別する。

## 21. Dockerfile

Browser Search WorkerのDockerfileを追加する。

ChromiumはWorkerコンテナにインストールしない。

Browserless側のChromiumを使用するため、Node.jsランタイムのみでよい。

方針:

* Node.js LTS
* マルチステージビルド
* TypeScriptをビルド
* production dependenciesのみコピー
* 非rootユーザーで実行
* `/app/debug`を書き込み可能にする

起動コマンド:

```text
node dist/server.js
```

## 22. Docker Compose更新

既存のDocker Composeに以下を追加する。

```yaml
services:
  browserless:
    image: ghcr.io/browserless/chromium
    restart: unless-stopped
    environment:
      TOKEN: ${BROWSERLESS_TOKEN}
      CONCURRENT: "1"
      QUEUED: "20"
      TIMEOUT: "60000"
    shm_size: "1gb"
    expose:
      - "3000"

  browser-search-worker:
    build:
      context: ./browser-search-worker
    restart: unless-stopped
    depends_on:
      - browserless
    environment:
      NODE_ENV: production
      PORT: "3000"
      BROWSER_WORKER_TOKEN: ${BROWSER_WORKER_TOKEN}
      BROWSERLESS_WS_ENDPOINT: ws://browserless:3000/chromium
      BROWSERLESS_TOKEN: ${BROWSERLESS_TOKEN}
      GOOGLE_MIN_INTERVAL_MS: "15000"
      GOOGLE_INTERVAL_JITTER_MS: "5000"
      GOOGLE_NAVIGATION_TIMEOUT_MS: "30000"
      DEBUG_ARTIFACTS_ENABLED: "false"
      DEBUG_ARTIFACTS_DIR: /app/debug
    expose:
      - "3000"
    volumes:
      - browser_search_debug:/app/debug

volumes:
  browser_search_debug:
```

BrowserlessとBrowser Search Workerのポートは、初期状態ではホストへ公開しない。

Railsの`searfront`コンテナからDocker内部ネットワーク経由でアクセスする。

## 23. searfront側の環境変数

Rails側に以下を追加する。

```text
BROWSER_SEARCH_WORKER_URL=http://browser-search-worker:3000
BROWSER_SEARCH_WORKER_TOKEN=<secret>
BROWSER_SEARCH_ENABLED=true
BROWSER_SEARCH_OPEN_TIMEOUT=5
BROWSER_SEARCH_READ_TIMEOUT=65
BROWSER_SEARCH_MIN_RESULTS=3
BROWSER_SEARCH_CAPTCHA_SUSPEND_SECONDS=86400
BROWSER_SEARCH_RATE_LIMIT_SUSPEND_SECONDS=7200
```

## 24. Rails側クライアント

以下のクラスを追加する。

```text
app/services/search_gateway/clients/browser_worker.rb
```

責務:

* Worker APIの呼び出し
* Bearer Token付与
* タイムアウト設定
* JSON解析
* HTTPステータス変換
* Worker固有レスポンスを内部形式へ変換
* 通信エラーの分類

想定インターフェース:

```ruby
SearchGateway::Clients::BrowserWorker.call(
  query:,
  language: "ja",
  country: "JP",
  limit: 10,
  request_id:
)
```

返却値はHashの直接利用ではなく、既存の`SearchGateway::Response`または専用Value Objectへ変換する。

## 25. Sidekiqジョブ

以下を追加または更新する。

```text
app/workers/browser_search_worker.rb
```

名称がNode側Workerと混同する場合は、Rails側を以下の名称にする。

```text
BrowserSearchJob
```

推奨:

```ruby
class BrowserSearchJob
  include Sidekiq::Job

  sidekiq_options(
    queue: :browser_search,
    retry: 1
  )
end
```

責務:

1. Redisのサーキットブレーカー確認
2. キャッシュ再確認
3. Browser Search Worker呼び出し
4. 結果保存
5. staleキャッシュ更新
6. CAPTCHAまたは429時のエンジン停止
7. 完了状態保存
8. 構造化ログ出力

CAPTCHA時はSidekiqで自動リトライしない。

タイムアウトや一時的なBrowserless接続失敗のみ、最大1回リトライする。

## 26. Sidekiqキュー

専用キューを追加する。

```yaml
:queues:
  - default
  - browser_search
```

Browser検索の並列数は1にする。

Sidekiq全体のconcurrencyが複数でも、Browser検索専用プロセスを分離する。

例:

```bash
bundle exec sidekiq -q browser_search -c 1
```

一般ジョブとは別プロセスで動かす。

## 27. Redisキー

Browser検索用に以下のキーを使用する。

```text
searfront:browser:result:<digest>
searfront:browser:job:<digest>
searfront:browser:lock:<digest>
searfront:browser:engine:google:suspended
searfront:browser:engine:google:last_request_at
```

検索結果キャッシュ:

```text
TTL: 30分
```

stale結果:

```text
TTL: 12時間
```

空結果:

```text
TTL: 3分
```

CAPTCHA停止状態:

```text
TTL: 24時間
```

レート制限停止状態:

```text
TTL: 2時間
```

## 28. フォールバック条件

SearXNG検索後、以下の条件でBrowser検索を投入する。

* SearXNG全体がタイムアウト
* 利用可能な検索結果が0件
* 有効結果数が`BROWSER_SEARCH_MIN_RESULTS`未満
* SearXNG側でGoogle、DuckDuckGoなど主要エンジンが停止中
* 明示的に`mode=browser`が指定された
* 管理・テスト用の`refresh=true`が指定された

ただし、Google Browserエンジンが停止中の場合はジョブを投入しない。

## 29. 検索結果統合

SearXNGとBrowser Search Workerの結果を共通形式に変換する。

共通形式:

```json
{
  "title": "Example",
  "url": "https://example.com/",
  "content": "Snippet",
  "engines": [
    "searxng",
    "google-browser"
  ],
  "positions": {
    "searxng": 2,
    "google-browser": 1
  }
}
```

URL単位で重複排除する。

両方に存在する場合:

* タイトルは長さと内容を比較して選択
* スニペットは空でない方を優先
* `engines`を統合
* 各エンジンの順位を保存

初期版では複雑なランキングスコアは実装しない。

SearXNG結果を先に保持し、その後にGoogle Browser固有結果を追加する。

## 30. searfront APIレスポンス更新

既存検索APIレスポンスへ以下を追加する。

```json
{
  "query": "llama.cpp Vulkan",
  "status": "ok",
  "cached": false,
  "source": "searxng+google-browser",
  "refresh_pending": false,
  "results": [],
  "engines": {
    "searxng": {
      "status": "ok",
      "result_count": 2
    },
    "google-browser": {
      "status": "ok",
      "result_count": 8
    }
  },
  "errors": []
}
```

Browser検索がSidekiqで実行中の場合:

```json
{
  "query": "llama.cpp Vulkan",
  "status": "pending",
  "cached": false,
  "source": "searxng",
  "refresh_pending": true,
  "request_id": "abc123",
  "results": [],
  "errors": []
}
```

HTTPステータスは`202 Accepted`とする。

stale結果を返しながら更新する場合は`200 OK`とし、`refresh_pending: true`を付ける。

## 31. テスト用モード

テスト実行で同じ検索を繰り返すため、以下のモードを維持する。

```text
mode=auto
mode=cache
mode=searxng
mode=browser
refresh=true
```

### `mode=auto`

通常の検索フロー。

### `mode=cache`

外部検索を行わず、キャッシュのみ確認。

### `mode=searxng`

Browser検索を使用しない。

### `mode=browser`

SearXNGを使用せずBrowser検索を実行する。

### `refresh=true`

freshキャッシュが存在しても再検索を実行する。

本番では`mode=browser`と`refresh=true`を管理用APIトークンのみに制限する。

## 32. Parser単体テスト

Google検索結果解析は、保存したHTML fixtureに対して単体テストする。

最低限以下を用意する。

* 通常の検索結果
* スニペットなし
* 重複URLあり
* GoogleリダイレクトURL
* 検索結果0件
* CAPTCHAページ
* automated queriesページ
* 同意画面
* DOM構造変更を模した不正HTML
* 広告や関連検索を含むページ

ネットワークへ接続しないテストを中心にする。

## 33. Worker統合テスト

Browserlessを利用する統合テストは、通常のテストスイートと分離する。

例:

```bash
npm test
npm run test:integration
```

統合テストは環境変数が設定されている場合のみ実行する。

Googleへの実アクセスを伴うテストは自動CIでは毎回実行しない。

手動実行またはスケジュール実行とする。

## 34. Rails側テスト

以下を追加する。

* Browser Workerクライアントの正常レスポンス
* CAPTCHAレスポンス
* 429レスポンス
* タイムアウト
* JSON不正
* 401
* Browserless停止
* Sidekiqジョブの重複抑止
* CAPTCHA時のサーキットブレーカー
* stale結果返却
* SearXNGとBrowser結果の統合
* URL重複排除
* `mode=browser`
* `mode=cache`
* `refresh=true`

外部HTTPはWebMockなどでスタブする。

## 35. README更新

ルートREADMEへ以下を追加する。

* Browser Search Workerの役割
* Browserlessの役割
* Docker Compose起動方法
* 必要な環境変数
* Google検索の利用上の注意
* CAPTCHAを自動解決しない方針
* デバッグ成果物の有効化方法
* テスト方法
* 手動検索例

curl例:

```bash
curl -X POST \
  http://localhost:3001/v1/search/google \
  -H "Authorization: Bearer ${BROWSER_WORKER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "llama.cpp Vulkan",
    "language": "ja",
    "country": "JP",
    "limit": 10
  }'
```

## 36. 実装順序

### Phase 1: Worker基盤

1. `browser-search-worker`ディレクトリ作成
2. TypeScript、Fastify、Vitest設定
3. `/health`実装
4. Bearer Token認証実装
5. Dockerfile作成
6. Browserless接続確認
7. Docker Composeへ追加

### Phase 2: Google検索

1. Google検索URL生成
2. Browser Context生成
3. ページ遷移
4. CAPTCHA・同意画面検出
5. Google検索結果Parser実装
6. 正規化JSONレスポンス
7. デバッグ成果物保存
8. Parser fixtureテスト

### Phase 3: Rails連携

1. Browser Workerクライアント追加
2. 環境変数追加
3. Sidekiqジョブ追加
4. `browser_search`専用キュー追加
5. Redisキャッシュ追加
6. サーキットブレーカー追加
7. SearXNGフォールバック条件追加
8. APIレスポンス更新

### Phase 4: 運用制御

1. 15秒＋jitterのアクセス制御
2. Browser検索並列数1の確認
3. CAPTCHA時24時間停止
4. 429時2時間停止
5. stale-while-revalidate
6. 構造化ログ
7. デバッグ成果物削除処理

### Phase 5: テスト・文書

1. Worker単体テスト
2. Worker統合テスト
3. Railsサービステスト
4. Sidekiqジョブテスト
5. APIリクエストテスト
6. README更新
7. `.env.example`更新

## 37. 受入条件

以下をすべて満たした時点で完了とする。

* Docker ComposeでBrowserlessとBrowser Search Workerが起動する
* Workerの`/health`が正常に応答する
* Google検索からタイトル、URL、スニペットを取得できる
* 最大10件まで返却できる
* Google内部URLや重複URLを除外できる
* CAPTCHA画面を検索結果として扱わない
* automated queries画面を検出できる
* 同意画面を検出できる
* Browser Search Workerへのアクセスに認証が必要
* Googleへの同時アクセスが1件に制限される
* 最低15秒の検索間隔が守られる
* SearXNG結果が不足した場合にSidekiqジョブが投入される
* 同じ検索の重複ジョブが抑止される
* Browser検索結果がRedisへ保存される
* 同じ検索の再実行時にRedisキャッシュが利用される
* CAPTCHA発生時にGoogle Browserエンジンが24時間停止される
* stale結果を返しながらバックグラウンド更新できる
* 外部接続なしでParserテストが実行できる
* READMEに起動・設定・テスト方法が記載される

## 38. 実装上の注意

* Google検索ページのDOMは変更される前提で実装する
* セレクターを一箇所へ集約する
* CSSクラス名だけに依存しない
* Parserとブラウザ操作を分離する
* CAPTCHA突破機能を実装しない
* stealth pluginを導入しない
* Googleへの並列アクセスを行わない
* エラー時の即時再試行を行わない
* CAPTCHAページをキャッシュしない
* CAPTCHA検出状態だけをRedisへ保存する
* Workerコンテナをインターネットへ直接公開しない
* Rails側からの通信にはBearer Tokenを使う
* トークン、Cookie、検索本文をログへ出さない
* Debug artifactは既定で無効にする
* Google検索に失敗しても、searfront全体を停止させない

## 39. Codexへの作業指示

既存コードを確認し、現在の命名規則、サービスクラス構成、テスト方針、Docker Compose構成に合わせて実装すること。

一度に大規模な変更を行わず、以下の単位で実装とテストを進めること。

1. Browser Search Workerの基盤
2. Google Parser
3. Browserless連携
4. Rails HTTPクライアント
5. Sidekiq連携
6. Redisキャッシュとサーキットブレーカー
7. API統合
8. ドキュメント

各段階で関連テストを追加し、既存テストを壊していないことを確認する。

既存の検索レスポンス形式を変更する場合は、可能な限り後方互換性を維持する。

不明点がある場合は、安易に新しいGemやnpmパッケージを追加せず、既存実装と標準ライブラリを優先する。
