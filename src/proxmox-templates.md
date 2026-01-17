# About `proxmox-templates.sh`

This script allows you to fetch and customize various Cloud Init-ready Linux distribution images and convert them into Proxmox VM templates. It supports multiple distributions with tailored customization steps and provides robust build tracking and validation features.

## Quick Start

```bash
# Show help and available options
./build-proxmox-templates.sh

# Validate configuration files
./build-proxmox-templates.sh --validate

# Build all configured templates
./build-proxmox-templates.sh --build

# Build specific distribution
./build-proxmox-templates.sh --build --only ubuntu

# Build specific version
./build-proxmox-templates.sh --build --only debian:bookworm
```

## Features

- ✅ **Auto-VMID Generation** - Unique IDs based on node + distro + version
- ✅ **Auto-Storage Selection** - Intelligent SSD/HDD detection
- ✅ **Build Tracking** - Success/Warning/Failure status for each template
- ✅ **Step Validation** - Tracks each build phase (download, checksum, customization, VM creation, etc.)
- ✅ **Configuration Validation** - Pre-flight checks before building
- ✅ **Catalog Integration** - Cross-reference versions and releases
- ✅ **Cleanup Operations** - Remove cache or templates selectively
- ✅ **Multi-distro Support** - AlmaLinux, Alpine, CentOS, Debian, openSUSE, Oracle Linux, Rocky Linux, Ubuntu

## Command-Line Options

Below are the details of the command-line options.

### Basic Usage

```bash
./build-proxmox-templates.sh [OPTIONS]
```

> [!NOTE]
> **Sensible Defaults & Batteries Included**: Running the script without any options shows the help screen. You must explicitly specify an action flag (`--build`, `--validate`, `--clean-cache`, or `--remove`) to perform any operation.

### Options

| Option | Description |
|--------|-------------|
| `--build` | Build templates (required to start builds) |
| `--only <distro[:release]>` | Filter builds (repeatable) |
| `--configroot <path>` | Root directory containing config/ and distros/ |
| `--validate` | Validate configuration files without building |
| `--clean-cache` | Remove all cached images and checksums |
| `--remove` | Remove VM templates (use with --only to filter) |
| `--force` | Skip confirmation prompts (use with --remove) |
| `-h, --help` | Show help message |

### Examples

```bash
# Show help screen
./build-proxmox-templates.sh

# Build all configured templates
./build-proxmox-templates.sh --build

# Build only Debian templates
./build-proxmox-templates.sh --build --only debian

# Build only Debian Bookworm
./build-proxmox-templates.sh --build --only debian:bookworm

# Build multiple specific distros
./build-proxmox-templates.sh --build --only ubuntu --only debian

# Validate all configuration files
./build-proxmox-templates.sh --validate

# Clean cache before building
./build-proxmox-templates.sh --clean-cache
./build-proxmox-templates.sh --build

# Remove only Ubuntu templates
./build-proxmox-templates.sh --remove --only ubuntu

# Remove templates without confirmation
./build-proxmox-templates.sh --remove --only ubuntu --force
```

> [!TIP]
> Use `--validate` before building to catch configuration errors early!

## Auto-Generation Features

### VMID Auto-Generation

VMIDs are **automatically generated** using a 6-digit formula:

```
{node_digit}{distro_digit}{version_4digits}
```

**Components:**
- **Node digit** (position 1): Extracted from hostname (e.g., `pve3` → `3`, fallback `0`)
- **Distro digit** (position 2): Assigned per distribution:
  - `0` = AlmaLinux
  - `1` = Alpine
  - `2` = CentOS
  - `3` = Debian
  - `4` = openSUSE
  - `5` = Oracle Linux
  - `6` = Rocky Linux
  - `7` = Ubuntu
  - `9` = Unknown/Other
- **Version** (positions 3-6): Major version (2 digits) + Minor version (2 digits)
  - Major: left-padded with zeros
  - Minor: right-padded with zeros

**Examples:**

| Host | Distro | Version | VMID | Calculation |
|------|--------|---------|------|-------------|
| pve1 | Ubuntu | 24.04 | `172404` | 1 + 7 + 24 + 04 |
| pve2 | Debian | 12 | `231200` | 2 + 3 + 12 + 00 |
| pve3 | AlmaLinux | 9 | `300900` | 3 + 0 + 09 + 00 |
| pve1 | Alpine | 3.23.0 | `110323` | 1 + 1 + 03 + 23 |

> [!IMPORTANT]
> VMIDs are node-specific, ensuring no collisions across your Proxmox cluster!

### Storage Auto-Selection

Storage is **automatically selected** with intelligent detection and configurable preferences.

**Default Behavior:**
- Prefers SSD storage (patterns: `ssd`, `nvme`, `flash`)
- Selects "last" matching storage (keeps "first" for active VMs)
- Falls back to HDD if no SSD found
- Filters out: cluster storage not on node, system storage (`local`, `local-lvm`, `pve`)

**Configuration Options:**

```yaml
# Simple string format (backward compatible)
storage: auto           # Uses defaults (last SSD, fallback HDD)
storage: SSD-1A         # Specific storage name

# Advanced configuration with preferences
storage:
  device: auto          # "auto" or specific storage name
  prefer_type: ssd      # "ssd" or "hdd"
  select_order: last    # "first" or "last"
```

**Examples:**

```yaml
# Default: last SSD (current behavior)
storage:
  device: auto
  prefer_type: ssd
  select_order: last

# Use first SSD instead
storage:
  device: auto
  prefer_type: ssd
  select_order: first

# Prefer HDD for cost savings
storage:
  device: auto
  prefer_type: hdd
  select_order: last

# Per-build override
builds:
  - distro: ubuntu
    version: "24.04"
    release: noble
    override:
      storage:
        device: auto
        prefer_type: hdd
        select_order: first
```

> [!NOTE]
> Storage preferences apply only when `device: auto`. Specific storage names always take precedence.

## Build Status Tracking

The build process tracks **individual steps** for each template and provides a comprehensive summary:

### Build States

- **✓ Success** (Green): Template completed AND all steps passed
- **⚠ Warning** (Yellow): Template completed BUT some non-critical steps had issues  
- **✗ Failure** (Red): Template did NOT complete

### Tracked Steps

Each build tracks these phases:
- `image_download` - Downloading cloud image
- `checksum_validation` - SHA-256 hash verification (when available)
- `image_customization` - virt-customize operations
- `vm_creation` - Initial VM creation
- `disk_import` - Importing disk to storage
- `disk_attachment` - Attaching disk to VM
- `cloudinit_drive` - Adding Cloud-Init CD-ROM
- `boot_disk` - Configuring boot disk
- `ssh_keys` - Validating SSH keys
- `cloudinit_config` - Applying Cloud-Init settings
- `disk_resize` - Resizing disk to target size
- `template_conversion` - Converting VM to template

> [!IMPORTANT]
> **SHA Checksum Validation**: Downloaded images are **always** validated against SHA-256 checksums when available from the distribution. This validation is critical for three reasons:
> 
> - **Security**: Verifies the file hasn't been altered since the distribution built the image, protecting against tampering or man-in-the-middle attacks
> - **Freshness**: Ensures you have the latest version. Distributions often update images with the same filename to include security patches and updates. Without checksum validation, you might unknowingly use an outdated, vulnerable image
> - **Completeness**: Confirms the download finished successfully. Partial or corrupted downloads will fail validation, preventing build failures or broken templates later in the process
> 
> For distributions that don't provide programmatic checksums (e.g., [Oracle Linux](https://yum.oracle.com/oracle-linux-templates.html)), a warning is displayed during both `--validate` and `--build` operations. **Additionally, the cache is always skipped for these distributions** - images are re-downloaded on every build to minimize the risk of using stale or corrupted files that cannot be verified. Use these templates with appropriate caution in production environments.

### Summary Output Example

```
======================================================================
F I N A L  B U I L D  S U M M A R Y
======================================================================
Total builds attempted: 3
Successful: 2
Failed: 1

✓ Successful builds:
  ✓ ubuntu 24.04 (noble)
  ✓ debian 12 (bookworm)

✗ Failed builds:
  ✗ centos 8 (8) - image customization failed
======================================================================
```

> [!TIP]
> Check the summary instead of scrolling through pages of build output!

## Configuration Files

### Directory Structure

```
zzbrainstorm/
├── build-proxmox-templates.sh   # Main entrypoint
├── config/
│   ├── _defaults.yaml           # Global defaults
│   └── *-builds.yaml            # Per-distro build lists
├── distros/
│   └── *-config.sh              # Per-distro download/customization
└── catalog/
    └── *-catalog.yaml           # Available releases reference
```

### Build File Format

> [!IMPORTANT]
> Both `version` and `release` are **REQUIRED** - copy from catalog files!

**Minimal build entry:**

```yaml
builds:
  - distro: ubuntu
    version: "24.04"
    release: noble
    notes: "Ubuntu 24.04 LTS (Noble Numbat)"
```

**With overrides:**

```yaml
builds:
  - distro: debian
    version: "12"
    release: bookworm
    notes: "Debian 12 (Bookworm)"
    override:
      storage: HDD-1C
      vm:
        cores: 4
        memory: 4096
        disk_size: 30G
      cloud_init:
        user: admin
        search_domain: lab.example.com
      tags:
        - production
        - web-server
```

**Auto-generated fields:**
- `vmid` - Calculated automatically
- `storage` - Auto-selected (unless overridden)

### Why Both version AND release?

Previously, you could specify either `version` OR `release` and the script would look up the missing field. This caused complexity and bugs. Now:

✅ **Simpler code** - No catalog lookups during build planning
✅ **Faster validation** - Immediate field checking
✅ **Clearer errors** - Know exactly what's missing
✅ **Easy to maintain** - Just copy both fields from catalog

## Validation

Run `--validate` to check configuration before building:

```bash
./build-proxmox-templates.sh --validate
```

**Checks performed:**
- ✓ YAML syntax in all build files
- ✓ Required fields present (distro, version, release)
- ✓ Distro config files exist
- ✓ Catalog files exist (warning if missing)
- ✓ SHA checksum availability (warns if not available)
- ✓ VMID generation works
- ✓ **VMID collision detection** across all builds

**Example output:**

```
Validating: ubuntu-builds.yaml
  Found 3 build(s)
    ✓ Build #1 (24.04): ubuntu 24.04 (noble) - VMID 172404
    ✓ Build #2 (22.04): ubuntu 22.04 (jammy) - VMID 172204
    ✓ Build #3 (20.04): ubuntu 20.04 (focal) - VMID 172004
Validating: oraclelinux-builds.yaml
  Found 3 build(s)
    ⚠ Build #1 (10.0): No SHA checksum available - downloads will NOT be validated
    ✓ Build #1 (10.0): oraclelinux 10.0 (10.0) - VMID 351000
    ⚠ Build #2 (9.6): No SHA checksum available - downloads will NOT be validated
    ✓ Build #2 (9.6): oraclelinux 9.6 (9.6) - VMID 350906

======================================================================
V A L I D A T I O N  S U M M A R Y
======================================================================
Build files validated: 8
Total builds found: 21
Warnings: 3 8
Total builds found: 21
Errors: 0
======================================================================
[+] Validation passed successfully
```

> [!WARNING]
> VMID collisions will cause build failures! Use `--validate` to detect them early.

## Cleanup Operations

### Clean Cache

Remove all downloaded images and checksums:

```bash
./build-proxmox-templates.sh --clean-cache
```

**What it removes:**
- All files in the cache directory (default: `./cache/`)
- Downloaded cloud images (`*.orig` files)
- Checksum files
- Working copies of images

> [!CAUTION]
> This will force re-download of all images on next build!

### Clean Templates

Remove VM templates from Proxmox:

```bash
# Remove all configured templates (with confirmation)
./build-proxmox-templates.sh --remove

# Remove only Ubuntu templates
./build-proxmox-templates.sh --remove --only ubuntu

# Remove specific version
./build-proxmox-templates.sh --remove --only debian:bookworm

# Remove without confirmation (automation-friendly)
./build-proxmox-templates.sh --remove --only centos --force
```

**How it works:**
1. Reads build configuration files
2. Calculates expected VMIDs
3. **Checks which VMIDs actually exist** in Proxmox
4. Shows list and asks for confirmation
5. Removes confirmed templates with `qm destroy --purge`

**Example:**

```
Templates to remove:
  - VMID 172404: ubuntu 24.04 (noble)
  - VMID 172204: ubuntu 22.04 (jammy)

Remove these templates? [y/N]:
```

> [!IMPORTANT]
> Only affects templates matching your build configuration VMIDs!
> Templates created manually or by other tools are not affected.

## Password File Format

The `cloud_init.password_file` must contain **only the password** in cleartext:

```bash
# Good
echo "MySecureP@ssw0rd" > /root/.ci_pass
chmod 600 /root/.ci_pass

# Bad - don't use key=value format
echo "password=MySecureP@ssw0rd" > /root/.ci_pass  # ✗ Wrong!
```

The script enforces secure permissions (600 or 400) and will error if the file is world-readable.

## Dependencies

**Required:**
- `yq` v4+ (YAML parsing) - auto-installs if missing
- `wget` - downloading images
- `virt-customize` (libguestfs-tools) - image customization
- `dhcpcd-base` - required for libguestfs networking
- Proxmox tools: `qm`, `pvesm`

**Auto-install:**
The script checks prerequisites and offers to install missing packages (except on Proxmox tools which must be run on a Proxmox host).

## Advanced Usage

### Custom Configuration Root

Run from anywhere with custom config location:

```bash
./build-proxmox-templates.sh --configroot /path/to/custom/config
```

The specified directory must contain:
- `config/` - Build files and defaults
- `distros/` - Distro-specific configurations  
- `catalog/` - Release catalogs (optional)

### Disable Specific Builds

Rename build files to disable without deleting:

```bash
mv config/centos-builds.yaml config/centos-builds.yaml.disabled
```

The script ignores `*.disabled` files.

### Multiple Filters

Combine multiple `--only` filters:

```bash
./build-proxmox-templates.sh --build --only ubuntu --only debian --only rocky
