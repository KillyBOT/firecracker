# A collection of functions for running MicroVMs

# Make sure all the commands used exist, to make things more atomic
assert_commands_exist() {
  set -eu

  shift
  for cmd in $@; do
    if ! command -v "${cmd}" &> /dev/null; then
        echo "Error: command \`${cmd}\` is not installed or not in the current \$PATH"
        exit 1
    fi
  done
}

# Build the specified kernel if it is not already built. Returns the path of the kernel.
# Usage:
#   build_kernel [KERNEL_VERSION] [ARCH]
build_kernel() {
  set -eu

  local KERNEL_VERSION=$1
  local ARCH=$2

  local KERNEL_PATH="kernel-$KERNEL_VERSION-$ARCH.bin"

  # Build the kernel if it doesn't exist
  if [[ ! -f $KERNEL_PATH ]]; then
    # TODO: Allow KERNEL_VERSION to be used in the sed regex
    local KERNEL_BUILD_PATH=$(find ./resources/$ARCH -maxdepth 1 -regextype sed -regex ".*/vmlinux-6\.1\.[0-9]*" -type f 2>/dev/null || true)
    if [[ -z $KERNEL_BUILD_PATH ]]; then
      sudo ./tools/devtool build_ci_artifacts kernels $KERNEL_VERSION
      KERNEL_BUILD_PATH="$(find ./resources/$ARCH -maxdepth 1 -regextype sed -regex ".*/vmlinux-6\.1\.[0-9]*" -type f)"
    fi

    cp $KERNEL_BUILD_PATH $KERNEL_PATH
  fi

  echo $KERNEL_PATH
}

# Create an SSH key pair if one does not already exist. Returns the contents of the public key.
create_ssh_keypair() {
  set -eu

  local KEY_NAME=$1

  [[ -f $KEY_NAME ]] || ssh-keygen -t ed25519 -f "$KEY_NAME" -N "" -q

  echo $(cat "$KEY_NAME.pub")
}

# Create a jailer user & group if they do not exist (requires sudo permission)
create_jailer_user() {
  if ! getent group "jailer" > /dev/null 2>&1; then
    echo "Creating group jailer"
    sudo groupadd --system "jailer"
  fi

  if ! getent passwd "jailer" > /dev/null 2>&1; then
    echo "Creating user jailer"
    sudo useradd --system \
        -g "jailer" \
        -d /dev/null \
        -s /usr/bin/nologin \
        "jailer"
  fi
}

# Prepare the jail for the VM (requires sudo permission to write to the jail)
# Usage:
#   preapare_jailer_root_dir [JAIL_ROOT_DIR] [KERNEL_PATH] [ROOTFS_PATH] [CONFIG_PATH]
prepare_jailer_root_dir() {
  set -eu

  local JAIL_ROOT_DIR=$1
  local KERNEL_PATH=$2
  local ROOTFS_PATH=$3
  local CONFIG_PATH=$4

  # Create the jailer root dir if it doesn't exist
  [[ -d $JAILER_ROOT_DIR ]] || sudo mkdir -p $JAILER_ROOT_DIR

  # Move the neccesary files into the root dir
  sudo mkdir -p $JAILER_ROOT_DIR
  sudo cp $KERNEL_PATH $JAILER_ROOT_DIR/kernel.bin
  sudo cp $ROOTFS_PATH $JAILER_ROOT_DIR/rootfs.ext4
  sudo cp $CONFIG_PATH $JAILER_ROOT_DIR/config.json
  sudo touch $JAILER_ROOT_DIR/out.log

  # Make the jailer the owner of the root dir
  sudo chown -R jailer:jailer $JAILER_ROOT_DIR
}

# Create a network bridge for the VM (requires sudo permissions)
# Usage:
#   enable_networking [TAP_DEV] [HOST_IP_WITH_MASK (e.g. 192.168.1.1/24)] [GUEST_IP] [HOST_IFACE]
enable_networking() {
  set -eu

  local TAP_DEV=$1
  local HOST_IP_WITH_MASK=$2
  local GUEST_IP=$3
  local HOST_IFACE=$4

  # Setup network interface
  sudo ip link del "$TAP_DEV" 2> /dev/null || true
  sudo ip tuntap add dev "$TAP_DEV" mode tap
  sudo ip addr add "$HOST_IP_WITH_MASK" dev "$TAP_DEV"
  sudo ip link set dev "$TAP_DEV" up

  # Allow for IPv4 forwarding
  sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

  ## Set up microVM internet access
  # Create NAT and forwarding tables
  sudo nft delete table firecracker 2>/dev/null || true
  sudo nft add table firecracker
  sudo nft 'add chain firecracker postrouting { type nat hook postrouting priority srcnat; policy accept; }'
  sudo nft 'add chain firecracker filter { type filter hook forward priority filter; policy accept; }'

  # Make VM packets look like they come from the host
  sudo nft add rule firecracker postrouting ip saddr ${GUEST_IP} oifname "${HOST_IFACE}" counter masquerade

  # Forward packets to and from the tap device
  sudo nft add rule firecracker filter iifname "${TAP_DEV}" oifname "${HOST_IFACE}" accept
}

# Disable networking
# Usage:
#   disable_networking [TAP_DEV]
disable_neworking() {
  set -eu

  local TAP_DEV=$1

  sudo ip link del $TAP_DEV
  sudo sh -c "echo 0 > /proc/sys/net/ipv4/ip_forward"
  sudo nft delete table firecracker
}
