# searfront Browser Search Worker

Google検索の1ページ目をBrowserless Chromium経由で取得する内部向けworkerです。

Phase 1では基盤のみを実装しています。

- Fastify server
- `GET /health`
- Bearer token認証部品
- Browserless接続確認
- Dockerfile
- TypeScript / Vitest / ESLint設定

CAPTCHA突破、stealth plugin、proxy rotation、Googleログインは実装しません。

## 開発

```sh
npm install
npm run dev
```

## テスト

```sh
npm test
npm run build
npm run lint
```

## 環境変数

`.env.example` を参照してください。本番では `BROWSER_WORKER_TOKEN` を必須にします。

## Health

```sh
curl http://localhost:3000/health
```

Browserlessへ接続できる場合:

```json
{
  "status": "ok",
  "browserless": "reachable"
}
```

接続できない場合は `503` と `degraded` を返します。
