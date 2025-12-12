set -e

source ./run_microvm.sh

# Make sure all the commands used exist, to make things more atomic

assert_commands_exist curl debootstrap nft jq

ARCH=$(uname -m)
DEBIAN_VERSION="bookworm"
ROOTFS_SIZE="1G"
UUID="$(uuidgen | tr A-Z a-z)"

JAILER_ROOT_DIR="/srv/jailer/firecracker/$UUID/root"
#API_SOCKET="${JAILER_ROOT_DIR}/run/firecracker.socket"

TMP_DIR="/tmp/$UUID"
UFFD_SOCKET="/tmp"

# KERNEL="kernel-debian-${DEBIAN_VERSION}.bin"
KERNEL_VERSION="6.1"
#KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off ip=172.16.0.2::172.16.0.1:255.255.255.252::eth0:off i8042.noaux i8042.nomux i8042.nopnp i8042.nokbd quiet loglevel=1"
ROOTFS_PATH="rootfs-debian-${DEBIAN_VERSION}.ext4"
ROOTFS_SIZE="1G"

KEY_NAME="id_ed25519-debian-${DEBIAN_VERSION}"
PUBLIC_KEY=$(cat "${KEY_NAME}.pub" 2>/dev/null || true)

# Networking information
TAP_DEV="tap0"
HOST_IP="172.16.0.1"
GUEST_IP="172.16.0.2"
MASK_SHORT="/30"

# This tries to determine the name of the host network interface to forward
# VM's outbound network traffic through. If outbound traffic doesn't work,
# double check this returns the correct interface!
HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev')
# The IP address of a guest is derived from its MAC address with
# `fcnet-setup.sh`, this has been pre-configured in the guest rootfs. It is
# important that `TAP_IP` and `FC_MAC` match this.
FC_MAC="06:00:AC:10:00:02"

# The configuration file will be built by the script
CONFIG_PATH="microvm_config-debian-${DEBIAN_VERSION}.json"
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off ip=${GUEST_IP}::${HOST_IP}:255.255.255.252::eth0:off quiet loglevel=1"

LOGFILE="log-debian-${DEBIAN_VERSION}.log"
JAILER="./build/cargo_target/x86_64-unknown-linux-musl/debug/jailer"
FIRECRACKER="./build/cargo_target/x86_64-unknown-linux-musl/debug/firecracker"

# Build firecracker if it doesn't exist
[[ -f ${FIRECRACKER} ]] || sudo ./tools/devtool build

# Download the kernel if it doesn't exist
KERNEL_PATH=$(build_kernel $KERNEL_VERSION $ARCH)

# Create a key pair
PUBLIC_KEY="$(create_ssh_keypair $KEY_NAME)"

# Download and setup the rootfs if it doesn't exist
if [[ ! -f ${ROOTFS_PATH} ]]; then
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
  rm -f "${ROOTFS_PATH}"
  truncate -s "${ROOTFS_SIZE}" "${ROOTFS_PATH}"
  sudo mkfs.ext4 "${ROOTFS_PATH}"

  # Create a temporary mount point to write everything to
  mount_dir=$(mktemp -d)
  sudo mount "${ROOTFS_PATH}" "${mount_dir}"
  sudo cp -a "${rootfs_dir}/." "${mount_dir}/"
  sudo umount "${mount_dir}"

  # Clean up
  sudo rm -rf "${rootfs_dir}"
  rmdir "${mount_dir}"
fi

# We are using the jailer, so we need to create the jailer user
create_jailer_user

# Build the config file
cat <<EOF > ${CONFIG_PATH}
{
  "boot-source": {
    "kernel_image_path": "kernel.bin",
    "boot_args": "$KERNEL_BOOT_ARGS"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "rootfs.ext4",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "network-interfaces": [
      {
          "iface_id": "eth0",
          "guest_mac": "$FC_MAC",
          "host_dev_name": "$TAP_DEV"
      }
  ],
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 1024,
    "smt": false,
    "track_dirty_pages": true
  },
  "logger": {
    "log_path": "out.log",
    "level": "Debug",
    "show_level": true,
    "show_log_origin": true
  }
}
EOF
echo "Config written to ${CONFIG_PATH}"

# Prepare the jail's root dir
prepare_jailer_root_dir $JAILER_ROOT_DIR $KERNEL_PATH $ROOTFS_PATH $CONFIG_PATH

# Enable networking for the MicroVM
enable_networking $TAP_DEV "$HOST_IP$MASK_SHORT" $GUEST_IP $HOST_IFACE

sudo $JAILER \
    --exec-file $FIRECRACKER \
    --id $UUID \
    --uid $(id -u jailer) \
    --gid $(id -g jailer) \
    --new-pid-ns \
    --daemonize \
    -- \
    --config-file config.json
# sudo ${FIRECRACKER} \
#   --no-api \
#   --config-file ${CONFIG_FILE}

# Sleep for a bit to give the VM time to start
sleep 1s

echo "Created VM with UUID $UUID"
echo "Jailer root is at /srv/jailer/firecracker/<ID>/root"
echo
echo "Running the following (DO NOT LOG OUT; use \`reboot\` to shutdown the VM):"
echo -e "ssh -i $KEY_NAME root@$GUEST_IP"
echo

ssh -i $KEY_NAME root@${GUEST_IP} || true

# Use `root` for both the login and password.
# Run `reboot` to exit.

sudo cp "$JAILER_ROOT_DIR/out.log" ./$LOGFILE
echo "Logs written to $LOGFILE"

function clean() {

  echo "Cleaning VM $UUID"

  disable_neworking $TAP_DEV
  sudo rm -rf "/srv/jailer/firecracker/$UUID"
}

clean

exit 0
