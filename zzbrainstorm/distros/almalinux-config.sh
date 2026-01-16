# AlmaLinux distro config (sourced by entrypoint)

DISTRO_NAME="almalinux"
IMAGE_URL_BASE="https://repo.almalinux.org/almalinux"
IMAGE_NAME_TEMPLATE="AlmaLinux-${RELEASE}-GenericCloud-latest.x86_64.qcow2"
IMAGE_PATH="${RELEASE}/cloud/x86_64/images/${IMAGE_NAME_TEMPLATE}"
SHA256SUMS_PATH="${RELEASE}/cloud/x86_64/images/CHECKSUM"

PKG_MANAGER="dnf"
PKGS=("epel-release" "qemu-guest-agent" "cloud-init" "firewalld" "watchdog" "fail2ban")
VIRT_CUSTOMIZE_OPTS=(
  "--selinux-relabel"
  "--run-command"
  "truncate -s 0 /etc/machine-id"
)

# AlmaLinux 9+ requires Proxmox CPU type 'host' to avoid kernel panics.
VM_CPU_TYPE="host"
# Serial console used for AlmaLinux troubleshooting on Proxmox.
VM_SERIAL0="socket"
VM_VGA="serial0"
