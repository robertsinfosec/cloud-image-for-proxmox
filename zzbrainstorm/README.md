# Brainstorm: unified template builder

This folder is a mock-up of a unified entrypoint + per-distro configs + batch builds.

## Entrypoint

`build-proxmox-templates.sh`

### Usage (conceptual)

- Run all configured builds:
  - `./build-proxmox-templates.sh`

- Filter-only run (no overrides):
  - `./build-proxmox-templates.sh --only debian`
  - `./build-proxmox-templates.sh --only debian:trixie`

- Run from a different working directory:
  - `./build-proxmox-templates.sh --configroot /path/to/zzbrainstorm`

### Arguments

#### Optional
- `--only <distro[:release|version]>` (repeatable filter)
- `--configroot <path>` (root directory containing `config/` and `distros/`)

## Auto-Generation Features

### VMID Auto-Generation

VMIDs are **automatically generated** using the formula:
```
{1_node_digit}{1_distro_digit}{4_version_digits}
```

**Components:**
- **Node digit** (1st digit): Extracted from hostname (e.g., `pve3` → `3`, fallback to `0`)
- **Distro digit** (2nd digit): Assigned per distribution alphabetically:
  - `0` = AlmaLinux
  - `1` = Alpine
  - `2` = CentOS
  - `3` = Debian
  - `4` = openSUSE
  - `5` = Oracle Linux
  - `6` = Rocky Linux
  - `7` = Ubuntu
  - `9` = Unknown/Other
- **Version digits** (last 4 digits): Version number without dots, padded to 4 digits

**Examples:**
- `pve3` + Ubuntu 24.04 → `372404`
- `pve1` + Debian 12 → `131200`
- `pve2` + AlmaLinux 9 → `209000`

**No manual VMID configuration needed!** The system ensures unique VMIDs across your Proxmox cluster by using the node digit.

### Storage Auto-Selection

Storage is **automatically selected** by default with intelligent fallback:

1. **Prefers last SSD** (identified by name patterns: `ssd`, `nvme`, `flash`)
2. **Falls back to last HDD** if no SSD is found
3. **Uses first available storage** if categorization fails

**Why "last" storage?** Template images are typically stored separate from active VMs, which often use the "first" available storage.

**Override:** Specify exact storage in `_defaults.yaml` or per-build `override`:
```yaml
storage: SSD-1A  # Use specific storage instead of auto
```

The script verifies storage exists and shows available options if not found.

## Files in this mock-up

- `build-proxmox-templates.sh`: entrypoint that reads the folder structure
- `config/_defaults.yaml`: defaults for all builds (same structure as a build `override` entry)
- `config/*-builds.yaml`: batch list of builds (rename to `*.disabled` to skip)
- `distros/*-config.sh`: per-distro download/checksum logic and image customization
- `catalog/*-catalog.yaml`: reference list of available releases

## Build file format (minimal)

Each entry must include:
- `distro` (distribution name)
- `release` (codename) OR `version` (numeric version)

**Auto-generated:**
- `vmid` (automatically calculated from node + distro + version)
- `storage` (automatically selected, or specify in `override.storage`)

Optional:
- `notes` (display name, looked up from catalog if available)
- `override` (same structure as defaults, can override storage and other settings)

**Example minimal build:**
```yaml
builds:
  - distro: ubuntu
    release: noble
  
  - distro: debian
    version: "12"
    override:
      storage: HDD-1C  # Override auto-selection
```

## Catalog Integration

The script automatically looks up release information from `catalog/*-catalog.yaml` files:
- If you specify `version: "22.04"`, it finds `release: "jammy"` from the catalog
- If you specify `release: "noble"`, it finds `version: "24.04"` from the catalog
- Display information (`notes`) is pulled from the catalog for better output

This ensures correct download URLs and better user experience without duplicating data.

## Password file format

The `cloud_init.password_file` value must point to a file that contains the
cleartext password only (no `key=value` format). The script reads the entire
file as the password and enforces secure file permissions.

## Dependencies

- `yq` (YAML parsing) - auto-installs if missing
- `wget`
- `virt-customize` (libguestfs-tools)
- `dhcpcd-base` (required for libguestfs networking)
- Proxmox tools: `qm`, `pvesm`

The script checks all prerequisites on startup and prompts to install missing packages.
