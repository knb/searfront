# SearXNG 日次保守

Compose で稼働する SearXNG を日次更新し、検索エンジンをローテーションして、更新後の検索を
検証するための手順です。

## 前提

- SearXNG は公式 Compose 構成で稼働している。
- `settings.yml` はホスト上の永続ファイルとして mount されている。
- 実行ユーザーが Docker を操作できる。
- searfront と SearXNG は外部公開しない。

公式の service 更新手順である `docker compose pull` と `docker compose up -d` を使用します。
Compose template 自体は自動更新しません。template の変更は公式版を確認して手動で反映します。

## 設定

```sh
cp config/searxng-maintenance.env.example .env.searxng-maintenance
chmod 600 .env.searxng-maintenance
```

実環境に合わせて次を変更します。

```sh
SEARXNG_COMPOSE_FILE=/home/kensei/sites/searxng/compose.yaml
SEARXNG_SETTINGS_PATH=/home/kensei/sites/searxng/core-config/settings.yml
SEARXNG_BASE_URL=http://127.0.0.1:8080/
SEARXNG_ENGINE_ROTATIONS="google,duckduckgo;bing,brave;qwant,mojeek"
```

`;` で日ごとの group を区切り、group 内は `,` で engine を指定します。engine 名は現在の
SearXNG 設定に存在する名前と完全一致させます。rotation script は他の設定を維持しながら
`use_default_settings.engines.keep_only` を更新し、smoke test に必要な HTML/JSON format を有効にします。

Compose の SearXNG image は保守コマンドが差し替えられる変数形式にします。

```yaml
image: ${SEARXNG_IMAGE:-docker.io/searxng/searxng:latest}
```

SearXNG をホストへ publish しない構成では `SEARXNG_HEALTH_MODE=compose` を指定します。health と
smoke search は container 内の loopback で実行され、公開 port は不要です。

## 手動確認

timer を有効にする前に手動で実行します。

```sh
script/searxng-maintenance
```

処理順序:

1. 排他 lock を取得する。
2. `settings.yml` と rotation state を退避する。
3. 現在の image を `searfront-rollback` tag で保持する。
4. 次の engine group を設定する。
5. SearXNG image を pull して service を再作成する。
6. HTTP health と JSON search を確認する。
7. `SEARFRONT_BASE_URL` と `SEARFRONT_TOKEN` があれば searfront の smoke search も実行する。

途中で失敗すると、設定と rotation state を復元し、退避 image で service を再作成します。

## systemd user timer

```sh
mkdir -p ~/.config/systemd/user
cp deploy/systemd/user/searxng-maintenance.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now searxng-maintenance.timer
```

既定では毎日 04:20、最大30分の random delay 付きで起動します。`Persistent=true` のため、停止中に
予定時刻を過ぎた場合は次回起動後に実行されます。

```sh
systemctl --user list-timers searxng-maintenance.timer
journalctl --user -u searxng-maintenance.service
```

`/srv/searfront` に root 所有で配置する production Compose では、代わりに
`deploy/systemd/system` の system unit を使用します。

```sh
sudo cp deploy/systemd/system/searxng-maintenance.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now searxng-maintenance.timer
```

## 注意事項

- 初回は各 engine group を手動実行し、少なくとも1件取得できることを確認する。
- CAPTCHA、429、結果不足、応答時間を engine 別に比較する。
- `latest` の設定互換性が壊れる可能性があるため journal を監視する。
- 自動 rollback 後も失敗する場合は timer を停止して設定と network を調査する。
- CAPTCHA 自動解決、browser fingerprint 偽装、bot 回避は行わない。
