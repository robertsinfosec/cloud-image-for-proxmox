# Oracle Linux distro config (sourced by entrypoint)

DISTRO_NAME="oraclelinux"
IMAGE_URL_BASE="https://yum.oracle.com"

# Oracle Linux uses major.minor versioning (e.g., 10.0, 9.6, 8.10)
# Extract major version for path construction
MAJOR_VERSION="${VERSION%%.*}"
# Extract minor/update number (e.g., 9.6 -> 6, 8.10 -> 10)
MINOR_VERSION="${VERSION#*.}"

# Path to the directory containing the image
# Specific filename should be provided via image_filename override in builds config
# Path format: templates/OracleLinux/OL{major}/u{minor}/x86_64/
IMAGE_PATH="templates/OracleLinux/OL${MAJOR_VERSION}/u${MINOR_VERSION}/x86_64"

# Note: IMAGE_PATH will be updated with actual filename via image_filename override
# Example filenames: OL10U0_x86_64-kvm-b266.qcow2, OL9U6_x86_64-kvm-b265.qcow2

# Oracle Linux does not provide programmatic checksum files
# Checksums are displayed on: https://yum.oracle.com/oracle-linux-templates.html
# Leave empty to skip checksum validation
SHA256SUMS_PATH=""

PKG_MANAGER="dnf"
PKGS=("qemu-guest-agent" "cloud-init" "firewalld" "watchdog")
VIRT_CUSTOMIZE_OPTS=(
  "--run-command"
  "truncate -s 0 /etc/machine-id"
)
