#!/bin/bash

# Trap SIGTERM and SIGINT to handle graceful shutdown
trap 'kill ${sleep_pid}; exit 0' SIGTERM SIGINT

# Configuration for QNAP stability
CHECK_INTERVAL=180     # Increased from 120s - QNAP systems have slower network
FAILURE_THRESHOLD=5    # Increased from 3 - more tolerance for transient issues
FAILURE_COUNT=0
LAST_RESTART_TIME=0
MIN_RESTART_INTERVAL=600  # Increased from 300s to 10 minutes - prevent restart loops
CURL_TIMEOUT=30        # Increased from 10s - QNAP may have network latency

# Main loop
while true; do
  CURRENT_TIME=$(date +%s)

  # Check if the Cloudflare WARP service is working
  # Much longer timeout and more retries for QNAP stability
  if curl --retry 3 -m $CURL_TIMEOUT -sSLx socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace/ 2>/dev/null | grep -q "warp=on"; then
    # Reset failure counter on success
    if [[ $FAILURE_COUNT -gt 0 ]]; then
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARP service recovered. Failure count reset."
      FAILURE_COUNT=0
    fi
  else
    # Increment failure count
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARP service check failed (attempt $FAILURE_COUNT/$FAILURE_THRESHOLD)"

    # Only restart after consecutive failures and respecting restart interval
    if [[ $FAILURE_COUNT -ge $FAILURE_THRESHOLD ]]; then
      RESTART_DIFF=$((CURRENT_TIME - LAST_RESTART_TIME))
      if [[ $RESTART_DIFF -ge $MIN_RESTART_INTERVAL ]] || [[ $LAST_RESTART_TIME -eq 0 ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARP service unstable. Restarting warp-svc..."
        supervisorctl restart warp-svc 2>&1 | awk '{print "[" strftime("%Y-%m-%d %H:%M:%S") "] " $0}'
        LAST_RESTART_TIME=$CURRENT_TIME
        FAILURE_COUNT=0
      else
        WAIT_TIME=$((MIN_RESTART_INTERVAL - RESTART_DIFF))
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] Restart cooldown active. Will retry in ${WAIT_TIME}s"
      fi
    fi
  fi

  # Sleep in a way that allows interruption
  sleep $CHECK_INTERVAL &
  sleep_pid=$!
  wait $sleep_pid
done