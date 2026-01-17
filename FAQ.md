# Frequently Asked Questions (FAQ)

## General Questions

<details>
<summary><b>What is this project about?</b></summary>
I've been an avid user of ProxMox for many years. It's an amazing hypervisor platform, but it definitely does not have "batteries included" when it comes to dealing with storage, and certainly with supporting Cloud Init images as VM Templates. Which, in 2026, is crazy-work since the entire cloud industry has standardized on Cloud Init for automating VM configuration at first boot.

So, these scripts have "sensible defaults", but are configurable enough to handle a variety of use cases. Now, with just a couple of commands, you can: allocate/provision all available, attached storage (excludes the system disk), and download, configure, and create Proxmox VM templates for multiple Linux distributions that are ready to clone and boot in seconds.

Meaning, on a fresh or re-purposed ProxMox cluster, you can take care of these two critical, time-consuming, and technically difficult tasks in just minutes, and have a production-ready environment.

</details>

<details>
<summary><b>Why should I use this?</b></summary>
You definitely don't need to! You can just raw-dog it with Proxmox's built-in tools, learn all about Logical Volume Management (LVM), ZFS, Cloud Init, and all the quirks of each Linux distribution's cloud images. Then maybe come up with a highly customized script that works on just your machines. 

That was me! I spent years having special scripts and manual processes to cover this "basic" stuff. So, this project is my "opinionated" way of doing it. However, you don't have do it this way. You can fork this repository and change it however you like. Keep in mind, you can also change many of the defaults in the `src/config/_defaults.yaml` file to suit your preferences too.

In the end, this is a way I have found to work with ProxMox that is relatively simple, reliable, and where the scripts "just work" in a variety of environments. If that sounds appealing, give it a try!

</details>

<details>
<summary><b>What distributions are currently supported?</b></summary>

This project supports creating Proxmox VM templates for the following Linux distributions:

- **AlmaLinux** - Enterprise-grade RHEL alternative
- **Alpine Linux** - Lightweight, security-oriented distribution
- **CentOS** - Community-supported enterprise Linux (legacy support)
- **Debian** - Universal operating system with extensive package repository
- **openSUSE** - Professional-grade Linux with YaST configuration tools
- **Oracle Linux** - Enterprise Linux distribution from Oracle
- **Rocky Linux** - Enterprise Linux distribution built by the community
- **Ubuntu** - Popular Debian-based distribution with LTS releases

Each distribution has its own configuration file in `src/distros/` and build definitions in `src/config/`.
</details>

<details>
<summary><b>How do I add a new distribution or version?</b></summary>

To add a new distribution or version:

1. **Create or update the catalog file** in `src/catalog/<distro>-catalog.yaml` with the cloud image URL and checksums
2. **Create or update the build configuration** in `src/config/<distro>-builds.yaml` to define which versions to build
3. **Create or update the distro-specific configuration** in `src/distros/<distro>-config.sh` if adding a new distribution family
4. **Run the template creation script**: `./src/proxmox-templates.sh`

The system will automatically download, verify, and create VM templates for all configured versions.
</details>

<details>
<summary><b>What are the system requirements for running these scripts?</b></summary>

To use this project, you need:

- **Proxmox VE** - A running Proxmox Virtual Environment installation
- **Root or sudo access** - Required for VM creation and storage management
- **Storage** - Sufficient space in your Proxmox storage pool for the templates
- **Internet connection** - For downloading cloud images from distribution mirrors
- **Dependencies**:
  - `wget` or `curl` - For downloading images
  - `qemu-img` - For image manipulation (usually included with Proxmox)
  - Standard shell utilities (`bash`, `grep`, `awk`, etc.)

The scripts are designed to run directly on a Proxmox host or a system with access to the Proxmox API.
</details>

<details>
<summary><b>What are the default username/password for these cloud images?</b></summary>

You define those in the configuration. View or modify [`src/config/_defaults.yaml`](src/config/_defaults.yaml).

- **Username** is the `user` field in that file. It's `sysadmin` by default.
- **Password** is defined inside of the file specified in `password_file`, which is `/root/.ci_pass` by default.

If the password file doesn't exist, or if the permissions are not locked down (e.g. `600` or `660`), you'll get an error when you try to build templates. It will explain what to do: create the file, put your desired password in it, and set the permissions appropriately.
</details>