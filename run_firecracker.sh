#!/bin/sh

set -e

ID="$(uuidgen | tr A-Z a-z)"
JAILER="./build/cargo_target/x86_64-unknown-linux-musl/debug/jailer"
FIRECRACKER=./build/cargo_target/x86_64-unknown-linux-musl/debug/firecracker

JAILER_ROOT_DIR="/srv/jailer/firecracker/$ID/root"
API_SOCKET="$JAILER_ROOT_DIR/run/firecracker.socket"

# Build firecracker if it doesn't exist
if [[ ! -e ${FIRECRACKER} ]]; then
  sudo tools/devtool build
fi

# Remove API unix socket
sudo rm -f $API_SOCKET

# Setup the root dir
if [[ ! -d ${JAILER_ROOT_DIR} ]]; then
  sudo mkdir -p $JAILER_ROOT_DIR
  sudo touch "$JAILER_ROOT_DIR/out.log"
fi

# Run firecracker
# sudo ${FIRECRACKER} \
#   --api-sock "${API_SOCKET}"

sudo ${JAILER} \
    --exec-file ${FIRECRACKER} \
    --id ${ID} \
    --uid $(sudo id -u) \
    --gid $(sudo id -g) \
    --new-pid-ns \
    --daemonize \
    -- \
    --log-path ./out.log \
    --level debug \


echo "Firecracker server started with ID ${ID}"
echo "Connect using the following socket:"
echo
echo ${API_SOCKET}
