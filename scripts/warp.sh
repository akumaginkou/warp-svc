#!/bin/bash

# Don't exit on error for better error handling
set +e

# Kill any existing instances of warp-svc before starting a new one
if pkill -x warp-svc -9; then
  echo "Existing warp-svc process killed."
fi

# Start warp-svc in the background and redirect output to exclude dbus messages
warp-svc > >(grep -iv dbus) 2> >(grep -iv dbus >&2) &
WARP_PID=$!

# Trap SIGTERM and SIGINT, and forward those signals to the warp-svc process
trap "echo 'Stopping warp-svc...'; kill -TERM $WARP_PID; exit" SIGTERM SIGINT

# Maximum number of attempts to try the registration
MAX_ATTEMPTS=10
attempt_counter=0

echo "Attempting to start warp-svc and register..."

# Function to wait for warp-svc to start
function wait_for_warp_svc {
  until warp-cli --accept-tos status &> /dev/null; do
    echo "Wait for warp-svc to start... Attempt $((++attempt_counter)) of $MAX_ATTEMPTS"
    sleep 1
    if [[ $attempt_counter -ge $MAX_ATTEMPTS ]]; then
      echo "Failed to start warp-svc after $MAX_ATTEMPTS attempts. Exiting."
      exit 1
    fi
  done
  echo "warp-svc started successfully!"
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
