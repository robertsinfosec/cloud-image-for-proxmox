# openSUSE distro config (sourced by entrypoint)

DISTRO_NAME="opensuse"
IMAGE_URL_BASE="https://download.opensuse.org/repositories/Cloud:/Images:/"
OPENSUSE_DISTRO=$(echo "$RELEASE" | awk '{print tolower($0)}')
IMAGE_NAME_TEMPLATE="openSUSE-Leap-${VERSION}.x86_64-NoCloud.qcow2"
IMAGE_PATH="openSUSE_Leap_${VERSION}/images/${IMAGE_NAME_TEMPLATE}"
SHA256SUMS_PATH="${IMAGE_PATH}.sha256"

PKG_MANAGER="zypper"
PKGS=("qemu-guest-agent" "cloud-init" "firewalld" "watchdog")
OPTIONAL_PKGS=("fail2ban" "crowdsec")
VIRT_CUSTOMIZE_OPTS=(
  "--run-command 'truncate -s 0 /etc/machine-id'"
)
