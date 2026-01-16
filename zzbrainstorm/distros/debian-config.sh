# Debian distro config (sourced by entrypoint)

DISTRO_NAME="debian"
IMAGE_URL_BASE="https://cloud.debian.org/images/cloud"
RELEASE_LOWER=$(echo "$RELEASE" | awk '{print tolower($0)}')
IMAGE_NAME_TEMPLATE="debian-${VERSION}-genericcloud-amd64.qcow2"
IMAGE_PATH="${RELEASE_LOWER}/latest/${IMAGE_NAME_TEMPLATE}"
SHA256SUMS_PATH="${RELEASE_LOWER}/latest/SHA512SUMS"

PKG_MANAGER="apt"
PKGS=("qemu-guest-agent" "cloud-init" "ufw" "watchdog")
VIRT_CUSTOMIZE_OPTS=(
  "--run-command"
  "truncate -s 0 /etc/machine-id"
)

# Debian kernels require Proxmox CPU type 'host' to avoid boot issues.
VM_CPU_TYPE="host"
