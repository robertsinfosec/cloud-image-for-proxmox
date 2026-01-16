# openSUSE distro config (sourced by entrypoint)

DISTRO_NAME="opensuse"
IMAGE_URL_BASE="https://download.opensuse.org/repositories/Cloud:/Images:"
OPENSUSE_DISTRO=$(echo "$RELEASE" | awk '{print tolower($0)}')
if [[ "$OPENSUSE_DISTRO" == "leap" ]]; then
  OPENSUSE_DISTRO_LABEL="Leap"
else
  OPENSUSE_DISTRO_LABEL="$RELEASE"
fi
IMAGE_NAME_TEMPLATE="openSUSE-${OPENSUSE_DISTRO_LABEL}-${VERSION}.x86_64-NoCloud.qcow2"
IMAGE_PATH="${OPENSUSE_DISTRO_LABEL}_${VERSION}/images/${IMAGE_NAME_TEMPLATE}"
SHA256SUMS_PATH="${IMAGE_PATH}.sha256"

PKG_MANAGER="zypper"
# openSUSE cloud images already ship with cloud-init and qemu-guest-agent.
# Package install is skipped to avoid repo resolution failures during build.
SKIP_PKG_INSTALL="true"
PKGS=()
OPTIONAL_PKGS=()
VIRT_CUSTOMIZE_OPTS=(
  "--run-command"
  "truncate -s 0 /etc/machine-id"
)
