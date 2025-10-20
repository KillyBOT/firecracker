#!/bin/sh

set -e

ARCH=$(uname -m)
DEBIAN_VERSION="bookworm"
ROOTFS_SIZE="1G"
ID="$(uuidgen | tr A-Z a-z)"

JAILER_ROOT_DIR="/srv/jailer/firecracker/$ID/root"
API_SOCKET="${JAILER_ROOT_DIR}/run/firecracker.socket"

KERNEL="kernel-debian-${DEBIAN_VERSION}.bin"
KERNEL_VERSION="6.1"
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off ip=172.16.0.2::172.16.0.1:255.255.255.252::eth0:off i8042.noaux i8042.nomux i8042.nopnp i8042.nokbd quiet"

ROOTFS="rootfs-debian-${DEBIAN_VERSION}.ext4"
ROOTFS_SIZE="1G"

KEY_NAME="id_ed25519-debian-${DEBIAN_VERSION}"
PUBLIC_KEY=$(cat "${KEY_NAME}.pub") 2>/dev/null || true

CONFIG_FILE="microvm_config-debian-${DEBIAN_VERSION}.json"

# Networking information
# BRIGE_DEV="br0"
TAP_DEV="tap0"
HOST_IP="172.16.0.1"
GUEST_IP="172.16.0.2"
MASK_SHORT="/30"

# This tries to determine the name of the host network interface to forward
# VM's outbound network traffic through. If outbound traffic doesn't work,
# double check this returns the correct interface!
HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev')
# # The IP address of a guest is derived from its MAC address with
# # `fcnet-setup.sh`, this has been pre-configured in the guest rootfs. It is
# # important that `TAP_IP` and `FC_MAC` match this.
# FC_MAC="06:00:AC:10:00:02"

# LOGFILE="./microvm_log-debian-${DEBIAN_VERSION}.log"

JAILER="./build/cargo_target/x86_64-unknown-linux-musl/debug/jailer"
FIRECRACKER="./build/cargo_target/x86_64-unknown-linux-musl/debug/firecracker"

# Download the kernel if it doesn't exist
if [[ ! -f ${KERNEL} ]]; then
  raw_kernel_path="$(find ./resources/${ARCH} -maxdepth 1 -regextype sed -regex ".*/vmlinux-6\.1\.[0-9]*" -type f)"
  if [[ -z $raw_kernel_path ]]; then
    ./tools/devtool build_ci_artifacts kernels $KERNEL_VERSION
    raw_kernel_path="$(find ./resources/${ARCH} -maxdepth 1 -regextype sed -regex ".*/vmlinux-6\.1\.[0-9]*" -type f)"
  fi

  # TODO: Allow KERNEL_VERSION to be used here
  cp $raw_kernel_path $KERNEL
fi

# Create a key pair
if [[ ! -f ${KEY_NAME} ]]; then
  ssh-keygen -t ed25519 -f "${KEY_NAME}" -N "" -q
  PUBLIC_KEY=$(cat "${KEY_NAME}.pub")
fi

# Download and setup the rootfs if it doesn't exist
if [[ ! -f ${ROOTFS} ]]; then
  rootfs_dir="rootfs-debian-${DEBIAN_VERSION}"

  # Create rootfs_dir
  echo "Creating ${rootfs_dir}"
  [[ -d "${rootfs_dir}" ]] || sudo rm -rf "${rootfs_dir}"
  mkdir -p "${rootfs_dir}"

  # Use debootstrap to create a standard rootfs
  sudo debootstrap --arch=amd64 "${DEBIAN_VERSION}" "${rootfs_dir}" http://deb.debian.org/debian/
  sudo mount --bind /proc "${rootfs_dir}/proc"
  sudo mount --bind /sys "${rootfs_dir}/sys"
  sudo mount --bind /dev "${rootfs_dir}/dev"
  sudo mount --bind /dev/pts "${rootfs_dir}/dev/pts" # Often needed too

  # Use chroot to configure the rootfs
  sudo chroot "${rootfs_dir}" /bin/bash -s <<EOF
  set -e

  apt update
  apt install -y openssh-server

  # Set a root password (password is "root")
  echo "root:root" | /usr/sbin/chpasswd

  # Set a hostname
  echo "microvm-debian-${DEBIAN_VERSION}" > /etc/hostname

  # Set up SSH for root login
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  echo "${PUBLIC_KEY}" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys

  # Clean up apt cache
  apt clean
EOF

  sudo umount "${rootfs_dir}/dev/pts"
  sudo umount "${rootfs_dir}/dev"
  sudo umount "${rootfs_dir}/sys"
  sudo umount "${rootfs_dir}/proc"

  # Create the rootfs image
  rm -f "${ROOTFS}"
  truncate -s "${ROOTFS_SIZE}" "${ROOTFS}"
  mkfs.ext4 "${ROOTFS}"

  # Create a temporary mount point to write everything to
  mount_dir=$(mktemp -d)
  sudo mount "${ROOTFS}" "${mount_dir}"
  sudo cp -a "${rootfs_dir}/." "${mount_dir}/"
  sudo umount "${mount_dir}"

  # Clean up
  sudo rm -rf "${rootfs_dir}"
  rmdir "${mount_dir}"
fi

# Create a jailer user/group, if they do not exist
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

# Copy the kernel and rootfs to the jail
if [[ ! -d $JAILER_ROOT_DIR ]]; then
  sudo mkdir -p $JAILER_ROOT_DIR
  sudo cp $KERNEL $JAILER_ROOT_DIR/kernel.bin
  sudo cp $ROOTFS $JAILER_ROOT_DIR/rootfs.ext4
  sudo cp $CONFIG_FILE $JAILER_ROOT_DIR/config.json
  sudo touch $JAILER_ROOT_DIR/out.log
  sudo chown -R jailer:jailer $JAILER_ROOT_DIR
fi

# Setup network interface
sudo ip link del "$TAP_DEV" 2> /dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${HOST_IP}${MASK_SHORT}" dev "$TAP_DEV"
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

sudo ${JAILER} \
    --exec-file ${FIRECRACKER} \
    --id ${ID} \
    --uid $(id -u jailer) \
    --gid $(id -g jailer) \
    --new-pid-ns \
    --daemonize \
    -- \
    --config-file config.json \
    --log-path out.log \
    --level debug
# sudo ${FIRECRACKER} \
#   --no-api \
#   --config-file ${CONFIG_FILE}

sleep 1s

echo "Created VM with ID ${ID}"
echo "Connect using the API socket found at ${JAILER_ROOT_DIR}/run/firecracker.socket"
echo
echo "Running ssh -i $KEY_NAME root@$GUEST_IP..."

ssh -i $KEY_NAME root@${GUEST_IP} || true

# Use `root` for both the login and password.
# Run `reboot` to exit.

function clean() {
  sudo ip link del $TAP_DEV
  sudo sh -c "echo 0 > /proc/sys/net/ipv4/ip_forward"
  sudo nft delete table firecracker
  sudo rm -rf "/srv/jailer/firecracker/$ID"
}

clean
