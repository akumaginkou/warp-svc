#!/bin/bash

# QNAP warp-svc ログ分析スクリプト
# 使用方法: docker-compose exec warp bash /scripts/analyze-logs.sh

echo "========================================"
echo "Warp-svc ログ分析 (最後の 1000行を分析)"
echo "========================================"
echo ""

LOG_FILE="/tmp/warp-svc.log"

if [[ ! -f "$LOG_FILE" ]]; then
  echo "❌ ログファイルが見つかりません: $LOG_FILE"
  exit 1
fi

# 1. エラーサマリー
echo "【1】エラーサマリー"
echo "---"
echo "WARN エラー数: $(tail -1000 $LOG_FILE | grep -c "WARN")"
echo "ERROR エラー数: $(tail -1000 $LOG_FILE | grep -c "ERROR")"
echo ""

# 2. 接続関連エラー
echo "【2】接続エラー"
echo "---"
echo "タイムアウト:"
tail -1000 $LOG_FILE | grep -c "timed out" || echo "0"
echo ""
echo "502 Bad Gateway:"
tail -1000 $LOG_FILE | grep -c "502 Bad Gateway" || echo "0"
echo ""
echo "Connection refused:"
tail -1000 $LOG_FILE | grep -c "Connection refused" || echo "0"
echo ""

# 3. ストリーム関連エラー
echo "【3】ストリーム・接続数エラー"
echo "---"
echo "Stream limit hit:"
tail -1000 $LOG_FILE | grep -c "stream limit" || echo "0"
echo ""
echo "Address already in use:"
tail -1000 $LOG_FILE | grep -c "AddrInUse" || echo "0"
echo ""

# 4. 最新エラー（最新10件）
echo "【4】最新エラー（最新10件）"
echo "---"
tail -1000 $LOG_FILE | grep -E "WARN|ERROR" | tail -10
echo ""

# 5. 接続確立時間の分析
echo "【5】接続確立パフォーマンス"
echo "---"
echo "1秒以上かかった接続:"
tail -1000 $LOG_FILE | grep "took.*ms" | grep -oE "took [0-9]+ms" | awk '{print $2}' | \
  awk -F'[ms]' '{if ($1 > 1000) count++} END {print count ? count : "0"}'
echo ""

# 6. warp-svc との通信状態
echo "【6】Warp-svc ステータス推移"
echo "---"
echo "接続成功:"
tail -1000 $LOG_FILE | grep -c "Connected" || echo "0"
echo ""
echo "接続失敗:"
tail -1000 $LOG_FILE | grep -c "Disconnected" || echo "0"
echo ""
echo "接続中:"
tail -1000 $LOG_FILE | grep -c "Connecting" || echo "0"
echo ""

# 7. dbus エラー
echo "【7】D-Bus 接続エラー（QNAP では無視しても良い）"
echo "---"
echo "D-Bus エラー数: $(tail -1000 $LOG_FILE | grep -c "D-Bus error" || echo "0")"
echo ""

# 8. ネットワーク問題
echo "【8】ネットワーク問題"
echo "---"
echo "Network is unreachable:"
tail -1000 $LOG_FILE | grep -c "Network is unreachable" || echo "0"
echo ""
echo "No route to host:"
tail -1000 $LOG_FILE | grep -c "No route to host" || echo "0"
echo ""

echo "========================================"
echo "ログ分析完了"
echo "========================================"
