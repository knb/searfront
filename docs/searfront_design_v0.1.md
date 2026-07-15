**Searfront**

**Rails API-only + Sidekiq\
検索ゲートウェイ システム設計書**

文書版: 0.1\
状態: Draft / 実装開始用\
作成日: 2026-07-15\
対象アプリケーション: searfront

目的: SearXNGを通常経路とし、RedisキャッシュとSidekiq制御下の\
Playwright/Browserless検索を低速フォールバックとして提供する。

# 文書管理

  --------------------------------------------------------------------------------------------------
  **項目**                            **内容**
  ----------------------------------- --------------------------------------------------------------
  文書名                              Searfront システム設計書

  対象                                独立型検索ゲートウェイ searfront

  主要技術                            Ruby on Rails API-only / Sidekiq / Redis / SearXNG /
                                      Playwright / Browserless

  初期データベース                    なし（Active Recordを使用しない）

  主利用者                            既存Railsアプリ、ローカルAIエージェント、テストクライアント

  優先事項                            CAPTCHA・429の抑制、同一検索の再利用、低頻度かつ安定した検索
  --------------------------------------------------------------------------------------------------

## 改訂履歴

  -----------------------------------------------------------------------------------------------------------------
  **版**                  **日付**                **内容**
  ----------------------- ----------------------- -----------------------------------------------------------------
  0.1                     2026-07-15              初版。基本アーキテクチャ、API、Redis、Sidekiq、運用設計を定義。

  -----------------------------------------------------------------------------------------------------------------

## 前提と用語

-   「Sidekiq」はバックグラウンドジョブ処理基盤を指す。

-   「Browser
    Worker」はNode.js/TypeScriptで実装するPlaywright検索アダプターを指す。

-   「Browserless」は自己ホストするheadlessブラウザ実行基盤を指す。

-   「stale結果」はfresh TTLを過ぎたが、stale
    TTL内にある直近の正常検索結果を指す。

-   本書では検索結果を取得するだけとし、CAPTCHAの自動突破は行わない。

# 目次

> 1 概要
>
> 2 要求事項
>
> 3 設計方針
>
> 4 システムアーキテクチャ
>
> 5 検索処理フロー
>
> 6 API設計
>
> 7 Redis設計
>
> 8 Sidekiq設計
>
> 9 検索結果処理
>
> 10 障害制御・レート制御
>
> 11 セキュリティ
>
> 12 監視・ログ
>
> 13 デプロイ・設定
>
> 14 Railsプロジェクト構成
>
> 15 テスト計画
>
> 16 実装フェーズと受入条件
>
> 17 リスクと未決事項
>
> 付録A 主要設定値
>
> 付録B 参考資料

# 1. 概要

## 1.1 背景

現在の検索構成では、SearXNGからGoogle、DuckDuckGo等への連続アクセスにより、CAPTCHA、429
Too Many
Requests、解析エラーが発生することがある。特にローカルAIやテストコードは、同一または類似クエリを短時間に繰り返すため、検索エンジン側の負荷判定を受けやすい。

searfrontはSearXNGの前段に配置し、検索要求の正規化、Redisキャッシュ、同一要求の集約、エンジン停止制御、Browserless/Playwrightへの低速フォールバックを一元化する独立APIサービスである。

## 1.2 目的

-   同一検索の外部送信回数を減らし、テスト実行やAIエージェントの反復検索を安全にする。

-   SearXNGを高速な通常経路として維持し、結果不足・429・CAPTCHA時だけheadless検索へ切り替える。

-   headless検索をSidekiqで直列化し、最低実行間隔と一時停止をRedisで共有する。

-   クライアントには検索エンジン差を隠した一貫したJSON APIを提供する。

-   検索結果の鮮度、取得元、キャッシュ状態、警告を明示し、ローカルAIが扱いやすい形式にする。

## 1.3 目標品質

  ----------------------------------------------------------------------------------------------------------------------------------
  **観点**                            **目標**
  ----------------------------------- ----------------------------------------------------------------------------------------------
  安定性                              外部検索が失敗しても、stale結果または明示的な202/エラーを返し、Railsプロセスを巻き込まない。

  外部負荷                            同一条件の検索は30分間再利用し、browser検索は1並列・原則15秒以上の間隔を空ける。

  保守性                              Railsの標準的な設定・Minitest・サービスクラス構成を用い、既存Rails資産と作法を揃える。

  拡張性                              将来、検索履歴DB、ドメイン評価、reranker、管理UIを追加できる境界を維持する。

  説明可能性                          各応答にcache status、source、generated_at、warningsを含める。
  ----------------------------------------------------------------------------------------------------------------------------------

# 2. 要求事項

## 2.1 機能要件

  ----------------------------------------------------------------------------------------------------------------------------
  **ID**                  **名称**                **要件**
  ----------------------- ----------------------- ----------------------------------------------------------------------------
  FR-01                   検索API                 日本語を含む検索クエリを受け付け、統一形式の結果を返す。

  FR-02                   キャッシュ              検索条件を正規化してRedisに保存し、fresh期間は外部検索を行わない。

  FR-03                   同一要求集約            同じcache keyの同時MISSは1回だけ外部取得し、他の要求は結果を待つ。

  FR-04                   通常検索                SearXNGを同期呼び出しし、十分な結果が得られれば即時返却する。

  FR-05                   フォールバック          結果不足、429、CAPTCHA、全エンジン失敗時にBrowserSearchJobを投入する。

  FR-06                   stale応答               直近の正常結果があれば、stale結果を返しつつバックグラウンド更新する。

  FR-07                   非同期取得              利用可能な結果がない場合、202
                                                  Acceptedとrequest_idを返し、後から状態照会できる。

  FR-08                   エンジン停止            429・CAPTCHA等を検出し、エンジン別のsuspended状態と期限をRedisに保持する。

  FR-09                   管理・診断              health、readiness、engine status、cache bypassを内部向けに提供する。

  FR-10                   監査情報                request_id、cache
                                                  hit、upstream、所要時間、結果件数、警告を構造化ログへ記録する。
  ----------------------------------------------------------------------------------------------------------------------------

## 2.2 非機能要件

  --------------------------------------------------------------------------------------------------------------------------------
  **ID**                  **観点**                **要件**
  ----------------------- ----------------------- --------------------------------------------------------------------------------
  NFR-01                  可用性                  RedisまたはSearXNGの一時障害時、可能ならstaleを返す。致命障害は503で明示する。

  NFR-02                  性能                    fresh cache hitのサーバ処理p95を100ms未満の目標とする。

  NFR-03                  制御性                  browser検索は並列1、最低間隔15秒を初期値とし、環境変数で変更可能にする。

  NFR-04                  セキュリティ            LAN内運用でもBearer tokenまたはリバースプロキシ認証を適用する。

  NFR-05                  データ最小化            クエリ本文をログへ常時出さず、既定ではquery_digestと文字数のみ記録する。

  NFR-06                  可観測性                JSONログ、Prometheus互換メトリクス、Sidekiqキュー監視を提供する。

  NFR-07                  テスト容易性            外部HTTPとBrowser Workerを差し替え可能にし、WebMock等で決定的テストを行う。
  --------------------------------------------------------------------------------------------------------------------------------

## 2.3 初期スコープ外

-   CAPTCHA自動解決、ステルス・bot回避機能の実装。

-   一般公開型の高トラフィック検索API。

-   検索履歴の長期保存・ユーザー別課金・利用分析用PostgreSQL。

-   検索結果本文の全文取得、Readabilityによる本文抽出、RAG登録。これらは既存fetch_url/RAG層の責務とする。

-   LLMによる検索結果reranking。初期版は決定的なルールで統合する。

# 3. 設計方針

  ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  **決定**                **採用方針**             **理由**
  ----------------------- ------------------------ ---------------------------------------------------------------------------------------------------------------------------------
  アプリ基盤              Rails API-only           既存Railsアプリとテスト・設定・運用作法を統一し、将来の管理API拡張にも対応する。API-only構成はJSON
                                                   API向けの軽量構成を提供する。\[R1\]

  永続DB                  初期は使用しない         キャッシュ・実行状態はTTL付きRedisで完結する。履歴や評価データが必要になった時点でPostgreSQLを追加する。

  非同期処理              Sidekiq                  Browser検索、stale再取得、低速処理をWebプロセスから分離する。Sidekiqはジョブと運用データをRedisに保持する。\[R2\]

  headless実行            Node.js/TypeScript       Rails側にブラウザDOM依存を持たせず、検索エンジン別DOM解析を独立させる。BrowserlessはPlaywrightのWebSocket接続を提供する。\[R4\]
                          Playwright + Browserless 

  通常経路                SearXNG同期呼び出し      高速で複数エンジンを集約できる既存資産を継続利用する。

  キャッシュ方式          cache-aside +            freshは即返却、staleは応答継続と再取得を両立する。
                          stale-while-revalidate   

  同時取得制御            Redis SET NX PX          同じcache keyのロードを1つに集約し、期限付きロックでクラッシュ時の残留を防ぐ。\[R3\]
  ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

  -----------------------------------------------------------------------
  **重要** headlessブラウザはCAPTCHA回避装置ではない。CAPTCHAやAccess
  Deniedを検出した場合は結果として扱わず、エンジンを一定時間停止する。
  -----------------------------------------------------------------------

  -----------------------------------------------------------------------

# 4. システムアーキテクチャ

![](media/image1.png){width="6.6141732283464565in"
height="3.5351038932633423in"}

図1 searfront論理アーキテクチャ

## 4.1 コンポーネント一覧

  -----------------------------------------------------------------------------------------------------------------------
  **コンポーネント**      **実装**                **責務**
  ----------------------- ----------------------- -----------------------------------------------------------------------
  searfront Web           Rails API-only          認証、入力検証、正規化、cache判定、SearXNG同期検索、結果統合、応答。

  searfront Worker        Sidekiq                 BrowserSearchJob、CacheRefreshJob、エンジン間隔制御、結果保存。

  Redis                   共有状態                検索結果、stale、single-flight lock、request status、engine
                                                  suspension、Sidekiq。

  SearXNG                 既存サービス            通常のメタ検索経路。searfrontからJSON APIを呼び出す。

  Browser Worker          Node.js/TypeScript      検索エンジンページをPlaywrightで操作し、結果DOMを統一JSONへ変換する。

  Browserless             headless基盤            Chromiumセッション、WebSocket、同時実行制限、ヘルスチェック。

  クライアント            呼出元                  既存Rails、ローカルAI
                                                  Agent、テストツール。searfront以外から検索エンジンを直接呼ばない。
  -----------------------------------------------------------------------------------------------------------------------

## 4.2 配置方針

-   searfront WebとWorkerは同一コードベース・別プロセスとして起動する。

-   Redisは初期は1インスタンスでよいが、検索結果キーとSidekiqキーは名前空間・URLを分離できる設定にする。

-   Browser WorkerとBrowserlessはsearfrontと同じDocker
    network上に配置し、外部公開しない。

-   クライアントはSearXNGを直接呼ばず、すべてsearfront経由に移行する。

-   SearXNG自体のエンジン停止機能は残し、searfront側でも上位のサーキットブレーカーを持つ。

# 5. 検索処理フロー

![](media/image2.png){width="6.6141732283464565in"
height="3.931408573928259in"}

図2 検索要求の標準フロー

## 5.1 fresh cache hit

> **1.** 要求を検証し、検索条件を正規化する。
>
> **2.** cache keyを生成し、fresh結果を取得する。
>
> **3.** 結果が存在すれば外部通信を行わず、200 OKで返却する。
>
> **4.** 応答にはcache.status =
> \"fresh\"、age_seconds、generated_atを含める。

## 5.2 cache miss + SearXNG成功

> **1.** single-flight
> lockを取得する。取得できない要求は短時間pollし、先行要求の保存結果を待つ。
>
> **2.** SearXNGへ同期検索を行う。
>
> **3.** 結果件数、エラー、CAPTCHA/429情報を評価する。
>
> **4.** 十分な結果があれば正規化・重複排除してRedisへ保存し、200
> OKを返す。
>
> **5.** ロックは所有トークンを確認して解放する。

## 5.3 結果不足 + staleあり

> **1.** fresh結果はないがstale TTL内の正常結果を取得する。
>
> **2.** 200 OKでstale結果を返し、warningsに鮮度情報を付ける。
>
> **3.**
> 同時にCacheRefreshJobまたはBrowserSearchJobを重複なしで投入する。
>
> **4.** クライアントは待たずに処理を継続できる。

## 5.4 結果不足 + staleなし

> **1.** BrowserSearchJobを投入し、request_idを発行する。
>
> **2.** wait_secondsが指定されている場合だけ、上限までRedisのrequest
> resultを待つ。
>
> **3.** 完了すれば200、未完了なら202 Acceptedを返す。
>
> **4.** クライアントはGET /v1/search_requests/{request_id}で取得する。

## 5.5 CAPTCHA・429時

> **1.** CAPTCHA、429、Access
> Deniedのレスポンスを通常結果として保存しない。
>
> **2.** engine stateをsuspendedへ変更し、reasonとresume_atを保存する。
>
> **3.** staleがあればstaleを返す。なければ別経路または202/503とする。
>
> **4.** 同一エンジンへの即時再試行は行わない。

# 6. API設計

## 6.1 API共通仕様

  -------------------------------------------------------------------------------------------------------
  **項目**                            **仕様**
  ----------------------------------- -------------------------------------------------------------------
  Base path                           /v1

  Content-Type                        application/json; charset=utf-8

  認証                                Authorization: Bearer
                                      \<token\>（初期）。将来mTLSまたはリバースプロキシ認証へ変更可能。

  Request ID                          X-Request-IDを受け入れ、未指定時はsearfrontが生成する。

  時刻                                ISO 8601 / UTCで返却。ログではUTC、表示側でAsia/Tokyoへ変換する。

  文字コード                          UTF-8。queryはUnicode NFKC正規化を行う。

  エラー形式                          error.code、error.message、retryable、request_idを統一する。
  -------------------------------------------------------------------------------------------------------

## 6.2 GET /v1/search

  -------------------------------------------------------------------------------------------------
  **パラメータ**   **型**         **必須**       **初期値**     **説明**
  ---------------- -------------- -------------- -------------- -----------------------------------
  q                string         Yes            \-             検索クエリ。1〜500文字。

  language         string         No             ja-JP          検索言語・ロケール。

  limit            integer        No             10             返却件数。1〜20。

  categories       string\[\]     No             general        SearXNGカテゴリ。

  time_range       string         No             null           day / week / month / year。

  mode             string         No             auto           auto / cache / searxng /
                                                                browser。browserは管理権限のみ。

  refresh          boolean        No             false          trueならfresh
                                                                cacheを無視。ただし同時実行・rate
                                                                limitは維持。

  wait_seconds     integer        No             0              browser
                                                                jobを同期的に待つ秒数。0〜30。
  -------------------------------------------------------------------------------------------------

### 6.3 200応答例

{\
\"request_id\": \"01J\...\",\
\"status\": \"completed\",\
\"query\": \"llama.cpp Vulkan\",\
\"normalized_query\": \"llama.cpp Vulkan\",\
\"cache\": {\
\"status\": \"fresh\",\
\"age_seconds\": 82,\
\"generated_at\": \"2026-07-15T00:10:00Z\"\
},\
\"sources\": \[\"searxng\"\],\
\"results\": \[\
{\
\"title\": \"llama.cpp\",\
\"url\": \"https://example.org/llama.cpp\",\
\"canonical_url\": \"https://example.org/llama.cpp\",\
\"snippet\": \"\...\",\
\"engines\": \[\"google\"\],\
\"rank\": 1,\
\"published_at\": null\
}\
\],\
\"warnings\": \[\],\
\"timing_ms\": { \"total\": 34, \"cache\": 3 }\
}

### 6.4 202応答例

{\
\"request_id\": \"01J\...\",\
\"status\": \"pending\",\
\"poll_after_seconds\": 3,\
\"expires_at\": \"2026-07-15T00:12:00Z\",\
\"warnings\": \[\"browser_fallback_queued\"\]\
}

## 6.5 GET /v1/search_requests/{request_id}

-   pending: 202。poll_after_secondsを返す。

-   completed: 200。GET /v1/searchと同じ結果形式を返す。

-   failed: 502または503。失敗理由とretryableを返す。

-   expired / unknown: 404。request status TTL経過後は取得不可。

## 6.6 診断API

  ------------------------------------------------------------------------------------------------------------
  **Endpoint**                **用途**                                                 **公開範囲**
  --------------------------- -------------------------------------------------------- -----------------------
  GET /healthz                Railsプロセスが応答可能か。依存サービスは確認しない。    内部

  GET /readyz                 Redis、SearXNG、Sidekiqキュー投入可否を確認。            内部

  GET /v1/engines             各エンジンのhealthy/suspended、resume_at、直近エラー。   管理

  POST                        手動で停止状態を解除。                                   管理
  /v1/engines/{name}/resume                                                            

  DELETE /v1/cache            条件付きキャッシュ削除。全削除は禁止または管理専用。     管理

  GET /metrics                Prometheus互換メトリクス。                               内部
  ------------------------------------------------------------------------------------------------------------

## 6.7 HTTPステータス

  ---------------------------------------------------------------------------------------------------------------------
  **Status**                          **意味**
  ----------------------------------- ---------------------------------------------------------------------------------
  200                                 fresh/stale/新規検索結果を返却。

  202                                 BrowserSearchJobが進行中で、まだ利用可能な結果がない。

  400                                 入力不正。

  401/403                             認証失敗または管理権限不足。

  404                                 request_id不明または期限切れ。

  409                                 refresh強制要求が既存処理と競合した場合（原則は既存処理を返すため使用を限定）。

  429                                 searfront利用者側のレート制限。検索エンジンの429とは区別する。

  502                                 上流検索が失敗し、staleもない。再試行可能な場合を含む。

  503                                 Redis等の必須依存が利用不能。
  ---------------------------------------------------------------------------------------------------------------------

# 7. Redis設計

## 7.1 用途分離

  -------------------------------------------------------------------------------------------------------------------------------
  **用途**                **推奨URL/名前空間**        **備考**
  ----------------------- --------------------------- ---------------------------------------------------------------------------
  検索キャッシュ          SEARFRONT_CACHE_REDIS_URL / 容量上限・evictionを設定できる独立用途。
                          searfront:cache:\*          

  制御状態                SEARFRONT_STATE_REDIS_URL / lock、engine state、request status。原則noeviction。
                          searfront:state:\*          

  Sidekiq                 SIDEKIQ_REDIS_URL /         Sidekiq専用。ジョブデータを検索キャッシュのevictionに巻き込まない。\[R2\]
                          sidekiq:\*                  
  -------------------------------------------------------------------------------------------------------------------------------

  ------------------------------------------------------------------------------------------------------------------
  **初期構成**
  1つのRedisコンテナでもよいが、URLとnamespaceを分ける。運用が安定したらSidekiq用とcache用をインスタンス分離する。
  ------------------------------------------------------------------------------------------------------------------

  ------------------------------------------------------------------------------------------------------------------

## 7.2 キー設計

  ---------------------------------------------------------------------------------------------------------------------
  **Key pattern**                                 **用途**                **内容**
  ----------------------------------------------- ----------------------- ---------------------------------------------
  searfront:cache:v1:result:\<digest\>            検索結果payload         fresh TTL後もstale
                                                                          TTLまで保持。payload内にfresh_untilを持つ。

  searfront:state:v1:lock:\<digest\>              single-flight lock      SET NX PX。値は所有者token。

  searfront:state:v1:request:\<request_id\>       非同期request状態       pending/completed/failedとresult cache key。

  searfront:state:v1:engine:\<engine\>            エンジン状態            status、reason、resume_at、failure_count。

  searfront:state:v1:last_run:\<engine\>          最終browser実行時刻     最低実行間隔を保証。

  searfront:state:v1:rate:\<client\>:\<window\>   クライアント制限        Rack::Attackまたは独自カウンター。
  ---------------------------------------------------------------------------------------------------------------------

## 7.3 Cache key canonical payload

{\
\"version\": 1,\
\"query\": \"llama.cpp Vulkan\",\
\"language\": \"ja-JP\",\
\"limit\": 10,\
\"categories\": \[\"general\"\],\
\"time_range\": null,\
\"safe_search\": 0,\
\"mode_scope\": \"auto\"\
}\
\
cache_key = \"searfront:cache:v1:result:\" + SHA256(canonical_json)

-   JSON
    keyは固定順序で生成する。配列項目のうち順序が意味を持たないcategories等はソートする。

-   query内の語順は保持する。全角/半角・空白のみNFKCと連続空白圧縮で正規化する。

-   キャッシュ形式変更時はv1をv2へ上げ、既存キーを一括削除しない。

## 7.4 TTL初期値

  ----------------------------------------------------------------------------------------------------------------
  **対象**                **TTL**                 **方針**
  ----------------------- ----------------------- ----------------------------------------------------------------
  正常結果 fresh          30分                    同一テスト検索の再利用を優先。

  正常結果 stale          12時間                  外部障害時の継続利用。ニュース等はtime_rangeに応じて短縮可能。

  0件結果                 3分                     誤った長期negative cacheを避ける。

  single-flight lock      45秒                    SearXNG同期処理の上限より少し長くする。

  request status          10分                    poll完了後に自動削除。

  429 suspension          2時間                   即時再試行を避ける。

  CAPTCHA suspension      24時間                  同一IPからの反復を避ける。

  Access Denied           24時間                  手動確認まで長めに停止。
  suspension                                      
  ----------------------------------------------------------------------------------------------------------------

## 7.5 single-flight lock

ロック取得にはRedisのSETコマンドへNXとPXを指定し、値に一意の所有者tokenを保存する。Redis公式のロックパターンに従い、解放時はLuaスクリプト等でtoken一致を確認してから削除する。\[R3\]

SET searfront:state:v1:lock:\<digest\> \<token\> NX PX 45000\
\
\-- release.lua\
if redis.call(\"GET\", KEYS\[1\]) == ARGV\[1\] then\
return redis.call(\"DEL\", KEYS\[1\])\
else\
return 0\
end

-   ロックを取得できない要求は250ms〜500msのjitter付きpollを行う。

-   待機上限を超えた場合はstaleを返すか、202へ移行する。

-   ロック中でもrefresh=trueによる並列外部検索は許可しない。

# 8. Sidekiq設計

## 8.1 キュー構成

  -------------------------------------------------------------------------------------------------------------
  **Queue**         **Concurrency**   **用途**                                                **優先度**
  ----------------- ----------------- ------------------------------------------------------- -----------------
  browser_search    1                 Playwright検索。エンジンへの最低間隔を保証。            最高

  cache_refresh     1〜2              stale結果の再取得。browser_searchへ移譲する場合あり。   中

  maintenance       1                 状態修復、メトリクス集計、期限確認等。                  低
  -------------------------------------------------------------------------------------------------------------

  -----------------------------------------------------------------------
  **推奨** browser_search専用Sidekiqプロセスを別起動し、-c
  1で直列化する。Web用の汎用worker
  concurrencyを上げても、headless検索の並列度は上げない。
  -----------------------------------------------------------------------

  -----------------------------------------------------------------------

## 8.2 Job一覧

  --------------------------------------------------------------------------------------------------------------------------
  **Job**                 **引数**                **責務**
  ----------------------- ----------------------- --------------------------------------------------------------------------
  BrowserSearchJob        request_id,             Browser Workerを呼び、成功結果を保存。CAPTCHA/429時はengine
                          canonical_params,       suspensionを更新。
                          cache_key               

  CacheRefreshJob         canonical_params,       stale
                          cache_key               cacheの再取得を開始。SearXNG成功なら保存、失敗時はBrowserSearchJobへ。

  EngineProbeJob          engine                  suspension期限後のhalf-open確認。低頻度・明示的に実行。

  StateRepairJob          \-                      古いpending状態、異常なlock、メトリクス補助状態を点検。通常はTTLで不要。
  --------------------------------------------------------------------------------------------------------------------------

## 8.3 Jobの冪等性

-   Job引数はJSONで表現可能な文字列、数値、配列、Hashだけを使用する。

-   cache_keyとrequest_idを冪等性キーとし、実行開始時に既存のcompleted/fresh結果を再確認する。

-   同じcache keyのBrowserSearchJobは重複投入を防ぐ。初期はRedis SET
    NXで実装し、必要に応じてsidekiq-unique-jobsを採用する。

-   結果保存はSETによる置換とし、部分更新で壊れたpayloadを残さない。

-   Workerがタイムアウトしても、Browser Worker側のrequest
    idで重複セッションを判別できる契約を用意する。

## 8.4 retry方針

  ----------------------------------------------------------------------------------------------------------------
  **失敗種別**            **Sidekiq retry**       **動作**
  ----------------------- ----------------------- ----------------------------------------------------------------
  接続タイムアウト        最大2回                 指数バックオフ。staleがあればクライアントにはstaleを維持。

  Browser Worker 5xx      1〜2回                  短時間の基盤障害のみ再試行。

  429                     0回                     engineを2時間停止。

  CAPTCHA / Access Denied 0回                     engineを24時間停止。

  DOM解析失敗             0〜1回                  HTMLスナップショット/診断情報を保存し、adapter修正対象とする。

  入力不正                0回                     failedとして終了。
  ----------------------------------------------------------------------------------------------------------------

## 8.5 Browser Worker契約

POST /v1/search\
Authorization: Bearer \<internal-token\>\
\
{\
\"request_id\": \"01J\...\",\
\"engine\": \"google\",\
\"query\": \"llama.cpp Vulkan\",\
\"language\": \"ja-JP\",\
\"limit\": 10,\
\"timeout_ms\": 30000\
}

{\
\"status\": \"ok\",\
\"engine\": \"google\",\
\"results\": \[ \... \],\
\"diagnostics\": {\
\"captcha\": false,\
\"rate_limited\": false,\
\"page_title\": \"\...\",\
\"duration_ms\": 8420\
}\
}

-   Browser WorkerはBrowserlessへPlaywright
    WebSocket接続する。BrowserlessはPlaywright接続を提供する。\[R4\]

-   画像、動画、フォント等の不要リソースは遮断し、検索結果ページの1ページ目だけ取得する。

-   Cookie/セッションはエンジン別に保持可能とするが、CAPTCHA突破を目的にしない。

-   HTML構造変更に備え、engine adapterを分離し、DOM
    selectorと判定ロジックをテストする。

# 9. 検索結果処理

## 9.1 クエリ正規化

> **1.** UTF-8文字列として受け付ける。
>
> **2.** Unicode NFKC正規化を行う。
>
> **3.** 全角空白を含む連続空白をASCII空白1個へ圧縮し、前後をtrimする。
>
> **4.**
> 語順と大文字小文字は保持する。コード・モデル名の意図を壊さないため、初期版ではdowncaseしない。
>
> **5.** language、categories、time_range等を許可リストで正規化する。

## 9.2 URL canonicalization

-   fragment（#\...）を除去する。

-   hostを小文字化し、既定ポートを除去する。

-   utm\_\*、fbclid、gclid等の既知トラッキングパラメータを除去する。

-   クエリパラメータの順序を安定化する。ただしサイト固有の意味が疑われる場合は原URLを保持する。

-   canonical_urlで重複排除し、元URLはurlとして残す。

## 9.3 統合・順位

  -------------------------------------------------------------------------------------------------------
  **処理**                            **ルール**
  ----------------------------------- -------------------------------------------------------------------
  重複排除                            canonical_url一致を同一結果とする。

  engine統合                          engines配列へ取得元を追加する。

  タイトル                            空でない最上位ソースを優先。極端に短い/長いタイトルは避ける。

  snippet                             情報量が多くHTML除去済みのsnippetを採用する。最大1,000文字。

  順位                                各ソースの順位をreciprocal
                                      rankで合成し、同点時は複数engine一致を優先する。

  ドメイン多様性                      同一ドメインの結果は上位で最大2件を目安にし、残りは順位を下げる。

  安全性                              javascript:、data:、file:、localhost/private
                                      IP等のURLを除外または内部設定で許可する。
  -------------------------------------------------------------------------------------------------------

## 9.4 結果payload

  ---------------------------------------------------------------------------------------------------------------------
  **Field**               **型**                  **説明**
  ----------------------- ----------------------- ---------------------------------------------------------------------
  title                   string                  表示タイトル。

  url                     string                  取得元が返した代表URL。

  canonical_url           string                  重複排除用URL。

  snippet                 string                  HTML除去済み概要。

  engines                 string\[\]              取得元エンジン。

  source                  string                  searxng / browser。

  rank                    integer                 統合後順位。

  published_at            datetime\|null          取得できた場合のみ。推測しない。

  metadata                object                  thumbnail等の任意追加情報。クライアントは未知フィールドを無視する。
  ---------------------------------------------------------------------------------------------------------------------

# 10. 障害制御・レート制御

## 10.1 エンジン状態機械

  ----------------------------------------------------------------------------------------------------
  **状態**                **説明**                      **遷移**
  ----------------------- ----------------------------- ----------------------------------------------
  healthy                 通常利用可能。                429/CAPTCHA/Access Deniedでsuspended。

  suspended               resume_atまで呼び出さない。   期限到達でhalf_open。管理APIで手動解除可能。

  half_open               1回だけ試験検索を許可。       成功でhealthy、失敗で再度suspended。

  disabled                設定で無効。                  設定変更まで使用しない。
  ----------------------------------------------------------------------------------------------------

## 10.2 Browser検索間隔

> **1.** browser_search queue自体をconcurrency=1にする。
>
> **2.** Redisのlast_run:\<engine\>を確認する。
>
> **3.** 前回実行から15秒未満なら、必要時間だけsleepする。
>
> **4.** 0〜5秒のjitterを加え、機械的な一定間隔を避ける。
>
> **5.** 同一hostで複数Workerを起動しても、engine
> lockにより1実行だけ許可する。

## 10.3 タイムアウト

  ----------------------------------------------------------------------------------
  **対象**                **初期値**              **備考**
  ----------------------- ----------------------- ----------------------------------
  SearXNG connect         2秒                     LAN内を想定。

  SearXNG total           12秒                    タイムアウト時はstale/fallback。

  Browser Worker connect  3秒                     内部ネットワーク。

  Browser search total    35秒                    ページ遷移30秒＋処理。

  API wait_seconds        最大30秒                Web worker占有を制限。通常は0。

  single-flight wait      最大15秒                超過後はstale/202。
  ----------------------------------------------------------------------------------

## 10.4 クライアントレート制限

-   Bearer token単位または送信元IP単位で制限する。

-   初期値は60 requests/minute/tokenを目安とし、cache
    hitも含めて暴走を防ぐ。

-   browser強制モードとrefresh=trueはより厳しい制限を設定する。

-   ローカルAIのtool
    loop対策として、同一request_idまたは同一queryの短時間反復をログで検知する。

# 11. セキュリティ

## 11.1 認証・認可

-   初期は環境変数で管理する複数Bearer
    tokenを許可し、tokenごとにroleを持たせる。

-   roleはsearch、adminを定義する。mode=browser、refresh、engine操作はadminのみ。

-   token本体はログへ出さず、token idまたはdigestのみ記録する。

-   外部公開する場合はTLS終端、IP制限、mTLSまたはOAuth2
    proxyを追加する。

## 11.2 SSRF・URL安全性

-   searfrontがアクセスするupstream URLは設定済みSearXNGとBrowser
    Workerだけに固定する。

-   検索結果URLをsearfront自身がfetchしない。本文取得は別のfetch_urlサービスでSSRF対策を行う。

-   管理APIから任意upstream URLを指定できる機能は作らない。

## 11.3 ログ・プライバシー

-   通常ログはquery_digest、query_length、language、結果件数のみを記録する。

-   デバッグ時のquery本文記録は明示的設定かつ短期間に限定する。

-   Browser
    WorkerのHTML保存はDOM解析失敗時だけとし、保存期間とアクセス権を限定する。

-   検索結果キャッシュに認証情報、Cookie、ブラウザstorageを含めない。

# 12. 監視・ログ

## 12.1 構造化ログ

{\
\"event\": \"search.completed\",\
\"request_id\": \"01J\...\",\
\"query_digest\": \"sha256:\...\",\
\"cache_status\": \"fresh\",\
\"source\": \"searxng\",\
\"result_count\": 10,\
\"duration_ms\": 34,\
\"warnings\": \[\]\
}

-   RailsのActiveSupport::Notificationsでsearch.request、cache.lookup、upstream.searxng、job.browser等を計測する。

-   WebとWorkerで同じrequest_id、cache_key_digestを引き継ぐ。

-   エラーは例外クラス、upstream status、retryable、engine
    stateを記録する。

## 12.2 メトリクス

  --------------------------------------------------------------------------------------------------------------
  **Metric**                            **Type**                **説明**
  ------------------------------------- ----------------------- ------------------------------------------------
  searfront_requests_total              counter                 status、mode、cache_status別のAPI件数。

  searfront_request_duration_seconds    histogram               API総所要時間。

  searfront_cache_hits_total            counter                 fresh/stale/miss別。

  searfront_upstream_duration_seconds   histogram               searxng/browser別。

  searfront_upstream_errors_total       counter                 engine、error_type別。

  searfront_browser_jobs_total          counter                 queued/succeeded/failed/captcha/rate_limited。

  searfront_engine_suspended            gauge                   engineごとの停止状態。

  sidekiq_queue_latency_seconds         gauge                   browser_search等の待ち時間。
  --------------------------------------------------------------------------------------------------------------

## 12.3 アラート目安

-   CAPTCHAまたは429が1時間に3回以上。

-   browser_search queue latencyが5分超。

-   fresh cache hit率が50%未満（テスト環境を除く）。

-   Redis接続エラー、Sidekiq dead job発生、readyz失敗。

-   SearXNG p95が10秒超またはエラー率20%超。

# 13. デプロイ・設定

## 13.1 プロセス構成

  --------------------------------------------------------------------------------------------------
  **Service**                **Command例**                **役割**
  -------------------------- ---------------------------- ------------------------------------------
  searfront-web              bundle exec puma -C          HTTP API。
                             config/puma.rb               

  searfront-browser-worker   bundle exec sidekiq -C       browser_search専用、concurrency 1。
                             config/sidekiq_browser.yml   

  searfront-worker           bundle exec sidekiq -C       cache_refresh、maintenance。
                             config/sidekiq.yml           

  redis                      redis-server                 cache/state/Sidekiq。初期は1コンテナ可。

  browser-worker             node dist/server.js          Playwright検索アダプター。

  browserless                Browserless Docker image     Chromium実行基盤。

  searxng                    既存コンテナ                 通常検索。
  --------------------------------------------------------------------------------------------------

## 13.2 rails new

rails new searfront \\\
\--api \\\
\--skip-active-record \\\
\--skip-active-storage \\\
\--skip-action-mailbox \\\
\--skip-action-text

-   実装時のRailsバージョンで rails new \--help
    を確認し、不要な生成機能を追加でskipする。

-   初期Gem候補:
    sidekiq、redis、faraday、faraday-retry、rack-attack、prometheus-client、webmock。

## 13.3 主要環境変数

  -------------------------------------------------------------------------------------
  **Variable**                   **区分**                **説明/初期値**
  ------------------------------ ----------------------- ------------------------------
  SEARFRONT_API_TOKENS           必須                    token idとsecret/role。secret
                                                         manager利用を推奨。

  SEARXNG_BASE_URL               必須                    例: http://searxng:8080。

  BROWSER_WORKER_BASE_URL        必須                    例:
                                                         http://browser-worker:3000。

  CACHE_REDIS_URL                必須                    検索結果キャッシュ。

  STATE_REDIS_URL                必須                    lock、engine、request state。

  SIDEKIQ_REDIS_URL              必須                    Sidekiq。

  SEARCH_RESULT_TTL_SECONDS      任意                    1800。

  SEARCH_STALE_TTL_SECONDS       任意                    43200。

  BROWSER_MIN_INTERVAL_SECONDS   任意                    15。

  BROWSER_JITTER_SECONDS         任意                    5。

  CAPTCHA_SUSPEND_SECONDS        任意                    86400。

  RATE_LIMIT_SUSPEND_SECONDS     任意                    7200。

  LOG_QUERY_TEXT                 任意                    false。
  -------------------------------------------------------------------------------------

## 13.4 Docker network

-   公開ポートはsearfrontのHTTPのみ。Redis、SearXNG、Browser
    Worker、Browserlessは内部networkへ置く。

-   Browserlessには十分な/dev/shmを割り当てる。

-   WebとWorkerに同じコードイメージを利用し、commandだけ変更する。

-   Redis永続化はSidekiq/state用で有効化し、cache用は容量・eviction方針を別設定可能にする。

# 14. Railsプロジェクト構成

searfront/\
├── app/\
│ ├── controllers/\
│ │ ├── application_controller.rb\
│ │ └── v1/\
│ │ ├── searches_controller.rb\
│ │ ├── search_requests_controller.rb\
│ │ ├── engines_controller.rb\
│ │ └── health_controller.rb\
│ ├── jobs/\
│ │ ├── browser_search_job.rb\
│ │ ├── cache_refresh_job.rb\
│ │ └── engine_probe_job.rb\
│ └── services/searfront/\
│ ├── search.rb\
│ ├── request.rb\
│ ├── response.rb\
│ ├── query_normalizer.rb\
│ ├── cache_key.rb\
│ ├── result_cache.rb\
│ ├── single_flight.rb\
│ ├── circuit_breaker.rb\
│ ├── rate_limiter.rb\
│ ├── result_merger.rb\
│ ├── url_canonicalizer.rb\
│ └── clients/\
│ ├── searxng_client.rb\
│ └── browser_worker_client.rb\
├── config/\
│ ├── initializers/redis.rb\
│ ├── initializers/sidekiq.rb\
│ ├── initializers/rack_attack.rb\
│ ├── sidekiq.yml\
│ └── sidekiq_browser.yml\
├── test/\
│ ├── controllers/\
│ ├── jobs/\
│ ├── services/\
│ ├── fixtures/upstream/\
│ └── support/\
└── docs/\
├── api.md\
└── operations.md

## 14.1 責務境界

  -----------------------------------------------------------------------------------------------------------
  **層**                  **責務**                                       **禁止事項**
  ----------------------- ---------------------------------------------- ------------------------------------
  Controller              HTTP変換、認証、params、status/render。        RedisやFaradayを直接呼ばない。

  Search service          検索ユースケース全体のオーケストレーション。   DOM解析やHTTP詳細を持たない。

  Client                  SearXNG/Browser                                cacheや業務判断を持たない。
                          Workerの通信、timeout、レスポンス変換。        

  Cache/State             Redis keyとserialization、TTL、lock。          Controller依存を持たない。

  Job                     非同期境界、冪等性確認、service呼出し。        複雑な統合ロジックを直接書かない。
  -----------------------------------------------------------------------------------------------------------

## 14.2 例外クラス案

Searfront::Error\
├── ValidationError\
├── AuthenticationError\
├── CacheUnavailableError\
├── UpstreamError\
│ ├── SearxngError\
│ └── BrowserWorkerError\
├── RateLimitedError\
├── CaptchaDetectedError\
├── AccessDeniedError\
└── PendingTimeoutError

# 15. テスト計画

## 15.1 単体テスト

  ---------------------------------------------------------------------------------------------------
  **対象**                            **テスト**
  ----------------------------------- ---------------------------------------------------------------
  QueryNormalizer                     日本語、全角空白、NFKC、長さ制限、語順保持。

  CacheKey                            Hash順序、categories順序、version変更、同一条件のdigest一致。

  UrlCanonicalizer                    fragment、tracking parameter、host/port、危険scheme。

  ResultMerger                        重複、複数engine、順位、同一ドメイン抑制。

  CircuitBreaker                      healthy→suspended→half_open→healthy。

  SingleFlight                        lock取得、待機、期限切れ、token不一致解放。
  ---------------------------------------------------------------------------------------------------

## 15.2 統合テスト

-   fresh cache hitではSearXNG/Browser Workerを呼ばない。

-   同一MISSを並行実行してもSearXNG呼出しが1回になる。

-   SearXNG成功時に結果が保存され、次回はfresh hitになる。

-   SearXNG 429 + staleありでstale応答し、engineがsuspendedになる。

-   結果不足 + staleなしで202とrequest_idを返し、Job完了後に200になる。

-   CAPTCHAレスポンスを結果キャッシュへ保存しない。

-   Redis cache障害時のfail-open/fail-closed方針が期待どおりである。

-   Bearer token roleによりbrowser強制・管理APIが制御される。

## 15.3 E2E・負荷テスト

-   Docker Compose上でsearfront、Redis、stub SearXNG、stub Browser
    Workerを起動する。

-   同一検索を100回実行し、外部検索回数が1回またはTTL単位に抑えられることを確認する。

-   10並列同一クエリでsingle-flightが機能することを確認する。

-   異なるクエリを連続投入し、browser_searchが15秒以上の間隔で1件ずつ実行されることを確認する。

-   Redis再起動、SearXNG停止、Browser
    Worker停止、Sidekiq再起動の回復試験を行う。

## 15.4 外部ページ依存テスト

-   実検索エンジンに対するCIテストは行わない。HTML
    fixtureでadapterをテストする。

-   手動または低頻度scheduled smoke
    testだけを本物の検索ページへ実行する。

-   DOM変更検出時はfixtureを追加し、selector修正をレビュー可能にする。

# 16. 実装フェーズと受入条件

  ---------------------------------------------------------------------------------------------------------------------------------------------------------
  **フェーズ**            **実装内容**                                                 **完了条件**
  ----------------------- ------------------------------------------------------------ --------------------------------------------------------------------
  Phase 1: 基盤           Rails API-only生成、認証、healthz、Redis接続、構造化ログ。   healthz/readyzが動作し、MinitestとCIが通る。

  Phase 2: SearXNG +      正規化、cache key、fresh/stale、single-flight、結果統合。    同一検索100回で外部呼出し1回。10並列でも1回。
  cache                                                                                

  Phase 3: Sidekiq        request status、BrowserSearchJob、Browser Worker             結果不足時に202またはstale応答し、browser検索が並列1で動作。
  fallback                API、interval/circuit breaker。                              

  Phase 4: 運用強化       metrics、engine管理API、Rack::Attack、アラート、障害試験。   主要障害シナリオとセキュリティ試験を合格。

  Phase 5: 移行           既存Rails/AI AgentのSearXNG URLをsearfrontへ変更。           直接SearXNG呼出しを停止し、キャッシュヒット率とCAPTCHA回数を計測。
  ---------------------------------------------------------------------------------------------------------------------------------------------------------

## 16.1 初期リリース受入条件

-   GET /v1/searchが日本語クエリで正常応答する。

-   同一検索条件は30分間キャッシュされる。

-   同時MISSがsingle-flightで1回に集約される。

-   SearXNGが失敗してもstaleがあれば200で返せる。

-   BrowserSearchJobがSidekiq専用queueで直列実行される。

-   CAPTCHA/429を検出したエンジンへ即時再試行しない。

-   202 requestをpollして完了結果を取得できる。

-   query本文を含めない構造化ログと基本メトリクスを出力できる。

-   Redis/SearXNG/Browser Worker停止時の挙動を自動テストで確認する。

# 17. リスクと未決事項

## 17.1 主なリスク

  -----------------------------------------------------------------------------------------------------------------------------------
  **リスク**              **影響**                                 **対策**
  ----------------------- ---------------------------------------- ------------------------------------------------------------------
  検索エンジンDOM変更     Browser Worker adapterが壊れる。         fixtureテスト、エンジン別adapter、失敗時suspend。

  IP単位ブロック          headless化してもCAPTCHAが続く。          低頻度、キャッシュ、複数エンジン、利用規約順守。突破は行わない。

  Redis単一障害点         cache/state/Sidekiqが同時に影響。        用途分離、永続化、health、バックアップ、将来インスタンス分離。

  stale誤利用             ニュース等で古い結果を返す。             cache.statusとageを明示し、time_rangeやカテゴリでTTLを短縮。

  AI tool loop            同一または微妙に異なる検索を繰り返す。   正規化、client rate limit、query digest監視、agent側回数上限。

  Web待機の長期化         Puma threadがbrowser完了待ちで占有。     wait_seconds初期0、最大30、202 pollingを標準にする。
  -----------------------------------------------------------------------------------------------------------------------------------

## 17.2 未決事項

  --------------------------------------------------------------------------------------------------------------
  **ID**                              **未決事項**
  ----------------------------------- --------------------------------------------------------------------------
  Q-01                                Bearer
                                      tokenをsearfront独自管理するか、既存リバースプロキシ認証へ寄せるか。

  Q-02                                初期Browser Worker対象をGoogleだけにするか、Bing等を先に採用するか。

  Q-03                                stale TTLを全検索12時間固定にするか、time_range/categories別に変更するか。

  Q-04                                sidekiq-unique-jobsを採用するか、Redis SET NXの小規模実装で開始するか。

  Q-05                                metrics
                                      endpoint実装にprometheus-clientを使うか、OpenTelemetryを先に導入するか。

  Q-06                                Browser
                                      WorkerのCookie/session永続化を初期から行うか、statelessで開始するか。
  --------------------------------------------------------------------------------------------------------------

  -----------------------------------------------------------------------
  **初期推奨** Q-02はGoogle 1エンジン、Q-03はfresh 30分/stale
  12時間、Q-04は自前SET
  NX、Q-06はstatelessまたは短寿命contextで開始する。
  -----------------------------------------------------------------------

  -----------------------------------------------------------------------

# 付録A. 主要設定値（初期案）

  ------------------------------------------------------------------------------------
  **設定**                **初期値**              **説明**
  ----------------------- ----------------------- ------------------------------------
  result_ttl              30分                    正常検索結果のfresh期間。

  stale_ttl               12時間                  障害時に利用可能な期間。

  empty_result_ttl        3分                     0件結果。

  single_flight_lock      45秒                    外部取得ロック。

  single_flight_wait      15秒                    先行要求待機。

  searxng_timeout         12秒                    通常検索の合計。

  browser_timeout         35秒                    Browser Workerの合計。

  browser_concurrency     1                       専用Sidekiq process。

  browser_min_interval    15秒                    同一エンジン間隔。

  browser_jitter          0〜5秒                  追加待機。

  minimum_results         3件                     browser fallback判定目安。

  captcha_suspend         24時間                  CAPTCHA時。

  rate_limit_suspend      2時間                   429時。

  request_status_ttl      10分                    非同期結果照会。

  max_results             20件                    API返却上限。

  client_rate_limit       60 req/min/token        通常API。refresh/browserは別制限。
  ------------------------------------------------------------------------------------

# 付録B. 参考資料

**\[R1\] Ruby on Rails Guides: Using Rails for API-only Applications\
**[[https://guides.rubyonrails.org/api_app.html]{.underline}](https://guides.rubyonrails.org/api_app.html)

**\[R2\] Sidekiq Wiki: Using Redis\
**[[https://github.com/sidekiq/sidekiq/wiki/Using-Redis]{.underline}](https://github.com/sidekiq/sidekiq/wiki/Using-Redis)

**\[R3\] Redis Docs: Distributed Locks with Redis\
**[[https://redis.io/docs/latest/develop/clients/patterns/distributed-locks/]{.underline}](https://redis.io/docs/latest/develop/clients/patterns/distributed-locks/)

**\[R4\] Browserless Documentation: Open Source Docker Deployment /
Playwright connectivity\
**[[https://docs.browserless.io/enterprise/open-source]{.underline}](https://docs.browserless.io/enterprise/open-source)

## 参考実装時の確認事項

-   Rails、Sidekiq、Redis、Browserlessの正確なバージョンと設定オプションは、実装開始時の公式ドキュメントで再確認する。

-   検索エンジンの利用規約、robots方針、アクセス制限を確認し、個人利用・低頻度の範囲で運用する。

-   SearXNG側のsuspended_times、outgoing connection
    pool、engine設定もsearfront導入後の負荷に合わせて調整する。

  -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  **設計の要点**
  searfrontは「検索を速くする」より「外部検索を必要最小限にし、失敗しても制御可能にする」ことを優先する。SearXNGは通常経路、Browserless/PlaywrightはSidekiqで直列化された最後の手段とする。
  -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

  -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
