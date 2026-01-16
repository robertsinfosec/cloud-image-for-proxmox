# Oracle Linux distro config (sourced by entrypoint)

DISTRO_NAME="oraclelinux"
IMAGE_URL_BASE="https://yum.oracle.com"
IMAGE_NAME_TEMPLATE="OracleLinux-${RELEASE}-GenericCloud-latest.x86_64.qcow2"
IMAGE_PATH="templates/OracleLinux/OL${RELEASE}/u0/x86_64/${IMAGE_NAME_TEMPLATE}"
SHA256SUMS_PATH="templates/OracleLinux/OL${RELEASE}/u0/x86_64/CHECKSUM"

PKG_MANAGER="dnf"
PKGS=("qemu-guest-agent" "cloud-init" "firewalld" "watchdog")
OPTIONAL_PKGS=("fail2ban" "crowdsec")
VIRT_CUSTOMIZE_OPTS=(
  "--run-command"
  "truncate -s 0 /etc/machine-id"
)
