# Proxmox Automation Toolkit

**Opinionated, battle-tested automation for Proxmox storage and cloud-init templates**

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Proxmox](https://img.shields.io/badge/proxmox-8.x+-orange.svg)](https://www.proxmox.com/)
[![Bash](https://img.shields.io/badge/bash-5.0+-green.svg)](https://www.gnu.org/software/bash/)

---

## What Is This?

There are infinite ways to configure and use Proxmox. **This is my way** — developed through years of real-world use, refined for simplicity, reliability, and speed.

This toolkit provides two powerful scripts:
- **`proxmox-storage.sh`** - Automatically discover, format, and provision storage devices
- **`proxmox-templates.sh`** - Download and configure cloud-init templates for instant VM deployment

## Why Cloud-Init Templates?

**The Old Way:**
1. Create a VM
2. Attach an ISO
3. Click through the installer
4. Install packages, configure SSH, harden security
5. Wait 30+ minutes
6. Finally log in

**The Modern Way:**
1. Clone a cloud-init template
2. Boot the VM (15 seconds)
3. SSH in immediately with your keys pre-configured

This is how cloud providers work. This is how you should work too.

![Proxmox Templates](docs/proxmox-templates.png)

---

## ⚡ Quick Start

On a **brand new Proxmox installation**, run these two commands:

```bash
cd src

# Configure all available storage (automatically discovers and provisions disks)
./proxmox-storage.sh --provision --force

# Download and install ALL current cloud-init templates
./proxmox-templates.sh --build
```

**That's it.** You now have:
- Storage devices like `HDD-1B`, `SSD-3A`, etc. (intelligently named and configured)
- Cloud-init templates for current + 2 previous versions of major Linux distributions
- Templates ready to clone for instant VM deployment

---

## 🎯 Features

### Storage Management (`proxmox-storage.sh`)
- ✅ **Auto-Discovery** - Finds all available non-system disks
- ✅ **Intelligent Naming** - `SSD-1A`, `HDD-2C` format (position-based, deterministic)
- ✅ **Safe Defaults** - Won't touch system disks or existing Proxmox storage
- ✅ **Batch Operations** - Provision entire racks of servers with one command

[**→ Full Storage Documentation**](src/proxmox-storage.md)

### Template Management (`proxmox-templates.sh`)
- ✅ **SHA-256 Checksum Validation** - Automatically verifies download integrity, freshness, and completeness
- ✅ **Auto-VMID Generation** - Unique IDs based on node + distro + version
- ✅ **Auto-Storage Selection** - Intelligently picks SSD/HDD based on availability
- ✅ **Build Tracking** - Success/Warning/Failure status for each template
- ✅ **Configuration Validation** - Pre-flight checks before building
- ✅ **Cleanup Operations** - Remove cache or templates selectively
- ✅ **Multi-distro Support** - AlmaLinux, Alpine, CentOS, Debian, openSUSE, Oracle Linux, Rocky Linux, Ubuntu

[**→ Full Template Documentation**](src/proxmox-templates.md)

---

## 📦 What You Get

### Pre-Configured Cloud-Init Templates

All templates include:
- ✅ SSH keys (from GitHub, Launchpad, or local file)
- ✅ Non-root user with sudo privileges
- ✅ Static IP or DHCP configuration
- ✅ DNS search domain
- ✅ Qemu guest agent
- ✅ Security hardening
- ✅ SHA-256 verified downloads (when available from distribution)

> [!IMPORTANT]
> **SHA-256 Checksum Validation** is a primary feature that protects you from:
> - **Security risks** - Detects tampered or corrupted downloads
> - **Incomplete downloads** - Catches partial/failed downloads before deployment
> - **Stale images** - Ensures you're using the latest version (same filename may have updates)
>
> Some distributions (e.g., [Oracle Linux](https://yum.oracle.com/oracle-linux-templates.html)) don't provide programmatic checksums. The script prominently warns you during validation and build when checksums aren't available. **For safety, the cache is always skipped for these distributions** - images are re-downloaded on every build to minimize the risk of using corrupted or incomplete files.

### Supported Distributions

| Distribution | Versions | Current Release |
|--------------|----------|-----------------|
| <img src="docs/logos/logo-almalinux.png" height="20" valign="middle">&nbsp;**AlmaLinux** | 8.x, 9.x | + 2 previous |
| <img src="docs/logos/logo-alpine.webp" height="20" valign="middle">&nbsp;**Alpine** | 3.x | + 2 previous |
| <img src="docs/logos/logo-centos.png" height="20" valign="middle">&nbsp;**CentOS** | Stream 8, 9 | + 2 previous |
| <img src="docs/logos/logo-debian.png" height="20" valign="middle">&nbsp;**Debian** | 10, 11, 12, 13 | + 2 previous |
| <img src="docs/logos/logo-opensuse.png" height="20" valign="middle">&nbsp;**openSUSE** | Leap 15.x | + 2 previous |
| <img src="docs/logos/logo-oraclelinux.jpg" height="20" valign="middle">&nbsp;**Oracle Linux** | 8.x, 9.x | + 2 previous |
| <img src="docs/logos/logo-rockylinux.png" height="20" valign="middle">&nbsp;**Rocky Linux** | 8.x, 9.x | + 2 previous |
| <img src="docs/logos/logo-ubuntu.png" height="20" valign="middle">&nbsp;**Ubuntu** | 20.04, 22.04, 24.04 | + 2 previous |

---

## 🎮 Basic Usage

### Storage Provisioning

```bash
cd src

# Preview what will be provisioned
./proxmox-storage.sh --status

# Provision all available disks (with confirmation)
./proxmox-storage.sh --provision

# Force provision without confirmation (automation-friendly)
./proxmox-storage.sh --provision --force

# Provision only specific device(s)
./proxmox-storage.sh --provision --only /dev/sdb --force

# Provision only specific storage (by name)
./proxmox-storage.sh --provision --only HDD-2C --force
```

### Template Building

```bash
cd src

# Validate configuration (always run this first!)
./proxmox-templates.sh --validate

# Build all configured templates
./proxmox-templates.sh --build

# Build only specific distribution
./proxmox-templates.sh --build --only ubuntu

# Build specific version
./proxmox-templates.sh --build --only debian:bookworm

# Clean cached images
./proxmox-templates.sh --clean-cache

# Remove templates
./proxmox-templates.sh --remove --only centos

# Remove templates without confirmation
./proxmox-templates.sh --remove --only centos --force
```

---

## 🎨 Customization

### Disable Specific Templates

Don't want all distributions? Just rename config files:

```bash
cd src/config
mv alpine-builds.yaml alpine-builds.yaml.disabled
mv centos-builds.yaml centos-builds.yaml.disabled
```

Or edit them to remove specific versions you don't need.

### Modify Template Configuration

Edit files in `src/config/` to customize:
- VM resources (CPU, memory, disk size)
- Cloud-init settings (users, SSH keys, networking)
- Storage preferences
- Tags and metadata

See [proxmox-templates.md](src/proxmox-templates.md) for complete configuration reference.

---

## 📚 Documentation

- [**Storage Management Guide**](src/proxmox-storage.md) - Complete storage provisioning documentation
- [**Template Management Guide**](src/proxmox-templates.md) - Complete template building documentation
- [**Contributing Guidelines**](CONTRIBUTING.md) - How to contribute to this project
- [**Style Guide**](STYLE_GUIDE.md) - Coding standards and best practices

---

## 🛠️ Requirements

**System:**
- Proxmox VE 8.x or later
- Root/sudo access
- Internet connection (for downloading images)

**Auto-installed dependencies:**
- `yq` v4+ (YAML parsing)
- `wget` (downloading images)
- `libguestfs-tools` (image customization)
- `dhcpcd-base` (libguestfs networking)

The scripts check for requirements and offer to install missing packages.

---

## 🤝 Contributing

Contributions are welcome! This project follows standard GitHub workflows.

1. Fork the repository
2. Create a feature branch
3. Follow the [Style Guide](STYLE_GUIDE.md)
4. Test thoroughly
5. Submit a pull request

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

---

## 📜 License

This project is licensed under the MIT License - see [LICENSE](LICENSE) for details.

---

## 🙏 Acknowledgments

Initially inspired by [TechnoTim's excellent work](https://docs.technotim.live/posts/cloud-init-cloud-image/):
- 📹 [YouTube: Perfect Proxmox Template with Cloud Image and Cloud Init](https://www.youtube.com/watch?v=shiIi38cJe4)
- 📝 [Blog: Cloud-Init Cloud Image](https://docs.technotim.live/posts/cloud-init-cloud-image/)

Built with the power of:
- [Proxmox VE](https://www.proxmox.com/) - Open-source virtualization platform
- [libguestfs](https://libguestfs.org/) - Tools for accessing and modifying VM disk images
- [yq](https://github.com/mikefarah/yq) - YAML processor

---

## 📊 Project Stats

![Alt](https://repobeats.axiom.co/api/embed/e5ec1c0f112dbd8b00638d82cf1027c41094fce9.svg "Repobeats analytics image")

---

**Questions? Issues?** [Open an issue](https://github.com/robertsinfosec/cloud-image-for-proxmox/issues) or check the documentation!
