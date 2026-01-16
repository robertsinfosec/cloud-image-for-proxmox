# CentOS distro config (sourced by entrypoint)

DISTRO_NAME="centos"
IMAGE_URL_BASE="https://cloud.centos.org/centos"

if [[ "$RELEASE" == "8" || "$RELEASE" == "8-stream" ]]; then
  RELEASE_STREAM="8-stream"
  IMAGE_NAME_TEMPLATE="CentOS-Stream-GenericCloud-8-latest.0.x86_64.qcow2"
else
  RELEASE_STREAM="9-stream"
  IMAGE_NAME_TEMPLATE="CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
fi

IMAGE_PATH="${RELEASE_STREAM}/x86_64/images/${IMAGE_NAME_TEMPLATE}"
SHA256SUMS_PATH="${RELEASE_STREAM}/x86_64/images/CHECKSUM"

PKG_MANAGER="dnf"
PKGS=("epel-release" "qemu-guest-agent" "cloud-init" "firewalld" "watchdog")
OPTIONAL_PKGS=("fail2ban" "crowdsec")
VIRT_CUSTOMIZE_OPTS=(
  "--selinux-relabel"
  "--run-command"
  "truncate -s 0 /etc/machine-id"
)

# CentOS Stream 9+ requires Proxmox CPU type 'host' to avoid kernel panics.
VM_CPU_TYPE="host"
# Serial console used for CentOS troubleshooting on Proxmox.
VM_SERIAL0="socket"
VM_VGA="serial0"
