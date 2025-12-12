#!/bin/sh

set -e

KERNEL="$(ls vmlinux-* | tail -1)"
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1"
ARCH=$(uname -m)

ROOTFS="$(ls rootfs-ubuntu-*.ext4 | tail -1)"

KEY_NAME="$(ls id_ed25519-ubuntu-* | tail -1)"
KEY_NAME="$(find . -maxdepth 1 -regextype sed -regex '\./id_ed25519-ubuntu-[0-9]+\.[0-9]+')"

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

API_SOCKET="/tmp/firecracker.socket"
LOGFILE="./firecracker.log"

# Download the kernel if it doesn't exist
if [[ -z ${KERNEL} ]]; then
  release_url="https://github.com/firecracker-microvm/firecracker/releases"
  latest_version=$(basename $(curl -fsSLI -o /dev/null -w  %{url_effective} ${release_url}/latest))
  CI_VERSION=${latest_version%.*}
  latest_kernel_key=$(curl "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-&list-type=2" \
      | grep -oP "(?<=<Key>)(firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
      | sort -V | tail -1)

  # Download a linux kernel binary
  wget "https://s3.amazonaws.com/spec.ccfc.min/${latest_kernel_key}"

  KERNEL="$(ls vmlinux-* | tail -1)"
fi

# Download the rootfs if it doesn't exist
if [[ -z ${ROOTFS} ]]; then
  release_url="https://github.com/firecracker-microvm/firecracker/releases"
  latest_version=$(basename $(curl -fsSLI -o /dev/null -w  %{url_effective} ${release_url}/latest))
  CI_VERSION=${latest_version%.*}
  latest_ubuntu_key=$(curl "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/${CI_VERSION}/${ARCH}/ubuntu-&list-type=2" \
      | grep -oP "(?<=<Key>)(firecracker-ci/${CI_VERSION}/${ARCH}/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" \
      | sort -V | tail -1)
  ubuntu_version=$(basename ${latest_ubuntu_key} .squashfs | grep -oE '[0-9]+\.[0-9]+')

  # Download a rootfs from Firecracker CI and unpack it
  wget -O ubuntu-${ubuntu_version}.squashfs "https://s3.amazonaws.com/spec.ccfc.min/${latest_ubuntu_key}"
  unsquashfs ubuntu-${ubuntu_version}.squashfs

  # The rootfs in our CI doesn't contain SSH keys to connect to the VM
  # For the purpose of this demo, let's create one and patch it in the rootfs
  KEY_NAME="id_ed25519-ubuntu-${ubuntu_version}"
  [[ -f ${KEY_NAME} ]] || ssh-keygen -f ${KEY_NAME} -N "" -q
  echo "$(${KEY_NAME}.pub)" > squashfs-root/root/.ssh/authorized_keys

  # create ext4 filesystem image
  ROOTFS="rootfs-ubuntu-${ubuntu_version}.ext4"
  truncate -s 1G ${ROOTFS}
  mkfs.ext4 -d squashfs-root -F ${ROOTFS}

  # Remove temporary files
  rm -rf squashfs-root ubuntu-${ubuntu_version}.squashfs
fi

echo
echo "The following files were downloaded and set up:"
[ -f ${KERNEL} ] && echo "Kernel: ${KERNEL}" || echo "ERROR: Kernel ${KERNEL} does not exist"
e2fsck -fn ${ROOTFS} &>/dev/null && echo "Rootfs: ${ROOTFS}" || echo "ERROR: ${ROOTFS} is not a valid ext4 fs"
[ -f ${KEY_NAME} ] && echo "SSH Key: ${KEY_NAME}" || echo "ERROR: Key ${KEY_NAME} does not exist"

# Setup network interface
sudo ip link del "${TAP_DEV}" 2> /dev/null || true
sudo ip tuntap add dev "${TAP_DEV}" mode tap
sudo ip addr add "${HOST_IP}${MASK_SHORT}" dev "${TAP_DEV}"
sudo ip link set dev "${TAP_DEV}" up

# Enable ip forwarding
sudo sh -c "echo 1 >/proc/sys/net/ipv4/ip_forward"

# Set up microVM internet access
sudo nft add table firecracker
sudo nft 'add chain firecracker postrouting { type nat hook postrouting priority srcnat; policy accept; }'
sudo nft 'add chain firecracker filter { type filter hook forward priority filter; policy accept; }'

sudo nft add rule firecracker postrouting ip saddr ${GUEST_IP} oifname ${HOST_IFACE} counter masquerade
sudo nft add rule firecracker filter iifname ${TAP_DEV} oifname ${HOST_IFACE} accept

# Create log file
touch ${LOGFILE}

# Set log file
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"log_path\": \"${LOGFILE}\",
        \"level\": \"Debug\",
        \"show_level\": true,
        \"show_log_origin\": true
    }" \
    "http://localhost/logger"

if [ ${ARCH} = "aarch64" ]; then
    KERNEL_BOOT_ARGS="keep_bootcon ${KERNEL_BOOT_ARGS}"
fi

# Set boot source
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"kernel_image_path\": \"${KERNEL}\",
        \"boot_args\": \"${KERNEL_BOOT_ARGS}\"
    }" \
    "http://localhost/boot-source"

# Set rootfs
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"${ROOTFS}\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }" \
    "http://localhost/drives/rootfs"

# Set network interface
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"iface_id\": \"net1\",
        \"guest_mac\": \"${FC_MAC}\",
        \"host_dev_name\": \"${TAP_DEV}\"
    }" \
    "http://localhost/network-interfaces/net1"

# API requests are handled asynchronously, it is important the configuration is
# set, before `InstanceStart`.
sleep 0.015s

# Start microVM
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"action_type\": \"InstanceStart\"
    }" \
    "http://localhost/actions"

# API requests are handled asynchronously, it is important the microVM has been
# started before we attempt to SSH into it.
sleep 2s

# Setup internet access in the guest
ssh -i ${KEY_NAME} root@172.16.0.2  "ip addr add ${GUEST_IP}${MASK_SHORT} dev eth0"
ssh -i ${KEY_NAME} root@172.16.0.2  "ip link set eth0 up"
ssh -i ${KEY_NAME} root@172.16.0.2  "ip route add default via ${HOST_IP} dev eth0"

# Set DNS nameserver
ssh -i ${KEY_NAME} root@172.16.0.2  "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"

# SSH into the microVM
ssh -i ${KEY_NAME} root@172.16.0.2

# Use `root` for both the login and password.
# Run `reboot` to exit.

# Clean up networking
sudo ip link del tap0
sudo sh -c "echo 0 >/proc/sys/net/ipv4/ip_forward"
sudo nft delete table firecracker
