# Ubuntu distro config (sourced by entrypoint)

DISTRO_NAME="ubuntu"
IMAGE_URL_BASE="https://cloud-images.ubuntu.com"
if [[ "$VERSION" == "16.04" || "$RELEASE" == "xenial" ]]; then
  IMAGE_NAME_TEMPLATE="${RELEASE}-server-cloudimg-amd64-disk1.img"
else
  IMAGE_NAME_TEMPLATE="${RELEASE}-server-cloudimg-amd64.img"
fi
SHA256SUMS_PATH="${RELEASE}/current/SHA256SUMS"
IMAGE_PATH="${RELEASE}/current/${IMAGE_NAME_TEMPLATE}"

# Packages and customize steps (entrypoint decides how to apply)
PKG_MANAGER="apt"
PKGS=("qemu-guest-agent" "cloud-init" "ufw" "watchdog" "fail2ban")
VIRT_CUSTOMIZE_OPTS=(
  "--run-command"
  "truncate -s 0 /etc/machine-id"
)
