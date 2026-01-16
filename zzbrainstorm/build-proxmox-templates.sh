#!/bin/bash

set -euo pipefail

Black='\033[0;30m'
DarkGray='\033[1;30m'
Red='\033[0;31m'
LightRed='\033[1;31m'
Green='\033[0;32m'
LightGreen='\033[1;32m'
Brown='\033[0;33m'
Yellow='\033[1;33m'
Blue='\033[0;34m'
LightBlue='\033[1;34m'
Purple='\033[0;35m'
LightPurple='\033[1;35m'
Cyan='\033[0;36m'
LightCyan='\033[1;36m'
LightGray='\033[0;37m'
White='\033[1;37m'
NC='\033[0m' # No Color

Name='ProxMox Cloud Init Creator'
Version='v2.0.0'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_ROOT="$SCRIPT_DIR"
CONFIG_DIR=""
DISTROS_DIR=""
DEFAULTS_FILE=""

ONLY_FILTERS=()

usage() {
    echo "Usage: $0 [--only <distro[:release]>] [--only <distro[:release]>] [--configroot <path>]"
    echo "  --only       Filter builds (repeatable), e.g. --only debian or --only debian:trixie"
    echo "  --configroot Root directory containing config/, distros/ (default: script directory)"
}

setStatus() {
    local description=$1
    local severity=$2

    if [[ "${NO_SYSLOG:-false}" != "true" ]]; then
        logger "$Name $Version: [${severity}] $description"
    fi

    case "$severity" in
        s)
            echo -e "[${LightGreen}+${NC}] ${LightGreen}${description}${NC}"
        ;;
        f)
            echo -e "[${Red}-${NC}] ${LightRed}${description}${NC}"
        ;;
        q)
            echo -e "[${LightPurple}?${NC}] ${LightPurple}${description}${NC}"
        ;;
        *)
            echo -e "[${LightCyan}*${NC}] ${LightCyan}${description}${NC}"
        ;;
    esac
}

require_root() {
    if [[ $(whoami) != "root" ]]; then
        echo "ERROR: This utility must be run as root (or sudo)."
        exit 1
    fi
}

check_command() {
    local cmd=$1
    local help_text=$2
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found."
        if [[ -n "$help_text" ]]; then
            echo "$help_text"
        fi
        exit 1
    fi
}

check_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
            echo "ERROR: 'yq' is required to parse YAML."
            echo "Install mikefarah/yq v4 or run without --non-interactive to install it."
            exit 1
        fi

        echo "Utility 'yq' is required to parse YAML."
        read -r -p "Install mikefarah/yq v4 now? [y/N]: " reply
        if [[ "$reply" != "y" && "$reply" != "Y" ]]; then
            echo "ERROR: 'yq' not installed."
            exit 1
        fi

        if ! command -v wget >/dev/null 2>&1; then
            echo "ERROR: 'wget' is required to install yq."
            exit 1
        fi

        local version="v4.2.0"
        local platform
        case "$(uname -m)" in
            x86_64) platform="linux_amd64" ;;
            aarch64|arm64) platform="linux_arm64" ;;
            *)
                echo "ERROR: Unsupported architecture for automatic yq install: $(uname -m)"
                exit 1
                ;;
        esac

        local url="https://github.com/mikefarah/yq/releases/download/${version}/yq_${platform}"
        echo "Installing yq from: $url"
        if wget "$url" -O /usr/local/bin/yq; then
            chmod +x /usr/local/bin/yq
        else
            echo "ERROR: Failed to download yq."
            exit 1
        fi
    fi

    local yq_version
    yq_version=$(yq --version 2>/dev/null || true)
    if [[ "$yq_version" != *"mikefarah"* && "$yq_version" != *"version 4"* ]]; then
        echo "ERROR: This script requires mikefarah/yq v4 (supports 'yq eval -r')."
        echo "The detected 'yq' appears to be the Python wrapper."
        echo "Install mikefarah/yq v4 and ensure it is first in PATH."
        exit 1
    fi
}

check_libguestfs() {
    if ! command -v virt-customize >/dev/null 2>&1; then
        echo "ERROR: 'virt-customize' is required (libguestfs-tools)."
        echo "Install: apt-get install libguestfs-tools"
        exit 1
    fi
}

yq_read() {
    local query=$1
    local file=$2
    yq eval --unwrapScalar "$query" "$file"
}

resolve_value() {
    local build_file=$1
    local build_index=$2
    local override_path=$3
    local default_value=$4

    local override_value
    override_value=$(yq_read ".builds[$build_index].override.${override_path} // \"\"" "$build_file")
    if [[ -n "$override_value" && "$override_value" != "null" ]]; then
        echo "$override_value"
    else
        echo "$default_value"
    fi
}

resolve_bool() {
    local build_file=$1
    local build_index=$2
    local override_path=$3
    local default_value=$4

    local override_value
    override_value=$(yq_read ".builds[$build_index].override.${override_path}" "$build_file")
    if [[ "$override_value" == "true" || "$override_value" == "false" ]]; then
        echo "$override_value"
    else
        echo "$default_value"
    fi
}

read_tags() {
    local build_file=$1
    local build_index=$2

    local override_len
    override_len=$(yq_read ".builds[$build_index].override.tags | length" "$build_file" 2>/dev/null || echo 0)

    if [[ "$override_len" != "0" && "$override_len" != "null" ]]; then
        yq_read ".builds[$build_index].override.tags[]" "$build_file"
    else
        yq_read ".defaults.tags[]" "$DEFAULTS_FILE"
    fi
}

join_tags() {
    local tags=()
    while IFS= read -r tag; do
        [[ -n "$tag" ]] && tags+=("$tag")
    done

    local unique_tags=()
    declare -A seen
    for tag in "${tags[@]}"; do
        if [[ -z "${seen[$tag]:-}" ]]; then
            unique_tags+=("$tag")
            seen[$tag]=1
        fi
    done

    local IFS=','
    echo "${unique_tags[*]}"
}

ensure_password_file_secure() {
    local password_file=$1
    if [[ ! -f "$password_file" ]]; then
        echo "ERROR: Password file '$password_file' does not exist."
        exit 1
    fi

    local perms
    perms=$(stat -c "%a" "$password_file")
    local other_read=$((perms % 10))
    if (( other_read >= 4 )); then
        echo "ERROR: Password file '$password_file' is world-readable."
        echo "Fix with: chmod 600 '$password_file' (or 660 if group-readable is needed)."
        exit 1
    fi
}

get_hash_command() {
    local hash_path=$1
    local hash_type=${2:-""}

    if [[ -z "$hash_type" ]]; then
        if [[ "$hash_path" == *"SHA512"* ]]; then
            hash_type="sha512"
        else
            hash_type="sha256"
        fi
    fi

    case "$hash_type" in
        sha512) echo "sha512sum" ;;
        sha256) echo "sha256sum" ;;
        *) echo "sha256sum" ;;
    esac
}

extract_hash_from_file() {
    local hash_file=$1
    local image_name=$2

    local hash
    hash=$(grep -E "(\*| )${image_name}$" "$hash_file" | awk '{print $1}' | head -n1)
    if [[ -n "$hash" ]]; then
        echo "$hash"
        return 0
    fi

    hash=$(grep -E "SHA256 \(${image_name}\)" "$hash_file" | awk -F '=' '{print $2}' | xargs | head -n1)
    if [[ -n "$hash" ]]; then
        echo "$hash"
        return 0
    fi

    hash=$(grep -E "SHA512 \(${image_name}\)" "$hash_file" | awk -F '=' '{print $2}' | xargs | head -n1)
    if [[ -n "$hash" ]]; then
        echo "$hash"
        return 0
    fi

    hash=$(awk 'NF==1 {print $1}' "$hash_file" | head -n1)
    if [[ -n "$hash" ]]; then
        echo "$hash"
        return 0
    fi

    echo ""
    return 1
}

collect_build_meta() {
    local build_file=$1
    local build_index=$2

    BUILD_DISTRO=$(yq_read ".builds[$build_index].distro" "$build_file")
    BUILD_RELEASE=$(yq_read ".builds[$build_index].release" "$build_file")
    BUILD_VERSION=$(yq_read ".builds[$build_index].version" "$build_file")
    BUILD_VMID=$(yq_read ".builds[$build_index].vmid" "$build_file")

    if [[ -z "$BUILD_VERSION" || "$BUILD_VERSION" == "null" ]]; then
        BUILD_VERSION=""
    fi

    if [[ -z "$BUILD_RELEASE" || "$BUILD_RELEASE" == "null" ]]; then
        echo "ERROR: Missing release in $build_file (index $build_index)."
        return 1
    fi

    if [[ -z "$BUILD_VERSION" ]]; then
        BUILD_VERSION="$BUILD_RELEASE"
    fi

    if [[ -z "$BUILD_DISTRO" || -z "$BUILD_VMID" ]]; then
        echo "ERROR: Missing required build fields in $build_file (index $build_index)."
        return 1
    fi

    BUILD_STORAGE=$(resolve_value "$build_file" "$build_index" "storage" "$DEFAULT_STORAGE")
    if [[ -z "$BUILD_STORAGE" || "$BUILD_STORAGE" == "null" ]]; then
        echo "ERROR: Storage not set. Configure defaults.storage or override.storage."
        return 1
    fi

    return 0
}

matches_filter() {
    local distro=$1
    local release=$2
    local version=$3
    local filter=$4

    if [[ "$filter" == "$distro" ]]; then
        return 0
    fi

    if [[ "$filter" == "$distro:"* ]]; then
        local target=${filter#*:}
        if [[ "$target" == "$release" || "$target" == "$version" ]]; then
            return 0
        fi
    fi

    return 1
}

build_optional_install_cmd() {
    local manager=$1
    shift
    local pkgs=("$@")
    local joined
    joined=$(printf "%s " "${pkgs[@]}")

    case "$manager" in
        apt)
            echo "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ${joined} || true"
            ;;
        dnf)
            echo "dnf -y install ${joined} || true"
            ;;
        zypper)
            echo "zypper -n in ${joined} || true"
            ;;
        apk)
            echo "apk add --no-cache ${joined} || true"
            ;;
        *)
            echo ""
            ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)
            shift
            [[ -n "${1:-}" ]] || { echo "ERROR: --only requires a value"; exit 1; }
            ONLY_FILTERS+=("$1")
            ;;
        --configroot)
            shift
            [[ -n "${1:-}" ]] || { echo "ERROR: --configroot requires a value"; exit 1; }
            CONFIG_ROOT="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

CONFIG_DIR="$CONFIG_ROOT/config"
DISTROS_DIR="$CONFIG_ROOT/distros"
DEFAULTS_FILE="$CONFIG_DIR/_defaults.yaml"

if [[ ! -f "$DEFAULTS_FILE" ]]; then
    echo "ERROR: Defaults file not found: $DEFAULTS_FILE"
    exit 1
fi

if [[ ! -d "$CONFIG_DIR" ]]; then
    echo "ERROR: Config directory not found: $CONFIG_DIR"
    exit 1
fi

if [[ ! -d "$DISTROS_DIR" ]]; then
    echo "ERROR: Distros directory not found: $DISTROS_DIR"
    exit 1
fi

echo -e "${LightPurple}$Name $Version${NC}"
echo ""
setStatus "Initializing environment" "*"

setStatus "Checking runtime prerequisites" "*"
require_root
check_yq
check_command wget "Install wget and retry."
check_command qm "This script must be run on a Proxmox host."
check_command pvesm "This script must be run on a Proxmox host."
check_libguestfs
setStatus "Runtime prerequisites OK" "s"

NO_SYSLOG=$(yq_read ".defaults.behavior.no_syslog" "$DEFAULTS_FILE")

DEFAULT_STORAGE=$(yq_read ".defaults.storage" "$DEFAULTS_FILE")
DEFAULT_CI_USER=$(yq_read ".defaults.cloud_init.user" "$DEFAULTS_FILE")
DEFAULT_CI_PASSWORD_FILE=$(yq_read ".defaults.cloud_init.password_file" "$DEFAULTS_FILE")
DEFAULT_SEARCH_DOMAIN=$(yq_read ".defaults.cloud_init.search_domain" "$DEFAULTS_FILE")
DEFAULT_SSH_KEYS_ID=$(yq_read ".defaults.cloud_init.ssh_keys_id" "$DEFAULTS_FILE")
DEFAULT_SSH_KEYS_FILE=$(yq_read ".defaults.cloud_init.ssh_keys_file" "$DEFAULTS_FILE")
DEFAULT_SSH_KEYS_URL=$(yq_read ".defaults.cloud_init.ssh_keys_url" "$DEFAULTS_FILE")

DEFAULT_CORES=$(yq_read ".defaults.vm.cores" "$DEFAULTS_FILE")
DEFAULT_MEMORY=$(yq_read ".defaults.vm.memory" "$DEFAULTS_FILE")
DEFAULT_DISK_SIZE=$(yq_read ".defaults.vm.disk_size" "$DEFAULTS_FILE")
DEFAULT_BRIDGE=$(yq_read ".defaults.vm.bridge" "$DEFAULTS_FILE")
DEFAULT_OSTYPE=$(yq_read ".defaults.vm.ostype" "$DEFAULTS_FILE")
DEFAULT_AGENT=$(yq_read ".defaults.vm.agent" "$DEFAULTS_FILE")
DEFAULT_IPCONFIG0=$(yq_read ".defaults.vm.ipconfig0" "$DEFAULTS_FILE")
DEFAULT_WATCHDOG=$(yq_read ".defaults.vm.watchdog" "$DEFAULTS_FILE")

DEFAULT_CACHE_DIR=$(yq_read ".defaults.cache.dir" "$DEFAULTS_FILE")
DEFAULT_CACHE_KEEP=$(yq_read ".defaults.cache.keep" "$DEFAULTS_FILE")
DEFAULT_NON_INTERACTIVE=$(yq_read ".defaults.behavior.non_interactive" "$DEFAULTS_FILE")

setStatus "Scanning build files" "*"
BUILD_FILES=()
while IFS= read -r -d '' file; do
    BUILD_FILES+=("$file")
done < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name "*-builds.yaml" ! -name "*.disabled" -print0)

if [[ ${#BUILD_FILES[@]} -eq 0 ]]; then
    echo "ERROR: No build files found in $CONFIG_DIR"
    exit 1
fi
setStatus "Found ${#BUILD_FILES[@]} build file(s)" "s"

setStatus "Planning build execution" "*"
PLANNED_BUILDS=()
for build_file in "${BUILD_FILES[@]}"; do
    build_count=$(yq_read ".builds | length" "$build_file")
    if [[ "$build_count" == "null" || "$build_count" == "0" ]]; then
        continue
    fi

    for ((i=0; i<build_count; i++)); do
        if ! collect_build_meta "$build_file" "$i"; then
            exit 1
        fi

        if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
            matched=false
            for filter in "${ONLY_FILTERS[@]}"; do
                if matches_filter "$BUILD_DISTRO" "$BUILD_RELEASE" "$BUILD_VERSION" "$filter"; then
                    matched=true
                    break
                fi
            done
            if [[ "$matched" != "true" ]]; then
                continue
            fi
        fi

        PLANNED_BUILDS+=("${BUILD_DISTRO}|${BUILD_VERSION}|${BUILD_RELEASE}|${BUILD_VMID}|${BUILD_STORAGE}")
    done
done

if [[ ${#PLANNED_BUILDS[@]} -eq 0 ]]; then
    setStatus "No builds matched filters." "f"
    exit 1
fi

setStatus "Planned builds:" "*"
for entry in "${PLANNED_BUILDS[@]}"; do
    IFS='|' read -r distro version release vmid storage <<< "$entry"
    echo "  - ${distro} ${version} (${release}) VMID ${vmid} storage ${storage}"
done
echo ""

for build_file in "${BUILD_FILES[@]}"; do
    build_count=$(yq_read ".builds | length" "$build_file")
    if [[ "$build_count" == "null" || "$build_count" == "0" ]]; then
        continue
    fi

    for ((i=0; i<build_count; i++)); do
        if ! collect_build_meta "$build_file" "$i"; then
            exit 1
        fi

        distro="$BUILD_DISTRO"
        release="$BUILD_RELEASE"
        version="$BUILD_VERSION"
        vmid="$BUILD_VMID"
        storage="$BUILD_STORAGE"

        if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
            matched=false
            for filter in "${ONLY_FILTERS[@]}"; do
                if matches_filter "$distro" "$release" "$version" "$filter"; then
                    matched=true
                    break
                fi
            done
            if [[ "$matched" != "true" ]]; then
                continue
            fi
        fi

        CI_USER=$(resolve_value "$build_file" "$i" "cloud_init.user" "$DEFAULT_CI_USER")
        CI_PASSWORD_FILE=$(resolve_value "$build_file" "$i" "cloud_init.password_file" "$DEFAULT_CI_PASSWORD_FILE")
        SEARCH_DOMAIN=$(resolve_value "$build_file" "$i" "cloud_init.search_domain" "$DEFAULT_SEARCH_DOMAIN")
        SSH_KEYS_ID=$(resolve_value "$build_file" "$i" "cloud_init.ssh_keys_id" "$DEFAULT_SSH_KEYS_ID")
        SSH_KEYS_FILE=$(resolve_value "$build_file" "$i" "cloud_init.ssh_keys_file" "$DEFAULT_SSH_KEYS_FILE")
        SSH_KEYS_URL=$(resolve_value "$build_file" "$i" "cloud_init.ssh_keys_url" "$DEFAULT_SSH_KEYS_URL")


        CORES=$(resolve_value "$build_file" "$i" "vm.cores" "$DEFAULT_CORES")
        MEMORY=$(resolve_value "$build_file" "$i" "vm.memory" "$DEFAULT_MEMORY")
        DISK_SIZE=$(resolve_value "$build_file" "$i" "vm.disk_size" "$DEFAULT_DISK_SIZE")
        BRIDGE=$(resolve_value "$build_file" "$i" "vm.bridge" "$DEFAULT_BRIDGE")
        OSTYPE=$(resolve_value "$build_file" "$i" "vm.ostype" "$DEFAULT_OSTYPE")
        AGENT=$(resolve_bool "$build_file" "$i" "vm.agent" "$DEFAULT_AGENT")
        IPCONFIG0=$(resolve_value "$build_file" "$i" "vm.ipconfig0" "$DEFAULT_IPCONFIG0")
        WATCHDOG=$(resolve_value "$build_file" "$i" "vm.watchdog" "$DEFAULT_WATCHDOG")

        CACHE_DIR=$(resolve_value "$build_file" "$i" "cache.dir" "$DEFAULT_CACHE_DIR")
        CACHE_KEEP=$(resolve_bool "$build_file" "$i" "cache.keep" "$DEFAULT_CACHE_KEEP")
        NON_INTERACTIVE=$(resolve_bool "$build_file" "$i" "behavior.non_interactive" "$DEFAULT_NON_INTERACTIVE")

        ensure_password_file_secure "$CI_PASSWORD_FILE"
        CI_PASSWORD=$(<"$CI_PASSWORD_FILE")

        if ! pvesm status | grep -q "^$storage"; then
            echo "ERROR: Storage device '$storage' does not exist."
            exit 1
        fi

        if [[ ! -f "$DISTROS_DIR/${distro}-config.sh" ]]; then
            echo "ERROR: Missing distro config: $DISTROS_DIR/${distro}-config.sh"
            exit 1
        fi

        RELEASE="$release"
        VERSION="$version"
        source "$DISTROS_DIR/${distro}-config.sh"

        IMAGE_URL="${IMAGE_URL_BASE%/}/${IMAGE_PATH#/}"
        HASH_URL="${IMAGE_URL_BASE%/}/${SHA256SUMS_PATH#/}"

        HASH_CMD=$(get_hash_command "$SHA256SUMS_PATH" "${HASH_TYPE:-}")

        mkdir -p "$CACHE_DIR"

        IMAGE_BASENAME=$(basename "$IMAGE_PATH")
        HASH_BASENAME=$(basename "$SHA256SUMS_PATH")

        IMAGE_ORIG="$CACHE_DIR/${IMAGE_BASENAME}.orig"
        HASH_FILE="$CACHE_DIR/${distro}-${release}-${HASH_BASENAME}"
        WORK_IMAGE="$CACHE_DIR/${distro}-${version}-${release}-work.qcow2"

        setStatus "Building ${distro} ${version} (${release}) as VMID ${vmid}" "*"

        HASHES_MATCH=0
        ATTEMPT=0

        while [[ $HASHES_MATCH -lt 1 ]]; do
            ATTEMPT=$((ATTEMPT+1))
            setStatus "Checking image cache (attempt: $ATTEMPT)" "*"

            if [[ ! -f "$IMAGE_ORIG" || "$HASHES_MATCH" -eq 0 ]]; then
                setStatus "Downloading image: $IMAGE_URL" "*"
                if ! wget -q "$IMAGE_URL" -O "$IMAGE_ORIG"; then
                    setStatus "Download failed." "f"
                fi
            fi

            setStatus "Downloading checksum file: $HASH_URL" "*"
            if ! wget -q "$HASH_URL" -O "$HASH_FILE"; then
                setStatus "Checksum download failed." "f"
                exit 1
            fi

            setStatus "Generating image hash (${HASH_CMD})" "*"
            HASH_ONDISK=$($HASH_CMD "$IMAGE_ORIG" | awk '{print $1}')

            setStatus "Extracting hash from checksum file" "*"
            HASH_FROMINET=$(extract_hash_from_file "$HASH_FILE" "$IMAGE_BASENAME")

            if [[ -z "$HASH_FROMINET" ]]; then
                setStatus "Checksum file does not contain entry for ${IMAGE_BASENAME}" "f"
                exit 1
            fi

            setStatus "Comparing hashes" "*"
            if [[ "$HASH_ONDISK" != "$HASH_FROMINET" ]]; then
                HASHES_MATCH=0
                setStatus "Hashes do NOT match. Retrying..." "f"
            else
                HASHES_MATCH=1
                setStatus "Hashes match." "s"
            fi

            if [[ $ATTEMPT -gt 3 ]]; then
                setStatus "FATAL: Unable to validate image after 3 attempts." "f"
                exit 1
            fi
        done

        cp "$IMAGE_ORIG" "$WORK_IMAGE"

        setStatus "Purging existing VM template (${vmid}) if it already exists" "*"
        if qm destroy "$vmid" --purge; then
            setStatus " - Successfully deleted." "s"
        else
            setStatus " - No existing template found." "s"
        fi

        VIRT_ARGS=()
        if declare -p PKGS >/dev/null 2>&1; then
            if [[ ${#PKGS[@]} -gt 0 ]]; then
                VIRT_ARGS+=("--install" "$(IFS=,; echo "${PKGS[*]}")")
            fi
        fi

        if declare -p OPTIONAL_PKGS >/dev/null 2>&1; then
            if [[ ${#OPTIONAL_PKGS[@]} -gt 0 ]]; then
                OPTIONAL_CMD=$(build_optional_install_cmd "${PKG_MANAGER:-}" "${OPTIONAL_PKGS[@]}")
                if [[ -n "$OPTIONAL_CMD" ]]; then
                    VIRT_ARGS+=("--run-command" "$OPTIONAL_CMD")
                fi
            fi
        fi

        if declare -p VIRT_CUSTOMIZE_OPTS >/dev/null 2>&1; then
            if [[ ${#VIRT_CUSTOMIZE_OPTS[@]} -gt 0 ]]; then
                VIRT_ARGS+=("${VIRT_CUSTOMIZE_OPTS[@]}")
            fi
        fi

        if [[ ${#VIRT_ARGS[@]} -gt 0 ]]; then
            setStatus "Customizing image" "*"
            if ! virt-customize -a "$WORK_IMAGE" "${VIRT_ARGS[@]}"; then
                setStatus "Unable to customize image: $WORK_IMAGE" "f"
                exit 1
            fi
        fi

        VM_NAME="${distro}-${version}"
        if [[ -n "$release" && "$release" != "$version" ]]; then
            VM_NAME="${VM_NAME}-${release}"
        fi

        TAG_LINES=$(read_tags "$build_file" "$i")
        TAG_LIST=$(join_tags < <(printf "%s\n" "$TAG_LINES" "$distro" "${distro}-${version}" "${distro}-${release}"))

        setStatus "Creating VM ${vmid}" "*"
        CREATE_ARGS=("$vmid" "--memory" "$MEMORY" "--cores" "$CORES" "--name" "$VM_NAME" "--net0" "virtio,bridge=${BRIDGE}" "--tags" "$TAG_LIST")
        if [[ -n "${VM_CPU_TYPE:-}" ]]; then
            CREATE_ARGS+=("--cpu" "cputype=${VM_CPU_TYPE}")
        fi
        [[ -n "$OSTYPE" ]] && CREATE_ARGS+=("--ostype" "$OSTYPE")
        [[ "$AGENT" == "true" ]] && CREATE_ARGS+=("--agent" "1") || CREATE_ARGS+=("--agent" "0")
        [[ -n "$WATCHDOG" ]] && CREATE_ARGS+=("--watchdog" "model=${WATCHDOG}")
        [[ -n "${VM_SERIAL0:-}" ]] && CREATE_ARGS+=("--serial0" "$VM_SERIAL0")
        [[ -n "${VM_VGA:-}" ]] && CREATE_ARGS+=("--vga" "$VM_VGA")

        if ! qm create "${CREATE_ARGS[@]}"; then
            setStatus "Error creating VM." "f"
            exit 1
        fi

        setStatus "Importing disk into storage: ${storage}" "*"
        if ! qm importdisk "$vmid" "$WORK_IMAGE" "$storage"; then
            setStatus "Error importing disk." "f"
            exit 1
        fi

        setStatus "Attaching imported disk" "*"
        STORAGE_TYPE=$(pvesm status --storage "$storage" | awk 'NR == 2 {print $2}')
        if [[ "$STORAGE_TYPE" == "dir" ]]; then
            setStatus " - Storage type 'Directory' detected."
            IMPORTED_DISKFILE=${storage}:${vmid}/vm-${vmid}-disk-0.raw
            rm -f "$IMPORTED_DISKFILE"
        elif [[ "$STORAGE_TYPE" == "lvm" ]]; then
            setStatus " - Storage type 'LVM' detected."
            IMPORTED_DISKFILE=${storage}:vm-${vmid}-disk-0
            lvremove -fy "$IMPORTED_DISKFILE" || true
        elif [[ "$STORAGE_TYPE" == "lvmthin" ]]; then
            setStatus " - Storage type 'LVM-Thin' detected."
            IMPORTED_DISKFILE=${storage}:vm-${vmid}-disk-0
            lvremove -fy "$IMPORTED_DISKFILE" || true
        elif [[ "$STORAGE_TYPE" == "rbd" ]]; then
            setStatus " - Storage type 'RBD' detected."
            IMPORTED_DISKFILE=${storage}:vm-${vmid}-disk-0
            rm -f "$IMPORTED_DISKFILE"
        elif [[ "$STORAGE_TYPE" == "zfspool" ]]; then
            setStatus " - Storage type 'ZFS Pool' detected."
            IMPORTED_DISKFILE=${storage}:vm-${vmid}-disk-0
            zfs destroy "$IMPORTED_DISKFILE" || true
        else
            setStatus " - Storage type not detected. Defaulting to treating as Directory storage."
            IMPORTED_DISKFILE=${storage}:${vmid}/vm-${vmid}-disk-0.raw
        fi
        sleep 1

        if ! qm set "$vmid" --scsihw virtio-scsi-pci --scsi0 "$IMPORTED_DISKFILE"; then
            setStatus "Error attaching disk." "f"
            exit 1
        fi

        setStatus "Adding Cloud-Init CD-ROM" "*"
        if ! qm set "$vmid" --ide2 "${storage}:cloudinit"; then
            setStatus "Error adding Cloud-Init drive." "f"
            exit 1
        fi

        setStatus "Setting boot disk" "*"
        if ! qm set "$vmid" --boot c --bootdisk scsi0; then
            setStatus "Error setting boot disk." "f"
            exit 1
        fi

        TEMP_KEYS=$(mktemp)
        touch "$TEMP_KEYS"

        if [[ -n "$SSH_KEYS_FILE" && -f "$SSH_KEYS_FILE" ]]; then
            cat "$SSH_KEYS_FILE" >> "$TEMP_KEYS"
        fi

        if [[ -n "$SSH_KEYS_URL" ]]; then
            wget -q "$SSH_KEYS_URL" -O - >> "$TEMP_KEYS" || true
        fi

        if [[ -n "$SSH_KEYS_ID" ]]; then
            wget -q "https://launchpad.net/~${SSH_KEYS_ID}/+sshkeys" -O - >> "$TEMP_KEYS" || true
            wget -q "https://github.com/${SSH_KEYS_ID}.keys" -O - >> "$TEMP_KEYS" || true
        fi

        INLINE_KEYS=$(yq_read ".builds[$i].override.cloud_init.ssh_keys_inline[]" "$build_file" 2>/dev/null || true)
        if [[ -z "$INLINE_KEYS" || "$INLINE_KEYS" == "null" ]]; then
            INLINE_KEYS=$(yq_read ".defaults.cloud_init.ssh_keys_inline[]" "$DEFAULTS_FILE" 2>/dev/null || true)
        fi
        if [[ -n "$INLINE_KEYS" && "$INLINE_KEYS" != "null" ]]; then
            printf "%s\n" "$INLINE_KEYS" >> "$TEMP_KEYS"
        fi

        if [[ ! -s "$TEMP_KEYS" ]]; then
            setStatus "No SSH keys found (file/url/id/inline)." "f"
            rm -f "$TEMP_KEYS"
            exit 1
        fi

        setStatus "Applying Cloud-Init settings" "*"
        QM_SET_ARGS=("$vmid" "--ciuser" "$CI_USER" "--cipassword" "$CI_PASSWORD" "--sshkeys" "$TEMP_KEYS" "--onboot" "1")
        [[ -n "$SEARCH_DOMAIN" ]] && QM_SET_ARGS+=("--searchdomain" "$SEARCH_DOMAIN")
        [[ -n "$IPCONFIG0" ]] && QM_SET_ARGS+=("--ipconfig0" "$IPCONFIG0")

        DESCRIPTION="Template from ${distro} ${version} (${release}) - $(date)"
        QM_SET_ARGS+=("--description" "$DESCRIPTION")

        if ! qm set "${QM_SET_ARGS[@]}"; then
            setStatus "Error applying Cloud-Init settings." "f"
            exit 1
        fi

        setStatus "Resizing disk to ${DISK_SIZE}" "*"
        ATTEMPT=0
        while [[ $ATTEMPT -lt 5 ]]; do
            ATTEMPT=$((ATTEMPT + 1))
            if qm resize "$vmid" scsi0 "$DISK_SIZE"; then
                break
            fi
            if [[ $ATTEMPT -lt 5 ]]; then
                setStatus " - Error resizing disk. Retrying..." "f"
                sleep 1
            else
                setStatus " - Error resizing disk." "f"
                exit 1
            fi
        done

        qm rescan --vmid "$vmid"

        setStatus "Converting VM to template" "*"
        if ! qm template "$vmid"; then
            setStatus "Error converting to template." "f"
            exit 1
        fi

        setStatus "Completed template: ${VM_NAME} (VMID ${vmid})" "s"
        echo "======================================================================"
        echo "S U M M A R Y"
        echo "======================================================================"
        echo "Template: ${VM_NAME}"
        echo "VMID: ${vmid}"
        echo "Distro: ${distro}"
        echo "Release: ${release}"
        echo "Version: ${version}"
        echo "Storage: ${storage}"
        echo "Cores: ${CORES}"
        echo "Memory: ${MEMORY}"
        echo "Disk Size: ${DISK_SIZE}"
        echo "Tags: ${TAG_LIST}"
        echo "Image URL: ${IMAGE_URL}"
        echo "Checksum URL: ${HASH_URL}"
        echo "======================================================================"
        echo "T E M P L A T E  C O N F I G"
        echo "======================================================================"
        qm config "$vmid" | grep -v sshkeys | column -t -s' '
        echo ""
        echo "======================================================================"
        echo "D I S K  S P A C E"
        echo "======================================================================"
        echo "Image cache usage:"
        if [[ -f "$IMAGE_ORIG" ]]; then
            du -chs "$IMAGE_ORIG"
        fi
        if [[ -f "$WORK_IMAGE" ]]; then
            du -chs "$WORK_IMAGE"
        fi
        echo ""
        echo "Available on the / mount point:"
        TOTAL=$(df -h | grep "/$" | xargs | cut -d ' ' -f2)
        FREE=$(df -h | grep "/$" | xargs | cut -d ' ' -f4)
        USED=$(df -h | grep "/$" | xargs | cut -d ' ' -f3)
        USED_PCT=$(df -h | grep "/$" | xargs | cut -d ' ' -f5)
        echo -e "Total: Used: Avail: Used%\n$TOTAL $USED $FREE $USED_PCT" | column -t -s' '
        echo ""
        echo ""

        rm -f "$TEMP_KEYS"
        rm -f "$WORK_IMAGE"

        if [[ "$CACHE_KEEP" != "true" ]]; then
            rm -f "$IMAGE_ORIG" "$HASH_FILE"
        fi
    done
done
