# QNAP 不安定性解決: 詳細分析とログ解釈

## 📊 ユーザーが提示したログの問題分析

### 1. **「Stream Limit Hit」エラー**
```
Proxy encountered fatal error: The connect socket encountered a fatal error:
The connect proxy hit the stream limit
```

**原因**: HTTP/3 (QUIC) のストリーム数が上限に達した

**解決方法**:
```bash
# warp.sh に追加
ulimit -n 8192   # ファイルディスクリプタを 8192 に
```

---

### 2. **大量のタイムアウトエラー**
```
WARN run: proxy: Socks greeting failed
error=Transient(Custom { kind: TimedOut, error: "connect to upstream timed out" })
local_addr=127.0.0.1:41XXX
```

**原因**:
- warp-svc のプロキサーが適切なレスポンスを返していない
- ポート 40000 が処理できる接続数を超えた
- ネットワーク遅延が大きい

**解決方法**:
```bash
# 1. curl のタイムアウトを 30 秒に
# healthcheck.sh
curl --retry 3 -m 30 ...

# 2. socat のスケーリング
# supervisord.conf
command=socat -ly tcp-listen:1080,reuseaddr,reuseport,fork tcp:localhost:40000
       ↑ ディレクトリモード    ↑ ポート再利用
```

---

### 3. **「502 Bad Gateway」エラー**
```
Invalid status code from CONNECT TCP endpoint: 502 Bad Gateway
```

**原因**:
- プロキシ側が接続を受け付けられない
- warp-svc がクラッシュまたは再起動中

**解決方法**:
```bash
# warp.sh の初期化待機を延長
sleep 5      # 3秒 → 5秒

# socat の起動遅延を増加
# supervisord.conf
[program:socat]
startsecs=15  # 5秒 → 15秒
```

---

### 4. **「socat: Connection refused」**
```
socat[2435] E connect(5, AF=2 127.0.0.1:40000, 16): Connection refused
```

**原因**: port 40000 がまだリッスンされていない（warp-svc 起動遅延）

**解決方法**: **既に修正済み**
- socat の起動遅延: 5 秒 → 15 秒
- socat のリトライ: 3 回 → 5 回

---

### 5. **「Address already in use」**
```
Failed to bind to preferred UDP socket
err=Os { code: 98, kind: AddrInUse, message: "Address already in use" }
preferred_addr=172.29.4.3:37333
```

**原因**: QNAP や ホスト側の前回接続が UDP ソケットをまだ保持

**解決方法**:
```bash
# warp.sh
ulimit -n 8192   # FD を増やす
ulimit -u 2048   # プロセス数 を増やす

# supervisord.conf 設定
stopasgroup=true  # グループ全体で停止
```

---

### 6. **D-Bus エラー（無視してOK）**
```
WARN network_info::linux::power_notifier:
dbus connection failed...
Failed to connect to socket /run/dbus/system_bus_socket
```

**原因**: Docker コンテナでは D-Bus デーモンが実行されていない

**対応**: 無視しても問題ありません（パフォーマンス通知用）

---

## 💡 実装された修正のハイライト

| 項目 | 変更前 | 変更後 | 効果 |
|------|--------|--------|------|
| **FD上限** | 1024 | 8192 | 多数の並行接続に対応 |
| **socat 起動待機** | 5秒 | 15秒 | warp-svc 起動完了まで待機 |
| **healthcheck 間隔** | 120秒 | 180秒 | 一時的なエラーを許容 |
| **再起動インターバル** | 5分 | 10分 | 無限ループを防止 |
| **curl タイムアウト** | 10秒 | 30秒 | QNAP の遅延に対応 |
| **connect リトライ** | 10回 | 20回 | 指数バックオフ |

---

## 🔧 追加で利用可能なツール

### 1. **トラブルシューティングスクリプト**
```bash
docker-compose exec warp bash /scripts/troubleshoot.sh
```

このスクリプトが以下をチェック:
- WARP 接続状態
- プロセス状態
- ポートリッスン状況
- DNS 解決
- プロキシ接続テスト
- メモリ使用量

### 2. **ログ分析スクリプト**
```bash
docker-compose exec warp bash /scripts/analyze-logs.sh
```

エラーの種類と頻度を自動分析

### 3. **低リソース設定**
```bash
docker-compose -f docker-compose.limited-resources.yml up -d
```

CPU 25%, メモリ 128MB での実行用

---

## 🚀 QNAP デプロイのベストプラクティス

### 初回セットアップ
```bash
# 1. リポジトリクローン
git clone https://github.com/bacnh85/warp-svc.git
cd warp-svc

# 2. イメージビルド（15-20分）
docker-compose build --no-cache

# 3. コンテナ起動
docker-compose up -d

# 4. 初期化待機（2-3分）
sleep 180

# 5. ステータス確認
docker-compose exec warp warp-cli --accept-tos status
```

### 日常監視
```bash
# 週 1 回確認
docker-compose exec warp bash /scripts/troubleshoot.sh

# 問題検出時
docker-compose exec warp bash /scripts/analyze-logs.sh
```

### トラブル時の対応
```bash
# 再起動
docker-compose restart warp

# ログ確認
docker-compose logs -f warp

# ディープな診断
docker-compose exec warp bash /scripts/troubleshoot.sh
```

---

## 📈 パフォーマンス期待値

### 正常運用時
- ヘルスチェック: 2-3回 成功後に安定
- 再起動: ほぼ発生しない（> 24時間稼働）
- CPU 使用率: 5-15%
- メモリ使用率: 80-150MB

### 問題兆候
- 5分ごとに再起動
- cpu 使用率が 50% 以上
- ストリームリミットエラーが頻発

---

**最終更新**: 2026年2月22日
