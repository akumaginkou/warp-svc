#!/bin/bash

# Don't exit on error for better error handling
set +e

# Ensure /run/cloudflare-warp directory exists with correct permissions
mkdir -p /run/cloudflare-warp
chmod 777 /run/cloudflare-warp
echo "Ensured /run/cloudflare-warp exists with full permissions"

# Also ensure /run directory itself is writable
chmod 777 /run 2>/dev/null || true

# Kill any existing instances of warp-svc before starting a new one
if pkill -x warp-svc -9; then
  echo "Existing warp-svc process killed."
fi

# Log system capabilities and environment
echo "=== System Information ==="
echo "UID: $(id -u), GID: $(id -g)"
echo "Available at /run: $(ls -la /run | head -5)"
echo "Warp-svc location: $(which warp-svc)"
echo "=========================="

# Check network and DNS connectivity before starting warp-svc
echo "=== Network Diagnostics ==="
echo "Resolving 1.1.1.1 (cloudflare.com):"
nslookup 1.1.1.1 2>&1 | head -5
echo "Checking network interfaces:"
ip link show 2>/dev/null | grep -E "^[0-9]|state" | head -10
echo "Checking routes:"
ip route show 2>/dev/null | head -5
echo "DNS config:"
cat /etc/resolv.conf 2>/dev/null | head -5
echo "============================"

# Start warp-svc with enhanced debugging
# Use strace to capture system calls if available, otherwise just run normally
export RUST_LOG=debug
export RUST_BACKTRACE=full

if command -v strace &>/dev/null; then
  echo "Starting warp-svc with strace for system call tracing..."
  strace -f -o /tmp/warp-svc.strace -e trace=socket,connect,bind warp-svc 2>&1 | tee /tmp/warp-svc.log &
else
  echo "strace not available, running warp-svc directly..."
  warp-svc 2>&1 | tee /tmp/warp-svc.log &
fi
WARP_PID=$!
echo "Started warp-svc with PID $WARP_PID, logging to /tmp/warp-svc.log"

# Wait longer for initialization
sleep 3

# Trap SIGTERM and SIGINT, and forward those signals to the warp-svc process
trap "echo 'Stopping warp-svc...'; kill -TERM $WARP_PID; exit" SIGTERM SIGINT

# Maximum number of attempts to try the registration
MAX_ATTEMPTS=10
attempt_counter=0

echo "Attempting to start warp-svc and register..."

# Function to wait for warp-svc to start
function wait_for_warp_svc {
  echo "Waiting for warp-svc Unix socket to be ready..."

  # Check if warp-cli command exists
  if ! command -v warp-cli &> /dev/null; then
    echo "Error: warp-cli command not found"
    which warp-cli || echo "warp-cli not in PATH"
    return 1
  fi

  # Wait for Unix socket to be created
  local socket_path="/run/cloudflare-warp/warp_service"
  for i in {1..20}; do
    if [[ -S "$socket_path" ]]; then
      echo "Unix socket found at $socket_path"
      break
    fi
    echo "Waiting for Unix socket ($i/20)..."
    sleep 1
  done

  # Try to communicate with warp-cli
  local max_attempts=15
  for i in $(seq 1 $max_attempts); do
    if warp-cli --accept-tos status &>/dev/null; then
      echo "warp-svc started successfully!"
      return 0
    fi
    echo "Attempt $i/$max_attempts: warp-cli not responding..."
    echo "Debug: $(warp-cli --accept-tos status 2>&1 || true)"
    sleep 2
  done

  echo "Failed to start warp-svc after $max_attempts attempts"
  echo "=== Detailed Debug Info ==="
  echo "Process check: $(pgrep -f warp-svc | head -1 || echo 'warp-svc not running')"
  echo "Socket exists: $(test -S "$socket_path" && echo 'Yes' || echo 'No')"
  echo "Socket directory: $(ls -la /run/cloudflare-warp 2>/dev/null || echo 'Directory not found')"
  echo "Warp-cli test: $(warp-cli --accept-tos status 2>&1 || true)"
  
  echo ""
  echo "=== warp-svc Exit Status ==="
  ps aux | grep -i warp-svc | grep -v grep || echo "No warp-svc process found"
  
  echo ""
  echo "=== System Capabilities ==="
  echo "UID/GID: $(id)"
  echo "Seccomp: $(cat /proc/self/status 2>/dev/null | grep Seccomp || echo 'N/A')"
  
  echo ""
  echo "=== Network Status ==="
  nslookup 1.1.1.1 2>&1 | head -3 || echo "DNS lookup failed"
  
  echo ""
  echo "=== Last 50 lines of warp-svc log ==="
  tail -50 /tmp/warp-svc.log 2>/dev/null || echo "Log file not found"
  
  if [[ -f /tmp/warp-svc.strace ]]; then
    echo ""
    echo "=== strace socket/connect calls ==="
    grep -E "socket|connect|bind" /tmp/warp-svc.strace 2>/dev/null | tail -15
  fi
  
  echo "=============================="
  return 1
}

# Wait for warp-svc to start
if wait_for_warp_svc; then
  echo "warp-svc has been started successfully!"
else
  echo "There was an issue starting the service. Check logs for details."
  kill $WARP_PID
  exit 1
fi

# Give warp-svc some more time to fully initialize
sleep 3

# Check if registration is already obtained before with warp-cli registration show
warp-cli --accept-tos registration show &> /dev/null
if [[ $? -ne 0 ]]; then
  echo "Registering service ... "
  # Retry registration up to 5 times with exponential backoff
  registration_attempts=0
  max_registration_attempts=5
  until warp-cli --accept-tos registration new &> /dev/null; do
    registration_attempts=$((registration_attempts + 1))
    if [[ $registration_attempts -ge $max_registration_attempts ]]; then
      echo "Failed to register after $max_registration_attempts attempts. Exiting."
      kill $WARP_PID
      exit 1
    fi
    wait_time=$((2 ** registration_attempts))
    echo "Registration attempt $registration_attempts failed. Retrying in ${wait_time}s..."
    sleep $wait_time
  done
  echo "Registration successful!"
fi

# Set the proxy port to 40000
if ! warp-cli --accept-tos proxy port 40000; then
  echo "Warning: Failed to set proxy port"
fi

# Set the mode to proxy
if ! warp-cli --accept-tos mode proxy; then
  echo "Warning: Failed to set proxy mode"
fi

# Disable DNS log
warp-cli --accept-tos dns log disable 2>/dev/null || true

# Set the families mode based on the value of the FAMILIES_MODE variable
if ! warp-cli --accept-tos dns families "${FAMILIES_MODE}"; then
  echo "Warning: Failed to set families mode"
fi

# Set the WARP_LICENSE if it is not empty
if [[ -n $WARP_LICENSE ]]; then
  echo "Applying WARP+ license..."
  # Retry license application up to 3 times
  license_attempts=0
  max_license_attempts=3
  until warp-cli --accept-tos registration license "${WARP_LICENSE}" &> /dev/null; do
    license_attempts=$((license_attempts + 1))
    if [[ $license_attempts -ge $max_license_attempts ]]; then
      echo "Warning: Failed to apply license after $max_license_attempts attempts. Continuing without WARP+..."
      break
    fi
    echo "License application attempt $license_attempts failed. Retrying in 2s..."
    sleep 2
  done
  if [[ $license_attempts -lt $max_license_attempts ]]; then
    echo "WARP+ license applied successfully!"
  fi
fi

# Connect to the WARP service with retry logic
echo "Connecting to WARP..."
connect_attempts=0
max_connect_attempts=10
until warp-cli --accept-tos connect &> /dev/null; do
  connect_attempts=$((connect_attempts + 1))
  if [[ $connect_attempts -ge $max_connect_attempts ]]; then
    echo "Failed to connect after $max_connect_attempts attempts. Exiting."
    kill $WARP_PID
    exit 1
  fi
  echo "Connection attempt $connect_attempts failed. Retrying in 2s..."
  sleep 2
done

while true; do
  # Check if warp-cli is connected
  if warp-cli --accept-tos status | grep -iq connected; then
    echo "Connected successfully."
    # If connected, start healthcheck and break the loop
    supervisorctl start healthcheck
    break
  else
    echo "Not connected. Checking again..."
  fi
  # Wait for a specified time before checking again
  sleep 1
done

# Wait for warp-svc process to finish
wait $WARP_PID
