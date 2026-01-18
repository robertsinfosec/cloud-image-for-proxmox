# The Scripts

In this folder are the scripts for administering Proxmox storage and building VM templates.

## Script: `proxmox-storage.sh`

Manages storage discovery and provisioning in Proxmox. It can scan available disks, create storage, and report on existing storage usage.

### Quick Start

Below are some of the basics:

```bash
# Discover and provision storage
./proxmox-storage.sh --status

# Provision new storage disks safely
./proxmox-storage.sh --provision --force
```

### Usage

Below is the detailed usage information:

```bash
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
  --nfs-options <opts> NFS mount options (default: vers=3,soft)
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
```

> Documentation: [proxmox-storage.md](proxmox-storage.md)

## Script: `proxmox-templates.sh`

Builds Proxmox VM templates from various Linux distribution cloud images. It handles downloading, verifying, customizing, and converting images into templates.

### Quick Start

Below are some of the basics:

```bash
# Validate configuration
./proxmox-templates.sh --validate

# Show status of available templates
./proxmox-templates.sh --status

# Build all configured templates
./proxmox-templates.sh --build
```

### Usage

Below is the detailed usage information:

```bash
Usage: ./proxmox-templates.sh [OPTIONS]

Automated cloud-init template builder with SHA-256 checksum validation

Options:
  --build                    Build templates (required to start builds)
  --only <distro[:release]>  Filter builds (repeatable), e.g. --only debian or --only debian:trixie
  --configroot <path>        Root directory containing config/, distros/ (default: script directory)
  --clean-cache              Remove all cached images and checksums
  --remove                   Remove VM templates (use with --only to filter which ones)
  --force                    Skip confirmation prompts (use with --remove)
  --validate                 Validate configuration files without building
  --status                   Show drift between configured templates and Proxmox
  -h, --help                 Show this help message

Primary Features:
  • SHA-256 validation (when available) ensures download security & integrity
  • Warnings displayed for distributions without checksum support
  • Automated VMID generation and storage selection

Examples:
  ./proxmox-templates.sh --build                 # Build all configured templates
  ./proxmox-templates.sh --build --only ubuntu   # Build only Ubuntu templates
  ./proxmox-templates.sh --remove --only ubuntu --force  # Remove Ubuntu templates without confirmation
  ./proxmox-templates.sh --validate              # Validate configuration without building
  ./proxmox-templates.sh --status                # Show template drift detection
  ./proxmox-templates.sh --clean-cache           # Clean cached images
  ```

> Documentation: [proxmox-templates.md](proxmox-templates.md)

## Bash Auto-Completion

Both scripts include intelligent tab completion to speed up your workflow and reduce errors.

### Features

- **Context-aware suggestions** - Only shows valid options based on what you've typed
- **Dynamic completions** - Suggests existing storage pools, VM IDs, and template IDs
- **Value hints** - Shows example values for options like `--type`, `--distro`, `--version`
- **Smart filtering** - Completion adapts based on the mode (provision, build, remove, etc.)

> [!TIP]
> **Modern Linux systems** (Ubuntu, Debian, Fedora, etc.) already have bash-completion installed and working. You just need to source our completion file - no system-wide setup required!

### Quick Setup

Simply source the completion file from the src/ directory:

```bash
cd /path/to/cloud-image-for-proxmox/src
source .bash_completion
```

Now tab completion works:

```bash
./proxmox-storage.sh --prov<TAB>        # Completes to --provision
./proxmox-storage.sh --provision --type <TAB>  # Shows: dir lvm lvm-thin nfs
./proxmox-templates.sh --build --distro <TAB>  # Shows all available distros
```

### Always Available (Optional)

The proper place for user-specific bash completions is `~/.bash_completion` (in your home directory). Modern systems with bash-completion installed automatically source this file.

Add this one-time to **`~/.bash_completion`** (create it if it doesn't exist):

```bash
# Proxmox storage and template script completions
source /home/robert/gitlocal/robertsinfosec/cloud-image-for-proxmox/src/.bash_completion
```

> [!NOTE]
> Replace the path with your actual clone location. This follows bash-completion best practices - user completions go in `~/.bash_completion`, not `~/.bashrc` or `~/.bash_aliases`.

### Troubleshooting

If tab completion doesn't work after sourcing, you may need to install bash-completion:

```bash
# Debian/Ubuntu
sudo apt install bash-completion

# RHEL/Rocky/Alma
sudo dnf install bash-completion

# Then log out and back in, or source it manually:
source /usr/share/bash-completion/bash_completion
```

> [!NOTE]
> The completion files are in [src/completions/](completions/) and are automatically loaded by [.bash_completion](.bash_completion). You don't need to modify system-wide completion directories.

### Completion Examples

**Storage Script:**
- `--provision --type <TAB>` -> Shows: `dir lvm lvm-thin nfs`
- `--storage <TAB>` -> Shows existing Proxmox storage pools
- `--nfs-server <TAB>` -> Shows IP address examples
- `--deprovision --storage <TAB>` -> Filters to only show storage pools

**Templates Script:**
- `--build --distro <TAB>` -> Shows: `almalinux alpine centos debian opensuse oraclelinux rockylinux ubuntu`
- `--distro ubuntu --version <TAB>` -> Shows common Ubuntu versions
- `--storage <TAB>` -> Shows available Proxmox storage pools
- `--remove <TAB>` -> Shows existing VM template IDs

> [!NOTE]
> Completion works with both `./proxmox-storage.sh` and `proxmox-storage.sh` (same for templates script).