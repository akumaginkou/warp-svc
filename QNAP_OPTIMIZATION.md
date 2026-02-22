# QNAP環境でのWarp-svcの最適化

QNAPコンテナ環境での不安定性を解決するための設定ガイドです。

## 🔧 **実装された改善事項**

### 1. **ストリーム上限超過の対応** (`warp.sh`)
- **ファイルディスクリプタ上限**: `ulimit -n 8192` で上限を大幅アップ
  - H3/QUICの多数並行接続に対応
  - デフォルト 1024 では不足

- **プロセス数上限**: `ulimit -u 2048` に設定
  - warp-svc の複数スレッド対応

### 2. **初期化タイムアウトの延長** (`warp.sh`)
- warp-svc 起動後の待機: 3秒 → **5秒**
- connect リトライ: 最大 10 → **20 回**
- リトライバックオフ: 固定 2秒 → **指数バックオフ** (2s, 4s, 6s...)

### 3. **socat の安定化** (`supervisord.conf`)
```properties
[program:socat]
command=socat -ly tcp-listen:1080,reuseaddr,reuseport,fork tcp:localhost:40000
                        ↑ ディレクトリ出力               ↑ ポート再利用
startsecs=15            # 15秒待機（warp-svc 準備完了まで）
startretries=5          # 5回までリトライ
```

### 4. **ヘルスチェック機構の大幅改善** (`healthcheck.sh`)
```bash
CHECK_INTERVAL=180       # 120秒 → 180秒（3分）
FAILURE_THRESHOLD=5      # 3回 → 5回の失敗で再起動
MIN_RESTART_INTERVAL=600 # 5分 → 10分（無限ループ防止）
CURL_TIMEOUT=30          # 10秒 → 30秒
```

### 5. **Docker ネットワークヘルスチェック**
```yaml
healthcheck:
  test: ["CMD", "curl", "-m", "30", ...]
  interval: 180s      # 120秒 → 180秒
  timeout: 40s        # 15秒 → 40秒
  retries: 3
  start_period: 60s   # 30秒 → 60秒（余裕を持たせる）
```

## 📋 **QNAP でのセットアップ手順**

### 前提条件
- QNAP NAS (CPU: 2GHz以上, RAM: 2GB以上推奨)
- Container Station がインストール済み
- Docker Compose v1.29+ 対応

### デプロイ方法

#### 1. **リポジトリをクローン**
```bash
cd /share/Container  # または適切なディレクトリ
git clone https://github.com/bacnh85/warp-svc.git
cd warp-svc
```

#### 2. **環境変数を設定** (オプション)
```bash
# .env ファイルを作成（docker-compose で読み込み）
echo "WARP_LICENSE=your-license-key" > .env
echo "FAMILIES_MODE=off" >> .env
```

#### 3. **コンテナをビルド・起動**
```bash
# イメージのビルド（初回のみ、15-20分要注意）
docker-compose build --no-cache

# コンテナの起動
docker-compose up -d

# ログの確認（60秒待機してから確認）
sleep 60
docker-compose logs -f --tail=100

# サービスのステータス確認（セットアップ完了後、2-3分待機）
sleep 120
docker-compose exec warp warp-cli --accept-tos status
```

## 🔍 **トラブルシューティング**

### 問題: 「Stream Limit Hit」エラーが出ている

**原因**: H3/QUIC の接続ストリーム数が上限に達している

**確認方法**:
```bash
# ファイルディスクリプタ上限の確認
docker-compose exec warp sh -c "ulimit -n"  # 8192 であることを確認

# 接続数の確認
docker-compose exec warp ss -tnp | grep 40000 | wc -l  # 接続数を表示
```

**対応**:
- docker-compose.yml で mem_limit を 512m に増やす
- 複数のコンテナで負荷分散する場合は、別インスタンスに分ける

### 問題: 「connect to upstream timed out」が多数出ている

**原因**: warp-svc が遅く、port 40000 が準備できていない

**確認方法**:
```bash
# warp-svc の状態確認
docker-compose exec warp warp-cli --accept-tos status
# → "Connected" または "Disconnected" のいずれか

# socat が port 1080 をリッスンしているか確認
docker-compose exec warp ss -tlnp | grep 1080
# → tcp    LISTEN 0 128 0.0.0.0:1080

# port 40000 のリッスン状態確認
docker-compose exec warp ss -tlnp | grep 40000
```

**対応**:
```bash
# warp-svc の再起動
docker-compose exec warp supervisorctl restart warp-svc

# 60秒待機後、再度テスト
sleep 60
docker-compose exec -T warp curl -x socks5h://127.0.0.1:40000 \
  https://www.cloudflare.com/cdn-cgi/trace/
```

### 問題: socat が「Connection refused」エラーを出している

**原因**: warp-svc がまだ port 40000 をリッスンしていない

**対応**: 通常は自動で回復します（socat が 5 回まで自動リトライ）
```bash
# 手動リトライ
docker-compose exec warp supervisorctl restart socat

# 15秒待機してから確認
sleep 15
docker-compose exec -T warp curl -x socks5h://127.0.0.1:1080 \
  https://www.cloudflare.com/cdn-cgi/trace/
```

### 問題: コンテナが頻繁に再起動される

**原因**: healthcheck が失敗し続けている

**対策**:
```bash
# ログを詳細確認
docker-compose logs warp | grep -E "WARN|ERROR" | tail -50

# 網の疎通確認
docker-compose exec warp ping -c 3 1.1.1.1

# DNS 確認
docker-compose exec warp nslookup cloudflare.com

# ハードコードされたエンドポイントで直接テスト
docker-compose exec -T warp curl \
  https://104.28.206.119/cdn-cgi/trace/ \
  -H "Host: www.cloudflare.com"
```

## 📊 **リソース使用量の監視**

```bash
# 実時間でのリソース監視
docker stats warp

# メモリ使用量の詳細確認
docker-compose exec warp ps aux | grep warp-svc

# ディスク使用量
docker-compose exec warp du -sh /var/lib/cloudflare-warp

# ネットワーク接続数
docker-compose exec warp ss -tnp | grep warp | wc -l
```

## ⚙️ **カスタマイズ**

### CPU/メモリ制限の変更

`docker-compose.yml` を編集:
```yaml
cpus: '1.0'          # 1コア全て使用可能にする
mem_limit: 512m      # メモリを 512MB に増加
```

### ストリーム数上限の変更

`scripts/warp.sh` で以下を編集:
```bash
ulimit -n 16384      # 8192 から 16384 に増加
```

### ヘルスチェック間隔の変更

`healthcheck.sh` で以下を編集:
```bash
CHECK_INTERVAL=300   # 180秒から 300秒に延長
FAILURE_THRESHOLD=3  # 5回から 3回に短縮（より敏感に）
```

## 📝 **QNAP Container Station での注意事項**

1. **ポート競合**: ポート 1080 が既に使用中でないか確認
2. **ボリュームパス**: `/var/lib/cloudflare-warp` は永続ストレージにマウント
3. **自動起動**: Container Station の設定で「コンテナ起動時に自動実行」を有効化
4. **メモリプール**: 他のサービスと共存する場合、メモリ設定を調整
5. **再起動ポリシー**: `restart: unless-stopped` がお勧め（意図的な停止を尊重）

## 🚀 **パフォーマンスチューニング**

### 高速化設定 (メモリ十分な場合)
```yaml
cpus: '1.0'
mem_limit: 512m
```

```bash
# warp.sh
ulimit -n 16384
CHECK_INTERVAL=120  # healthcheck.sh
FAILURE_THRESHOLD=3
```

### 低リソース設定 (リソース限定の場合)
```yaml
cpus: '0.25'
mem_limit: 128m
```

```bash
# warp.sh
ulimit -n 2048
CHECK_INTERVAL=300  # healthcheck.sh
FAILURE_THRESHOLD=7
```

## 🔗 **参考資料**

- [Cloudflare WARP for Linux](https://developers.cloudflare.com/warp-client/get-started/linux/)
- [Docker Compose の healthcheck](https://docs.docker.com/compose/compose-file/#healthcheck)
- [socat の socket オプション](http://www.dest-unreach.org/socat/doc/socat.html)

---

**最終更新**: 2026年2月
**対応環境**: QNAP Container Station (Docker 19.03+)
**テスト QNAP モデル**: TS-xxx シリーズ
