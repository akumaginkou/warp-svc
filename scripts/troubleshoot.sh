#!/bin/bash

# QNAP warp-svc トラブルシューティングスクリプト
# 使用方法: docker-compose exec warp bash /scripts/troubleshoot.sh

echo "========================================"
echo "Warp-svc トラブルシューティング"
echo "========================================"
echo ""

# 1. warp-cli ステータス
echo "【1】WARP接続状態"
echo "---"
warp-cli --accept-tos status
echo ""

# 2. プロセス確認
echo "【2】プロセス確認"
echo "---"
ps aux | grep -E "warp-svc|socat" | grep -v grep
echo ""

# 3. ファイルディスクリプタ上限
echo "【3】ファイルディスクリプタ上限"
echo "---"
echo "Current: $(ulimit -n)"
echo "Recommended: 8192"
echo ""

# 4. ポート確認
echo "【4】ポートリッスン状態"
echo "---"
echo "ポート 1080 (socat):"
ss -tlnp | grep 1080 || echo "❌ リッスンしていません"
echo ""
echo "ポート 40000 (warp-svc):"
ss -tlnp | grep 40000 || echo "❌ リッスンしていません"
echo ""

# 5. ネットワーク接続数
echo "【5】アクティブな接続数"
echo "---"
echo "WARP側 (port 40000):"
ss -tnp | grep 40000 | wc -l
echo "プロキシ側 (port 1080):"
ss -tnp | grep 1080 | wc -l
echo ""

# 6. DNS確認
echo "【6】DNS確認"
echo "---"
echo "/etc/resolv.conf:"
cat /etc/resolv.conf | head -3
echo ""
echo "DNS解決テスト:"
nslookup cloudflare.com 8.8.8.8 2>&1 | head -5 || echo "❌ DNS失敗"
echo ""

# 7. プロキシテスト
echo "【7】プロキシ接続テスト"
echo "---"
echo "SOCKS5 プロキシテスト:"
timeout 10 curl -v -x socks5h://127.0.0.1:40000 \
  https://www.cloudflare.com/cdn-cgi/trace/ 2>&1 | grep -E "warp=|Connected|refused" || echo "❌ テスト失敗"
echo ""

# 8. ソケットディレクトリ
echo "【8】Warp ソケットディレクトリ"
echo "---"
ls -la /run/cloudflare-warp/ 2>/dev/null || echo "❌ ディレクトリが見つかりません"
echo ""

# 9. メモリ使用量
echo "【9】メモリ使用量"
echo "---"
ps aux | grep -E "warp-svc|socat" | grep -v grep | awk '{print $2, $6}' | while read pid mem; do
  echo "PID $pid: ${mem}KB"
done
echo ""

# 10. 最新エラーログ
echo "【10】最新のエラーログ（最新50行）"
echo "---"
tail -50 /tmp/warp-svc.log 2>/dev/null | grep -E "WARN|ERROR" || echo "❌ ログが見つかりません"
echo ""

echo "========================================"
echo "トラブルシューティング完了"
echo "========================================"
