# Rocky Linux distro config (sourced by entrypoint)

DISTRO_NAME="rockylinux"
IMAGE_URL_BASE="https://dl.rockylinux.org/pub/rocky"

ROCKY_BASE_VER=$(echo "$VERSION" | awk '{ sub(/.[0-9]{1,2}-[0-9]{6,8}.[0-9]{1,2}$/, ""); print }')
if [[ "$ROCKY_BASE_VER" == "$VERSION" ]]; then
  IMAGE_NAME_TEMPLATE="Rocky-${ROCKY_BASE_VER}-GenericCloud-Base.latest.x86_64.qcow2"
else
  IMAGE_NAME_TEMPLATE="Rocky-${ROCKY_BASE_VER}-GenericCloud-Base-${VERSION}.x86_64.qcow2"
fi

IMAGE_PATH="${ROCKY_BASE_VER}/images/x86_64/${IMAGE_NAME_TEMPLATE}"
SHA256SUMS_PATH="${ROCKY_BASE_VER}/images/x86_64/CHECKSUM"

PKG_MANAGER="dnf"
PKGS=("epel-release" "qemu-guest-agent" "cloud-init" "firewalld" "watchdog" "fail2ban")
VIRT_CUSTOMIZE_OPTS=(
  "--selinux-relabel"
  "--run-command"
  "truncate -s 0 /etc/machine-id"
)

# Rocky Linux 9+ requires Proxmox CPU type 'host' to avoid kernel panics.
VM_CPU_TYPE="host"
# Serial console used for Rocky Linux troubleshooting on Proxmox.
VM_SERIAL0="socket"
VM_VGA="serial0"
