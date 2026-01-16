# Alpine Linux distro config (sourced by entrypoint)

DISTRO_NAME="alpine"
IMAGE_URL_BASE="https://dl-cdn.alpinelinux.org/alpine"

# Alpine cloud images use the full VERSION (e.g., 3.23.0) in the filename
# but RELEASE (e.g., 3.23) in the path.
IMAGE_NAME_TEMPLATE="nocloud_alpine-${VERSION}-x86_64-bios-cloudinit-r0.qcow2"
IMAGE_PATH="v${RELEASE}/releases/cloud/${IMAGE_NAME_TEMPLATE}"
SHA256SUMS_PATH="v${RELEASE}/releases/cloud/${IMAGE_NAME_TEMPLATE}.sha512"

PKG_MANAGER="apk"
PKGS=("qemu-guest-agent" "cloud-init" "nftables")
VIRT_CUSTOMIZE_OPTS=(
  "--run-command"
  "truncate -s 0 /etc/machine-id"
)
