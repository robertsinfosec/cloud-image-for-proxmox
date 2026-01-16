# Alpine Linux distro config (sourced by entrypoint)

DISTRO_NAME="alpine"
IMAGE_URL_BASE="https://dl-cdn.alpinelinux.org/alpine"

# Alpine cloud images include a patch-level version in the filename.
# Use VERSION if provided; otherwise fall back to RELEASE.
IMAGE_VERSION="${VERSION:-$RELEASE}"
IMAGE_NAME_TEMPLATE="nocloud_alpine-${IMAGE_VERSION}-x86_64-bios-cloudinit-r0.qcow2"
IMAGE_PATH="v${RELEASE}/releases/cloud/${IMAGE_NAME_TEMPLATE}"
SHA256SUMS_PATH="v${RELEASE}/releases/cloud/SHA256SUMS"

PKG_MANAGER="apk"
PKGS=("qemu-guest-agent" "cloud-init" "nftables")
OPTIONAL_PKGS=("fail2ban" "crowdsec")
VIRT_CUSTOMIZE_OPTS=(
  "--run-command"
  "truncate -s 0 /etc/machine-id"
)
