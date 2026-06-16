#!/usr/bin/env bash
set -Eeo pipefail

# Strict error handling: ERR trap must be set BEFORE set -u to avoid trap crashes
# This trap will fire if any command exits non-zero (unless caught by ||)
# We use only safe variable references here to prevent trap-induced crashes
on_err() {
  # Use only safe variable references; LINENO and BASH_COMMAND are special and always available
  local rc="${1:-1}"
  local line="${2:-unknown}"
  local cmd="${3:-unknown}"
  p_err "Command failed (rc=$rc) at line $line: $cmd"
  exit "${rc}"
}
trap 'on_err "$?" "${LINENO}" "${BASH_COMMAND}"' ERR

# Enable strict variable checking AFTER ERR trap is set up
# This prevents uninitialized variables from crashing the script before the trap is ready
set -u

# Color definitions
NC="\033[0m"
BOLD="\033[1m"
C_INFO="\033[1;36m"     # cyan
C_OK="\033[1;32m"       # green
C_WARN="\033[1;33m"     # yellow
C_ERR="\033[1;31m"      # red

# Output functions
p_info()  { echo -e "${C_INFO}[*]${NC} $*"; }
p_ok()    { echo -e "${C_OK}[+]${NC} $*"; }
p_warn()  { echo -e "${C_WARN}[!]${NC} $*" >&2; }
p_q()     { echo -e "${C_WARN}[?]${NC} $*"; }
p_err()   { echo -e "${C_ERR}[-]${NC} $*" >&2; }
p_step()  { echo -e "${C_INFO}[*] STEP $1:${NC} ${*:2}"; }

# Legacy aliases for compatibility
log()  { p_info "$@"; }
ok()   { p_ok "$@"; }
warn() { p_warn "$@"; }
ask()  { p_q "$@"; }
err()  { p_err "ERROR: $*"; }
die()  { err "$*"; exit 1; }

show_mode_banner() {
  local mode="$1"
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  case "$mode" in
    provision)
      echo -e "║ ${C_OK}MODE: PROVISION STORAGE${NC}"
      echo "╠════════════════════════════════════════════════════════════════════════════════╣"
      echo "║ This will create new Proxmox storage on available disks."
      if [[ $ALL -eq 1 ]]; then
        echo -e "║ ${C_WARN}WARNING: --all specified - will DESTROY and re-provision ALL storage!${NC}"
      fi
      echo "║ Storage Type: $STORAGE_TYPE"
      if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
        echo "║ Filtered to: ${ONLY_FILTERS[*]}"
      else
        echo "║ Target: All available/unprovisioned disks"
      fi
      ;;
    deprovision)
      echo -e "║ ${C_ERR}MODE: DEPROVISION STORAGE${NC}"
      echo "╠════════════════════════════════════════════════════════════════════════════════╣"
      echo -e "║ ${C_ERR}WARNING: This will DESTROY storage and wipe disks!${NC}"
      if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
        echo "║ Filtered to: ${ONLY_FILTERS[*]}"
      else
        echo "║ Target: ALL non-system storage"
      fi
      ;;
    status)
      echo "║ MODE: STATUS REPORT"
      ;;
    rename)
      echo "║ MODE: RENAME STORAGE"
      echo "╠════════════════════════════════════════════════════════════════════════════════╣"
      echo "║ Renaming: $OLD_STORAGE_NAME -> $NEW_STORAGE_NAME"
      ;;
    list-usage)
      echo "║ MODE: LIST STORAGE USAGE"
      echo "╠════════════════════════════════════════════════════════════════════════════════╣"
      echo "║ Storage: $STORAGE_NAME"
      ;;
  esac
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
}

MODE=""
FORCE=0
WHATIF=0
QUICK_FORMAT=1
EXTENDED=0
ALL=0
ONLY_FILTERS=()
OLD_STORAGE_NAME=""
NEW_STORAGE_NAME=""
STORAGE_NAME=""
STORAGE_TYPE="dir"  # dir, lvm, lvm-thin, nfs
NFS_SERVER=""
NFS_PATH=""
NFS_OPTIONS="vers=4,soft"

# pvesm status cache - populated lazily, invalidated after every pvesm write.
# Using plain variables (not arrays) so set -u is safe.
_PVESM_STATUS_CACHE=""
_PVESM_STATUS_READY=0

log_context() {
  local node
  node="$(hostname -s)"
  local filters="all"
  if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
    filters="${ONLY_FILTERS[*]}"
  fi
  p_info "Context: node=$node mode=${MODE:-unset} type=$STORAGE_TYPE whatif=$WHATIF force=$FORCE full_format=$((1-QUICK_FORMAT)) all=$ALL filters=$filters"
}

usage() {
  cat <<'EOF'
Usage:
  proxmox-storage.sh --provision [--type <type>] [--force] [--whatif] [--full-format] [--all] [--only <filter>]
  proxmox-storage.sh --deprovision [--force] [--whatif] [--only <filter>]
  proxmox-storage.sh --rename <old-name>:<new-name> [--force]
  proxmox-storage.sh --list-usage <storage-name>
  proxmox-storage.sh --status [--extended]
  proxmox-storage.sh --help

Options:
  --provision         Provision unused/new disks only (safe default)
  --deprovision       Deprovision non-system storage (destructive)
  --type <type>       Storage type: dir, lvm, lvm-thin, nfs (default: dir)
                      - dir: Directory storage with ext4 filesystem
                      - lvm: LVM thick-provisioned volumes
                      - lvm-thin: LVM thin-provisioned volumes (recommended for VMs)
                      - nfs: Network filesystem (requires --nfs-server and --nfs-path)
  --nfs-server <host> NFS server hostname or IP (required with --type nfs)
  --nfs-path <path>   NFS export path (required with --type nfs)
  --nfs-options <opts> NFS mount options (default: vers=4,soft)
  --rename            Rename existing storage (non-destructive)
                      Format: --rename old-name:new-name
                      Example: --rename pve-disk-storage1:SSD-1C
  --list-usage        Show VMs/CTs and content on a storage
                      Example: --list-usage SSD-1C
  --all               Destroy and re-provision ALL storage (use with --provision)
  --force             Skip confirmation prompt
  --whatif, --simulate
                      Show what would be done without making changes
  --full-format       Slower, full ext4 format (default is quick, dir type only)
  --status            Show storage status and available devices
  --extended          Show additional SMART health fields
  --only <filter>     Filter to specific device(s) or storage name(s) (repeatable)
                      Examples: --only /dev/sdb  --only HDD-2C  --only SSD-3A
  --help              Show this help

Examples:
  # Provision as directory storage (default)
  ./proxmox-storage.sh --provision --force

  # Provision as LVM-Thin for VM storage with snapshots
  ./proxmox-storage.sh --provision --type lvm-thin --force

  # Provision as LVM thick provisioning
  ./proxmox-storage.sh --provision --type lvm --force

  # Add NFS storage
  ./proxmox-storage.sh --provision --type nfs --nfs-server 192.168.1.100 --nfs-path /export/storage --force

  # Destroy and re-provision ALL storage (destructive)
  ./proxmox-storage.sh --provision --all --force

  # Destroy and re-provision specific device
  ./proxmox-storage.sh --provision --only /dev/sdb --force

  # Rename existing storage (non-destructive)
  ./proxmox-storage.sh --rename pve-disk-storage1:SSD-1C --force

  # Check what's on a storage before renaming
  ./proxmox-storage.sh --list-usage SSD-1C
EOF
}

parse_args() {
  if [[ "$#" -eq 0 ]]; then
    usage
    exit 0
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --provision)
        MODE="provision"
        ;;
      --deprovision)
        MODE="deprovision"
        ;;
      --force)
        FORCE=1
        ;;
      --whatif|--simulate)
        WHATIF=1
        ;;
      --full-format)
        QUICK_FORMAT=0
        ;;
      --status)
        MODE="status"
        ;;
      --rename)
        MODE="rename"
        shift
        [[ -n "${1:-}" ]] || die "--rename requires OLD_NAME:NEW_NAME format"
        OLD_STORAGE_NAME="${1%%:*}"
        NEW_STORAGE_NAME="${1##*:}"
        [[ "$OLD_STORAGE_NAME" != "$NEW_STORAGE_NAME" ]] || die "Old and new storage names must be different"
        [[ -n "$OLD_STORAGE_NAME" && -n "$NEW_STORAGE_NAME" ]] || die "--rename requires OLD_NAME:NEW_NAME format"
        ;;
      --list-usage)
        MODE="list-usage"
        shift
        [[ -n "${1:-}" ]] || die "--list-usage requires a storage name"
        STORAGE_NAME="$1"
        ;;
      --extended)
        EXTENDED=1
        ;;
      --all)
        ALL=1
        ;;
      --type)
        shift
        [[ -n "${1:-}" ]] || die "--type requires a value (dir, lvm, lvm-thin, or nfs)"
        case "$1" in
          dir|lvm|lvm-thin|nfs)
            STORAGE_TYPE="$1"
            ;;
          *)
            die "Invalid --type value: $1 (must be: dir, lvm, lvm-thin, or nfs)"
            ;;
        esac
        ;;
      --nfs-server)
        shift
        [[ -n "${1:-}" ]] || die "--nfs-server requires a hostname or IP"
        NFS_SERVER="$1"
        ;;
      --nfs-path)
        shift
        [[ -n "${1:-}" ]] || die "--nfs-path requires a path"
        NFS_PATH="$1"
        ;;
      --nfs-options)
        shift
        [[ -n "${1:-}" ]] || die "--nfs-options requires mount options"
        NFS_OPTIONS="$1"
        ;;
      --only)
        shift
        [[ -n "${1:-}" ]] || die "--only requires a value (device path or storage name)"
        ONLY_FILTERS+=("$1")
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        err "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done

  if [[ -z "$MODE" ]]; then
    usage
    exit 1
  fi
  
  # Validate argument combinations
  if [[ "$MODE" == "deprovision" || "$MODE" == "status" || "$MODE" == "rename" || "$MODE" == "list-usage" ]]; then
    if [[ "$STORAGE_TYPE" != "dir" ]]; then
      die "--type is only valid with --provision (not with --$MODE)"
    fi
    if [[ -n "$NFS_SERVER" || -n "$NFS_PATH" ]]; then
      die "NFS options (--nfs-server, --nfs-path) are only valid with --provision"
    fi
    if [[ $ALL -eq 1 ]]; then
      die "--all is only valid with --provision"
    fi
  fi

  # Validate NFS requirements
  if [[ "$MODE" == "provision" && "$STORAGE_TYPE" == "nfs" ]]; then
    if [[ -z "$NFS_SERVER" ]]; then
      die "--type nfs requires --nfs-server\n       Example: --type nfs --nfs-server 192.168.1.100 --nfs-path /export/storage"
    fi
    if [[ -z "$NFS_PATH" ]]; then
      die "--type nfs requires --nfs-path\n       Example: --type nfs --nfs-server 192.168.1.100 --nfs-path /export/storage"
    fi
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      die "--type nfs cannot be used with --only (NFS doesn't provision local disks)\n       NFS storage is network-based and doesn't map to specific devices.\n       Remove --only flag to provision NFS storage."
    fi
  fi
}

confirm_destroy() {
  if [[ "$WHATIF" -eq 1 ]]; then
    p_warn "Simulation mode enabled: no changes will be made."
    return 0
  fi

  if [[ "$FORCE" -eq 1 ]]; then
    p_warn "Force mode enabled: skipping confirmation."
    return 0
  fi

  p_warn "Type DESTROY to continue. Any other input aborts."
  printf '%b' "${C_WARN}[?]${NC} Confirm: "
  read -r confirm

  if [[ "$confirm" != "DESTROY" ]]; then
    p_warn "Aborted by user."
    exit 0
  fi
}

run_cmd() {
  local desc="$1"
  shift
  p_info "$desc"
  if [[ "$WHATIF" -eq 1 ]]; then
    p_warn "Would run: $*"
    return 0
  fi
  if "$@"; then
    p_ok "$desc"
  else
    p_err "Failed: $desc"
    return 1
  fi
}

run_cmd_str() {
  local desc="$1"
  local cmd="$2"
  p_info "$desc"
  if [[ "$WHATIF" -eq 1 ]]; then
    p_warn "Would run: $cmd"
    return 0
  fi
  if eval "$cmd"; then
    p_ok "$desc"
  else
    p_err "Failed: $desc"
    return 1
  fi
}



require_root() {
  p_info "Checking root privileges"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    p_ok "Running as root"
  else
    die "Run as root."
  fi
}

is_proxmox() {
  command -v pvesm >/dev/null 2>&1 && [[ -d /etc/pve ]]
}

require_cmd() {
  local cmd="$1"
  local pkg=""
  local reason=""

  case "$cmd" in
    # util-linux
    lsblk|findmnt|partx|wipefs|blkid|blockdev)
      pkg="util-linux"
      reason="core disk and mount inspection/manipulation utilities"
      ;;
    # partition editor
    parted)
      pkg="parted"
      reason="disk partition resize support for system PV auto-expansion"
      ;;
    # LVM
    pvs|vgs|lvs|lvremove|lvextend|lvreduce|vgchange|vgremove|pvremove)
      pkg="lvm2"
      reason="LVM inspection and storage lifecycle operations"
      ;;
    # ext4 tools
    resize2fs|mkfs.ext4)
      pkg="e2fsprogs"
      reason="ext4 filesystem tools"
      ;;
    # GPT tooling
    sgdisk)
      pkg="gdisk"
      reason="GPT partition table operations"
      ;;
    # Proxmox tooling
    pvesm)
      pkg="proxmox-ve"
      reason="Proxmox storage management commands"
      ;;
    # SMART tools
    smartctl)
      pkg="smartmontools"
      reason="SMART disk health reporting"
      ;;
    *)
      pkg=""
      reason=""
      ;;
  esac

  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ -z "$pkg" ]]; then
      err "Missing required command: $cmd"
      err "Install the package that provides '$cmd'"
      exit 1
    fi

    if [[ "$WHATIF" -eq 1 ]]; then
      p_warn "Simulation mode: would prompt to install package '$pkg' for missing command '$cmd'"
      return 0
    fi

    if [[ "$FORCE" -eq 1 ]]; then
      p_warn "Missing prerequisite command '$cmd'"
      p_warn "Force mode: installing package '$pkg' automatically"
      if ! run_cmd "Updating package cache" apt-get update; then
        die "Failed to update package cache. Install manually: apt install $pkg"
      fi
      if ! run_cmd "Installing package '$pkg'" apt-get install -y "$pkg"; then
        die "Failed to install required package '$pkg'. Install manually: apt install $pkg"
      fi
    else
      p_q "Utility '$cmd' is required for ${reason:-this operation}."
      local choice
      printf '%b' "${C_WARN}[?]${NC} Install $pkg now? [y/N]: "
      read -r choice

      case "$choice" in
        y|Y|yes|YES)
          if ! run_cmd "Updating package cache" apt-get update; then
            die "Failed to update package cache. Install manually: apt install $pkg"
          fi
          if ! run_cmd "Installing package '$pkg'" apt-get install -y "$pkg"; then
            die "Failed to install required package '$pkg'. Install manually: apt install $pkg"
          fi
          ;;
        *)
          die "Cannot proceed without '$cmd'. Install manually: apt install $pkg"
          ;;
      esac
    fi

    if ! command -v "$cmd" >/dev/null 2>&1; then
      die "Command '$cmd' is still missing after installing '$pkg'."
    fi
  fi
}

require_nfs_common() {
  p_info "Checking for NFS client utilities"
  
  # Check if nfs-common package is installed
  if dpkg -l nfs-common 2>/dev/null | grep -q "^ii"; then
    p_ok "nfs-common package is installed"
    return 0
  fi
  
  p_warn "NFS client utilities are not installed"
  p_warn "The nfs-common package is required to provision NFS storage."
  p_warn ""
  p_warn "This package provides:"
  p_warn "  - mount.nfs: NFS filesystem mounting support"
  p_warn "  - showmount: NFS server discovery and validation"
  p_warn "  - rpc.statd: NFS lock management"
  p_warn ""
  
  if [[ "$WHATIF" -eq 1 ]]; then
    p_warn "Simulation mode: would prompt to install nfs-common"
    return 0
  fi
  
  if [[ "$FORCE" -eq 1 ]]; then
    p_warn "Force mode: attempting automatic installation"
    if ! run_cmd "Installing nfs-common package" apt-get update && apt-get install -y nfs-common; then
      die "Failed to install nfs-common package. Install manually: apt install nfs-common"
    fi
    return 0
  fi
  
  # Interactive prompt
  p_q "Install nfs-common package now? [y/N]"
  printf '%b' "${C_WARN}[?]${NC} Choice: "
  read -r choice
  
  case "$choice" in
    y|Y|yes|YES)
      p_info "Installing nfs-common package"
      if ! run_cmd "Updating package cache" apt-get update; then
        die "Failed to update package cache. Check your network connection."
      fi
      if ! run_cmd "Installing nfs-common" apt-get install -y nfs-common; then
        die "Failed to install nfs-common package. Install manually: apt install nfs-common"
      fi
      p_ok "nfs-common package installed successfully"
      ;;
    *)
      p_warn "Installation declined by user"
      die "Cannot provision NFS storage without nfs-common package.\n       Install it manually: apt install nfs-common"
      ;;
  esac
}

storage_exists() {
  local sid="$1"
  _pvesm_status_cached | awk 'NR>1 {print $1}' | grep -qx "$sid"
}

# Return cached pvesm status output, populating on first call.
_pvesm_status_cached() {
  if [[ "$_PVESM_STATUS_READY" -eq 0 ]]; then
    _PVESM_STATUS_CACHE="$(pvesm status 2>/dev/null || true)"
    _PVESM_STATUS_READY=1
  fi
  printf '%s\n' "$_PVESM_STATUS_CACHE"
}

# Invalidate the cache after any pvesm add/remove operation.
_pvesm_invalidate_cache() {
  _PVESM_STATUS_CACHE=""
  _PVESM_STATUS_READY=0
}

ensure_fstab_writable() {
  if [[ ! -f /etc/fstab ]]; then
    run_cmd "Creating /etc/fstab" touch /etc/fstab
  fi
  if [[ ! -w /etc/fstab ]]; then
    die "/etc/fstab is not writable. Fix permissions or remount read-write."
  fi
}

get_hostname_digit() {
  local hn
  hn="$(hostname -s)"
  if [[ "$hn" =~ ([0-9])$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    die "Hostname '$hn' does not end in a single digit (expected pve1..pve9)."
  fi
}

hostname_digit() {
  p_info "Extracting hostname digit"
  local digit
  digit="$(get_hostname_digit)"
  p_ok "Hostname '$(hostname -s)' ends with digit: $digit"
  printf '%s' "$digit"
}

# Determine base disk device backing /
get_system_disk() {
  local src pv disk vg base
  src="$(findmnt -n -o SOURCE /)"

  # Default Proxmox ISO install puts / on LVM (/dev/mapper/pve-root).
  if [[ "$src" == /dev/mapper/* || "$src" == /dev/dm-* ]]; then
    # Get VG name from the root LV
    vg="$(lvs --noheadings -o vg_name "$src" 2>/dev/null | awk 'NF{print $1; exit 0}')"
    [[ -n "$vg" ]] || die "Unable to determine VG for root."
    
    # Find PV that's part of this VG
    pv="$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v vg="$vg" '$2==vg {print $1; exit 0}')"
    [[ -n "$pv" ]] || die "Unable to determine PV device backing root VG '$vg'."
    
    # For NVMe: pv might be /dev/nvme0n1p3, need base disk nvme0n1
    # For SATA: pv might be /dev/sda3, need base disk sda
    # lsblk -no PKNAME returns the parent disk name without /dev/ prefix
    disk="$(lsblk -no PKNAME "$pv" 2>/dev/null | tail -1)"
    if [[ -z "$disk" ]]; then
      # Fallback: strip partition number manually from the PV device
      base="$(basename "$pv")"
      # Handle NVMe (nvme0n1p3 -> nvme0n1) and SATA (sda3 -> sda)
      disk="$(basename "$(get_base_disk "$base")")"  
    fi
    [[ -n "$disk" ]] || die "Unable to determine base disk for PV '$pv'."
    # lsblk returns name without /dev/, so add it
    printf '%s' "/dev/$disk"
    return 0
  fi

  # Fallback: root on partition
  disk="$(basename "$(get_base_disk "$src")")"
  [[ -n "$disk" ]] || die "Unable to determine base disk for root source '$src'."
  # get_base_disk returns /dev/diskname; strip the /dev/ prefix since we add it below
  printf '%s' "/dev/$disk"
}

system_disk() {
  p_info "Determining system disk"
  local disk
  disk="$(get_system_disk)"
  p_ok "System disk identified: $disk"
  printf '%s' "$disk"
}

# Strip partition suffix from a device path, returning the base disk path.
# Handles NVMe (nvme0n1p3 -> /dev/nvme0n1), SATA (sda3 -> /dev/sda),
# and MMC (mmcblk0p2 -> /dev/mmcblk0).
get_base_disk() {
  local dev="$1"
  # Ensure /dev/ prefix is present
  [[ "$dev" == /dev/* ]] || dev="/dev/$dev"
  # Use lsblk parent lookup first (most reliable)
  local parent
  parent="$(lsblk -no PKNAME "$dev" 2>/dev/null | tail -1)"
  if [[ -n "$parent" ]]; then
    printf '%s' "/dev/$parent"
    return 0
  fi
  # Fallback: strip partition suffix via regex
  local base
  base="$(basename "$dev" | sed 's|p\?[0-9]\+$||')"
  printf '%s' "/dev/$base"
}

get_first_partition() {
  local disk="$1"
  lsblk -ln -o NAME,TYPE "$disk" | awk '$2=="part"{print "/dev/"$1; exit}'
}

disk_is_rotational() {
  local dev="$1" base
  base="$(basename "$dev")"
  
  # NVMe drives are always non-rotational
  if [[ "$base" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
    echo "0"
    return 0
  fi
  
  if command -v smartctl >/dev/null 2>&1; then
    local rotation
    rotation="$(smart_rotation "$dev")"
    if [[ "$rotation" == "SSD" || "$rotation" == "NVMe" ]]; then
      echo "0"
      return 0
    elif echo "$rotation" | grep -qi 'rpm'; then
      echo "1"
      return 0
    fi
  fi
  
  if [[ -r "/sys/block/$base/queue/rotational" ]]; then
    cat "/sys/block/$base/queue/rotational" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

next_letter() {
  local typ="$1" hd="$2"
  local used letters vg_names vg_list sid_names
  
  # Check partition labels (for dir storage)
  used="$(blkid -o value -s LABEL 2>/dev/null | grep -E "^${typ}-${hd}[A-Z]$" || true)"
  
  # Also check LVM VG names (for lvm/lvm-thin storage)
  vg_names=""
  vg_list="$(vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' || true)"
  
  # Filter VG names that match our pattern
  while IFS= read -r vg; do
    [[ -z "$vg" ]] && continue
    if [[ "$vg" =~ ^${typ}-${hd}[A-Z]$ ]]; then
      vg_names+="${vg}"$'\n'
    fi
  done <<< "$vg_list"
  
  # Combine both sources
  sid_names="$(_pvesm_status_cached | awk -v t="$typ" -v h="$hd" 'NR>1 && $1 ~ ("^" t "-" h "[A-Z]$") {print $1}' || true)"
  used="${used}${vg_names}${sid_names}"
  
  letters=""
  for L in $used; do
    letters+="${L: -1}"
  done

  local c
  for c in {A..Z}; do
    if [[ "$letters" != *"$c"* ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  die "Ran out of letters for $typ-$hd (A..Z exhausted)."
}

ensure_mount() {
  local label="$1" devpart="$2"
  local mnt="/mnt/disks/$label"
  local uuid

  p_info "Ensuring mount for $label ($devpart)"
  
  uuid="$(blkid -o value -s UUID "$devpart" 2>/dev/null || true)"
  [[ -n "$uuid" ]] || die "Cannot read UUID for $devpart"

  run_cmd "Creating mount point directory if needed: $mnt" mkdir -p "$mnt"
  ensure_fstab_writable

  # Ensure fstab entry exists (by UUID). Replace any stale mountpoint entries.
  if ! grep -qE "^[[:space:]]*UUID=${uuid}[[:space:]]+${mnt}[[:space:]]" /etc/fstab; then
    run_cmd "Removing stale /etc/fstab entries for $mnt" sed -i "\|[[:space:]]${mnt}[[:space:]]|d" /etc/fstab
    run_cmd_str "Adding /etc/fstab entry for $label" "printf 'UUID=%s %s ext4 defaults,nofail,x-systemd.device-timeout=10 0 2\\n' '$uuid' '$mnt' | tee -a /etc/fstab >/dev/null"
  else
    p_ok "/etc/fstab entry already present for $label"
  fi

  if ! findmnt -n "$mnt" >/dev/null 2>&1; then
    run_cmd "Mounting $mnt" mount "$mnt"
  else
    p_ok "Already mounted: $mnt"
  fi
}

ensure_pvesm_storage() {
  local sid="$1" path="$2"
  local content="images,iso,vztmpl,backup,snippets,rootdir"
  local node
  node="$(hostname -s)"

  p_info "Ensuring Proxmox storage '$sid' exists"
  
  if storage_exists "$sid"; then
    p_ok "Proxmox storage '$sid' already present"
    return 0
  fi

  run_cmd "Adding Proxmox storage '$sid' at $path" pvesm add dir "$sid" --path "$path" --content "$content" --is_mountpoint 1 --nodes "$node" --shared 0
  _pvesm_invalidate_cache
}

ensure_pvesm_lvm_storage() {
  local sid="$1" vgname="$2"
  local content="images,rootdir"
  local node
  node="$(hostname -s)"

  p_info "Ensuring Proxmox LVM storage '$sid' exists"
  
  if storage_exists "$sid"; then
    p_ok "Proxmox storage '$sid' already present"
    return 0
  fi

  run_cmd "Adding Proxmox LVM storage '$sid' (VG: $vgname)" pvesm add lvm "$sid" --vgname "$vgname" --content "$content" --nodes "$node"
  _pvesm_invalidate_cache
}

ensure_pvesm_lvm_thin_storage() {
  local sid="$1" vgname="$2" thinpool="$3"
  local content="images,rootdir"
  local node
  node="$(hostname -s)"

  p_info "Ensuring Proxmox LVM-Thin storage '$sid' exists"
  
  if storage_exists "$sid"; then
    p_ok "Proxmox storage '$sid' already present"
    return 0
  fi

  run_cmd "Adding Proxmox LVM-Thin storage '$sid' (VG: $vgname, pool: $thinpool)" pvesm add lvmthin "$sid" --vgname "$vgname" --thinpool "$thinpool" --content "$content" --nodes "$node"
  _pvesm_invalidate_cache
}

ensure_pvesm_nfs_storage() {
  local sid="$1" server="$2" export_path="$3" options="$4"
  local content="images,iso,vztmpl,backup,snippets,rootdir"
  local node
  node="$(hostname -s)"

  p_info "Ensuring Proxmox NFS storage '$sid' exists"
  
  if storage_exists "$sid"; then
    p_ok "Proxmox storage '$sid' already present"
    return 0
  fi

  run_cmd "Adding Proxmox NFS storage '$sid' (server: $server, export: $export_path)" \
    pvesm add nfs "$sid" --server "$server" --export "$export_path" --content "$content" --options "$options" --nodes "$node"
  _pvesm_invalidate_cache
}

partition_number_from_device() {
  local dev="$1"
  local base
  base="$(basename "$dev")"

  # NVMe/MMC style (nvme0n1p3, mmcblk0p2)
  if [[ "$base" =~ p([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  # SATA/SCSI style (sda3, vda2)
  if [[ "$base" =~ ([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

expand_system_pv_to_full_disk() {
  local pv disk partnum max_part tail_free_mib

  # This script targets standard Proxmox ISO LVM layout where pve VG backs root.
  pv="$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk '$2=="pve"{print $1; exit}')"
  if [[ -z "$pv" ]]; then
    p_warn "Could not find PV for VG 'pve'; skipping automatic system PV expansion"
    return 0
  fi

  if [[ "$(lsblk -dn -o TYPE "$pv" 2>/dev/null || true)" != "part" ]]; then
    p_warn "System PV $pv is not a partition; skipping automatic system PV expansion"
    return 0
  fi

  disk="/dev/$(lsblk -no PKNAME "$pv" 2>/dev/null | tail -1)"
  [[ -b "$disk" ]] || {
    p_warn "Could not determine parent disk for PV $pv; skipping automatic system PV expansion"
    return 0
  }

  partnum="$(partition_number_from_device "$pv" || true)"
  if [[ -z "$partnum" ]]; then
    p_warn "Could not determine partition number for PV $pv; skipping automatic system PV expansion"
    return 0
  fi

  max_part="$(lsblk -ln -o NAME,TYPE "$disk" | awk '$2=="part"{print $1}' | sed -E 's/.*p?([0-9]+)$/\1/' | sort -n | tail -1)"
  if [[ "$partnum" != "$max_part" ]]; then
    p_warn "System PV partition ($pv) is not the last partition on $disk; skipping auto-resize for safety"
    return 0
  fi

  # Last 'free' segment in parted output is typically the trailing free space.
  tail_free_mib="$(parted -ms "$disk" unit MiB print free 2>/dev/null | awk -F: '$5=="free;" {gsub("MiB", "", $4); last=$4+0} END {printf "%.0f", last+0}')"
  tail_free_mib="${tail_free_mib:-0}"

  if (( tail_free_mib < 2048 )); then
    p_ok "System PV partition already uses disk tail (or <2GiB free tail). No PV expansion needed."
    return 0
  fi

  p_warn "Detected ${tail_free_mib}MiB unpartitioned tail space on system disk $disk; expanding $pv to 100%"
  run_cmd "Expanding partition $pv to fill disk" parted --script "$disk" resizepart "$partnum" 100%
  run_cmd "Refreshing kernel partition table for $disk" partx -u "$disk" || true
  run_cmd "Waiting for udev to settle" udevadm settle || true
  run_cmd "Expanding PV to use full partition: $pv" pvresize "$pv"
}

show_system_disk_reclaim_readiness() {
  local sysdisk="$1"
  local pv disk partnum max_part tail_free_mib vg_free_g root_g

  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║ SYSTEM DISK RECLAIM READINESS"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""

  pv="$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk '$2=="pve"{print $1; exit}')"
  if [[ -z "$pv" ]]; then
    echo "  - VG pve PV: not detected"
    echo "  - Auto-expand: unavailable (non-standard layout)"
    echo ""
    return
  fi

  disk="/dev/$(lsblk -no PKNAME "$pv" 2>/dev/null | tail -1)"
  partnum="$(partition_number_from_device "$pv" 2>/dev/null || true)"
  max_part="$(lsblk -ln -o NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}' | sed -E 's/.*p?([0-9]+)$/\1/' | sort -n | tail -1)"
  tail_free_mib="$(parted -ms "$disk" unit MiB print free 2>/dev/null | awk -F: '$5=="free;" {gsub("MiB", "", $4); last=$4+0} END {printf "%.0f", last+0}')"
  tail_free_mib="${tail_free_mib:-0}"

  root_g="$(lvs --noheadings -o lv_size --units g --nosuffix pve/root 2>/dev/null | awk '{$1=$1; print int($1+0.5); exit}')"
  root_g="${root_g:-0}"
  vg_free_g="$(vgs --noheadings -o vg_free --units g --nosuffix pve 2>/dev/null | awk '{$1=$1; print int($1+0.5); exit}')"
  vg_free_g="${vg_free_g:-0}"

  echo "  - System disk: $sysdisk"
  echo "  - Root LV (pve/root): ${root_g}G (as installed)"
  echo "  - pve VG free now: ${vg_free_g}G"
  echo "  - pve PV: $pv on $disk"
  echo ""

  if [[ -z "$partnum" || -z "$max_part" ]]; then
    echo "  - Auto-expand check: unable to parse partition layout"
    echo ""
    return
  fi

  if [[ "$partnum" != "$max_part" ]]; then
    echo "  - Auto-expand check: blocked (system PV is not the last partition on disk)"
    echo ""
    return
  fi

  if (( tail_free_mib >= 2048 )); then
    echo "  - Trailing unpartitioned space detected: ${tail_free_mib}MiB"
    echo "  - On --provision, script will auto-expand $pv and run pvresize"
  else
    echo "  - No meaningful trailing unpartitioned space detected on system disk"
  fi

  echo ""
}

reclaim_system_disk() {
  local hd="$1"
  local vg_free_mb thin_size_mb
  local sid letter thinpool existing_system_storage
  local canonical_sid canonical_pool

  canonical_sid="SSD-${hd}A"
  canonical_pool="pool-${hd}A"

  p_info "System disk reclaim: use installed root layout and convert remaining system VG space into Proxmox storage"

  # Auto-heal Proxmox installs where installer left large unpartitioned tail space.
  expand_system_pv_to_full_disk

  # Remove local-lvm storage entry if present
  p_info "Checking for Proxmox storage 'local-lvm'"
  if storage_exists "local-lvm"; then
    run_cmd "Removing Proxmox storage 'local-lvm'" pvesm remove local-lvm
    _pvesm_invalidate_cache
  else
    p_ok "Proxmox storage 'local-lvm' not present (already removed)"
  fi

  # Remove thinpool LVs if present (idempotent)
  p_info "Checking for LV pve/data"
  if lvs --noheadings -o lv_name pve 2>/dev/null | awk '{print $1}' | grep -qx "data"; then
    run_cmd "Removing LV pve/data" lvremove -y pve/data
  else
    p_ok "LV pve/data not present (already removed)"
  fi

  p_info "Checking for LV pve/data_tmeta"
  if lvs --noheadings -o lv_name pve 2>/dev/null | awk '{print $1}' | grep -qx "data_tmeta"; then
    run_cmd "Removing LV pve/data_tmeta" lvremove -y pve/data_tmeta
  else
    p_ok "LV pve/data_tmeta not present (already removed)"
  fi

  p_info "Checking for LV pve/data_tdata"
  if lvs --noheadings -o lv_name pve 2>/dev/null | awk '{print $1}' | grep -qx "data_tdata"; then
    run_cmd "Removing LV pve/data_tdata" lvremove -y pve/data_tdata
  else
    p_ok "LV pve/data_tdata not present (already removed)"
  fi

  # Force-all policy: collapse system-disk tail storage to one canonical pool.
  if [[ "$ALL" -eq 1 ]]; then
    p_warn "--all mode: rebuilding system-disk thin pools to canonical ${canonical_sid} (${canonical_pool})"

    # Remove all pve-backed SSD entries for this node digit so config can be rebuilt cleanly.
    local type sid_cfg path_cfg nodes_cfg shared_cfg vgname_cfg thinpool_cfg
    while IFS='|' read -r type sid_cfg path_cfg nodes_cfg shared_cfg vgname_cfg thinpool_cfg; do
      [[ "$type" == "lvmthin" ]] || continue
      [[ "$vgname_cfg" == "pve" ]] || continue
      [[ "$sid_cfg" =~ ^SSD-${hd}[A-Z]$ ]] || continue
      run_cmd "Removing system-disk storage entry '$sid_cfg'" pvesm remove "$sid_cfg"
      _pvesm_invalidate_cache
    done < <(parse_storage_cfg)

    # Remove all previously-created system thin pools for this node digit.
    local pool_name lv_attr
    while read -r pool_name lv_attr; do
      [[ -n "$pool_name" ]] || continue
      [[ "$lv_attr" =~ ^t ]] || continue
      [[ "$pool_name" =~ ^pool-${hd}[A-Z]$ ]] || continue
      run_cmd "Removing stale system thin pool pve/$pool_name" lvremove -y "pve/$pool_name"
    done < <(lvs --noheadings -o lv_name,lv_attr pve 2>/dev/null | awk 'NF{print $1, $2}')
  fi

  # If storage.cfg was cleared manually, rehydrate it from the existing pve
  # thin pools before trying to reuse or create any system-disk SSD entries.
  if [[ "$ALL" -ne 1 ]]; then
    if ensure_system_disk_storage_entries_from_pve_lvs "$hd"; then
      p_info "System-disk storage entry reconciled from existing pve thin pools"
      return 0
    fi
  fi

  # If this host already has a pve-backed SSD-<digit><letter> storage entry,
  # reuse it instead of minting a new letter every time reclaim runs.
  if [[ "$ALL" -ne 1 ]]; then
    if existing_system_storage="$(find_existing_system_disk_storage "$hd" 2>/dev/null || true)"; [[ -n "$existing_system_storage" ]]; then
      sid="${existing_system_storage%%|*}"
      thinpool="${existing_system_storage##*|}"
      p_info "Reusing existing system-disk storage: $sid (VG pve, thin pool $thinpool)"
      ensure_pvesm_lvm_thin_storage "$sid" "pve" "$thinpool"
      cleanup_duplicate_system_disk_storage_entries "$hd" "$sid"
      return 0
    fi
  fi

  vg_free_mb="$(vgs --noheadings -o vg_free --units m --nosuffix pve 2>/dev/null | awk '{$1=$1; print int($1); exit}')"
  vg_free_mb="${vg_free_mb:-0}"
  if (( vg_free_mb < 2048 )); then
    p_warn "Not enough free VG space on system disk (${vg_free_mb}M free); skipping system-disk storage creation."
    p_info "'local' remains valid and usable root-backed storage."
    p_info "If you want additional system-disk storage, allocate a smaller OS partition during install, then re-run provision."
    return 0
  fi

  if [[ "$ALL" -eq 1 ]]; then
    sid="$canonical_sid"
    thinpool="$canonical_pool"
  else
    sid=""
    for letter in {A..Z}; do
      local candidate_sid candidate_pool
      candidate_sid="SSD-${hd}${letter}"
      candidate_pool="pool-${hd}${letter}"
      if storage_exists "$candidate_sid"; then
        continue
      fi
      if lvs "pve/$candidate_pool" >/dev/null 2>&1; then
        continue
      fi
      sid="$candidate_sid"
      thinpool="$candidate_pool"
      break
    done
    [[ -n "$sid" ]] || die "Ran out of system-disk SSD storage names for host digit $hd"
  fi

  thin_size_mb="$(awk -v m="$vg_free_mb" 'BEGIN {printf "%.0f", m * 0.95}')"
  if (( thin_size_mb < 1024 )); then
    p_warn "Free VG space too small for a useful thin pool (${thin_size_mb}M). Skipping system-disk storage creation."
    return 0
  fi

  run_cmd "Creating system-disk thin pool pve/$thinpool (${thin_size_mb}M)" lvcreate -L "${thin_size_mb}M" -T "pve/$thinpool"
  lvs "pve/$thinpool" >/dev/null 2>&1 || die "System thin pool creation succeeded but pve/$thinpool not visible to lvs"
  ensure_pvesm_lvm_thin_storage "$sid" "pve" "$thinpool"
  p_ok "System disk storage created: $sid (VG pve, thin pool $thinpool)"
}

is_on_disk() {
  local dev="$1" disk="$2"
  local dev_base disk_base
  
  # Normalize both to base disk names (strip /dev/ for comparison)
  dev_base="$(basename "$dev")"
  disk_base="$(basename "$disk")"
  
  # Get parent disk of dev if it's a partition
  local parent
  parent="$(lsblk -no PKNAME "$dev" 2>/dev/null | tail -1)"
  if [[ -n "$parent" ]]; then
    dev_base="$parent"
  fi
  
  # Get parent disk of disk if it's a partition  
  parent="$(lsblk -no PKNAME "$disk" 2>/dev/null | tail -1)"
  if [[ -n "$parent" ]]; then
    disk_base="$parent"
  fi
  
  # Compare base disk names
  [[ "$dev_base" == "$disk_base" ]]
}

is_on_system_disk() {
  local dev="$1" sysdisk="$2"
  is_on_disk "$dev" "$sysdisk"
}

matches_any_filter() {
  local disk="$1"
  local storage_name="${2:-}"
  
  # If no filters specified, everything matches
  if [[ ${#ONLY_FILTERS[@]} -eq 0 ]]; then
    return 0
  fi
  
  # Check each filter
  for filter in "${ONLY_FILTERS[@]}"; do
    # Check if filter is a storage name (e.g., HDD-2C)
    if [[ "$filter" =~ ^[a-zA-Z]+-[0-9]+[A-Z]$ ]]; then
      if [[ "$storage_name" == "$filter" ]]; then
        return 0
      fi
      # Also check partition label on the disk
      local part label
      part="$(get_first_partition "$disk" 2>/dev/null || true)"
      if [[ -n "$part" ]]; then
        label="$(blkid -o value -s LABEL "$part" 2>/dev/null || true)"
        if [[ "$label" == "$filter" ]]; then
          return 0
        fi
      fi
    else
      # Filter is a device path
      local normalized_filter="$filter"
      if [[ "$filter" != /dev/* ]]; then
        normalized_filter="/dev/$filter"
      fi
      normalized_filter="$(readlink -f "$normalized_filter" 2>/dev/null || echo "$normalized_filter")"
      
      if [[ "$disk" == "$normalized_filter" ]]; then
        return 0
      fi
    fi
  done
  
  return 1
}

validate_storage_filters() {
  local mode="$1"  # "provision" or "deprovision"
  local sysdisk="${2:-}"
  
  # No filters = no validation needed
  if [[ ${#ONLY_FILTERS[@]} -eq 0 ]]; then
    return 0
  fi
  
  # Check each filter that looks like a storage name
  for filter in "${ONLY_FILTERS[@]}"; do
    if [[ "$filter" =~ ^[a-zA-Z]+-[0-9]+[A-Z]$ ]]; then
      # This looks like a storage name (e.g., HDD-2C)
      # Check if it exists in Proxmox storage config
      local exists=0
      while IFS='|' read -r type sid path nodes shared vgname thinpool; do
        if [[ "$sid" == "$filter" ]]; then
          exists=1
          break
        fi
      done < <(parse_storage_cfg)
      
      if [[ "$mode" == "deprovision" ]]; then
        if [[ "$exists" -eq 0 ]]; then
          die "Storage '$filter' does not exist in Proxmox.\n       Cannot deprovision non-existent storage.\n       Use 'pvesm status' to list existing storage, or use a device path like '--only /dev/sde'"
        fi
      elif [[ "$mode" == "provision" ]]; then
        # For provision, storage name is only allowed if we can map it to a disk
        # Check 1: Does it already exist? (error)
        if [[ "$exists" -eq 1 ]]; then
          die "Storage '$filter' already exists in Proxmox.\n       Cannot provision over existing storage.\n       Either deprovision it first, or use a device path like '--only /dev/sde'"
        fi
        
        # Check 2: Can we map it to a disk? (via VG or partition label)
        local can_map=0
        
        # Try VG lookup
        if pvs --noheadings -o vg_name 2>/dev/null | grep -qx "[[:space:]]*${filter}"; then
          can_map=1
        else
          # Try partition label lookup on all non-system disks
          if [[ -n "$sysdisk" ]]; then
            mapfile -t all_disks < <(list_non_system_disks "$sysdisk")
            for disk in "${all_disks[@]}"; do
              local part label
              part="$(get_first_partition "$disk" || true)"
              if [[ -n "$part" ]]; then
                label="$(blkid -o value -s LABEL "$part" 2>/dev/null || true)"
                if [[ "$label" == "$filter" ]]; then
                  can_map=1
                  break
                fi
              fi
            done
          fi
        fi
        
        if [[ "$can_map" -eq 0 ]]; then
          die "Storage name '$filter' cannot be mapped to any disk.\n       The storage doesn't exist and no disk has VG or label '$filter'.\n       For provisioning, use a device path instead: '--only /dev/sdc'\n       (Device paths are required when creating new storage)"
        fi
      fi
    fi
  done
}

list_non_system_disks() {
  local sysdisk="$1"
  mapfile -t disks < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
  for d in "${disks[@]}"; do
    [[ "$d" == "$sysdisk" ]] && continue
    printf '%s\n' "$d"
  done
}

list_target_disks() {
  local sysdisk="$1"
  local all_disks=()
  
  # Get all non-system disks
  mapfile -t all_disks < <(list_non_system_disks "$sysdisk")
  
  # If no filters specified, return all disks
  if [[ ${#ONLY_FILTERS[@]} -eq 0 ]]; then
    printf '%s\n' "${all_disks[@]}"
    return
  fi
  
  # Apply filters
  local matched_disks=()
  for disk in "${all_disks[@]}"; do
    for filter in "${ONLY_FILTERS[@]}"; do
      # Normalize filter (could be /dev/sdb, sdb, HDD-2C, etc.)
      local normalized_filter="$filter"
      if [[ "$filter" =~ ^[a-zA-Z]+-[0-9]+[A-Z]$ ]]; then
        # This is a storage name like HDD-2C
        # Check 1: Partition label
        local part
        part="$(get_first_partition "$disk" || true)"
        if [[ -n "$part" ]]; then
          local existing_label
          existing_label="$(blkid -o value -s LABEL "$part" 2>/dev/null || true)"
          if [[ "$existing_label" == "$filter" ]]; then
            matched_disks+=("$disk")
            break
          fi
        fi
        
        # Check 2: LVM VG name (for when storage is deprovisioned but VG still exists)
        local vg_name pv_device base_device
        vg_name="$filter"
        pv_device=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v vg="$vg_name" '$2==vg {print $1; exit}')
        if [[ -n "$pv_device" ]]; then
          base_device=$(echo "$pv_device" | sed 's/[0-9]*$//')
          if [[ "$disk" == "$base_device" ]]; then
            matched_disks+=("$disk")
            break
          fi
        fi
      else
        # This is a device path
        if [[ "$filter" != /dev/* ]]; then
          normalized_filter="/dev/$filter"
        fi
        normalized_filter="$(readlink -f "$normalized_filter" 2>/dev/null || echo "$normalized_filter")"
        
        if [[ "$disk" == "$normalized_filter" ]]; then
          matched_disks+=("$disk")
          break
        fi
      fi
    done
  done
  
  printf '%s\n' "${matched_disks[@]}"
}

normalize_device() {
  local dev="$1"
  dev="$(echo "$dev" | xargs)"
  [[ -n "$dev" ]] || die "--only requires a device path or storage name"
  if [[ "$dev" != /dev/* ]]; then
    dev="/dev/$dev"
  fi
  if [[ -e "$dev" ]]; then
    dev="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"
  fi
  printf '%s' "$dev"
}

probe_device_readable() {
  local dev="$1"
  p_info "Probing device readability: $dev"
  if [[ "$WHATIF" -eq 1 ]]; then
    p_warn "Would run: dd if=$dev of=/dev/null bs=1M count=1 iflag=direct"
    return 0
  fi
  if dd if="$dev" of=/dev/null bs=1M count=1 iflag=direct status=none 2>/dev/null; then
    p_ok "Device read probe succeeded"
  else
    die "Device read probe failed. Check cable/power/enclosure/USB."
  fi
}

validate_device() {
  local dev="$1"
  local typ state ro base
  typ="$(lsblk -dn -o TYPE "$dev" 2>/dev/null || true)"
  [[ -n "$typ" ]] || die "Device not found in lsblk: $dev"
  [[ "$typ" == "disk" ]] || die "--only must specify a disk device (e.g., /dev/sde), not a partition: $dev"

  base="$(basename "$dev")"
  if [[ ! -b "$dev" && ! -e "/sys/block/$base" ]]; then
    die "Device not found or not a block device: $dev"
  fi

  ro="$(blockdev --getro "$dev" 2>/dev/null || echo 0)"
  if [[ "$ro" == "1" ]]; then
    die "Device is read-only: $dev"
  fi

  state="$(lsblk -dn -o STATE "$dev" 2>/dev/null | xargs)"
  if [[ -n "$state" && "$state" != "running" && "$state" != "live" && "$state" != "idle" ]]; then
    die "Device state is '$state' (not ready): $dev"
  fi

  probe_device_readable "$dev"
}

provision_disk_dir() {
  local dev="$1" label="$2"
  local part

  # Wipe signatures/partition table
  run_cmd "Wiping filesystem signatures on $dev" wipefs -a "$dev"
  
  if ! run_cmd "Zapping GPT/MBR on $dev" sgdisk --zap-all "$dev"; then
    return 1
  fi

  # Create partition + label
  if ! run_cmd "Creating GPT partition on $dev with label $label" sgdisk -n 1:0:0 -t 1:8300 -c 1:"$label" "$dev"; then
    return 1
  fi

  # Refresh kernel partition table
  run_cmd "Refreshing kernel partition table for $dev" partx -u "$dev" || true
  run_cmd "Waiting for udev to settle" udevadm settle || true

  part="$(get_first_partition "$dev" || true)"
  [[ -n "$part" ]] || die "Failed to detect new partition on $dev"

  # Format ext4 (lazy init keeps this fast even on huge disks)
  local mkfs_opts
  mkfs_opts=("-F" "-L" "$label" "-E" "lazy_itable_init=1,lazy_journal_init=1")
  if [[ "$QUICK_FORMAT" -eq 1 ]]; then
    mkfs_opts+=("-m" "0" "-T" "largefile4")
  fi
  if ! run_cmd "Formatting $part as ext4 with label $label" mkfs.ext4 "${mkfs_opts[@]}" "$part"; then
    return 1
  fi

  ensure_mount "$label" "$part"
  ensure_pvesm_storage "$label" "/mnt/disks/$label"
  return 0
}

provision_disk_lvm() {
  local dev="$1" label="$2"
  local part vgname

  # Wipe signatures/partition table
  run_cmd "Wiping filesystem signatures on $dev" wipefs -a "$dev"
  
  if ! run_cmd "Zapping GPT/MBR on $dev" sgdisk --zap-all "$dev"; then
    return 1
  fi

  # Create partition (type 8e00 = Linux LVM)
  if ! run_cmd "Creating GPT partition on $dev for LVM" sgdisk -n 1:0:0 -t 1:8e00 -c 1:"$label" "$dev"; then
    return 1
  fi

  # Refresh kernel partition table
  run_cmd "Refreshing kernel partition table for $dev" partx -u "$dev" || true
  run_cmd "Waiting for udev to settle" udevadm settle || true

  part="$(get_first_partition "$dev" || true)"
  [[ -n "$part" ]] || die "Failed to detect new partition on $dev"

  # Create PV
  if ! run_cmd "Creating LVM physical volume on $part" pvcreate -ff -y "$part"; then
    return 1
  fi
  pvs "$part" >/dev/null 2>&1 || die "PV creation succeeded but $part not visible to pvs - check kernel/udev state"

  # Create VG with label as VG name
  vgname="$label"
  if ! run_cmd "Creating LVM volume group $vgname" vgcreate "$vgname" "$part"; then
    return 1
  fi
  vgs "$vgname" >/dev/null 2>&1 || die "VG creation succeeded but $vgname not visible to vgs"

  ensure_pvesm_lvm_storage "$label" "$vgname"
  p_ok "Proxmox will create LVs within VG $vgname as needed"
  return 0
}

provision_disk_lvm_thin() {
  local dev="$1" label="$2"
  local part vgname thinpool
  local vg_size_kb thin_size_kb meta_size_kb

  # Wipe signatures/partition table
  run_cmd "Wiping filesystem signatures on $dev" wipefs -a "$dev"
  
  if ! run_cmd "Zapping GPT/MBR on $dev" sgdisk --zap-all "$dev"; then
    return 1
  fi

  # Create partition (type 8e00 = Linux LVM)
  if ! run_cmd "Creating GPT partition on $dev for LVM-Thin" sgdisk -n 1:0:0 -t 1:8e00 -c 1:"$label" "$dev"; then
    return 1
  fi

  # Refresh kernel partition table
  run_cmd "Refreshing kernel partition table for $dev" partx -u "$dev" || true
  run_cmd "Waiting for udev to settle" udevadm settle || true

  part="$(get_first_partition "$dev" || true)"
  [[ -n "$part" ]] || die "Failed to detect new partition on $dev"

  # Create PV
  if ! run_cmd "Creating LVM physical volume on $part" pvcreate -ff -y "$part"; then
    return 1
  fi
  pvs "$part" >/dev/null 2>&1 || die "PV creation succeeded but $part not visible to pvs - check kernel/udev state"

  # Create VG with label as VG name
  vgname="$label"
  if ! run_cmd "Creating LVM volume group $vgname" vgcreate "$vgname" "$part"; then
    return 1
  fi
  vgs "$vgname" >/dev/null 2>&1 || die "VG creation succeeded but $vgname not visible to vgs"

  # Create thin pool (use 95% of VG space, leaving some for metadata overhead)
  # Get VG size in KB
  vg_size_kb=$(vgs --noheadings --units k --nosuffix -o vg_size "$vgname" | awk '{print int($1)}')
  thin_size_kb=$(awk "BEGIN {printf \"%.0f\", $vg_size_kb * 0.95}")
  
  # Minimum size check (1GB = 1048576 KB)
  if [[ $thin_size_kb -lt 1048576 ]]; then
    die "Disk too small for LVM-Thin ($(awk "BEGIN {printf \"%.2f\", $thin_size_kb/1024/1024}") GB). Minimum 1GB required."
  fi
  
  # Use unique pool name based on storage label (e.g., pool-2A from HDD-2A or SSD-2A)
  local hd_digit letter
  hd_digit="${label:4:1}"  # Extract digit from label (HDD-2A -> 2)
  letter="${label: -1}"     # Extract letter from label (HDD-2A -> A)
  thinpool="pool-${hd_digit}${letter}"
  
  if ! run_cmd "Creating LVM thin pool $vgname/$thinpool (${thin_size_kb}K)" \
    lvcreate -L "${thin_size_kb}K" -T "$vgname/$thinpool"; then
    return 1
  fi
  lvs "$vgname/$thinpool" >/dev/null 2>&1 || die "Thin pool creation succeeded but $vgname/$thinpool not visible to lvs"

  ensure_pvesm_lvm_thin_storage "$label" "$vgname" "$thinpool"
  p_ok "Proxmox will create thin LVs within $vgname/$thinpool as needed"
  return 0
}

provision_nfs() {
  local server="$1" export_path="$2" options="$3"
  local sid hd letter

  # Get hostname digit for consistent naming
  hd="$(get_hostname_digit)"
  
  # Find next available NFS letter for this node
  local used letters
  used="$(_pvesm_status_cached | awk 'NR>1 && $1 ~ /^NFS-'$hd'[A-Z]$/ {print $1}' || true)"
  letters=""
  for L in $used; do
    letters+="${L: -1}"
  done
  
  for letter in {A..Z}; do
    if [[ "$letters" != *"$letter"* ]]; then
      break
    fi
  done
  
  if [[ -z "$letter" || "$letters" == *"$letter"* ]]; then
    die "Ran out of letters for NFS-$hd (A..Z exhausted)."
  fi
  
  sid="NFS-${hd}${letter}"

  p_info "Provisioning NFS storage: $server:$export_path -> $sid"
  p_info "Proxmox will manage the mount at /mnt/pve/$sid"

  # Verify NFS server is reachable (only for NFSv3 - showmount doesn't work with NFSv4)
  # Pre-flight: probe NFS port 2049 via TCP. Works for both NFSv3 and NFSv4.
  # Uses Bash built-in /dev/tcp so no extra tools required.
  p_info "Probing NFS server $server port 2049 (TCP)"
  if timeout 5 bash -c "echo >/dev/tcp/${server}/2049" 2>/dev/null; then
    p_ok "NFS server $server is reachable on port 2049"
    # NFSv3 only: also validate the export path via showmount
    if [[ "$options" =~ vers=3 ]] && command -v showmount >/dev/null 2>&1; then
      if showmount -e "$server" 2>/dev/null | grep -q "^${export_path}[[:space:]]"; then
        p_ok "Export path $export_path is listed by NFS server"
      else
        p_warn "Export path $export_path not found in showmount output. Will attempt anyway."
        p_warn "  Check on the server: showmount -e $server"
      fi
    fi
  else
    p_warn "Cannot reach NFS server $server on port 2049 (TCP timeout)"
    p_warn "Possible causes:"
    p_warn "  - Server is unreachable or offline"
    p_warn "  - Firewall blocking TCP port 2049"
    p_warn "  - Wrong server address: $server"
    if [[ "$FORCE" -eq 0 && "$WHATIF" -eq 0 ]]; then
      printf '%b' "${C_WARN}[?]${NC} Server unreachable. Attempt to add NFS storage anyway? [y/N]: "
      local _ans
      read -r _ans
      [[ "$_ans" =~ ^[Yy]$ ]] || { p_warn "Aborted by user."; return 1; }
    else
      p_warn "Force/whatif mode: proceeding despite unreachable server"
    fi
  fi

  # Let Proxmox handle all mounting - it will create /mnt/pve/$sid and manage fstab
  if ! ensure_pvesm_nfs_storage "$sid" "$server" "$export_path" "$options"; then
    p_err "Failed to add Proxmox NFS storage configuration"
    p_err "Possible causes:"
    p_err "  - NFS server $server is unreachable"
    p_err "  - Export path $export_path does not exist"
    p_err "  - Firewall blocking NFS ports (2049, 111)"
    p_err "  - NFS server not exporting to this client IP"
    p_err "  - Mount options '$options' are incompatible"
    p_err ""
    p_err "Check NFS server configuration and network connectivity."
    
    # Cleanup: remove storage if it was partially created
    if storage_exists "$sid" 2>/dev/null; then
      p_info "Cleaning up partial storage configuration"
      pvesm remove "$sid" 2>/dev/null || true
      _pvesm_invalidate_cache
    fi
    return 1
  fi
  
  # Verify the storage is actually online
  if [[ "$WHATIF" -ne 1 ]]; then
    sleep 2  # Give Proxmox time to mount
    local status
    status="$(pvesm status -storage "$sid" 2>/dev/null | awk 'NR==2 {print $3}' || echo 'unknown')"
    
    if [[ "$status" == "active" ]]; then
      p_ok "NFS storage $sid is online and accessible"
    else
      p_err "NFS storage $sid was added but is not active (status: $status)"
      p_err "Proxmox was unable to mount the NFS share."
      p_err "Check 'pvesm status' and system logs for details."
      
      # Cleanup
      p_info "Removing non-functional storage configuration"
      pvesm remove "$sid" 2>/dev/null || true
      _pvesm_invalidate_cache
      return 1
    fi
  fi
  
  p_ok "Provisioned NFS storage: $sid"
}

# Return "HDD" for rotational disks, "SSD" for everything else (NVMe, SATA SSD).
get_disk_type_prefix() {
  local dev="$1" rot
  rot="$(disk_is_rotational "$dev")"
  if [[ "$rot" == "1" ]]; then
    printf '%s' "HDD"
  else
    printf '%s' "SSD"
  fi
}

# Attempt to heal an already-provisioned disk's mount/storage config.
# Returns 0 if fully healed (caller should skip to next disk).
# Returns 1 if heal failed (caller should fall through to full re-provision).
heal_provisioned_disk() {
  local label="$1" part="$2"

  case "$STORAGE_TYPE" in
    dir)
      ensure_mount "$label" "$part"
      ensure_pvesm_storage "$label" "/mnt/disks/$label"
      return 0
      ;;
    lvm|lvm-thin)
      if ! vgs "$label" >/dev/null 2>&1; then
        p_warn "Disk labeled $label but VG not found; will re-provision"
        return 1
      fi
      if [[ "$STORAGE_TYPE" == "lvm-thin" ]]; then
        local hd_digit thinpool
        hd_digit="$(get_hostname_digit)"
        thinpool="pool-${hd_digit}${label: -1}"
        if ! lvs "$label/$thinpool" >/dev/null 2>&1; then
          p_warn "Disk labeled $label but thin pool $thinpool not found; will re-provision"
          return 1
        fi
        ensure_pvesm_lvm_thin_storage "$label" "$label" "$thinpool"
      else
        ensure_pvesm_lvm_storage "$label" "$label"
      fi
      return 0
      ;;
  esac
  return 0
}

# If a Proxmox storage entry for 'label' exists with a different type than
# the currently-requested $STORAGE_TYPE, remove the stale entry so it can
# be recreated with the correct type.
remove_stale_storage_if_type_mismatch() {
  local label="$1"
  storage_exists "$label" || return 0

  local existing_type expected_type
  existing_type="$(_pvesm_status_cached | awk -v sid="$label" 'NR>1 && $1==sid {print $2; exit}')"
  [[ -n "$existing_type" ]] || return 0

  expected_type="$STORAGE_TYPE"
  [[ "$expected_type" == "lvm-thin" ]] && expected_type="lvmthin"
  [[ "$existing_type" == "$expected_type" ]] && return 0

  p_warn "Removing old Proxmox storage '$label' (type: $existing_type, will recreate as: $STORAGE_TYPE)"
  run_cmd "Removing Proxmox storage '$label'" pvesm remove "$label"
  _pvesm_invalidate_cache
}

# Process a single data disk: determine its label, heal or provision it.
provision_single_disk() {
  local d="$1" hd="$2"

  p_info "Processing disk: $d"

  local typ rot
  typ="$(get_disk_type_prefix "$d")"
  rot="$(disk_is_rotational "$d")"
  p_ok "Disk type determined: $typ (rotational=$rot)"

  local part existing_label label
  part="$(get_first_partition "$d" || true)"
  p_info "Checking for existing label on ${part:-$d}"
  existing_label=""
  if [[ -n "$part" ]]; then
    existing_label="$(blkid -o value -s LABEL "$part" 2>/dev/null || true)"
  fi

  local expected_pattern="^${typ}-${hd}[A-Z]$"

  if [[ -n "$existing_label" && "$existing_label" =~ $expected_pattern ]]; then
    label="$existing_label"
    if [[ $ALL -eq 0 && ${#ONLY_FILTERS[@]} -eq 0 ]]; then
      p_ok "Disk $d already provisioned as $label; skipping (use --all or --only to re-provision)"
      if heal_provisioned_disk "$label" "$part"; then
        return 0  # Healed successfully; skip to next disk
      fi
      # Heal failed (e.g. broken VG): fall through to fresh provision with new label
      p_info "Heal failed for $label; re-provisioning with a fresh label"
    else
      p_warn "Disk $d already provisioned as $label; will DESTROY and re-provision"
      if [[ "$STORAGE_TYPE" == "dir" ]]; then
        local old_mount="/mnt/disks/$existing_label"
        if storage_exists "$existing_label"; then
          run_cmd "Removing Proxmox storage '$existing_label'" pvesm remove "$existing_label"
          _pvesm_invalidate_cache
        fi
        if findmnt -n "$old_mount" >/dev/null 2>&1; then
          run_cmd "Unmounting existing mount $old_mount" umount -lf "$old_mount"
        fi
        remove_fstab_mount "$old_mount"
        if [[ -d "$old_mount" ]]; then
          run_cmd "Removing mount directory $old_mount" rm -rf "$old_mount"
        fi
      fi
    fi
  fi

  # Assign a fresh label for new provisioning (or after a failed heal)
  local letter
  letter="$(next_letter "$typ" "$hd")"
  label="${typ}-${hd}${letter}"

  remove_stale_storage_if_type_mismatch "$label"

  case "$STORAGE_TYPE" in
    dir)      p_warn "Disk $d will be DESTROYED and provisioned as $label (dir: GPT, ext4)" ;;
    lvm)      p_warn "Disk $d will be DESTROYED and provisioned as $label (LVM: thick volumes)" ;;
    lvm-thin) p_warn "Disk $d will be DESTROYED and provisioned as $label (LVM-Thin: thin pool)" ;;
  esac

  case "$STORAGE_TYPE" in
    dir)
      provision_disk_dir "$d" "$label" || { p_err "Failed to provision $d as directory storage"; return 1; }
      ;;
    lvm)
      provision_disk_lvm "$d" "$label" || { p_err "Failed to provision $d as LVM storage"; return 1; }
      ;;
    lvm-thin)
      provision_disk_lvm_thin "$d" "$label" || { p_err "Failed to provision $d as LVM-Thin storage"; return 1; }
      ;;
    *)
      die "Unknown storage type: $STORAGE_TYPE"
      ;;
  esac

  p_ok "Provisioned $d -> $label ($STORAGE_TYPE)"
}

provision_data_disks() {
  local sysdisk="$1"
  local hd="$2"

  validate_storage_filters "provision" "$sysdisk"

  if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
    p_info "Provisioning filtered disk(s) as Proxmox storage: filters=[${ONLY_FILTERS[*]}] sysdisk=$sysdisk hostdigit=$hd"
  else
    p_info "Provisioning non-system disks as Proxmox storage (fair game): sysdisk=$sysdisk hostdigit=$hd"
  fi

  p_info "Detecting target disk(s)"
  mapfile -t disks < <(list_target_disks "$sysdisk")
  [[ "${#disks[@]}" -gt 0 ]] || die "No disks detected."
  p_ok "Found ${#disks[@]} disk(s)"

  local d
  for d in "${disks[@]}"; do
    [[ "$d" == "$sysdisk" ]] && continue
    provision_single_disk "$d" "$hd" || true
  done

  refresh_grub_device_map "$FORCE"
}

remove_fstab_mount() {
  local mnt="$1"
  ensure_fstab_writable
  run_cmd_str "Removing /etc/fstab entries for $mnt" "sed -i '\\|[[:space:]]${mnt}[[:space:]]|d' /etc/fstab"
}

validate_boot_disk_detection() {
  local boot_disk="$1"
  
  # Must be a block device
  if [[ ! -b "$boot_disk" ]]; then
    return 1
  fi
  
  # Must be a base disk, not a partition
  if [[ "$boot_disk" =~ (p[0-9]+|[0-9]+)$ ]]; then
    return 1
  fi
  
  # Must have partitions (a boot disk should have a partition table)
  local part_count
  part_count=$(lsblk -ln -o TYPE "$boot_disk" 2>/dev/null | grep -c "^part$" || echo "0")
  if [[ "$part_count" -eq 0 ]]; then
    return 1
  fi
  
  # Verify root partition is actually on this disk
  local root_dev
  root_dev="$(findmnt -no SOURCE / 2>/dev/null)"
  if [[ -z "$root_dev" ]]; then
    return 1
  fi
  
  # For LVM, resolve to physical device
  if [[ "$root_dev" =~ ^/dev/mapper/ ]]; then
    local vg lv pv
    vg="${root_dev#/dev/mapper/}"
    vg="${vg%-*}"
    lv="${root_dev#/dev/mapper/}"
    lv="${lv#*-}"
    
    # Get PV for this VG
    pv="$(pvs --noheadings -o pv_name -S vg_name="$vg" 2>/dev/null | awk 'NF{print $1; exit}')"
    if [[ -z "$pv" ]]; then
      return 1
    fi
    
    # Strip partition from PV to get disk
    local pv_disk
    pv_disk="$(get_base_disk "$pv")"
    
    # Verify it matches our boot disk
    if [[ "$pv_disk" != "$boot_disk" ]]; then
      return 1
    fi
  else
    # Direct partition - strip partition number and compare
    local root_disk
    root_disk="$(get_base_disk "$root_dev")"
    if [[ "$root_disk" != "$boot_disk" ]]; then
      return 1
    fi
  fi
  
  # All checks passed
  return 0
}

refresh_grub_device_map() {
  local force="${1:-0}"
  
  # Check if GRUB is installed
  if ! command -v grub-mkdevicemap &>/dev/null; then
    return 0
  fi
  
  # Check if this is a GRUB-based system
  if [[ ! -d /boot/grub ]] && [[ ! -d /boot/efi/EFI ]]; then
    return 0
  fi
  
  printf '\n'
  p_info "STEP: Refreshing GRUB device map"
  p_info "Disk topology has changed - updating bootloader configuration"
  
  if [[ "$force" -eq 0 ]]; then
    printf '\n'
    p_info "After adding/removing disks, GRUB's device map should be refreshed to prevent"
    p_info "boot issues during future system updates. This will safely regenerate the device map."
    printf '\n'
    read -p "Refresh GRUB now? (recommended) [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ -n $REPLY ]]; then
      p_warn "Skipping GRUB refresh. Run manually if you encounter boot issues:"
      printf '%s\n' "    sudo grub-mkdevicemap"
      printf '%s\n' "    sudo grub-install /dev/YOUR_BOOT_DISK"
      printf '%s\n' "    sudo update-grub"
      return 0
    fi
  fi
  
  # SAFE OPERATION: Always regenerate device map (no destructive operations)
  if ! run_cmd "Regenerating GRUB device map" grub-mkdevicemap; then
    p_warn "Failed to regenerate GRUB device map"
    p_info "Run manually: sudo grub-mkdevicemap"
    return 1
  fi
  
  # POTENTIALLY DESTRUCTIVE: Only reinstall GRUB if we're 100% certain
  local boot_disk
  boot_disk="$(get_system_disk 2>/dev/null)"
  
  if [[ -z "$boot_disk" ]]; then
    printf '\n'
    p_warn "Could not auto-detect boot disk - skipping GRUB reinstall for safety"
    p_info "GRUB device map has been refreshed, but you should manually reinstall GRUB:"
    printf '%s\n' "    sudo grub-install /dev/YOUR_BOOT_DISK"
    printf '%s\n' "    sudo update-grub"
    printf '\n'
    p_info "To find your boot disk, run: findmnt / | tail -1"
    return 0
  fi
  
  # Validate boot disk detection with multiple safety checks
  if ! validate_boot_disk_detection "$boot_disk"; then
    printf '\n'
    p_warn "Boot disk detection uncertain (detected: $boot_disk) - skipping GRUB reinstall for safety"
    p_info "GRUB device map has been refreshed, but you should manually verify and reinstall GRUB:"
    printf '%s\n' "    # Verify your boot disk:"
    printf '%s\n' "    findmnt / | tail -1"
    printf '%s\n' "    lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS"
    printf '\n'
    printf '%s\n' "    # Then reinstall GRUB to the correct disk:"
    printf '%s\n' "    sudo grub-install /dev/YOUR_BOOT_DISK"
    printf '%s\n' "    sudo update-grub"
    printf '\n'
    return 0
  fi
  
  # We're confident - proceed with GRUB reinstall
  p_info "Detected boot disk: $boot_disk (validated)"
  
  if ! run_cmd "Reinstalling GRUB to $boot_disk" grub-install "$boot_disk" 2>&1 | grep -v "^Installing for"; then
    printf '\n'
    p_err "Failed to reinstall GRUB to $boot_disk"
    p_warn "GRUB device map was refreshed, but bootloader reinstall failed"
    p_info "Run manually: sudo grub-install $boot_disk && sudo update-grub"
    printf '\n'
    return 1
  fi
  
  if ! run_cmd "Updating GRUB configuration" update-grub 2>&1 | grep -v "^Found"; then
    p_warn "Failed to update GRUB configuration"
    p_info "Run manually: sudo update-grub"
    return 1
  fi
  
  p_ok "GRUB device map refreshed and bootloader reinstalled successfully"
  return 0
}

parse_storage_cfg() {
  local cfg="/etc/pve/storage.cfg"
  [[ -f "$cfg" ]] || return 0
  awk '
    /^[[:alpha:]]+:/ {
      type=$1; sub(":", "", type); sid=$2; path=""; nodes=""; shared=""; vgname=""; thinpool=""; inblock=1; next
    }
    inblock && /^[[:space:]]*path[[:space:]]+/ {path=$2}
    inblock && /^[[:space:]]*nodes[[:space:]]+/ {nodes=$2}
    inblock && /^[[:space:]]*shared[[:space:]]+/ {shared=$2}
    inblock && /^[[:space:]]*vgname[[:space:]]+/ {vgname=$2}
    inblock && /^[[:space:]]*thinpool[[:space:]]+/ {thinpool=$2}
    inblock && NF==0 {
      if (sid != "") {print type "|" sid "|" path "|" nodes "|" shared "|" vgname "|" thinpool}
      inblock=0
    }
    END { if (sid != "") {print type "|" sid "|" path "|" nodes "|" shared "|" vgname "|" thinpool} }
  ' "$cfg"
}

find_existing_system_disk_storage() {
  local hd="$1"
  local type sid path nodes shared vgname thinpool
  local candidates=()

  while IFS='|' read -r type sid path nodes shared vgname thinpool; do
    [[ "$type" == "lvmthin" ]] || continue
    [[ "$vgname" == "pve" ]] || continue
    [[ "$sid" =~ ^SSD-${hd}[A-Z]$ ]] || continue
    [[ -n "$thinpool" ]] || continue
    lvs "pve/$thinpool" >/dev/null 2>&1 || continue
    candidates+=("$sid|$thinpool")
  done < <(parse_storage_cfg)

  [[ ${#candidates[@]} -gt 0 ]] || return 1

  mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort)
  printf '%s\n' "${candidates[0]}"
}

cleanup_duplicate_system_disk_storage_entries() {
  local hd="$1" keep_sid="$2"
  local type sid path nodes shared vgname thinpool

  while IFS='|' read -r type sid path nodes shared vgname thinpool; do
    [[ "$type" == "lvmthin" ]] || continue
    [[ "$vgname" == "pve" ]] || continue
    [[ "$sid" =~ ^SSD-${hd}[A-Z]$ ]] || continue
    [[ "$sid" == "$keep_sid" ]] && continue
    p_warn "Removing stale system-disk storage '$sid' (keeping '$keep_sid')"
    run_cmd "Removing stale system-disk storage '$sid'" pvesm remove "$sid"
  done < <(parse_storage_cfg)
}

ensure_system_disk_storage_entries_from_pve_lvs() {
  local hd="$1"
  local pool_name lv_attr sid
  local chosen_pool=""

  while read -r pool_name lv_attr; do
    [[ -n "$pool_name" ]] || continue
    [[ "$lv_attr" =~ ^t ]] || continue
    [[ "$pool_name" =~ ^pool-${hd}[A-Z]$ ]] || continue

    if [[ -z "$chosen_pool" || "$pool_name" < "$chosen_pool" ]]; then
      chosen_pool="$pool_name"
    fi
  done < <(lvs --noheadings -o lv_name,lv_attr pve 2>/dev/null | awk 'NF{print $1, $2}')

  [[ -n "$chosen_pool" ]] || return 1

  sid="SSD-${hd}${chosen_pool: -1}"
  if storage_exists "$sid"; then
    p_ok "System-disk storage already present: $sid -> pve/$chosen_pool"
  else
    p_info "Recreating missing system-disk storage: $sid -> pve/$chosen_pool"
    ensure_pvesm_lvm_thin_storage "$sid" "pve" "$chosen_pool"
  fi

  cleanup_duplicate_system_disk_storage_entries "$hd" "$sid"
  return 0
}

node_in_list() {
  local node="$1" list="$2"
  [[ -z "$list" ]] && return 1
  IFS=',' read -r -a nodes <<< "$list"
  for n in "${nodes[@]}"; do
    [[ "$n" == "$node" ]] && return 0
  done
  return 1
}

is_shared_flag() {
  local val="$1"
  [[ "$val" == "1" || "$val" == "true" || "$val" == "yes" ]] && return 0
  return 1
}

rename_storage() {
  local old_sid="$1"
  local new_sid="$2"
  local cfg="/etc/pve/storage.cfg"
  local node
  node="$(hostname -s)"
  
  p_info "Renaming storage: $old_sid -> $new_sid"
  
  # Verify old storage exists
  if ! storage_exists "$old_sid"; then
    die "Storage '$old_sid' does not exist"
  fi

  if [[ "$old_sid" == "local" ]]; then
    die "Renaming 'local' is disabled. In clusters, 'local' is a cluster-wide storage ID with node-local paths and renaming it causes confusing behavior.\n       Keep 'local' as-is, or perform offline root shrink to free VG space and let this script create SSD-${node: -1}A style system storage."
  fi
  
  # Verify new name doesn't exist
  if storage_exists "$new_sid"; then
    die "Storage '$new_sid' already exists"
  fi
  
  # Verify storage name format (optional - warn if non-standard)
  if [[ ! "$new_sid" =~ ^(HDD|SSD)-[0-9]+[A-Z]$ ]]; then
    p_warn "New storage name '$new_sid' doesn't match standard format (HDD-<N><Letter> or SSD-<N><Letter>)"
    if [[ "$FORCE" -eq 0 ]]; then
      read -r -p "Continue anyway? [y/N] " response
      if [[ ! "$response" =~ ^[Yy]$ ]]; then
        die "Rename aborted by user"
      fi
    fi
  fi
  
  # Backup configuration
  local backup_file="${cfg}.backup.$(date +%Y%m%d-%H%M%S)"
  run_cmd "Backing up storage configuration" cp "$cfg" "$backup_file"
  p_ok "Backup created: $backup_file"
  
  if [[ "$WHATIF" -eq 1 ]]; then
    p_info "[WHATIF] Would rename storage in $cfg"
    p_info "[WHATIF] Change: 'dir: $old_sid' -> 'dir: $new_sid'"
    return 0
  fi
  
  # Perform rename (edit the storage type line)
  # The storage.cfg format is:
  #   <type>: <storage-id>
  #       <key> <value>
  # We need to change the storage-id part
  run_cmd_str "Renaming storage in configuration" \
    "sed -i '/^[a-z]*:[[:space:]]*${old_sid}[[:space:]]*$/s/:.*$/: ${new_sid}/' '$cfg'"
  
  # Verify the change
  if storage_exists "$new_sid" && ! storage_exists "$old_sid"; then
    p_ok "Storage renamed successfully: $old_sid -> $new_sid"
    p_info "Filesystem path remains unchanged (cosmetic mismatch is OK)"
    p_info "VM/CT configs now reference: $new_sid"
    p_info "To align directory name, deprovision and re-provision the disk"
  else
    die "Rename verification failed. Restore from backup: $backup_file"
  fi
}

list_storage_usage() {
  local storage="$1"
  
  if ! storage_exists "$storage"; then
    die "Storage '$storage' does not exist"
  fi
  
  p_info "Content on storage: $storage"
  echo ""
  
  # List all content
  if ! pvesm list "$storage" 2>/dev/null; then
    p_warn "Unable to list content (storage may be offline or empty)"
  fi
  
  echo ""
  p_info "VMs/CTs using this storage:"
  
  local found=0
  
  # Check VMs
  if command -v qm >/dev/null 2>&1; then
    while read -r vmid; do
      [[ -z "$vmid" ]] && continue
      if qm config "$vmid" 2>/dev/null | grep -q "$storage"; then
        local name status
        name=$(qm config "$vmid" 2>/dev/null | awk -F': ' '/^name:/ {print $2}')
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        echo "  VM $vmid ($name) - $status"
        found=1
      fi
    done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')
  fi
  
  # Check containers
  if command -v pct >/dev/null 2>&1; then
    while read -r ctid; do
      [[ -z "$ctid" ]] && continue
      if pct config "$ctid" 2>/dev/null | grep -q "$storage"; then
        local name status
        name=$(pct config "$ctid" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}')
        status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
        echo "  CT $ctid ($name) - $status"
        found=1
      fi
    done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')
  fi
  
  if [[ $found -eq 0 ]]; then
    echo "  None"
  fi
}

smartctl_safe() {
  local dev="$1"
  # Timeout guards against drives that block on ATA passthrough (e.g. bad USB bridges).
  timeout 15 smartctl -a "$dev" 2>/dev/null || true
}

smart_first_line() {
  local dev="$1" regex="$2"
  smartctl_safe "$dev" | awk -v r="$regex" '$0 ~ r {print; exit}'
}

smart_rotation() {
  local dev="$1" base line value
  base="$(basename "$dev")"
  
  # NVMe drives - check device name pattern
  if [[ "$base" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
    printf '%s' "NVMe"
    return 0
  fi
  
  line="$(smart_first_line "$dev" "Rotation Rate")"
  if [[ -n "$line" ]]; then
    value="${line#*:}"
    value="$(echo "$value" | xargs)"
    if echo "$value" | grep -qi 'solid state'; then
      printf '%s' "SSD"
    else
      printf '%s' "$value"
    fi
  else
    printf '%s' "unknown"
  fi
}

smart_model() {
  local dev="$1" line value
  line="$(smart_first_line "$dev" "Device Model|Model Number|Product")"
  if [[ -n "$line" ]]; then
    value="${line#*:}"
    printf '%s' "$(echo "$value" | xargs)"
  else
    printf '%s' "unknown"
  fi
}

smart_health() {
  local dev="$1" line
  line="$(smart_first_line "$dev" "SMART overall-health self-assessment test result|SMART Health Status")"
  if echo "$line" | grep -qi 'pass\|ok'; then
    printf '%s' "OK"
  elif [[ -n "$line" ]]; then
    printf '%s' "WARN"
  else
    printf '%s' "unknown"
  fi
}

smart_temp() {
  local dev="$1" line value
  line="$(smartctl_safe "$dev" | awk '
    /Temperature_Celsius|Airflow_Temperature_Cel/ {
      for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}
    }
    /Current Drive Temperature/ {
      for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}
    }
    /^Temperature:/ {
      for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}
    }
  ' || true)"
  if [[ -n "$line" ]]; then
    value="$line"
    printf '%s' "${value}C"
  else
    printf '%s' "unknown"
  fi
}

smart_power_on_hours() {
  local dev="$1" line value
  line="$(smart_first_line "$dev" "Power_On_Hours|Power On Hours")"
  if [[ -n "$line" ]]; then
    value="$(echo "$line" | grep -oE '[0-9]+' | tail -n1)"
    printf '%s' "${value}h"
  else
    printf '%s' "unknown"
  fi
}

smart_life_remaining() {
  local dev="$1" line value used
  line="$(smart_first_line "$dev" "Percent_Lifetime_Remain|Media_Wearout_Indicator|Percentage Used")"
  if [[ -z "$line" ]]; then
    printf '%s' "unknown"
    return 0
  fi

  value="$(echo "$line" | grep -oE '[0-9]+' | head -n1)"
  if echo "$line" | grep -qi 'percentage used'; then
    used="$value"
    if [[ -n "$used" ]]; then
      printf '%s' "$((100 - used))%"
      return 0
    fi
  fi

  if [[ -n "$value" ]]; then
    printf '%s' "${value}%"
  else
    printf '%s' "unknown"
  fi
}

# Build a device-name -> storage-id mapping from the current Proxmox storage
# config. The result is written into the caller's associative array whose name
# is passed as the first argument (passed by reference via local -n).
#
# Keys are bare device names without /dev/ (e.g. "nvme0n1", "sda") so they
# can be used directly against lsblk NAME output.
#
# Usage:
#   declare -A my_map
#   build_device_storage_map my_map
build_device_storage_map() {
  local -n _map_ref="$1"

  while IFS='|' read -r type sid path nodes shared vgname thinpool; do
    [[ -n "$sid" ]] || continue
    [[ "$sid" == "local" || "$sid" == "local-lvm" ]] && continue

    case "$type" in
      dir)
        [[ -z "$path" ]] && continue
        local _md
        _md="$(findmnt -n -o SOURCE --target "$path" 2>/dev/null || true)"
        if [[ -n "$_md" ]]; then
          local _bd
          _bd="$(basename "$(get_base_disk "$_md")")"
          [[ -n "$_bd" ]] && _map_ref["$_bd"]="$sid"
        fi
        ;;
      lvm|lvmthin)
        local _pv
        _pv="$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v vg="$sid" '$2==vg {print $1; exit}')"
        if [[ -n "$_pv" ]]; then
          local _bd
          _bd="$(basename "$(get_base_disk "$_pv")")"
          [[ -n "$_bd" ]] && _map_ref["$_bd"]="$sid"
        fi
        ;;
      nfs)
        # NFS storage - no physical device to map
        ;;
    esac
  done < <(parse_storage_cfg)
}

show_available_storage() {
  local sysdisk
  sysdisk="$(get_system_disk)"

  declare -A device_storage_map
  build_device_storage_map device_storage_map
  
  # Display device table with storage status
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║ PHYSICAL STORAGE DEVICES"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  
  if [[ "$EXTENDED" -eq 1 ]]; then
    printf '%-15s %-9s %-30s %-8s %-8s %-8s %-10s %-15s\n' "Device" "Size" "Model" "Media" "Health" "Temp" "Life" "Proxmox Storage"
  else
    printf '%-15s %-9s %-30s %-8s %-15s\n' "Device" "Size" "Model" "Media" "Proxmox Storage"
  fi

  mapfile -t disks < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')
  for name in "${disks[@]}"; do
    local dev size model rotation health temp life storage_status
    dev="/dev/$name"
    size="$(lsblk -dn -o SIZE "$dev" 2>/dev/null || echo "?")"
    model="$(smart_model "$dev")"
    rotation="$(smart_rotation "$dev")"
    if [[ "$rotation" == "unknown" && "$model" == "unknown" ]]; then
      model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | xargs)"
      [[ -z "$model" ]] && model="unknown"
    fi
    
    # Check storage status
    if [[ -n "${device_storage_map[$name]:-}" ]]; then
      storage_status="${device_storage_map[$name]}"
    elif is_on_disk "$dev" "$sysdisk"; then
      storage_status="(system)"
    else
      storage_status="-"
    fi
    
    if [[ "$EXTENDED" -eq 1 ]]; then
      health="$(smart_health "$dev")"
      temp="$(smart_temp "$dev")"
      life="$(smart_life_remaining "$dev")"
      printf '%-15s %-9s %-30s %-8s %-8s %-8s %-10s %-15s\n' "$dev" "$size" "$model" "$rotation" "$health" "$temp" "$life" "$storage_status"
    else
      printf '%-15s %-9s %-30s %-8s %-15s\n' "$dev" "$size" "$model" "$rotation" "$storage_status"
    fi
  done
}

show_storage_mapping() {
  local node
  node="$(hostname -s)"
  
  # Parse storage config to get paths, filtering by node assignment
  declare -A storage_paths storage_types
  while IFS='|' read -r type sid path nodes shared vgname thinpool; do
    [[ -n "$sid" ]] || continue
    [[ "$sid" == "local" || "$sid" == "local-lvm" ]] && continue
    
    # Skip storage not assigned to this node
    if ! node_in_list "$node" "$nodes"; then
      continue
    fi
    
    storage_types["$sid"]="$type"
    storage_paths["$sid"]="$path"
  done < <(parse_storage_cfg)
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║ PROXMOX STORAGE → DEVICE MAPPING"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  
  # Track whether we display any mappings
  local found_mappings=0
  
  # Check if there are any storage entries to display (safe for set -u)
  local storage_count="${!storage_types[*]}"
  if [[ -z "$storage_count" ]]; then
    echo "  No custom storage configured."
    echo ""
    return
  fi
  
  # Sort storage IDs alphabetically for consistent display
  mapfile -t sorted_sids < <(printf '%s\n' "${!storage_types[@]}" | sort)
  
  for sid in "${sorted_sids[@]}"; do
    local storage_type="${storage_types[$sid]}"
    local storage_path="${storage_paths[$sid]}"
    
    case "$storage_type" in
      dir)
        if [[ -z "$storage_path" ]]; then
          continue
        fi
        
        # Get mount device
        local mount_device
        mount_device=$(findmnt -n -o SOURCE --target "$storage_path" 2>/dev/null || echo "")
        
        if [[ -z "$mount_device" ]]; then
          continue
        fi
        
        local base_device size model
        base_device="$(get_base_disk "$mount_device")"

        if [[ -n "$base_device" && -b "$base_device" ]]; then
          size=$(lsblk -ndo SIZE "$base_device" 2>/dev/null || echo "?")
          model=$(lsblk -ndo MODEL "$base_device" 2>/dev/null | xargs || echo "Unknown")
          
          echo -e "  ${C_OK}${sid}${NC} (${storage_type}) → ${base_device} (${size}, ${model})"
          echo "    Mount: ${storage_path}"
          echo "    Device: ${mount_device}"
          echo ""
          found_mappings=1
        fi
        ;;
      lvm|lvmthin)
        # LVM storage - VG name matches storage ID
        local pv_device base_device
        pv_device=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v vg="$sid" '$2==vg {print $1; exit}')
        
        if [[ -n "$pv_device" ]]; then
          base_device="$(get_base_disk "$pv_device")"
          local size model
          size=$(lsblk -ndo SIZE "$base_device" 2>/dev/null || echo "?")
          model=$(lsblk -ndo MODEL "$base_device" 2>/dev/null | xargs || echo "Unknown")
          
          echo -e "  ${C_OK}${sid}${NC} (${storage_type}) → ${base_device} (${size}, ${model})"
          echo "    VG: ${sid}"
          echo "    PV: ${pv_device}"
          
          if [[ "$storage_type" == "lvmthin" ]]; then
            # Show thin pool info
            local pool_name pool_data
            pool_name=$(lvs --noheadings -o lv_name,lv_attr "$sid" 2>/dev/null | awk '$2 ~ /^t/ {print $1; exit}')
            if [[ -n "$pool_name" ]]; then
              pool_data=$(lvs --noheadings -o data_percent "$sid/$pool_name" 2>/dev/null | awk '{printf "%.1f%%", $1}')
              echo "    Thin Pool: ${pool_name} (Used: ${pool_data})"
            fi
          fi
          echo ""
          found_mappings=1
        fi
        ;;
      nfs)
        # NFS storage
        if [[ -n "$storage_path" ]]; then
          echo -e "  ${C_OK}${sid}${NC} (${storage_type}) → Network Storage"
          echo "    Mount: ${storage_path}"
          echo ""
          found_mappings=1
        fi
        ;;
    esac
  done
  
  # If no mappings were displayed, show message
  if [[ $found_mappings -eq 0 ]]; then
    echo "  No device allocations found"
    echo ""
  fi
}

show_available_for_provisioning() {
  local sysdisk
  sysdisk="$(get_system_disk)"

  declare -A device_storage_map
  build_device_storage_map device_storage_map
  
  # Find unallocated devices
  local available_devices=()
  mapfile -t disks < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')
  
  for name in "${disks[@]}"; do
    local dev="/dev/$name"
    
    # Skip system disk
    if is_on_disk "$dev" "$sysdisk"; then
      continue
    fi
    
    # Skip if already allocated to Proxmox storage
    if [[ -n "${device_storage_map[$name]:-}" ]]; then
      continue
    fi
    
    # This device is available
    local size model
    size=$(lsblk -dn -o SIZE "$dev" 2>/dev/null || echo "?")
    model=$(smart_model "$dev")
    if [[ "$model" == "unknown" ]]; then
      model=$(lsblk -dn -o MODEL "$dev" 2>/dev/null | xargs || echo "Unknown")
    fi
    
    available_devices+=("$dev|$size|$model")
  done
  
  # Display available devices
  if [[ ${#available_devices[@]} -eq 0 ]]; then
    return
  fi
  
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║ AVAILABLE FOR PROVISIONING"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  
  if [[ ${#available_devices[@]} -eq 1 ]]; then
    # Single device - show detailed message
    IFS='|' read -r dev size model <<< "${available_devices[0]}"
    echo -e "  ${C_WARN}${dev}${NC} is available for Proxmox storage (${size}, ${model})"
    echo ""
    echo "  To provision it, run:"
    echo ""
    echo -e "    ${C_INFO}./proxmox-storage.sh --provision --only ${dev}${NC}"
  else
    # Multiple devices - show list and build exact command
    echo "  The following devices are available for Proxmox storage:"
    echo ""
    local exact_cmd="./proxmox-storage.sh --provision"
    for entry in "${available_devices[@]}"; do
      IFS='|' read -r dev size model <<< "$entry"
      echo -e "    ${C_WARN}${dev}${NC} (${size}, ${model})"
      exact_cmd+=" --only ${dev}"
    done
    echo ""
    echo "  To provision them, run:"
    echo ""
    echo -e "    ${C_INFO}# Provision all available devices${NC}"
    echo -e "    ${C_INFO}./proxmox-storage.sh --provision --force${NC}"
    echo ""
    echo -e "    ${C_INFO}# Or provision specific device(s)${NC}"
    echo -e "    ${C_INFO}${exact_cmd}${NC}"
  fi
  echo ""
}

whatif_summary_provision() {
  local sysdisk="$1" hd="$2"
  p_info "What-if summary (provision)"
  printf '%s\n' "    - System disk: $sysdisk (use installed root layout, reclaim local-lvm, auto-expand system PV tail if present, create system lvm-thin if free space exists)"

  mapfile -t disks < <(list_target_disks "$sysdisk")
  if [[ "${#disks[@]}" -eq 0 ]]; then
    printf '%s\n' "    - No non-system disks detected"
    return 0
  fi

  for d in "${disks[@]}"; do
    local rot typ part existing_label expected_pattern label base
    rot="$(disk_is_rotational "$d")"
    base="$(basename "$d")"
    
    if [[ "$rot" == "1" ]]; then
      typ="HDD"
    elif [[ "$base" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
      # NVMe drives use SSD prefix for storage naming
      typ="SSD"
    else
      typ="SSD"
    fi

    part="$(get_first_partition "$d" || true)"
    existing_label=""
    if [[ -n "$part" ]]; then
      existing_label="$(blkid -o value -s LABEL "$part" 2>/dev/null || true)"
    fi
    expected_pattern="^${typ}-${hd}[A-Z]$"

    if [[ -n "$existing_label" && "$existing_label" =~ $expected_pattern ]]; then
      printf '%s\n' "    - $d: keep ($existing_label), heal mount/fstab/storage"
    else
      label="${typ}-${hd}$(next_letter "$typ" "$hd")"
      printf '%s\n' "    - $d: wipe + format -> $label"
    fi
  done
}

whatif_summary_deprovision() {
  local sysdisk="$1"
  local node
  node="$(hostname -s)"
  p_info "What-if summary (deprovision)"
  printf '%s\n' "    - System disk: $sysdisk (untouched)"

  declare -A storage_paths storage_nodes storage_shared
  while IFS='|' read -r _ sid path nodes shared; do
    [[ -n "$sid" ]] || continue
    storage_paths["$sid"]="$path"
    storage_nodes["$sid"]="$nodes"
    storage_shared["$sid"]="$shared"
  done < <(parse_storage_cfg)

  local any_storage=0
  for sid in "${!storage_paths[@]}"; do
    [[ "$sid" == "local" || "$sid" == "local-lvm" ]] && continue
    if ! node_in_list "$node" "${storage_nodes[$sid]:-}"; then
      continue
    fi
    if is_shared_flag "${storage_shared[$sid]:-}"; then
      continue
    fi
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      local path_match=0 label_match=0 src=""
      
      # Check if path matches any filter
      if [[ -n "${storage_paths[$sid]:-}" ]]; then
        src="$(findmnt -n -o SOURCE --target "${storage_paths[$sid]}" 2>/dev/null || true)"
        if [[ -n "$src" ]]; then
          local disk
          disk="$(lsblk -no PKNAME "$src" 2>/dev/null || echo "$src")"
          if [[ "$disk" != /dev/* ]]; then
            disk="/dev/$disk"
          fi
          if matches_any_filter "$disk" "$sid"; then
            path_match=1
          fi
        fi
      fi
      
      # Check if storage name matches any filter
      if matches_any_filter "" "$sid"; then
        label_match=1
      fi
      
      if [[ "$path_match" -eq 0 && "$label_match" -eq 0 ]]; then
        continue
      fi
    fi
    any_storage=1
    printf '%s\n' "    - Remove storage $sid (${storage_paths[$sid]:-unknown})"
  done

  if [[ "$any_storage" -eq 0 ]]; then
    printf '%s\n' "    - No node-local, non-shared storages to remove"
  fi

  mapfile -t disks < <(list_target_disks "$sysdisk")
  if [[ "${#disks[@]}" -eq 0 ]]; then
    printf '%s\n' "    - No non-system disks detected"
    return 0
  fi

  for d in "${disks[@]}"; do
    if lsblk -ln -o MOUNTPOINT "$d" | awk 'NF{print $1}' | grep -qv '^/mnt/disks/'; then
      printf '%s\n' "    - Skip wipe $d (active mounts outside /mnt/disks)"
    else
      printf '%s\n' "    - Wipe disk $d to raw state"
    fi
  done
}

deprovision_storage_entries() {
  local sysdisk="$1"
  local node
  node="$(hostname -s)"
  declare -A storage_paths storage_types storage_nodes storage_shared storage_ids

  while IFS='|' read -r type sid path nodes shared vgname thinpool; do
    [[ -n "$sid" ]] || continue
    storage_types["$sid"]="$type"
    storage_paths["$sid"]="$path"
    storage_nodes["$sid"]="$nodes"
    storage_shared["$sid"]="$shared"
    storage_ids["$sid"]=1
  done < <(parse_storage_cfg)

  for sid in "${!storage_ids[@]}"; do
    [[ "$sid" == "local" || "$sid" == "local-lvm" ]] && continue

    local path="${storage_paths[$sid]:-}"
    local nodes="${storage_nodes[$sid]:-}"
    local shared="${storage_shared[$sid]:-}"

    if ! node_in_list "$node" "$nodes"; then
      p_warn "Skipping storage '$sid' (not assigned to node $node)"
      continue
    fi
    if is_shared_flag "$shared"; then
      p_warn "Skipping shared storage '$sid'"
      continue
    fi

    local path_match=0
    local label_match=0
    if [[ -n "$path" ]]; then
      local src
      src="$(findmnt -n -o SOURCE --target "$path" 2>/dev/null || true)"
      if [[ -n "$src" ]] && is_on_system_disk "$src" "$sysdisk"; then
        p_warn "Skipping storage '$sid' on system disk path: $path"
        continue
      fi
      if [[ ${#ONLY_FILTERS[@]} -gt 0 && -n "$src" ]]; then
        local disk
        disk="$(lsblk -no PKNAME "$src" 2>/dev/null || echo "$src")"
        if [[ "$disk" != /dev/* ]]; then
          disk="/dev/$disk"
        fi
        if matches_any_filter "$disk" "$sid"; then
          path_match=1
        fi
      fi
    fi
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      if matches_any_filter "" "$sid"; then
        label_match=1
      fi
      if [[ "$path_match" -eq 0 && "$label_match" -eq 0 ]]; then
        p_warn "Skipping storage '$sid' (does not match filters: ${ONLY_FILTERS[*]})"
        continue
      fi
    fi

    if storage_exists "$sid"; then
      run_cmd "Removing Proxmox storage '$sid'" pvesm remove "$sid"
      _pvesm_invalidate_cache
    fi
    if [[ -n "$path" ]]; then
      if findmnt -n "$path" >/dev/null 2>&1; then
        run_cmd "Unmounting $path" umount -lf "$path"
      fi
      remove_fstab_mount "$path"
      # Clean up mount directories for our managed storage
      if [[ "$path" == /mnt/disks/* ]]; then
        run_cmd "Removing mount directory $path" rm -rf "$path"
      elif [[ "$path" == /mnt/pve/* ]]; then
        # Proxmox-managed NFS mount points - safe to remove after unmount
        run_cmd "Removing Proxmox NFS mount directory $path" rm -rf "$path"
      else
        p_warn "Skipping removal of unrecognized path: $path"
      fi
    fi
  done
}

cleanup_lvm_on_non_system_disks() {
  local sysdisk="$1"
  declare -A vgs_seen vgs_has_system vgs_has_target vgs_has_other vgs_removed
  mapfile -t pvs_list < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk 'NF{print $1 " " $2}')

  for line in "${pvs_list[@]}"; do
    local pv vg
    pv="${line%% *}"
    vg="${line##* }"
    [[ -n "$pv" && -n "$vg" ]] || continue
    if is_on_system_disk "$pv" "$sysdisk"; then
      vgs_has_system["$vg"]=1
    else
      vgs_seen["$vg"]=1
    fi
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      local disk
      disk="$(lsblk -no PKNAME "$pv" 2>/dev/null || echo "$pv")"
      if [[ "$disk" != /dev/* ]]; then
        disk="/dev/$disk"
      fi
      if matches_any_filter "$disk" "$vg"; then
        vgs_has_target["$vg"]=1
      else
        vgs_has_other["$vg"]=1
      fi
    fi
  done

  for vg in "${!vgs_seen[@]}"; do
    if [[ "$vg" == "pve" ]]; then
      p_warn "Skipping VG $vg (system VG)"
      continue
    fi
    if [[ -n "${vgs_has_system[$vg]:-}" ]]; then
      p_warn "Skipping VG $vg (has PV on system disk)"
      continue
    fi
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      if [[ -z "${vgs_has_target[$vg]:-}" ]]; then
        p_warn "Skipping VG $vg (does not match filters: ${ONLY_FILTERS[*]})"
        continue
      fi
      if [[ -n "${vgs_has_other[$vg]:-}" ]]; then
        p_warn "Skipping VG $vg (spans other disks; not removing partially)"
        continue
      fi
    fi
    
    # Explicitly remove thin pools first (cleaner teardown)
    local thin_pools
    mapfile -t thin_pools < <(lvs --noheadings -o lv_name,lv_attr "$vg" 2>/dev/null | awk '$2 ~ /^t/ {print $1}' || true)
    for pool in "${thin_pools[@]}"; do
      if [[ -n "$pool" ]]; then
        run_cmd "Removing thin pool $vg/$pool" lvremove -y "$vg/$pool"
      fi
    done
    
    run_cmd "Deactivating VG $vg" vgchange -an "$vg"
    run_cmd "Removing VG $vg" vgremove -y "$vg"
    vgs_removed["$vg"]=1
  done

  for line in "${pvs_list[@]}"; do
    local pv vg
    pv="${line%% *}"
    vg="${line##* }"
    [[ -n "$pv" && -n "$vg" ]] || continue
    if [[ "$vg" == "pve" ]]; then
      p_warn "Skipping PV $pv (system VG)"
      continue
    fi
    if is_on_system_disk "$pv" "$sysdisk"; then
      continue
    fi
    if [[ -n "${vgs_has_system[$vg]:-}" ]]; then
      p_warn "Skipping PV $pv (VG $vg has system-disk PV)"
      continue
    fi
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      local disk
      disk="$(lsblk -no PKNAME "$pv" 2>/dev/null || echo "$pv")"
      if [[ "$disk" != /dev/* ]]; then
        disk="/dev/$disk"
      fi
      if ! matches_any_filter "$disk"; then
        continue
      fi
      if [[ -z "${vgs_removed[$vg]:-}" ]]; then
        p_warn "Skipping PV $pv (VG $vg not removed)"
        continue
      fi
    fi
    run_cmd "Removing PV $pv" pvremove -y "$pv"
  done
}

cleanup_zfs_on_non_system_disks() {
  local sysdisk="$1"
  command -v zpool >/dev/null 2>&1 || return 0

  mapfile -t pools < <(zpool list -H -o name 2>/dev/null || true)
  for pool in "${pools[@]}"; do
    [[ -n "$pool" ]] || continue
    local hit=0
    local all_on_target=1
    mapfile -t vdevs < <(zpool status -P "$pool" 2>/dev/null | awk '/\/dev\//{print $1}')
    for v in "${vdevs[@]}"; do
      if ! is_on_system_disk "$v" "$sysdisk"; then
        hit=1
      fi
      if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
        local disk
        disk="$(lsblk -no PKNAME "$v" 2>/dev/null || echo "$v")"
        if [[ "$disk" != /dev/* ]]; then
          disk="/dev/$disk"
        fi
        if ! matches_any_filter "$disk"; then
          all_on_target=0
        fi
      fi
    done
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      if [[ "$hit" -eq 1 && "$all_on_target" -eq 1 ]]; then
        run_cmd "Destroying ZFS pool $pool" zpool destroy "$pool"
      elif [[ "$hit" -eq 1 ]]; then
        p_warn "Skipping ZFS pool $pool (spans other disks; not removing partially)"
      fi
    else
      if [[ "$hit" -eq 1 ]]; then
        run_cmd "Destroying ZFS pool $pool" zpool destroy "$pool"
      fi
    fi
  done
}

cleanup_mdraid_on_non_system_disks() {
  local sysdisk="$1"
  command -v mdadm >/dev/null 2>&1 || return 0

  mapfile -t mds < <(awk '/^md[0-9]+/ {print $1}' /proc/mdstat 2>/dev/null || true)
  for md in "${mds[@]}"; do
    [[ -n "$md" ]] || continue
    local hit=0
    local all_on_target=1
    mapfile -t members < <(mdadm --detail "/dev/$md" 2>/dev/null | awk '/\/dev\//{print $NF}')
    for m in "${members[@]}"; do
      if ! is_on_system_disk "$m" "$sysdisk"; then
        hit=1
      fi
      if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
        local disk
        disk="$(lsblk -no PKNAME "$m" 2>/dev/null || echo "$m")"
        if [[ "$disk" != /dev/* ]]; then
          disk="/dev/$disk"
        fi
        if ! matches_any_filter "$disk"; then
          all_on_target=0
        fi
      fi
    done
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      if [[ "$hit" -eq 1 && "$all_on_target" -eq 1 ]]; then
        run_cmd "Stopping MD array /dev/$md" mdadm --stop "/dev/$md"
        for m in "${members[@]}"; do
          if ! is_on_system_disk "$m" "$sysdisk"; then
            run_cmd "Clearing MD superblock on $m" mdadm --zero-superblock -f "$m"
          fi
        done
      elif [[ "$hit" -eq 1 ]]; then
        p_warn "Skipping MD array /dev/$md (spans other disks; not removing partially)"
      fi
    else
      if [[ "$hit" -eq 1 ]]; then
        run_cmd "Stopping MD array /dev/$md" mdadm --stop "/dev/$md"
        for m in "${members[@]}"; do
          if ! is_on_system_disk "$m" "$sysdisk"; then
            run_cmd "Clearing MD superblock on $m" mdadm --zero-superblock -f "$m"
          fi
        done
      fi
    fi
  done
}

wipe_disks() {
  local sysdisk="$1"
  shift
  local disks=("$@")
  
  if [[ ${#disks[@]} -eq 0 ]]; then
    p_ok "No disks to wipe"
    return 0
  fi
  
  for d in "${disks[@]}"; do
    # Skip empty disk names (e.g., from NFS storage which has no disk)
    if [[ -z "$d" ]]; then
      continue
    fi
    
    p_warn "Disk $d will be wiped to raw state"

    if lsblk -ln -o MOUNTPOINT "$d" | awk 'NF{print $1}' | grep -qv '^/mnt/disks/'; then
      p_warn "Skipping $d: has active mounts outside /mnt/disks"
      continue
    fi

    mapfile -t mnts < <(lsblk -ln -o MOUNTPOINT "$d" | awk 'NF{print $1}' | sort -r)
    for mnt in "${mnts[@]}"; do
      run_cmd "Unmounting $mnt" umount -lf "$mnt"
    done

    run_cmd "Wiping filesystem signatures on $d" wipefs -a "$d"
    run_cmd "Zapping GPT/MBR on $d" sgdisk --zap-all "$d"
    run_cmd "Refreshing kernel partition table for $d" partx -u "$d" || true
    run_cmd "Removing stale partition mappings for $d" partx -d "$d" || true
    run_cmd "Waiting for udev to settle" udevadm settle || true

    if lsblk -ln -o TYPE "$d" | grep -qx "part"; then
      p_warn "Partitions still detected on $d after wipe"
    else
      p_ok "No partitions remain on $d"
    fi
  done
}

deprovision_all() {
  local sysdisk="$1"
  
  # Validate storage name filters before proceeding
  validate_storage_filters "deprovision"
  
  if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
    p_info "Deprovisioning filtered storage/disks: ${ONLY_FILTERS[*]}"
  else
    p_info "Deprovisioning all non-system storage"
  fi

  p_info "Deprovision plan (node-local, non-shared only)"
  printf '%s\n' "    - Remove node-local, non-shared Proxmox storages"
  if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
    printf '%s\n' "    - Unmount and clean /etc/fstab entries for filtered storage/disks"
    printf '%s\n' "    - Dismantle LVM/ZFS/MD on filtered disks (if not spanning other disks)"
    printf '%s\n' "    - Wipe filtered disks to raw state"
  else
    printf '%s\n' "    - Unmount and clean /etc/fstab entries under /mnt/disks"
    printf '%s\n' "    - Dismantle LVM/ZFS/MD on non-system disks"
    printf '%s\n' "    - Wipe all non-system disks to raw state"
  fi

  # Build list of target disks BEFORE removing LVM/ZFS structures
  # (so we can still resolve storage names to disks via VG lookups)
  local disks_to_wipe=()
  mapfile -t disks_to_wipe < <(list_target_disks "$sysdisk")

  deprovision_storage_entries "$sysdisk"
  cleanup_lvm_on_non_system_disks "$sysdisk"
  cleanup_zfs_on_non_system_disks "$sysdisk"
  cleanup_mdraid_on_non_system_disks "$sysdisk"

  if [[ ${#ONLY_FILTERS[@]} -eq 0 ]]; then
    ensure_fstab_writable
    run_cmd_str "Removing /etc/fstab entries for /mnt/disks" "sed -i '\\|[[:space:]]/mnt/disks/|d' /etc/fstab"
    if compgen -G "/mnt/disks/*" >/dev/null; then
      run_cmd "Removing /mnt/disks mount directories" rm -rf /mnt/disks/*
    else
      p_ok "No /mnt/disks entries to remove"
    fi
  fi

  wipe_disks "$sysdisk" "${disks_to_wipe[@]}"
  
  # Refresh GRUB device map after changing disk topology
  refresh_grub_device_map "$FORCE"
}

print_summary_and_plan() {
  local sysdisk="$1"
  local hd="$2"

  printf '\n'
  p_info "Summary"
  printf '%s\n' "    - System disk: $sysdisk"
  if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
    printf '%s\n' "    - Filters: ${ONLY_FILTERS[*]}"
    printf '%s\n' "    - Goal: provision filtered disks only (system disk unchanged)"
  else
    printf '%s\n' "    - Goal: keep system root as installed and allocate remaining system VG space to Proxmox lvm-thin"
    printf '%s\n' "    - ALL other disks are fair game and will be (re)provisioned as Proxmox storage"
  fi
  printf '%s\n' "    - Storage naming: HDD-${hd}A, HDD-${hd}B... and SSD-${hd}A, SSD-${hd}B... (per host digit, per type)"
  printf '\n'

  p_info "Current block devices"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS

  printf '\n'
  p_info "Current Proxmox storage"
  pvesm status || true

  printf '\n'
  p_info "Current LVM"
  vgs || true
  lvs -a || true

  printf '\n'
  p_warn "Planned actions"
  if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
    printf '%s\n' "    1) Provision filtered disks only: ${ONLY_FILTERS[*]}"
    printf '%s\n' "       - If labeled HDD-${hd}X / SSD-${hd}X already: heal mount/fstab/storage"
    printf '%s\n' "       - Else: wipe, GPT single partition, ext4 format + label, mount, fstab, add Proxmox dir storage"
  else
    printf '%s\n' "    1) Remove Proxmox storage 'local-lvm' (if present)"
    printf '%s\n' "    2) Destroy LVM thinpool LV(s): pve/data, pve/data_tmeta, pve/data_tdata (if present)"
    printf '%s\n' "    3) Auto-expand system PV partition to disk tail and run pvresize (when trailing free space exists)"
    printf '%s\n' "    4) Create lvm-thin storage on remaining system VG space (SSD-${hd}A, SSD-${hd}B...)"
    printf '%s\n' "    5) For every non-system disk:"
    printf '%s\n' "       - If labeled HDD-${hd}X / SSD-${hd}X already: heal mount/fstab/storage"
    printf '%s\n' "       - Else: wipe, GPT single partition, ext4 format + label, mount, fstab, add Proxmox dir storage"
  fi
  printf '\n'
}

main() {
  parse_args "$@"
  
  show_mode_banner "$MODE"
  log_context
  
  p_step 1 "Checking root privileges"
  require_root

  if [[ "$MODE" == "status" ]]; then
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      die "--only is not valid with --status"
    fi
    require_cmd smartctl
    require_cmd parted
    show_available_storage
    show_storage_mapping
    show_available_for_provisioning
    show_system_disk_reclaim_readiness "$(get_system_disk)"
    exit 0
  fi

  if [[ "$MODE" == "rename" ]]; then
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      die "--only is not valid with --rename"
    fi
    require_cmd pvesm
    rename_storage "$OLD_STORAGE_NAME" "$NEW_STORAGE_NAME"
    exit 0
  fi

  if [[ "$MODE" == "list-usage" ]]; then
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      die "--only is not valid with --list-usage"
    fi
    require_cmd pvesm
    list_storage_usage "$STORAGE_NAME"
    exit 0
  fi

  # Core prerequisites with actionable install hints
  p_step 2 "Checking for required commands"
  require_cmd findmnt
  require_cmd lsblk
  require_cmd blkid
  require_cmd wipefs
  require_cmd partx
  require_cmd parted
  require_cmd udevadm
  require_cmd sgdisk
  require_cmd pvesm
  
  # Storage-type-specific command checks
  if [[ "$STORAGE_TYPE" == "dir" ]]; then
    require_cmd mkfs.ext4
  fi
  
  if [[ "$STORAGE_TYPE" == "lvm" || "$STORAGE_TYPE" == "lvm-thin" ]]; then
    require_cmd pvcreate
    require_cmd vgcreate
    require_cmd lvcreate
    require_cmd pvs
    require_cmd vgs
    require_cmd lvs
  fi
  
  if [[ "$STORAGE_TYPE" == "nfs" ]]; then
    require_nfs_common
  fi
  
  # Always needed for deprovisioning
  require_cmd blockdev
  require_cmd pvs
  require_cmd vgs
  require_cmd lvs
  require_cmd lvremove
  require_cmd lvextend
  require_cmd vgchange
  require_cmd vgremove
  require_cmd pvremove
  
  p_ok "All required commands are available"

  p_step 3 "Verifying this is a Proxmox node"
  if is_proxmox; then
    p_ok "Proxmox node verified (pvesm and /etc/pve found)"
  else
    die "This does not look like a Proxmox node (missing pvesm and/or /etc/pve)."
  fi

  local hd sysdisk
  p_step 4 "Determining hostname digit and system disk"
  hd="$(get_hostname_digit)"
  sysdisk="$(get_system_disk)"
  p_ok "Hostname digit: $hd"
  p_ok "System disk: $sysdisk"

  # Validate all filters and normalize device paths
  if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
    local normalized_filters=()
    for filter in "${ONLY_FILTERS[@]}"; do
      # If it looks like a storage name (e.g., HDD-2C), keep as-is
      if [[ "$filter" =~ ^[a-zA-Z]+-[0-9]+[A-Z]$ ]]; then
        normalized_filters+=("$filter")
      else
        # It's a device path - normalize and validate
        local normalized
        normalized="$(normalize_device "$filter")"
        validate_device "$normalized"
        if is_on_system_disk "$normalized" "$sysdisk"; then
          die "Filter device $normalized is the system disk. Refusing to operate."
        fi
        normalized_filters+=("$normalized")
      fi
    done
    ONLY_FILTERS=("${normalized_filters[@]}")
  fi

  if [[ "$MODE" == "provision" ]]; then
    # Handle NFS separately (no disk provisioning)
    if [[ "$STORAGE_TYPE" == "nfs" ]]; then
      p_info "Provisioning NFS storage (no local disks)"
      confirm_destroy
      if ! provision_nfs "$NFS_SERVER" "$NFS_PATH" "$NFS_OPTIONS"; then
        die "Failed to provision NFS storage. Check error messages above and try again."
      fi
      printf '\n'
      p_ok "Done. Final state:"
      pvesm status || true
      exit 0
    fi
    
    # For disk-based storage types
    if [[ "$WHATIF" -eq 1 ]]; then
      whatif_summary_provision "$sysdisk" "$hd"
    fi
    if [[ "$STORAGE_TYPE" == "dir" && "$QUICK_FORMAT" -eq 0 ]]; then
      p_warn "Full format enabled: slower but uses default inode density"
    fi
    print_summary_and_plan "$sysdisk" "$hd"
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      p_warn "This is destructive for filtered disks only: ${ONLY_FILTERS[*]}"
    else
      p_warn "This is destructive for ALL non-system disks that are not already labeled in the expected scheme."
    fi
    confirm_destroy
    if [[ ${#ONLY_FILTERS[@]} -eq 0 ]]; then
      reclaim_system_disk "$hd"
    else
      p_warn "Filtered mode: skipping system disk reclaim."
    fi
    provision_data_disks "$sysdisk" "$hd"
  else
    if [[ "$WHATIF" -eq 1 ]]; then
      whatif_summary_deprovision "$sysdisk"
    fi
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      p_warn "This is destructive for filtered storage/disks only: ${ONLY_FILTERS[*]}"
    else
      p_warn "This is destructive for ALL non-system storage and disks. System disk will be untouched."
    fi
    confirm_destroy
    deprovision_all "$sysdisk"
  fi

  printf '\n'
  p_ok "Done. Final state:"
  df -h /
  pvesm status || true
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS
}

main "$@"
