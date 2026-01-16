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

## Files in this mock-up

- `build-proxmox-templates.sh`: entrypoint that reads the folder structure
- `config/_defaults.yaml`: defaults for all builds (same structure as a build `override` entry)
- `config/*-builds.yaml`: batch list of builds (rename to `*.disabled` to skip)
- `distros/*-config.sh`: per-distro download/checksum logic and image customization
- `catalog/*-catalog.yaml`: reference list of available releases

## Build file format (minimal)

Each entry must include:
- `vmid`
- `storage`
- `distro`
- `release` (codename or version)
- `version` (numeric version string; used for naming)

Optional:
- `notes`
- `override` (same structure as defaults)

## Dependencies

- `yq` (YAML parsing)
- `wget`
- `virt-customize` (libguestfs-tools)
- Proxmox tools: `qm`, `pvesm`
