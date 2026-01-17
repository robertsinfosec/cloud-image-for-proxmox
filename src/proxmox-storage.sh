#!/usr/bin/env bash
set -Eeuo pipefail

# proxmox-storage.sh
# Purpose:
#   Provision:
#   1) Make system disk OS-only on a fresh Proxmox ISO install (LVM-thin default):
#      - remove local-lvm thinpool
#      - extend /dev/pve/root to consume all free extents
#      - resize ext4 filesystem
#   2) Treat ALL non-system disks as fair game:
#      - provision as single GPT partition, ext4
#      - label as HDD-<N><A..> / SSD-<N><A..> (N is hostname digit)
#      - mount under /mnt/disks/<LABEL>
#      - persist /etc/fstab by UUID
#      - register as Proxmox "dir" storage with broad content types
#
# Safety:
#   - Prints summary + plan, then requires typing DESTROY
#   - Idempotent/self-healing:
#       * disks already labeled in the expected scheme are not reformatted
#       * mounts/fstab/pvesm storage are repaired if missing
#
#   Deprovision:
#     - remove non-system Proxmox storage entries
#     - unmount and clean /etc/fstab and mount directories
#     - dismantle non-system storage (LVM/ZFS/MD) if present
#     - wipe non-system disks back to raw/unpartitioned state
#
# Notes:
#   - Uses partx (util-linux) instead of partprobe to refresh kernel partition table.

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
p_err()   { echo -e "${C_ERR}[-]${NC} $*" >&2; }

# Legacy aliases for compatibility
log()  { p_info "$@"; }
ok()   { p_ok "$@"; }
warn() { p_warn "$@"; }
err()  { p_err "ERROR: $*"; }
die()  { err "$*"; exit 1; }

MODE=""
FORCE=0
WHATIF=0
QUICK_FORMAT=1
EXTENDED=0
ONLY_FILTERS=()

log_context() {
  local node
  node="$(hostname -s)"
  local filters="all"
  if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
    filters="${ONLY_FILTERS[*]}"
  fi
  p_info "Context: node=$node mode=${MODE:-unset} whatif=$WHATIF force=$FORCE full_format=$((1-QUICK_FORMAT)) filters=$filters"
}

usage() {
  cat <<'EOF'
Usage:
  proxmox-storage.sh --provision [--force] [--whatif] [--full-format] [--only <filter>]
  proxmox-storage.sh --deprovision [--force] [--whatif] [--only <filter>]
  proxmox-storage.sh --show-available [--extended]
  proxmox-storage.sh --help

Options:
  --provision         Provision non-system disks (destructive)
  --deprovision       Deprovision non-system storage (destructive)
  --force             Skip confirmation prompt
  --whatif, --simulate
                      Show what would be done without making changes
  --full-format       Slower, full ext4 format (default is quick)
  --show-available    Show available storage summary and exit
  --extended          Show additional SMART health fields
  --only <filter>     Filter to specific device(s) or storage name(s) (repeatable)
                      Examples: --only /dev/sdb  --only HDD-2C  --only SSD-3A
  --help              Show this help
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
      --show-available)
        MODE="show-available"
        ;;
      --extended)
        EXTENDED=1
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

  printf '%s\n' "[!] Type DESTROY to continue. Any other input aborts."
  printf '%s'   "[?] Confirm: "
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

on_err() {
  local rc=$?
  p_err "Command failed (rc=$rc) at line $1: $2"
  exit "$rc"
}
trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR

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

  case "$cmd" in
    # util-linux
    lsblk|findmnt|partx|wipefs|blkid|blockdev)
      pkg="util-linux"
      ;;
    # LVM
    pvs|vgs|lvs|lvremove|lvextend|vgchange|vgremove|pvremove)
      pkg="lvm2"
      ;;
    # ext4 tools
    resize2fs|mkfs.ext4)
      pkg="e2fsprogs"
      ;;
    # GPT tooling
    sgdisk)
      pkg="gdisk"
      ;;
    # Proxmox tooling
    pvesm)
      pkg="proxmox-ve"
      ;;
    # SMART tools
    smartctl)
      pkg="smartmontools"
      ;;
    *)
      pkg=""
      ;;
  esac

  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Missing required command: $cmd"
    if [[ -n "$pkg" ]]; then
      err "Install this by running: sudo apt install $pkg"
    else
      err "Install the package that provides '$cmd'"
    fi
    exit 1
  fi
}

storage_exists() {
  local sid="$1"
  pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$sid"
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
  local src pv disk
  src="$(findmnt -n -o SOURCE /)"

  # Default Proxmox ISO install puts / on LVM (/dev/mapper/pve-root).
  if [[ "$src" == /dev/mapper/* || "$src" == /dev/dm-* ]]; then
    pv="$(pvs --noheadings -o pv_name 2>/dev/null | awk 'NF{print $1; exit 0}')"
    [[ -n "$pv" ]] || die "Unable to determine PV device backing root."
    disk="$(lsblk -no PKNAME "$pv" | awk 'NF{print $1; exit 0}')"
    [[ -n "$disk" ]] || die "Unable to determine base disk for PV '$pv'."
    printf '%s' "/dev/$disk"
    return 0
  fi

  # Fallback: root on partition
  disk="$(lsblk -no PKNAME "$src" | awk 'NF{print $1; exit 0}')"
  [[ -n "$disk" ]] || die "Unable to determine base disk for root source '$src'."
  printf '%s' "/dev/$disk"
}

system_disk() {
  p_info "Determining system disk"
  local disk
  disk="$(get_system_disk)"
  p_ok "System disk identified: $disk"
  printf '%s' "$disk"
}

get_first_partition() {
  local disk="$1"
  lsblk -ln -o NAME,TYPE "$disk" | awk '$2=="part"{print "/dev/"$1; exit}'
}

disk_is_rotational() {
  local dev="$1" base
  if command -v smartctl >/dev/null 2>&1; then
    local rotation
    rotation="$(smart_rotation "$dev")"
    if [[ "$rotation" == "SSD" ]]; then
      echo "0"
      return 0
    elif echo "$rotation" | grep -qi 'rpm'; then
      echo "1"
      return 0
    fi
  fi
  base="$(basename "$dev")"
  if [[ -r "/sys/block/$base/queue/rotational" ]]; then
    cat "/sys/block/$base/queue/rotational" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

next_letter() {
  local typ="$1" hd="$2"
  local used letters
  used="$(blkid -o value -s LABEL 2>/dev/null | grep -E "^${typ}-${hd}[A-Z]$" || true)"
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
}

reclaim_system_disk() {
  p_info "System disk reclaim (OS-only): remove local-lvm thinpool, expand /"

  # Remove local-lvm storage entry if present
  p_info "Checking for Proxmox storage 'local-lvm'"
  if storage_exists "local-lvm"; then
    run_cmd "Removing Proxmox storage 'local-lvm'" pvesm remove local-lvm
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

  # Extend root if VG has free space
  p_info "Checking for free space in VG pve"
  local vfree
  vfree="$(vgs --noheadings -o vg_free --units m --nosuffix pve 2>/dev/null | awk '{$1=$1;print $1}')"
  vfree="${vfree:-0}"

  if awk "BEGIN{exit !($vfree > 1)}"; then
    run_cmd "Extending /dev/pve/root to use all free extents (${vfree}M available)" lvextend -l +100%FREE /dev/pve/root
    run_cmd "Resizing filesystem on /dev/pve/root" resize2fs /dev/pve/root
  else
    p_ok "No meaningful free space in VG pve (root already expanded)"
  fi
}

is_on_disk() {
  local dev="$1" disk="$2"
  local base
  if [[ "$dev" == "$disk"* ]]; then
    return 0
  fi
  if base="$(lsblk -no PKNAME "$dev" 2>/dev/null)" && [[ -n "$base" ]]; then
    dev="/dev/$base"
  fi
  [[ "$dev" == "$disk" ]]
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
        # This is a storage name like HDD-2C - we'll match it later after provisioning check
        # For now, we need to check if this disk already has this label
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

provision_data_disks() {
  local sysdisk="$1"
  local hd="$2"

  if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
    p_info "Provisioning filtered disk(s) as Proxmox storage: filters=[${ONLY_FILTERS[*]}] sysdisk=$sysdisk hostdigit=$hd"
  else
    p_info "Provisioning non-system disks as Proxmox storage (fair game): sysdisk=$sysdisk hostdigit=$hd"
  fi

  p_info "Detecting target disk(s)"
  mapfile -t disks < <(list_target_disks "$sysdisk")
  [[ "${#disks[@]}" -gt 0 ]] || die "No disks detected."
  p_ok "Found ${#disks[@]} disk(s)"

  for d in "${disks[@]}"; do
    [[ "$d" == "$sysdisk" ]] && continue

    p_info "Processing disk: $d"
    
    local rot typ
    rot="$(disk_is_rotational "$d")"
    if [[ "$rot" == "1" ]]; then
      typ="HDD"
    else
      typ="SSD"
    fi
    p_ok "Disk type determined: $typ (rotational=$rot)"

    local part existing_label expected_pattern label
    part="$(get_first_partition "$d" || true)"

    p_info "Checking for existing label on ${part:-$d}"
    existing_label=""
    if [[ -n "$part" ]]; then
      existing_label="$(blkid -o value -s LABEL "$part" 2>/dev/null || true)"
    fi
    expected_pattern="^${typ}-${hd}[A-Z]$"

    # If already provisioned in our scheme, heal and continue
    if [[ -n "$existing_label" && "$existing_label" =~ $expected_pattern ]]; then
      label="$existing_label"
      p_ok "Disk $d already provisioned as $label; healing mount + fstab + Proxmox storage"
      ensure_mount "$label" "$part"
      ensure_pvesm_storage "$label" "/mnt/disks/$label"
      continue
    fi

    # Otherwise: DESTROY + reprovision
    local letter
    letter="$(next_letter "$typ" "$hd")"
    label="${typ}-${hd}${letter}"

    p_warn "Disk $d will be DESTROYED and reprovisioned as $label (GPT, single partition, ext4)"

    # Wipe signatures/partition table
    run_cmd "Wiping filesystem signatures on $d" wipefs -a "$d"
    
    if ! run_cmd "Zapping GPT/MBR on $d" sgdisk --zap-all "$d"; then
      continue
    fi

    # Create partition + label
    if ! run_cmd "Creating GPT partition on $d with label $label" sgdisk -n 1:0:0 -t 1:8300 -c 1:"$label" "$d"; then
      continue
    fi

    # Refresh kernel partition table without partprobe
    run_cmd "Refreshing kernel partition table for $d" partx -u "$d" || true
    run_cmd "Waiting for udev to settle" udevadm settle || true

    part="$(get_first_partition "$d" || true)"
    [[ -n "$part" ]] || die "Failed to detect new partition on $d"

    # Format ext4 (lazy init keeps this fast even on huge disks)
    local mkfs_opts
    mkfs_opts=("-F" "-L" "$label" "-E" "lazy_itable_init=1,lazy_journal_init=1")
    if [[ "$QUICK_FORMAT" -eq 1 ]]; then
      mkfs_opts+=("-m" "0" "-T" "largefile4")
    fi
    if ! run_cmd "Formatting $part as ext4 with label $label" mkfs.ext4 "${mkfs_opts[@]}" "$part"; then
      continue
    fi

    ensure_mount "$label" "$part"
    ensure_pvesm_storage "$label" "/mnt/disks/$label"

    p_ok "Provisioned $d -> $label"
  done
}

remove_fstab_mount() {
  local mnt="$1"
  ensure_fstab_writable
  run_cmd_str "Removing /etc/fstab entries for $mnt" "sed -i '\\|[[:space:]]${mnt}[[:space:]]|d' /etc/fstab"
}

parse_storage_cfg() {
  local cfg="/etc/pve/storage.cfg"
  [[ -f "$cfg" ]] || return 0
  awk '
    /^[[:alpha:]]+:/ {
      type=$1; sub(":", "", type); sid=$2; path=""; nodes=""; shared=""; inblock=1; next
    }
    inblock && /^[[:space:]]*path[[:space:]]+/ {path=$2}
    inblock && /^[[:space:]]*nodes[[:space:]]+/ {nodes=$2}
    inblock && /^[[:space:]]*shared[[:space:]]+/ {shared=$2}
    inblock && NF==0 {
      if (sid != "") {print type "|" sid "|" path "|" nodes "|" shared}
      inblock=0
    }
    END { if (sid != "") {print type "|" sid "|" path "|" nodes "|" shared} }
  ' "$cfg"
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

smartctl_safe() {
  local dev="$1"
  smartctl -a "$dev" 2>/dev/null || true
}

smart_first_line() {
  local dev="$1" regex="$2"
  smartctl_safe "$dev" | awk -v r="$regex" '$0 ~ r {print; exit}'
}

smart_rotation() {
  local dev="$1" line value
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

show_available_storage() {
  # Build device-to-storage mapping first
  declare -A device_storage_map
  
  # Get all Proxmox storage and map to devices
  while read -r storage_name; do
    [[ -z "$storage_name" ]] && continue
    [[ "$storage_name" == "local" || "$storage_name" == "local-lvm" ]] && continue
    
    # Get storage type
    local storage_type
    storage_type=$(pvesm status 2>/dev/null | grep "^${storage_name}" | awk '{print $2}')
    
    # For directory storage, find the device
    if [[ "$storage_type" == "dir" ]]; then
      local storage_path mount_device base_device
      storage_path=$(pvesm path "${storage_name}:0" 2>/dev/null | sed 's|/0$||' || echo "")
      
      if [[ -n "$storage_path" ]]; then
        mount_device=$(df "$storage_path" 2>/dev/null | tail -1 | awk '{print $1}')
        
        # Resolve to base disk device
        if [[ -n "$mount_device" ]]; then
          base_device=$(lsblk -no PKNAME "$mount_device" 2>/dev/null | head -1)
          if [[ -z "$base_device" ]]; then
            # No parent, strip partition number
            base_device=$(echo "$mount_device" | sed 's|/dev/||; s|[0-9]*$||')
          fi
          
          if [[ -n "$base_device" ]]; then
            device_storage_map["$base_device"]="$storage_name"
          fi
        fi
      fi
    fi
  done < <(pvesm status 2>/dev/null | tail -n +2 | awk '{print $1}')
  
  # Display device table with storage status
  p_info "Available storage summary"
  if [[ "$EXTENDED" -eq 1 ]]; then
    printf '%-10s %-8s %-30s %-12s %-8s %-8s %-10s %-15s\n' "Device" "Size" "Model" "Media" "Health" "Temp" "Life" "Proxmox Storage"
  else
    printf '%-10s %-8s %-30s %-20s %-15s\n' "Device" "Size" "Model" "Media" "Proxmox Storage"
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
    else
      storage_status="-"
    fi
    
    if [[ "$EXTENDED" -eq 1 ]]; then
      health="$(smart_health "$dev")"
      temp="$(smart_temp "$dev")"
      life="$(smart_life_remaining "$dev")"
      printf '%-10s %-8s %-30s %-12s %-8s %-8s %-10s %-15s\n' "$dev" "$size" "$model" "$rotation" "$health" "$temp" "$life" "$storage_status"
    else
      printf '%-10s %-8s %-30s %-20s %-15s\n' "$dev" "$size" "$model" "$rotation" "$storage_status"
    fi
  done
}

show_storage_mapping() {
  local node
  node="$(hostname -s)"
  
  # Get existing Proxmox storage
  local storage_list
  storage_list=$(pvesm status 2>/dev/null | tail -n +2 | awk '{print $1}' || echo "")
  
  if [[ -z "$storage_list" ]]; then
    return
  fi
  
  # Check if there's any non-system storage
  local has_storage=0
  while IFS= read -r storage_name; do
    [[ "$storage_name" == "local" || "$storage_name" == "local-lvm" ]] && continue
    has_storage=1
    break
  done <<< "$storage_list"
  
  if [[ $has_storage -eq 0 ]]; then
    return
  fi
  
  echo ""
  p_info "Proxmox storage to device mapping"
  printf '%-15s %-8s %-12s %-10s %-30s\n' "Storage Name" "Type" "Device" "Size" "Mount Point"
  
  while IFS= read -r storage_name; do
    [[ -z "$storage_name" ]] && continue
    [[ "$storage_name" == "local" || "$storage_name" == "local-lvm" ]] && continue
    
    local storage_type storage_path mount_device base_device size mount_point
    storage_type=$(pvesm status 2>/dev/null | grep "^${storage_name}" | awk '{print $2}')
    
    if [[ "$storage_type" == "dir" ]]; then
      storage_path=$(pvesm path "${storage_name}:0" 2>/dev/null | sed 's|/0$||' || echo "")
      mount_point="$storage_path"
      
      if [[ -n "$storage_path" ]]; then
        mount_device=$(df "$storage_path" 2>/dev/null | tail -1 | awk '{print $1}')
        
        # Resolve to base disk device
        if [[ -n "$mount_device" ]]; then
          base_device=$(lsblk -no PKNAME "$mount_device" 2>/dev/null | head -1)
          if [[ -z "$base_device" ]]; then
            base_device=$(echo "$mount_device" | sed 's|/dev/||; s|[0-9]*$||')
          fi
          
          if [[ -n "$base_device" ]]; then
            size=$(lsblk -ndo SIZE "/dev/$base_device" 2>/dev/null || echo "?")
            printf '%-15s %-8s %-12s %-10s %-30s\n' "$storage_name" "$storage_type" "/dev/$base_device" "$size" "$mount_point"
          fi
        fi
      fi
    fi
  done <<< "$storage_list"
}

whatif_summary_provision() {
  local sysdisk="$1" hd="$2"
  p_info "What-if summary (provision)"
  printf '%s\n' "    - System disk: $sysdisk (unchanged)"

  mapfile -t disks < <(list_target_disks "$sysdisk")
  if [[ "${#disks[@]}" -eq 0 ]]; then
    printf '%s\n' "    - No non-system disks detected"
    return 0
  fi

  for d in "${disks[@]}"; do
    local rot typ part existing_label expected_pattern label
    rot="$(disk_is_rotational "$d")"
    if [[ "$rot" == "1" ]]; then
      typ="HDD"
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

  while IFS='|' read -r type sid path nodes shared; do
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
    fi
    if [[ -n "$path" ]]; then
      if findmnt -n "$path" >/dev/null 2>&1; then
        run_cmd "Unmounting $path" umount -lf "$path"
      fi
      remove_fstab_mount "$path"
      if [[ "$path" == /mnt/disks/* ]]; then
        run_cmd "Removing mount directory $path" rm -rf "$path"
      else
        p_warn "Skipping removal of non-/mnt/disks path: $path"
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
      if matches_any_filter "$disk"; then
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
    run_cmd "Deactivating VG $vg" vgchange -an "$vg"
    run_cmd "Removing VG $vg" vgremove -y "$vg"
    vgs_removed["$vg"]=1
  done

  for line in "${pvs_list[@]}"; do
    local pv vg
    pv="${line%% *}"
    vg="${line##* }"
    [[ -n "$pv" ]] || continue
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

wipe_non_system_disks() {
  local sysdisk="$1"
  mapfile -t disks < <(list_target_disks "$sysdisk")
  for d in "${disks[@]}"; do
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

  wipe_non_system_disks "$sysdisk"
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
    printf '%s\n' "    - Goal: OS-only system disk (expand /), no local-lvm"
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
    printf '%s\n' "    3) Extend /dev/pve/root to all free extents; resize ext4 filesystem"
    printf '%s\n' "    4) For every non-system disk:"
    printf '%s\n' "       - If labeled HDD-${hd}X / SSD-${hd}X already: heal mount/fstab/storage"
    printf '%s\n' "       - Else: wipe, GPT single partition, ext4 format + label, mount, fstab, add Proxmox dir storage"
  fi
  printf '\n'
}

main() {
  parse_args "$@"
  log_context
  require_root

  if [[ "$MODE" == "show-available" ]]; then
    if [[ ${#ONLY_FILTERS[@]} -gt 0 ]]; then
      die "--only is not valid with --show-available"
    fi
    require_cmd smartctl
    show_available_storage
    show_storage_mapping
    exit 0
  fi

  # Core prerequisites with actionable install hints
  p_info "Checking for required commands"
  require_cmd findmnt
  require_cmd lsblk
  require_cmd blkid
  require_cmd wipefs
  require_cmd partx
  require_cmd udevadm
  require_cmd sgdisk
  require_cmd mkfs.ext4
  require_cmd resize2fs
  require_cmd blockdev
  require_cmd pvs
  require_cmd vgs
  require_cmd lvs
  require_cmd lvremove
  require_cmd lvextend
  require_cmd vgchange
  require_cmd vgremove
  require_cmd pvremove
  require_cmd pvesm
  p_ok "All required commands are available"

  p_info "Verifying this is a Proxmox node"
  if is_proxmox; then
    p_ok "Proxmox node verified (pvesm and /etc/pve found)"
  else
    die "This does not look like a Proxmox node (missing pvesm and/or /etc/pve)."
  fi

  local hd sysdisk
  p_info "Determining hostname digit and system disk"
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
    if [[ "$WHATIF" -eq 1 ]]; then
      whatif_summary_provision "$sysdisk" "$hd"
    fi
    if [[ "$QUICK_FORMAT" -eq 0 ]]; then
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
      reclaim_system_disk
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
