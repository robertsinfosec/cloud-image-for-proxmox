# About `proxmox-storage.sh`

This script provisions and deprovisions storage on a Proxmox node in a repeatable, node‑local way. It is designed for fresh installs (ISO defaults) and for cleanup/reprovisioning of older systems.

At a high level:
- The system disk is kept **OS‑only** (no Proxmox storage on it).
- Every **non‑system disk** is either adopted into Proxmox storage (provision) or wiped back to raw (deprovision).
- Storage naming is standardized: `HDD-<N><Letter>` and `SSD-<N><Letter>`, where `<N>` is the node’s hostname digit.

> [!NOTE]
> This is opinionated on purpose. Proxmox can be configured in many ways, but this script encodes a consistent, scalable pattern that works well for real‑world fleets.

## Opinionated assumptions (read this first)

These are intentional defaults to keep storage consistent across many nodes:

- **Node naming**: hostnames are `pve1`, `pve2`, `pve3`, etc.
  - The final digit is used as `<N>` in storage labels.
  - Hostnames must end in a single digit (e.g., `pve1`). Multi-digit suffixes (e.g., `pve10`) are not supported.
- **Labeling scheme**: storage IDs and disk labels use `HDD-<N><Letter>` or `SSD-<N><Letter>`.
  - Example on `pve2`: `HDD-2A`, `HDD-2B`, `SSD-2A`.
- **System disk policy**: the system disk is **OS‑only**.
  - No Proxmox storage is created on it.
- **Everything else**: all non‑system disks are owned by Proxmox after provisioning.

> [!TIP]
> If you want a different labeling scheme or hostname policy, edit the naming logic in the script before rolling it out to a fleet.

## Typical usage (fresh install)

Most users only need the defaults:

1) See what disks are attached:

```
proxmox-storage.sh --status
```

2) Provision all unused/new non‑system disks:

```
proxmox-storage.sh --provision --force
```

That run will:
- Expand the system disk to use all available space for `/`.
- Remove the default `local-lvm` thinpool if present.
- Partition, format, and mount every **new/unused** non‑system disk.
- Add each disk as a Proxmox `dir` storage.
- **Skip** any already-provisioned disks (non-destructive, safe default).

> [!TIP]
> The `--provision` command is **safe to run repeatedly**. It only provisions new/unused devices and will not destroy existing provisioned storage. This means you can add a new disk to your server and simply run `./proxmox-storage.sh --provision --force` without worrying about wiping out existing storage.

### Example: common single‑node layout

Imagine a node named `pve1` with:

- A **small SSD** for the OS (system disk)
- A **second SSD** for VM OS disks
- A **large HDD** (or USB/eSATA RAID) for VM data

After provisioning, you typically end up with:

- System disk expanded for `/` only
- `SSD-1A` → VM OS disks (fast, low latency)
- `HDD-1A` → VM data (large, cheaper storage)

> [!TIP]
> This pattern keeps the OS isolated, gives guests fast boot drives, and allocates large data storage to cheaper media.

## Typical usage (re‑provision an older node)

If the node has old storage you want to completely reset:

```bash
# Option 1: Deprovision everything, then provision fresh
proxmox-storage.sh --deprovision --force
proxmox-storage.sh --provision --force

# Option 2: Destroy and re-provision all storage in one step
proxmox-storage.sh --provision --all --force
```

The `--all` flag tells `--provision` to destroy and re-provision **all** storage, including already-provisioned disks. This is useful when you want to start completely fresh.

> [!CAUTION]
> The `--provision --all` command is **destructive** and will wipe all existing provisioned storage. Use it carefully!

### Example: cluster‑scale naming consistency

If your cluster has nodes `pve1`, `pve2`, and `pve3`, each node will label its own disks:

- `pve1`: `SSD-1A`, `SSD-1B`, `HDD-1A` …
- `pve2`: `SSD-2A`, `HDD-2A`, `HDD-2B` …
- `pve3`: `SSD-3A`, `HDD-3A` …

> [!NOTE]
> Storage operations are node‑local and skip shared storage. This prevents accidental changes to other nodes’ disks.

## Naming convention

Disk labels and storage IDs follow this pattern:
`HDD-<N><Letter>` or `SSD-<N><Letter>`

`<N>` is taken from the node hostname (e.g., `pve1` → `1`). `Letter` increments per disk of the same type.

> [!NOTE]
> We only distinguish **HDD vs SSD** on purpose. We intentionally do **not** split further (e.g., SATA SSD vs NVMe) because it adds complexity without much operational value. The key question for operators is: “Is this slow, rotational storage or solid‑state?” That’s what matters most for placement decisions like OS disks.

### Usage

```
Usage:
  proxmox-storage.sh --provision [--force] [--whatif] [--full-format] [--all] [--only <filter>]
  proxmox-storage.sh --deprovision [--force] [--whatif] [--only <filter>]
  proxmox-storage.sh --rename <old-name>:<new-name> [--force]
  proxmox-storage.sh --list-usage <storage-name>
  proxmox-storage.sh --status [--extended]
  proxmox-storage.sh --help

Options:
  --provision         Provision unused/new disks only (safe default)
  --deprovision       Deprovision non-system storage (destructive)
  --rename            Rename existing storage (non-destructive)
                      Format: --rename old-name:new-name
                      Example: --rename pve-disk-storage1:SSD-1C
  --list-usage        Show VMs/CTs and content on a storage
                      Example: --list-usage SSD-1C
  --all               Destroy and re-provision ALL storage (use with --provision)
  --force             Skip confirmation prompt
  --whatif, --simulate
                      Show what would be done without making changes
  --full-format       Slower, full ext4 format (default is quick)
  --status            Show storage status and available devices
  --extended          Show additional SMART health fields
  --only <filter>     Filter to specific device(s) or storage name(s) (repeatable)
                      Examples: --only /dev/sdb  --only HDD-2C  --only SSD-3A
  --help              Show this help

Examples:
  # Provision only new/unused devices (safe)
  ./proxmox-storage.sh --provision --force

  # Destroy and re-provision ALL storage (destructive)
  ./proxmox-storage.sh --provision --all --force

  # Destroy and re-provision specific device
  ./proxmox-storage.sh --provision --only /dev/sdb --force

  # Rename existing storage (non-destructive)
  ./proxmox-storage.sh --rename pve-disk-storage1:SSD-1C --force

  # Check what's on a storage before renaming
  ./proxmox-storage.sh --list-usage SSD-1C
```

## `--status`

Prints a concise table of attached disks and their characteristics using SMART data where possible. The `Media` column shows rotation speed for HDDs, `SSD` for solid‑state disks, and `unknown` if SMART does not report a rotation rate.

> [!TIP]
> Use this before provisioning to verify which disks are SSDs vs HDDs and to spot external RAID devices.

### Example Output - Nothing Allocated

Below is the output of one node when running with `--status` where nothing has been provisioned yet:

```
[*] Context: node=pve2 mode=status whatif=0 force=0 full_format=0 filters=all
[*] Checking root privileges
[+] Running as root
╔════════════════════════════════════════════════════════════════════════════════╗
║ PHYSICAL STORAGE DEVICES
╚════════════════════════════════════════════════════════════════════════════════╝

Device     Size     Model                          Media                Proxmox Storage
/dev/sda    1.8T    ST2000DM008-2FR102             7200 rpm             -              
/dev/sdb   232.9G   Samsung SSD 860 EVO 250GB      SSD                  (system)       
/dev/sdc    7.3T    JMicron H/W RAID5              unknown              -              

╔════════════════════════════════════════════════════════════════════════════════╗
║ PROXMOX STORAGE → DEVICE MAPPING
╚════════════════════════════════════════════════════════════════════════════════╝

  No device allocations found

╔════════════════════════════════════════════════════════════════════════════════╗
║ AVAILABLE FOR PROVISIONING
╚════════════════════════════════════════════════════════════════════════════════╝

  The following devices are available for Proxmox storage:

    /dev/sda ( 1.8T, ST2000DM008-2FR102)
    /dev/sdc ( 7.3T, JMicron H/W RAID5)

  To provision them, run:

    # Provision all available devices
    ./proxmox-storage.sh --provision --force

    # Or provision specific device(s)
    ./proxmox-storage.sh --provision --only /dev/sda --only /dev/sdc

```

### Example Output - Some Storage Allocated
Below is the output of one node when running with `--status` where some disks are already provisioned:

```
[*] Context: node=pve1 mode=status whatif=0 force=0 full_format=0 filters=all
[*] Checking root privileges
[+] Running as root
╔════════════════════════════════════════════════════════════════════════════════╗
║ PHYSICAL STORAGE DEVICES
╚════════════════════════════════════════════════════════════════════════════════╝

Device     Size     Model                          Media                Proxmox Storage
/dev/sda    1.8T    ST2000DM008-2FR102             7200 rpm             -              
/dev/sdb   238.5G   Micron 1100 SATA 256GB         SSD                  (system)       
/dev/sdc    7.3T    JMicron H/W RAID5              unknown              HDD-1B         

╔════════════════════════════════════════════════════════════════════════════════╗
║ PROXMOX STORAGE → DEVICE MAPPING
╚════════════════════════════════════════════════════════════════════════════════╝

  HDD-1B (dir) → /dev/sdc ( 7.3T, JMicron H/W RAID5)
    Mount: /mnt/disks/HDD-1B
    Device: /dev/sdc1

╔════════════════════════════════════════════════════════════════════════════════╗
║ AVAILABLE FOR PROVISIONING
╚════════════════════════════════════════════════════════════════════════════════╝

  /dev/sda is available for Proxmox storage ( 1.8T, ST2000DM008-2FR102)

  To provision it, run:

    ./proxmox-storage.sh --provision --only /dev/sda

```

### Example Output - All Storage Allocated

Below is the output of one node when running with `--status` where all disks are already provisioned:

```
[*] Context: node=pve2 mode=status whatif=0 force=0 full_format=0 filters=all
[*] Checking root privileges
[+] Running as root
╔════════════════════════════════════════════════════════════════════════════════╗
║ PHYSICAL STORAGE DEVICES
╚════════════════════════════════════════════════════════════════════════════════╝

Device     Size     Model                          Media                Proxmox Storage
/dev/sda   476.9G   OSSD512GBTSS2                  SSD                  (system)       
/dev/sdb    1.8T    ST2000LX001-1RG174             5400 rpm             HDD-2A         
/dev/sdc    1.8T    ST2000LX001-1RG174             5400 rpm             HDD-2B         
/dev/sdd   476.9G   Timetec 30TT253X2-512G         SSD                  SSD-2A         
/dev/sde   13.6T    H/W RAID5                      unknown              HDD-2C         

╔════════════════════════════════════════════════════════════════════════════════╗
║ PROXMOX STORAGE → DEVICE MAPPING
╚════════════════════════════════════════════════════════════════════════════════╝

  HDD-2B (dir) → /dev/sdc ( 1.8T, ST2000LX001-1RG174)
    Mount: /mnt/disks/HDD-2B
    Device: /dev/sdc1

  HDD-2C (dir) → /dev/sde (13.6T, H/W RAID5)
    Mount: /mnt/disks/HDD-2C
    Device: /dev/sde1

  HDD-2A (dir) → /dev/sdb ( 1.8T, ST2000LX001-1RG174)
    Mount: /mnt/disks/HDD-2A
    Device: /dev/sdb1

  SSD-2A (dir) → /dev/sdd (476.9G, Timetec 30TT253X2-512G)
    Mount: /mnt/disks/SSD-2A
    Device: /dev/sdd1

```

### Extended SMART fields

If you pass `--extended`, the table includes:

- `Health` (SMART overall health)
- `Temp` (current temperature, if reported)
- `Life` (estimated life remaining, if reported)

Example with `--extended`:

```
Device     Size     Model                          Media        Health   Temp     Life      
/dev/sda   476.9G   SPCC Solid State Disk          SSD          OK       194C     unknown   
/dev/sdb    1.8T    ST2000LX001-1RG174             5400 rpm     OK       190C     unknown   
/dev/sdc    1.8T    ST2000LX001-1RG174             5400 rpm     OK       190C     unknown   
/dev/sdd   13.6T    H/W RAID5                      unknown      OK       unknown  unknown   
/dev/sde   476.9G   Timetec 30TT253X2-512G         SSD          OK       194C     unknown 
```

## `--provision`

This mode provisions **new/unused non‑system disks** as node‑local Proxmox storage:

- Wipes and partitions each new/unused non‑system disk
- Formats as ext4 and mounts under `/mnt/disks/<LABEL>`
- Adds each mount as a Proxmox `dir` storage (node‑local, non‑shared)
- Reclaims the system disk by removing `local-lvm` and expanding `/`
- **Skips** already-provisioned disks (safe default)

Typical usage:

```bash
# Provision only new/unused devices (safe, repeatable)
proxmox-storage.sh --provision --force
```

> [!TIP]
> This is **safe to run repeatedly**. Add a new disk, run the command, and only the new disk gets provisioned.

### Destroy and re-provision all storage

If you need to completely reset all storage (destructive), use `--all`:

```bash
# Destroy and re-provision ALL storage (DESTRUCTIVE)
proxmox-storage.sh --provision --all --force
```

> [!CAUTION]
> The `--all` flag makes `--provision` destructive, wiping even already-provisioned disks.

> [!TIP]
> Use `--whatif` first to preview the plan without making changes.

### Filter to specific devices or storage

If you need to provision only specific disk(s), use `--only` (repeatable):

```bash
# Provision (or re-provision) a single device
proxmox-storage.sh --provision --only /dev/sde --force

# Provision multiple devices
proxmox-storage.sh --provision --only /dev/sdb --only /dev/sdc --force

# Provision by storage name (will destroy and re-provision if already labeled)
proxmox-storage.sh --provision --only HDD-2C --force

# Mix device paths and storage names
proxmox-storage.sh --provision --only /dev/sdb --only SSD-3A --force
```

> [!CAUTION]
> Using `--only` makes the command **destructive** for the specified devices, even if they're already provisioned. The device(s) will be destroyed and re-provisioned.

> [!TIP]
> Use `lsblk` to see attached disks and identify the correct device path. Use `--status` to see existing storage labels.

When `--only` is used:

- The system disk reclaim step is skipped.
- A quick read-probe is performed before destructive actions.
- Only disks matching the specified filter(s) are processed.
- Matching disks are **destroyed and re-provisioned**, even if already provisioned.

## `--deprovision`

This mode **removes node‑local, non‑shared Proxmox storages** and wipes all non‑system disks back to a raw state:

- Removes applicable storage entries from Proxmox
- Unmounts `/mnt/disks/*` and cleans `/etc/fstab`
- Dismantles LVM/ZFS/MD on non‑system disks
- Wipes all non‑system disks (system disk is untouched)

Typical usage:

```
proxmox-storage.sh --deprovision --force
```

### Filter to specific devices or storage

To deprovision just specific disk(s) or storage, use `--only` (repeatable):

```bash
# Deprovision a single device
proxmox-storage.sh --deprovision --only /dev/sde

# Deprovision by storage name
proxmox-storage.sh --deprovision --only HDD-2C --force

# Deprovision multiple items
proxmox-storage.sh --deprovision --only SSD-2A --only SSD-2B --force
```

## `--rename`

Renames existing Proxmox storage in `/etc/pve/storage.cfg` without moving any files or affecting VM/CT functionality. This is a **non-destructive** operation useful for retrofitting existing clusters to naming standards.

### How it works

The rename operation:
1. Verifies the old storage name exists
2. Verifies the new storage name doesn't already exist
3. Backs up `/etc/pve/storage.cfg`
4. Updates the storage ID in the configuration
5. VM/CT configs automatically reference the new storage name

**Important:** The filesystem path remains unchanged. For example:
- Storage ID: `pve-disk-storage1` → `SSD-1C` (changed)
- Filesystem path: `/mnt/disks/pve-disk-storage1` (unchanged)
- This cosmetic mismatch is perfectly fine and doesn't affect functionality

### When to use

Use `--rename` when:
- You need immediate naming consistency in the Proxmox UI
- You're retrofitting an existing cluster to your naming standards
- You can't afford downtime to migrate VMs off storage
- You want a quick, non-destructive fix

### Example

```bash
# Check what's on the storage first
./proxmox-storage.sh --list-usage pve-disk-storage1

# Rename it to match your standard
./proxmox-storage.sh --rename pve-disk-storage1:SSD-1C --force
```

After renaming, if you want the directory name to also match (cosmetic), you can later:
1. Migrate VMs/CTs off the storage
2. Deprovision it with `--deprovision --only SSD-1C`
3. Re-provision the underlying device with `--provision --only /dev/sdX`

This gives you full alignment: storage name, directory name, and filesystem label all match.

## `--list-usage`

Shows what VMs, containers, and content are stored on a specific Proxmox storage. Use this before renaming or deprovisioning to verify it's safe.

### Example

```bash
./proxmox-storage.sh --list-usage SSD-2A
```

**Output:**
```
[*] Content on storage: SSD-2A

Volid                                   Format  Type             Size VMID
SSD-2A:272004/base-272004-disk-0.raw    raw     images    21474836480 272004
SSD-2A:272004/vm-272004-cloudinit.qcow2 qcow2   images        4194304 272004
SSD-2A:272204/base-272204-disk-0.raw    raw     images    21474836480 272204
SSD-2A:272204/vm-272204-cloudinit.qcow2 qcow2   images        4194304 272204

[*] VMs/CTs using this storage:
  VM 272004 (ubuntu-20.04-focal) - running
  VM 272204 (ubuntu-22.04-jammy) - stopped
```

This helps you:
- Verify storage is empty before deprovisioning
- Identify which VMs need migration before major changes
- Understand what will be affected by rename operations

## USB / enclosure caveats

If a disk is behind a USB bridge, transient disconnects or UAS issues can cause I/O failures.
If you see read errors or SMART failures:

- Try a different cable/port or a powered hub.
- Consider disabling UAS for the bridge.

### Example Output

Here is an example of the deprovision output:

<details>
  <summary>Click to expand</summary>

```
[*] Context: node=pve1 mode=deprovision whatif=0 force=1 full_format=0 device=all
[*] Checking root privileges
[+] Running as root
[*] Checking for required commands
[+] All required commands are available
[*] Verifying this is a Proxmox node
[+] Proxmox node verified (pvesm and /etc/pve found)
[*] Determining hostname digit and system disk
[+] Hostname digit: 1
[+] System disk: /dev/sda
[!] This is destructive for ALL non-system storage and disks. System disk will be untouched.
[!] Force mode enabled: skipping confirmation.
[*] Deprovisioning all non-system storage
[*] Deprovision plan (node-local, non-shared only)
    - Remove node-local, non-shared Proxmox storages
    - Unmount and clean /etc/fstab entries under /mnt/disks
    - Dismantle LVM/ZFS/MD on non-system disks
    - Wipe all non-system disks to raw state
[!] Skipping storage 'HDD-2B' (not assigned to node pve1)
[!] Skipping storage 'HDD-2C' (not assigned to node pve1)
[!] Skipping storage 'HDD-2A' (not assigned to node pve1)
[!] Skipping storage 'SSD-2A' (not assigned to node pve1)
[*] Removing Proxmox storage 'HDD-1C'
[+] Removing Proxmox storage 'HDD-1C'
[*] Unmounting /mnt/disks/HDD-1C
[+] Unmounting /mnt/disks/HDD-1C
[*] Removing /etc/fstab entries for /mnt/disks/HDD-1C
[+] Removing /etc/fstab entries for /mnt/disks/HDD-1C
[*] Removing mount directory /mnt/disks/HDD-1C
[+] Removing mount directory /mnt/disks/HDD-1C
[*] Removing Proxmox storage 'HDD-1B'
[+] Removing Proxmox storage 'HDD-1B'
[*] Unmounting /mnt/disks/HDD-1B
[+] Unmounting /mnt/disks/HDD-1B
[*] Removing /etc/fstab entries for /mnt/disks/HDD-1B
[+] Removing /etc/fstab entries for /mnt/disks/HDD-1B
[*] Removing mount directory /mnt/disks/HDD-1B
[+] Removing mount directory /mnt/disks/HDD-1B
[*] Removing Proxmox storage 'HDD-1A'
[+] Removing Proxmox storage 'HDD-1A'
[*] Unmounting /mnt/disks/HDD-1A
[+] Unmounting /mnt/disks/HDD-1A
[*] Removing /etc/fstab entries for /mnt/disks/HDD-1A
[+] Removing /etc/fstab entries for /mnt/disks/HDD-1A
[*] Removing mount directory /mnt/disks/HDD-1A
[+] Removing mount directory /mnt/disks/HDD-1A
[*] Removing Proxmox storage 'SSD-1A'
[+] Removing Proxmox storage 'SSD-1A'
[*] Unmounting /mnt/disks/SSD-1A
[+] Unmounting /mnt/disks/SSD-1A
[*] Removing /etc/fstab entries for /mnt/disks/SSD-1A
[+] Removing /etc/fstab entries for /mnt/disks/SSD-1A
[*] Removing mount directory /mnt/disks/SSD-1A
[+] Removing mount directory /mnt/disks/SSD-1A
[!] Skipping PV /dev/sda3 (system VG)
[*] Removing /etc/fstab entries for /mnt/disks
[+] Removing /etc/fstab entries for /mnt/disks
[+] No /mnt/disks entries to remove
[!] Disk /dev/sdb will be wiped to raw state
[*] Wiping filesystem signatures on /dev/sdb
/dev/sdb: 8 bytes were erased at offset 0x00000200 (gpt): 45 46 49 20 50 41 52 54
/dev/sdb: 8 bytes were erased at offset 0x1d1c1115e00 (gpt): 45 46 49 20 50 41 52 54
/dev/sdb: 2 bytes were erased at offset 0x000001fe (PMBR): 55 aa
/dev/sdb: calling ioctl to re-read partition table: Success
[+] Wiping filesystem signatures on /dev/sdb
[*] Zapping GPT/MBR on /dev/sdb
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.
[+] Zapping GPT/MBR on /dev/sdb
[*] Refreshing kernel partition table for /dev/sdb
partx: /dev/sdb: failed to read partition table
[-] Failed: Refreshing kernel partition table for /dev/sdb
[*] Removing stale partition mappings for /dev/sdb
partx: specified range <1:0> does not make sense
[-] Failed: Removing stale partition mappings for /dev/sdb
[*] Waiting for udev to settle
[+] Waiting for udev to settle
[+] No partitions remain on /dev/sdb
[!] Disk /dev/sdc will be wiped to raw state
[*] Wiping filesystem signatures on /dev/sdc
/dev/sdc: 8 bytes were erased at offset 0x00000200 (gpt): 45 46 49 20 50 41 52 54
/dev/sdc: 8 bytes were erased at offset 0x1d1c1115e00 (gpt): 45 46 49 20 50 41 52 54
/dev/sdc: 2 bytes were erased at offset 0x000001fe (PMBR): 55 aa
/dev/sdc: calling ioctl to re-read partition table: Success
[+] Wiping filesystem signatures on /dev/sdc
[*] Zapping GPT/MBR on /dev/sdc
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.
[+] Zapping GPT/MBR on /dev/sdc
[*] Refreshing kernel partition table for /dev/sdc
partx: /dev/sdc: failed to read partition table
[-] Failed: Refreshing kernel partition table for /dev/sdc
[*] Removing stale partition mappings for /dev/sdc
partx: specified range <1:0> does not make sense
[-] Failed: Removing stale partition mappings for /dev/sdc
[*] Waiting for udev to settle
[+] Waiting for udev to settle
[+] No partitions remain on /dev/sdc
[!] Disk /dev/sdd will be wiped to raw state
[*] Wiping filesystem signatures on /dev/sdd
/dev/sdd: 8 bytes were erased at offset 0x00000200 (gpt): 45 46 49 20 50 41 52 54
/dev/sdd: 8 bytes were erased at offset 0xda519fffe00 (gpt): 45 46 49 20 50 41 52 54
/dev/sdd: 2 bytes were erased at offset 0x000001fe (PMBR): 55 aa
/dev/sdd: calling ioctl to re-read partition table: Success
[+] Wiping filesystem signatures on /dev/sdd
[*] Zapping GPT/MBR on /dev/sdd
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.
[+] Zapping GPT/MBR on /dev/sdd
[*] Refreshing kernel partition table for /dev/sdd
partx: /dev/sdd: failed to read partition table
[-] Failed: Refreshing kernel partition table for /dev/sdd
[*] Removing stale partition mappings for /dev/sdd
partx: specified range <1:0> does not make sense
[-] Failed: Removing stale partition mappings for /dev/sdd
[*] Waiting for udev to settle
[+] Waiting for udev to settle
[+] No partitions remain on /dev/sdd
[!] Disk /dev/sde will be wiped to raw state
[*] Wiping filesystem signatures on /dev/sde
/dev/sde: 8 bytes were erased at offset 0x00000200 (gpt): 45 46 49 20 50 41 52 54
/dev/sde: 8 bytes were erased at offset 0x773c255e00 (gpt): 45 46 49 20 50 41 52 54
/dev/sde: 2 bytes were erased at offset 0x000001fe (PMBR): 55 aa
/dev/sde: calling ioctl to re-read partition table: Success
[+] Wiping filesystem signatures on /dev/sde
[*] Zapping GPT/MBR on /dev/sde
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.
[+] Zapping GPT/MBR on /dev/sde
[*] Refreshing kernel partition table for /dev/sde
partx: /dev/sde: failed to read partition table
[-] Failed: Refreshing kernel partition table for /dev/sde
[*] Removing stale partition mappings for /dev/sde
partx: specified range <1:0> does not make sense
[-] Failed: Removing stale partition mappings for /dev/sde
[*] Waiting for udev to settle
[+] Waiting for udev to settle
[+] No partitions remain on /dev/sde

[+] Done. Final state:
Filesystem            Size  Used Avail Use% Mounted on
/dev/mapper/pve-root  461G  5.0G  436G   2% /
Name          Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %
HDD-2A         dir   disabled               0               0               0      N/A
HDD-2B         dir   disabled               0               0               0      N/A
HDD-2C         dir   disabled               0               0               0      N/A
SSD-2A         dir   disabled               0               0               0      N/A
local          dir     active       482371416         5218808       456503256    1.08%
NAME           SIZE TYPE MOUNTPOINTS
sda          476.9G disk 
├─sda1        1007K part 
├─sda2           1G part /boot/efi
└─sda3       475.9G part 
  ├─pve-swap     8G lvm  [SWAP]
  └─pve-root 467.9G lvm  /
sdb            1.8T disk 
sdc            1.8T disk 
sdd           13.6T disk 
sde          476.9G disk 
sr0           1024M rom
```

</details>

---

Here is an example of the provision output:

<details>
  <summary>Click to expand</summary>

```
[*] Context: node=pve1 mode=provision whatif=0 force=1 full_format=0 device=all
[*] Checking root privileges
[+] Running as root
[*] Checking for required commands
[+] All required commands are available
[*] Verifying this is a Proxmox node
[+] Proxmox node verified (pvesm and /etc/pve found)
[*] Determining hostname digit and system disk
[+] Hostname digit: 1
[+] System disk: /dev/sda

[*] Summary
    - System disk: /dev/sda
    - Goal: OS-only system disk (expand /), no local-lvm
    - ALL other disks are fair game and will be (re)provisioned as Proxmox storage
    - Storage naming: HDD-1A, HDD-1B... and SSD-1A, SSD-1B... (per host digit, per type)

[*] Current block devices
NAME           SIZE TYPE MOUNTPOINTS
sda          476.9G disk 
├─sda1        1007K part 
├─sda2           1G part /boot/efi
└─sda3       475.9G part 
  ├─pve-swap     8G lvm  [SWAP]
  └─pve-root 467.9G lvm  /
sdb            1.8T disk 
sdc            1.8T disk 
sdd           13.6T disk 
sde          476.9G disk 
sr0           1024M rom  

[*] Current Proxmox storage
Name          Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %
HDD-2A         dir   disabled               0               0               0      N/A
HDD-2B         dir   disabled               0               0               0      N/A
HDD-2C         dir   disabled               0               0               0      N/A
SSD-2A         dir   disabled               0               0               0      N/A
local          dir     active       482371416         5218820       456503244    1.08%

[*] Current LVM
  VG  #PV #LV #SN Attr   VSize    VFree
  pve   1   2   0 wz--n- <475.94g    0 
  LV   VG  Attr       LSize    Pool Origin Data%  Meta%  Move Log Cpy%Sync Convert
  root pve -wi-ao---- <467.94g                                                    
  swap pve -wi-ao----    8.00g                                                    

[!] Planned actions
    1) Remove Proxmox storage 'local-lvm' (if present)
    2) Destroy LVM thinpool LV(s): pve/data, pve/data_tmeta, pve/data_tdata (if present)
    3) Extend /dev/pve/root to all free extents; resize ext4 filesystem
    4) For every non-system disk:
       - If labeled HDD-1X / SSD-1X already: heal mount/fstab/storage
       - Else: wipe, GPT single partition, ext4 format + label, mount, fstab, add Proxmox dir storage

[!] This is destructive for ALL non-system disks that are not already labeled in the expected scheme.
[!] Force mode enabled: skipping confirmation.
[*] System disk reclaim (OS-only): remove local-lvm thinpool, expand /
[*] Checking for Proxmox storage 'local-lvm'
[+] Proxmox storage 'local-lvm' not present (already removed)
[*] Checking for LV pve/data
[+] LV pve/data not present (already removed)
[*] Checking for LV pve/data_tmeta
[+] LV pve/data_tmeta not present (already removed)
[*] Checking for LV pve/data_tdata
[+] LV pve/data_tdata not present (already removed)
[*] Checking for free space in VG pve
[+] No meaningful free space in VG pve (root already expanded)
[*] Provisioning non-system disks as Proxmox storage (fair game): sysdisk=/dev/sda hostdigit=1
[*] Detecting target disk(s)
[+] Found 4 disk(s)
[*] Processing disk: /dev/sdb
[+] Disk type determined: HDD (rotational=1)
[*] Checking for existing label on /dev/sdb1
[!] Disk /dev/sdb will be DESTROYED and reprovisioned as HDD-1A (GPT, single partition, ext4)
[*] Wiping filesystem signatures on /dev/sdb
[+] Wiping filesystem signatures on /dev/sdb
[*] Zapping GPT/MBR on /dev/sdb
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.
[+] Zapping GPT/MBR on /dev/sdb
[*] Creating GPT partition on /dev/sdb with label HDD-1A
Creating new GPT entries in memory.
The operation has completed successfully.
[+] Creating GPT partition on /dev/sdb with label HDD-1A
[*] Refreshing kernel partition table for /dev/sdb
[+] Refreshing kernel partition table for /dev/sdb
[*] Waiting for udev to settle
[+] Waiting for udev to settle
[*] Formatting /dev/sdb1 as ext4 with label HDD-1A
mke2fs 1.47.2 (1-Jan-2025)
/dev/sdb1 contains a ext4 file system labelled 'HDD-1A'
	last mounted on Thu Jan 15 19:07:55 2026
Creating filesystem with 488378385 4k blocks and 476960 inodes
Filesystem UUID: c3079eab-3827-43b5-b76b-c7f6a04f1efa
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, 
	4096000, 7962624, 11239424, 20480000, 23887872, 71663616, 78675968, 
	102400000, 214990848

Allocating group tables: done                            
Writing inode tables: done                            
Creating journal (262144 blocks): done
Writing superblocks and filesystem accounting information: done       

[+] Formatting /dev/sdb1 as ext4 with label HDD-1A
[*] Ensuring mount for HDD-1A (/dev/sdb1)
[*] Creating mount point directory if needed: /mnt/disks/HDD-1A
[+] Creating mount point directory if needed: /mnt/disks/HDD-1A
[*] Removing stale /etc/fstab entries for /mnt/disks/HDD-1A
[+] Removing stale /etc/fstab entries for /mnt/disks/HDD-1A
[*] Adding /etc/fstab entry for HDD-1A
[+] Adding /etc/fstab entry for HDD-1A
[*] Mounting /mnt/disks/HDD-1A
mount: (hint) your fstab has been modified, but systemd still uses
       the old version; use 'systemctl daemon-reload' to reload.
[+] Mounting /mnt/disks/HDD-1A
[*] Ensuring Proxmox storage 'HDD-1A' exists
[*] Adding Proxmox storage 'HDD-1A' at /mnt/disks/HDD-1A
[+] Adding Proxmox storage 'HDD-1A' at /mnt/disks/HDD-1A
[+] Provisioned /dev/sdb -> HDD-1A
[*] Processing disk: /dev/sdc
[+] Disk type determined: HDD (rotational=1)
[*] Checking for existing label on /dev/sdc1
[!] Disk /dev/sdc will be DESTROYED and reprovisioned as HDD-1B (GPT, single partition, ext4)
[*] Wiping filesystem signatures on /dev/sdc
[+] Wiping filesystem signatures on /dev/sdc
[*] Zapping GPT/MBR on /dev/sdc
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.
[+] Zapping GPT/MBR on /dev/sdc
[*] Creating GPT partition on /dev/sdc with label HDD-1B
Creating new GPT entries in memory.
The operation has completed successfully.
[+] Creating GPT partition on /dev/sdc with label HDD-1B
[*] Refreshing kernel partition table for /dev/sdc
[+] Refreshing kernel partition table for /dev/sdc
[*] Waiting for udev to settle
[+] Waiting for udev to settle
[*] Formatting /dev/sdc1 as ext4 with label HDD-1B
mke2fs 1.47.2 (1-Jan-2025)
/dev/sdc1 contains a ext4 file system labelled 'HDD-1B'
	last mounted on Thu Jan 15 19:08:07 2026
Creating filesystem with 488378385 4k blocks and 476960 inodes
Filesystem UUID: 20e6a1fd-6d6d-4c7d-bf68-cb04cf3d92d2
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, 
	4096000, 7962624, 11239424, 20480000, 23887872, 71663616, 78675968, 
	102400000, 214990848

Allocating group tables: done                            
Writing inode tables: done                            
Creating journal (262144 blocks): done
Writing superblocks and filesystem accounting information: done       

[+] Formatting /dev/sdc1 as ext4 with label HDD-1B
[*] Ensuring mount for HDD-1B (/dev/sdc1)
[*] Creating mount point directory if needed: /mnt/disks/HDD-1B
[+] Creating mount point directory if needed: /mnt/disks/HDD-1B
[*] Removing stale /etc/fstab entries for /mnt/disks/HDD-1B
[+] Removing stale /etc/fstab entries for /mnt/disks/HDD-1B
[*] Adding /etc/fstab entry for HDD-1B
[+] Adding /etc/fstab entry for HDD-1B
[*] Mounting /mnt/disks/HDD-1B
mount: (hint) your fstab has been modified, but systemd still uses
       the old version; use 'systemctl daemon-reload' to reload.
[+] Mounting /mnt/disks/HDD-1B
[*] Ensuring Proxmox storage 'HDD-1B' exists
[*] Adding Proxmox storage 'HDD-1B' at /mnt/disks/HDD-1B
[+] Adding Proxmox storage 'HDD-1B' at /mnt/disks/HDD-1B
[+] Provisioned /dev/sdc -> HDD-1B
[*] Processing disk: /dev/sdd
[+] Disk type determined: HDD (rotational=1)
[*] Checking for existing label on /dev/sdd1
[!] Disk /dev/sdd will be DESTROYED and reprovisioned as HDD-1C (GPT, single partition, ext4)
[*] Wiping filesystem signatures on /dev/sdd
[+] Wiping filesystem signatures on /dev/sdd
[*] Zapping GPT/MBR on /dev/sdd
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.
[+] Zapping GPT/MBR on /dev/sdd
[*] Creating GPT partition on /dev/sdd with label HDD-1C
Creating new GPT entries in memory.
The operation has completed successfully.
[+] Creating GPT partition on /dev/sdd with label HDD-1C
[*] Refreshing kernel partition table for /dev/sdd
[+] Refreshing kernel partition table for /dev/sdd
[*] Waiting for udev to settle
[+] Waiting for udev to settle
[*] Formatting /dev/sdd1 as ext4 with label HDD-1C
mke2fs 1.47.2 (1-Jan-2025)
/dev/sdd1 contains a ext4 file system labelled 'HDD-1C'
	last mounted on Thu Jan 15 19:12:54 2026
Creating filesystem with 3662782203 4k blocks and 3576960 inodes
Filesystem UUID: 0a4dd5bf-b363-4ef5-975d-422e0288f4a7
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, 
	4096000, 7962624, 11239424, 20480000, 23887872, 71663616, 78675968, 
	102400000, 214990848, 512000000, 550731776, 644972544, 1934917632, 
	2560000000

Allocating group tables: done                            
Writing inode tables: done                            
Creating journal (262144 blocks): done
Writing superblocks and filesystem accounting information: done         

[+] Formatting /dev/sdd1 as ext4 with label HDD-1C
[*] Ensuring mount for HDD-1C (/dev/sdd1)
[*] Creating mount point directory if needed: /mnt/disks/HDD-1C
[+] Creating mount point directory if needed: /mnt/disks/HDD-1C
[*] Removing stale /etc/fstab entries for /mnt/disks/HDD-1C
[+] Removing stale /etc/fstab entries for /mnt/disks/HDD-1C
[*] Adding /etc/fstab entry for HDD-1C
[+] Adding /etc/fstab entry for HDD-1C
[*] Mounting /mnt/disks/HDD-1C
mount: (hint) your fstab has been modified, but systemd still uses
       the old version; use 'systemctl daemon-reload' to reload.
[+] Mounting /mnt/disks/HDD-1C
[*] Ensuring Proxmox storage 'HDD-1C' exists
[*] Adding Proxmox storage 'HDD-1C' at /mnt/disks/HDD-1C
[+] Adding Proxmox storage 'HDD-1C' at /mnt/disks/HDD-1C
[+] Provisioned /dev/sdd -> HDD-1C
[*] Processing disk: /dev/sde
[+] Disk type determined: SSD (rotational=0)
[*] Checking for existing label on /dev/sde1
[!] Disk /dev/sde will be DESTROYED and reprovisioned as SSD-1A (GPT, single partition, ext4)
[*] Wiping filesystem signatures on /dev/sde
[+] Wiping filesystem signatures on /dev/sde
[*] Zapping GPT/MBR on /dev/sde
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.
[+] Zapping GPT/MBR on /dev/sde
[*] Creating GPT partition on /dev/sde with label SSD-1A
Creating new GPT entries in memory.
The operation has completed successfully.
[+] Creating GPT partition on /dev/sde with label SSD-1A
[*] Refreshing kernel partition table for /dev/sde
[+] Refreshing kernel partition table for /dev/sde
[*] Waiting for udev to settle
[+] Waiting for udev to settle
[*] Formatting /dev/sde1 as ext4 with label SSD-1A
mke2fs 1.47.2 (1-Jan-2025)
/dev/sde1 contains a ext4 file system labelled 'SSD-1A'
	last mounted on Thu Jan 15 19:12:59 2026
Creating filesystem with 125026641 4k blocks and 122112 inodes
Filesystem UUID: 8eda41d4-f6ce-4fb0-9850-2ef7e3963d1e
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, 
	4096000, 7962624, 11239424, 20480000, 23887872, 71663616, 78675968, 
	102400000

Allocating group tables: done                            
Writing inode tables: done                            
Creating journal (262144 blocks): done
Writing superblocks and filesystem accounting information: done     

[+] Formatting /dev/sde1 as ext4 with label SSD-1A
[*] Ensuring mount for SSD-1A (/dev/sde1)
[*] Creating mount point directory if needed: /mnt/disks/SSD-1A
[+] Creating mount point directory if needed: /mnt/disks/SSD-1A
[*] Removing stale /etc/fstab entries for /mnt/disks/SSD-1A
[+] Removing stale /etc/fstab entries for /mnt/disks/SSD-1A
[*] Adding /etc/fstab entry for SSD-1A
[+] Adding /etc/fstab entry for SSD-1A
[*] Mounting /mnt/disks/SSD-1A
mount: (hint) your fstab has been modified, but systemd still uses
       the old version; use 'systemctl daemon-reload' to reload.
[+] Mounting /mnt/disks/SSD-1A
[*] Ensuring Proxmox storage 'SSD-1A' exists
[*] Adding Proxmox storage 'SSD-1A' at /mnt/disks/SSD-1A
[+] Adding Proxmox storage 'SSD-1A' at /mnt/disks/SSD-1A
[+] Provisioned /dev/sde -> SSD-1A

[+] Done. Final state:
Filesystem            Size  Used Avail Use% Mounted on
/dev/mapper/pve-root  461G  5.0G  436G   2% /
Name          Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %
HDD-1A         dir     active      1952130876            2104      1952112388    0.00%
HDD-1B         dir     active      1952130876            2104      1952112388    0.00%
HDD-1C         dir     active     14648095052            2104     14648076564    0.00%
HDD-2A         dir   disabled               0               0               0      N/A
HDD-2B         dir   disabled               0               0               0      N/A
HDD-2C         dir   disabled               0               0               0      N/A
SSD-1A         dir     active       498918812            2104       498900324    0.00%
SSD-2A         dir   disabled               0               0               0      N/A
local          dir     active       482371416         5218900       456503164    1.08%
NAME           SIZE TYPE MOUNTPOINTS
sda          476.9G disk 
├─sda1        1007K part 
├─sda2           1G part /boot/efi
└─sda3       475.9G part 
  ├─pve-swap     8G lvm  [SWAP]
  └─pve-root 467.9G lvm  /
sdb            1.8T disk 
└─sdb1         1.8T part /mnt/disks/HDD-1A
sdc            1.8T disk 
└─sdc1         1.8T part /mnt/disks/HDD-1B
sdd           13.6T disk 
└─sdd1        13.6T part /mnt/disks/HDD-1C
sde          476.9G disk 
└─sde1       476.9G part /mnt/disks/SSD-1A
sr0           1024M rom  
```

</details>

---

## Technical details (for engineers)

### System disk handling
- The system disk is detected by tracing `/` back to its underlying block device.
- The system disk is **never wiped** in deprovisioning.
- LVM actions explicitly skip the `pve` volume group and any PVs on the system disk.

### Storage scope in clusters
- Storage operations are **node‑local only**.
- Shared storage is skipped.
- Storage IDs are derived from `/etc/pve/storage.cfg` and filtered by `nodes` and `shared` fields.

### Idempotency and self‑healing
- Disks already labeled in the expected scheme are **not reformatted**.
- Missing mounts and `/etc/fstab` entries are automatically repaired.
- Proxmox storage entries are added if missing.

### Formatting behavior
- Default format is **quick**: fewer inodes and 0% reserved blocks.
- Use `--full-format` for a slower, full ext4 format.

### Safety checks
- Destructive actions require typing `DESTROY` unless `--force` is provided.
- Deprovisioning skips disks with active mounts outside `/mnt/disks`.
- `/etc/fstab` is created if missing and must be writable.

> [!WARNING]
> This script is **destructive** by design. Use `--whatif` to preview changes and `--force` only when you are certain the node can be wiped.
