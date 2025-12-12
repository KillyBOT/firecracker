#!/bin/bash

set -e

UUID="$1"
JAILER_ROOT_PATH="/srv/jailer/firecracker/$UUID/root"
API_SOCKET_PATH="$JAILER_ROOT_PATH/run/firecracker.socket"
UFFD_SOCKET_PATH="$JAILER_ROOT_PATH/dev/userfaultfd"

if [ -z "$UUID" ]; then
  echo "Error: No VM UUID provided"
  echo "Usage: $0 [VM UUID]"
  exit 1
fi

if sudo test -S "$API_SOCKET_PATH"; then
  true
else
  echo "Error: socket $API_SOCKET_PATH is not a socket or does not exist"
  exit 1
fi

# Make sure all the commands used exist, to make things more atomic
assert_commands_exist() {
  shift
  for cmd in $@; do
    if ! command -v "${cmd}" &> /dev/null; then
        echo "Error: command \`${cmd}\` is not installed or not in the current \$PATH"
        exit 1
    fi
  done
}

assert_commands_exist curl

# Send the given API command
send_api_command() {

  local request=$1
  local request_addr=$2
  local data=$3

  local status=$(sudo curl --unix-socket "$API_SOCKET_PATH" \
    -s \
    -w "%{http_code}" \
    -X $request $request_addr \
    -H  'Accept: application/json' \
    -H  'Content-Type: application/json' \
    -d "$data"
  )

  if [ ! "$status" == "204" ]; then
    echo "Error: API returned unexpected code (expected 204, got $status)"
    exit 1
  fi
}


# Pause
send_api_command PATCH "http://localhost/vm" \
  '{
    "state": "Paused"
  }'
echo "MicroVM stopped"

# Take first diff snapshot (basically full)
send_api_command PUT 'http://localhost/snapshot/create' \
  '{
    "snapshot_type": "Diff",
    "snapshot_path": "./snapshot_file",
    "mem_file_path": "./mem_file"
  }'
sudo cp "$JAILER_ROOT_PATH/snapshot_file" ./base_snapshot_file
sudo cp "$JAILER_ROOT_PATH/mem_file" ./base_mem_file
echo "MicroVM full snapshotted"

# Resume
send_api_command PATCH "http://localhost/vm" \
  '{
    "state": "Resumed"
  }'
echo "MicroVM resumed"

# Sleep for a bit to give time for memory to change
sleep 3s

# Pause
send_api_command PATCH "http://localhost/vm" \
  '{
    "state": "Paused"
  }'
echo "MicroVM stopped"

# Take second diff snapshot
send_api_command PUT 'http://localhost/snapshot/create' \
  '{
    "snapshot_type": "Diff",
    "snapshot_path": "./snapshot_file",
    "mem_file_path": "./mem_file"
  }'
sudo cp "$JAILER_ROOT_PATH/snapshot_file" ./diff_snapshot_file
sudo cp "$JAILER_ROOT_PATH/mem_file" ./diff_mem_file
echo "MicroVM diff snapshotted"

# Resume
send_api_command PATCH "http://localhost/vm" \
  '{
    "state": "Resumed"
  }'
echo "MicroVM resumed"

# Wait again for things to change
sleep 3s

# Pause
send_api_command PATCH "http://localhost/vm" \
  '{
    "state": "Paused"
  }'
echo "MicroVM stopped"

# Take lazydiff snapshot
send_api_command PUT 'http://localhost/snapshot/create' \
  '{
    "snapshot_type": "LazyDiff",
    "snapshot_path": "./snapshot_file",
    "mem_file_path": "./mem_file"
  }'
sudo cp "$JAILER_ROOT_PATH/snapshot_file" ./lazydiff_snapshot_file
sudo cp "$JAILER_ROOT_PATH/mem_file" ./lazydiff_mem_file
echo "MicroVM lazydiff snapshotted"

# Resume
send_api_command PATCH "http://localhost/vm" \
  '{
    "state": "Resumed"
  }'
echo "MicroVM resumed"

exit 0

# Test 1: New VM
# Full: 88836 us
# Diff: 9596 us
# LazyDiff (does nothing): 1857 us
