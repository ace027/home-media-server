# Runbook 01 — Proxmox host preparation

This runbook takes the Proxmox host from a bare ZFS pool to a VM ready for
Debian 13 installation, with the Intel Arc A380 bound to `vfio-pci` and
`/data` shared into the VM. Run every command on the Proxmox host itself
(as root, or with `sudo`).

## Prerequisites

- Proxmox VE 8.4 or later. Check with:
  ```bash
  pveversion
  ```
  Expected output:
  ```
  pve-manager/9.0.6/49c767b70aeb6660 (running kernel: 6.14.8-2-pve)
  ```
  (Yours will differ in the trailing hash and kernel version — only the
  `pve-manager` major.minor matters.)
- A ZFS pool named `tank` already exists (`zpool list` shows it).
- The Intel Arc A380 is physically installed and visible to the host
  (`lspci -nn | grep -i arc` should show it).
- This repository is cloned on the host, e.g. to `/root/home-media-server`.
- The Debian 13 netinst ISO is uploaded to the `local` storage. Real ISO
  file names include the point release (e.g.
  `debian-13.1.0-amd64-netinst.iso`), so find the exact name before running
  `scripts/host/20-create-vm.sh`:
  ```bash
  pvesm list local --content iso
  ```
  Expected output:
  ```
  local:iso/debian-13-amd64-netinst.iso iso 123456789
  ```
  Pass the exact name to the VM-creation script, e.g.
  `ISO=local:iso/debian-13.1.0-amd64-netinst.iso scripts/host/20-create-vm.sh --apply`.
- The storage that will hold the VM's disk exists. Check with:
  ```bash
  pvesm status
  ```
  On a host whose Proxmox root is **not** on ZFS, the default
  `VM_STORAGE=local-zfs` will not exist; set `VM_STORAGE=local-lvm` (or
  whatever `pvesm status` lists) when running `20-create-vm.sh`.

## 1. BIOS settings

Before touching software, set these in the host's BIOS/UEFI setup:

- **Intel VT-d** (or **AMD-Vi** on AMD platforms) — enabled. This is
  IOMMU support and is required for PCI passthrough.
- **Above 4G Decoding** — enabled. Required for the A380's large PCI BARs.
- **Resizable BAR (ReBAR)** — enabled. Intel Arc GPUs perform poorly, or
  fail to initialize under passthrough, without it.
- Optionally, if the host also has an integrated GPU (iGPU) or onboard
  video, set the **primary display** to that device rather than the A380,
  so the A380 stays free for passthrough and the host console doesn't
  depend on it.

Save, reboot into Proxmox, and continue below.

## 1a. Migrating an existing pool

Skip this section if `tank` is a new, empty pool you created yourself on
this host (with `zpool create`, as the Prerequisites assume). `## 2. ZFS
datasets` below only creates the datasets on an existing pool; it never
creates the pool itself. Follow this section instead if `/data` will be an
**existing** ZFS pool, on SSDs, moved from another (still-running) server
into this Proxmox host, with a media library on it that must be kept.
Nothing in this procedure destroys or overwrites data by default: import
never uses `-f` unless you explicitly opt in, and no dataset is renamed or
consolidated without you naming it.

### Before moving the drives (old server)

0. **Back up the app configs that are NOT on the pool.** On the owner's old
   server, the Docker app configs (Sonarr, Radarr, Plex, SAB, …) live in
   `/docker` on the old Ubuntu VM's own disk (`/dev/sda2`, ext4), **not** on
   `tank`. They don't move with the SSDs, so archive them onto the pool
   first. Run this on the old Ubuntu VM:
   ```bash
   # 1) Record what was running (image tags matter: Phase 2 restores onto the
   #    same or newer versions, never older, or the app databases can't be read)
   docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sudo tee /docker/_containers.txt
   # _inspect.json and _compose-resolved.yml hold live secrets copied from the
   # containers' env (Twingate tokens, VPN keys, *arr API keys), so they are
   # written root-only (umask 077) and are never world-readable, even briefly.
   docker inspect $(docker ps -aq) | sudo sh -c 'umask 077; cat > /docker/_inspect.json'
   docker inspect --format '{{.Name}} {{.Config.Image}} {{index .Config.Labels "org.opencontainers.image.version"}}' $(docker ps -aq) | sudo tee /docker/_versions.txt
   # Old layout: two compose projects, /docker/plex (plex, seerr, tautulli)
   # and /docker/servarr (everything else). Save the resolved compose files;
   # their volume mappings are what Phase 2 uses to remap old paths.
   ls /docker/plex /docker/servarr | sudo tee /docker/_layout.txt
   for p in /docker/plex /docker/servarr; do (cd "$p" && docker compose config); done \
     | sudo sh -c 'umask 077; cat > /docker/_compose-resolved.yml'
   sudo ls -l /docker/_inspect.json /docker/_compose-resolved.yml   # expect -rw------- root
   du -sh /docker                     # size check (Plex metadata can be large)

   # 2) Stop the containers so the SQLite databases are consistent
   docker stop $(docker ps -q)

   # 3) Stream an archive straight onto the pool on the old Proxmox host
   #    (no local disk space needed). Plex's Cache is disposable, so it's excluded.
   #    (chmod, not mkdir -m: -m has no effect on an existing directory)
   ssh root@<old-proxmox-host> 'mkdir -p /tank/migration && chmod 700 /tank/migration'
   sudo tar --exclude='*/Plex Media Server/Cache' -cpf - -C / docker \
     | zstd -T0 \
     | ssh root@<old-proxmox-host> "umask 077 && cat > /tank/migration/old-docker-$(date +%F).tar.zst"

   # 4) Verify the archive before going any further, and keep it root-only
   #    (it contains the same secrets as _inspect.json)
   ssh root@<old-proxmox-host> "zstd -t /tank/migration/old-docker-*.tar.zst && tar -I zstd -tf /tank/migration/old-docker-*.tar.zst | head"
   ssh root@<old-proxmox-host> "chmod 600 /tank/migration/old-docker-*.tar.zst && ls -l /tank/migration"
   ```
   **Secrets warning.** `_inspect.json`, `_compose-resolved.yml` and the
   `.tar.zst` archive contain live credentials from the old containers'
   environment: Twingate connector tokens, VPN keys and the *arr/SAB API
   keys. Never copy them (or excerpts of them) into this git repository or
   any other; `.gitignore` blocks these names as a safety net, not as
   permission. Read what you need from them in place on the pool. Once the
   old VM is retired, **revoke** the old Twingate connector's tokens (Twingate
   admin console) and the old VPN credentials (the VPN provider's account
   page), since copies of them now sit in these files. Also delete the plain
   dumps from the old VM before it is retired (the archive on the pool keeps
   a copy inside it):
   ```bash
   # on the old Ubuntu VM, once Phase 2 has restored the configs
   sudo rm -f /docker/_inspect.json /docker/_compose-resolved.yml
   ```
   Expected output: `zstd -t` reports the file OK, and the listing starts with
   `docker/…`. If the containers must keep serving until the move, restart
   them now (`docker start $(docker ps -aq)`) and repeat steps 2–4 right
   before step 4 below, so the archive is current. Phase 2 restores these
   configs from `/tank/migration/` and remaps their paths to `/data/...`.
1. Stop anything using the pool (Plex, *arr apps, SMB/NFS shares, etc.).
2. Confirm the pool is healthy:
   ```bash
   zpool status <pool>
   ```
   Expected output: `state: ONLINE` with no `DEGRADED`/`FAULTED` vdevs.
3. Record the current layout, for reference after the move:
   ```bash
   zfs list -r -o name,used,avail,mountpoint,recordsize <pool>
   ```
4. Export the pool so the new host can import it cleanly:
   ```bash
   zpool export <pool>
   ```
   Expected output: the pool disappears from `zpool list`.
5. Physically move the SSDs to the new Proxmox host.

### Import (new host)

List what's importable, to confirm the pool is visible:
```bash
zpool import
```

Dry-run the import script, from the repo root on the new host:
```bash
cd /root/home-media-server
SOURCE_POOL=<old-name> scripts/host/05-import-pool.sh
```
Expected output (stub-captured; real output additionally lists the
inventory once you re-run with `--apply`):
```
DRY-RUN: zpool import <old-name> tank
[INFO] re-run after import (with --apply) to inventory the pool
```
(If `<old-name>` already equals `tank`, the script omits the trailing
rename argument: `DRY-RUN: zpool import tank`.)

Review it, then apply:
```bash
SOURCE_POOL=<old-name> scripts/host/05-import-pool.sh --apply
```

This project's convention is to rename the pool to `tank` on import (as
above) so every other script's `POOL=tank` default just works. If you'd
rather keep the pool's original name, pass `POOL=<old-name>` to every
script from here on (including `00-zfs-datasets.sh` and `20-create-vm.sh`)
instead of renaming.

`FORCE_IMPORT=1` (environment only: set it on the command line; the
script ignores it in `.env`) passes `-f` to `zpool import`, needed only if ZFS reports
the pool as still "in use by another system" (e.g. the old server wasn't
cleanly shut down, or you skipped `zpool export`). It is only safe once the
old server is definitely no longer using the pool — importing a pool that's
still live elsewhere can corrupt it.

### Do not `zpool upgrade`

`05-import-pool.sh` inventories the pool and warns about this on every run.
Do not run `zpool upgrade <pool>` until you are committed to the new
server — upgrading the on-disk format makes the pool unimportable by an
older ZFS version, so you lose the option to move the drives back.

### Consolidation decision tree

The *arr apps import downloads into the media library with hardlinks, and
hardlinks cannot cross ZFS dataset boundaries — so everything under `/data`
must end up as **one** dataset, `tank/data`, with no children. Which path
below applies depends on how the old pool was laid out.

**(a) All media is already in one dataset, with no children.** Rename it
directly — instant, uses no extra space:
```bash
MEDIA_DATASET=<pool>/<dataset> scripts/host/05-import-pool.sh --apply
```
`05-import-pool.sh` refuses if `MEDIA_DATASET` isn't a direct child of the
pool, or has children of its own — those need path (b)/(c) first.

**(b) Media is split across several datasets.** Rename the largest to
`tank/data` as in (a) (`MEDIA_DATASET=<pool>/<largest> ... --apply`). For
each remaining dataset:
1. Check free space first — `tank/data` must have enough room for what
   you're about to copy into it:
   ```bash
   zfs list -o name,avail tank/data <pool>/<other>
   ```
2. Copy, preserving hardlinks/ACLs/xattrs and showing progress:
   ```bash
   rsync -aHAX --info=progress2 /<pool>/<other>/ /tank/data/media/<category>/
   ```
3. Verify before touching the source: compare file counts and `du` between
   source and target, and spot-check a few titles play back correctly.
4. Don't delete the source yet. Snapshots can't outlive their dataset:
   destroying a dataset also destroys its snapshots, and plain `zfs destroy`
   refuses while any exist. So keep the source read-only until the library
   is confirmed working in Phase 2:
   ```bash
   zfs snapshot <pool>/<other>@pre-consolidate
   zfs set readonly=on <pool>/<other>
   ```
   Once Sonarr/Radarr/Lidarr and Plex show everything correctly, free the
   space (this deletes the dataset **and** its snapshots, irreversibly):
   ```bash
   zfs destroy -r <pool>/<other>
   ```

SSD capacity is typically far smaller than the library on it, so an
in-place `rsync` copy that needs the source and target to coexist may not
fit — check free space (step 1) before starting, and consider consolidating
one dataset at a time. AV1 re-encoding (Phase 4, via FileFlows) reclaims a
large amount of space once the library is imported, but don't count on it
during this migration.

**(c) `tank/data` already exists with child datasets.** Same procedure as
(b): `05-import-pool.sh` refuses to touch `tank/data` while it has
children, so copy each child's contents up into the parent with `rsync`,
verify, then destroy the (now-empty of purpose) child dataset.

**(d) Media lives directly in the pool's root dataset** (e.g. `zfs list -r tank`
shows only `tank`, with files under `/tank/<folders>`). This is the owner's
layout: `tank`, 1.14T used, 9.56T free. A root dataset can't be renamed into
`tank/data`, so the library has to be **copied** across the dataset boundary
once. There's plenty of room, and the copy picks up `tank/data`'s 1M recordsize.
1. Import and inventory (no rename needed, since the pool is already named `tank`):
   ```bash
   scripts/host/05-import-pool.sh            # dry-run
   scripts/host/05-import-pool.sh --apply
   zfs snapshot tank@pre-migration           # safety net
   ```
2. Create the dataset (section 2): `scripts/host/00-zfs-datasets.sh --apply`.
3. Copy each top-level folder from `ls /tank` into its category (skip
   `data/` and `backups/`):
   ```bash
   mkdir -p /tank/data/media/{movies,movies-4k,tv,tv-4k,anime-tv,anime-movies,music}
   rsync -aHAX --info=progress2 /tank/<Movies>/ /tank/data/media/movies/
   rsync -aHAX --info=progress2 /tank/<TV>/     /tank/data/media/tv/
   ```
4. Verify each copy before removing anything:
   ```bash
   find /tank/<Movies> -type f | wc -l; find /tank/data/media/movies -type f | wc -l
   du -sh /tank/<Movies> /tank/data/media/movies
   ```
   Then delete the original folders (never `/tank/data` or `/tank/backups`).
   The space isn't freed until the snapshot is removed.
   **The owner's mapping** (`ls /tank` inventory, 2026-09-23):

   | `/tank/…` | Action |
   |---|---|
   | `movies` | copy to `data/media/movies`; 4K is mixed in and gets split out in Phase 2 via Radarr-4K |
   | `shows` | copy to `data/media/tv`; 4K is split out in Phase 2 via Sonarr-4K |
   | `anime` (series only) | copy to `data/media/anime-tv` |
   | `music` | copy to `data/media/music` |
   | `docker` | **not** the live configs (those were on the old VM's disk and are archived to `migration/` in step 0). Keep in place; review later |
   | `migration` | `old-docker-<date>.tar.zst` from step 0. **Keep.** Phase 2 restores the configs from it |
   | `template` | old ISOs/templates. Register as ISO storage (below) |
   | `dump`, `images`, `private`, `snippets`, `import` | old Proxmox storage content. Keep; review and clean up later |
   | `downloads` | old download state. Check for unfinished items, then delete (not migrated) |
   | `fileflows` | old FileFlows state. Not migrated (Phase 4 starts fresh) |
   | `books` | out of scope. Leave in place |

   ```bash
   mkdir -p /tank/data/media/{movies,movies-4k,tv,tv-4k,anime-tv,anime-movies,music}
   rsync -aHAX --info=progress2 /tank/movies/ /tank/data/media/movies/
   rsync -aHAX --info=progress2 /tank/shows/  /tank/data/media/tv/
   rsync -aHAX --info=progress2 /tank/anime/  /tank/data/media/anime-tv/
   rsync -aHAX --info=progress2 /tank/music/  /tank/data/media/music/
   ```

   Register the old ISOs/templates as storage. Proxmox reads ISOs from
   `<path>/template/iso`, so this picks up `/tank/template`. You can also
   upload the Debian 13 netinst here and use `ISO=tank-iso:iso/<file>`
   with `20-create-vm.sh`:
   ```bash
   pvesm add dir tank-iso --path /tank --content iso,vztmpl --is_mountpoint yes
   pvesm list tank-iso --content iso
   ```
   `--is_mountpoint yes` makes Proxmox treat the storage as offline when
   `/tank` isn't mounted, instead of silently writing into the empty
   directory on the root filesystem.
5. After Phase 2 confirms the library in Sonarr/Radarr/Lidarr and Plex:
   `zfs destroy tank@pre-migration`. This is irreversible and frees the old copy's space.

### Reorganize into the TRaSH layout

Once everything is one dataset, arrange it to match the layout
`scripts/mkdirs.sh` creates (see `docs/architecture.md` → Storage layout),
inside `/tank/data`:
```bash
mkdir -p /tank/data/media/{movies,movies-4k,tv,tv-4k,anime-tv,anime-movies,music}
```
Then `mv` the existing folders into place, e.g.:
```bash
mv /tank/data/movies/*      /tank/data/media/movies/
mv /tank/data/tv-4k/*       /tank/data/media/tv-4k/
mv /tank/data/anime/movies/* /tank/data/media/anime-movies/
mv /tank/data/anime/*.mkv   /tank/data/media/anime-tv/   # adjust to your actual layout
mv /tank/data/music/*       /tank/data/media/music/
```
`mv` is instant within one dataset (no data is copied). Once the library is
under `media/<category>/`, Phase 2 imports it into Sonarr/Radarr/Lidarr as
an **existing** library — no re-downloads.

### Ownership

Dry-run the ownership report first:
```bash
scripts/host/05-import-pool.sh
```
Then fix it, if needed:
```bash
FIX_OWNERSHIP=1 scripts/host/05-import-pool.sh --apply
```
`FIX_OWNERSHIP` is environment only: the script ignores it in `.env`, so a
recursive `chown` never runs unless you ask for it on the command line. If
the script prints `tank/data not mounted ...; ownership not checked`, mount
it (`zfs mount tank/data`) and re-run; it doesn't report `ownership OK`
unless it actually looked.

Continue with `## 2. ZFS datasets` below — `00-zfs-datasets.sh` detects
that `tank/data` already exists and sets its properties
(`recordsize=1M compression=lz4 atime=off xattr=sa`) on it instead of
creating it.

## 2. ZFS datasets

Creates `tank/data` (recordsize=1M, compression=lz4, atime=off, xattr=sa —
tuned for large media files) and `tank/backups` (compression=zstd), from the
repo root on the host.

```bash
cd /root/home-media-server
scripts/host/00-zfs-datasets.sh
```

Expected output:
```
DRY-RUN: zfs create -o recordsize=1M -o compression=lz4 -o atime=off -o xattr=sa tank/data
DRY-RUN: zfs create -o compression=zstd tank/backups
[INFO] next: run 10-iommu-vfio.sh
```

Review the commands, then apply them:

```bash
scripts/host/00-zfs-datasets.sh --apply
```

Confirm the recordsize:

```bash
zfs get recordsize tank/data
```

Expected output:
```
NAME       PROPERTY    VALUE    SOURCE
tank/data  recordsize  1M       local
```

**Warning:** `tank/data` must never gain child datasets. The *arr apps
import downloads into the media library with hardlinks, and hardlinks
cannot cross ZFS dataset boundaries. If you (or a script) later run
`zfs create tank/data/something`, re-running `00-zfs-datasets.sh` will
detect it and refuse:
```
[ERROR] child datasets break hardlinks: tank/data/something
```
Destroy the child dataset and move its contents back under `tank/data` as
plain directories instead.

## 3. IOMMU and vfio

Binds the Arc A380 (PCI ID `8086:56a5`) and its audio function
(`8086:4f92`) to `vfio-pci` instead of the host's `i915`/`xe` driver, so the
GPU can be passed through cleanly to the VM. Detects the CPU vendor to pick
the right IOMMU kernel parameters, and edits `/etc/kernel/cmdline`
(systemd-boot, the default when Proxmox root is on ZFS) or
`/etc/default/grub` (otherwise) — whichever is present.

```bash
scripts/host/10-iommu-vfio.sh
```

Expected output:
```
[INFO] detected GPU: 0000:03:00.0
[INFO] detected audio: 0000:04:00.0
[INFO] CPU vendor: GenuineIntel -> params: intel_iommu=on iommu=pt
DRY-RUN: sed -i 's/$/ intel_iommu=on iommu=pt/' "/etc/kernel/cmdline"
DRY-RUN: mkdir -p "/etc/modules-load.d" && printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' > "/etc/modules-load.d/vfio.conf"
DRY-RUN: mkdir -p "/etc/modprobe.d" && printf 'options vfio-pci ids=8086:56a5,8086:4f92\nsoftdep i915 pre: vfio-pci\nsoftdep xe pre: vfio-pci\nsoftdep snd_hda_intel pre: vfio-pci\n' > "/etc/modprobe.d/vfio.conf"
DRY-RUN: update-initramfs -u -k all
DRY-RUN: proxmox-boot-tool refresh
[WARN] reboot required for the new IOMMU/vfio configuration to take effect
[INFO] after reboot, verify with: dmesg | grep -e DMAR -e IOMMU
[INFO] after reboot, verify with: lspci -nnk -s 0000:03:00.0 (expect: Kernel driver in use: vfio-pci)
```
(Captured on an Intel CPU, systemd-boot host, with nothing configured yet.
Both refreshes run last, after every file is written: `update-initramfs`
first, so that `proxmox-boot-tool refresh` (or `update-grub` on a GRUB host)
picks up the rebuilt initramfs.
PCI addresses like `0000:03:00.0` are specific to this host's slot layout;
yours may differ. If detection fails or finds more than one match, set
`GPU_PCI=<address>` explicitly.)

Apply, then reboot:

```bash
scripts/host/10-iommu-vfio.sh --apply
reboot
```

After the reboot, confirm the running kernel actually got the new
parameters (this catches an edit to a bootloader file this host doesn't
boot from):

```bash
cat /proc/cmdline
```

Expected output (contains `intel_iommu=on iommu=pt`; just `iommu=pt` on AMD):
```
initrd=\EFI\proxmox\6.14.8-2-pve\initrd.img-6.14.8-2-pve root=ZFS=rpool/ROOT/pve-1 boot=zfs intel_iommu=on iommu=pt
```
(Representative; on a GRUB host it starts with `BOOT_IMAGE=/boot/vmlinuz-...`.)
If the parameters are missing, the edit went to the wrong file: check which
bootloader is in use with `proxmox-boot-tool status`.

Confirm IOMMU is active:

```bash
dmesg | grep -e DMAR -e IOMMU
```

Expected output:
```
DMAR: IOMMU enabled
DMAR: Intel(R) Virtualization Technology for Directed I/O
```
(Representative — exact lines vary by chipset.)

Confirm the GPU is bound to `vfio-pci`:

```bash
lspci -nnk -s 0000:03:00.0
```

Expected output:
```
03:00.0 VGA compatible controller [0300]: Intel Corporation DG2 [Arc A380] [8086:56a5] (rev 05)
	Subsystem: Intel Corporation Device [8086:1234]
	Kernel driver in use: vfio-pci
	Kernel modules: i915, xe
```
(Representative; `0000:03:00.0` is this host's address — substitute the
address `10-iommu-vfio.sh` printed for yours.) The key line is
`Kernel driver in use: vfio-pci`. If it still says `i915` or `xe`, see
Troubleshooting below.

## 4. Directory mapping and VM

Creates the Proxmox directory mapping (`media-data` → `/tank/data`) if it
doesn't already exist, then the VM: Debian 13 guest (q35/OVMF), the A380
passed through, and `tank/data` attached as a virtiofs share.

```bash
scripts/host/20-create-vm.sh
```

Expected output:
```
[INFO] detected GPU: 0000:03:00.0
[INFO] PVE version: 9.0
DRY-RUN: pvesh create /cluster/mapping/dir --id media-data --map node=<your-node>,path=/tank/data
DRY-RUN: qm create 200 --name media-01 --machine q35 --bios ovmf --cpu host --cores 8 --memory 20480 --balloon 0 --scsihw virtio-scsi-single --scsi0 local-zfs:64,iothread=1,discard=on,ssd=1 --efidisk0 local-zfs:1,efitype=4m,pre-enrolled-keys=0 --net0 virtio,bridge=vmbr0 --ide2 local:iso/debian-13-amd64-netinst.iso,media=cdrom --boot 'order=scsi0;ide2' --ostype l26 --agent enabled=1 --onboot 1
DRY-RUN: qm set 200 --hostpci0 0000:03:00.0,pcie=1
DRY-RUN: qm set 200 --virtiofs0 media-data,cache=auto
[INFO] next: start VM 200, install Debian 13, then follow docs/runbooks/02-vm-bootstrap.md
[INFO] fallback: if the guest's i915 fails to initialise, run:
[INFO]   qm set 200 --vga none
[INFO]   qm set 200 --hostpci0 0000:03:00.0,pcie=1,x-vga=1
```
(Captured on a fresh host with nothing created yet. `<your-node>` is this
host's hostname — the script fills it in automatically with `hostname`.)
If the `media-data` mapping already exists, the script prints
`mapping media-data exists -> <path>` instead of creating it, and refuses
unless the mapping has an entry for this node pointing at `tank/data`'s
mountpoint (`/tank/data`); fix the mapping in the GUI or set
`DIR_MAPPING_ID` to a new id.

If the ISO path shown by `pvesm list local --content iso` (Prerequisites)
differs from the default, pass it explicitly:
`ISO=local:iso/<file>.iso scripts/host/20-create-vm.sh`. On a host whose
storage listing doesn't include `local-zfs`, also pass
`VM_STORAGE=local-lvm` (or the correct storage name).

Apply it:

```bash
scripts/host/20-create-vm.sh --apply
```

Confirm the VM's configuration:

```bash
qm config 200
```

Expected output:
```
agent: enabled=1
bios: ovmf
boot: order=scsi0;ide2
cores: 8
hostpci0: 0000:03:00.0,pcie=1
machine: q35
memory: 20480
net0: virtio,bridge=vmbr0
onboot: 1
ostype: l26
scsi0: local-zfs:vm-200-disk-0,iothread=1,discard=on,ssd=1
virtiofs0: media-data,cache=auto
```
(Representative; `hostpci0` and `virtiofs0` are the lines that matter.)

If `--apply` stops part-way (e.g. `qm create` succeeded but a `qm set` line
failed), a plain re-run refuses with `VMID 200 already exists`. See
"`20-create-vm.sh` stopped half-way" in Troubleshooting below.

**GUI alternative** for step 4, if you prefer clicking through the web UI
instead of running the script:
1. **Datacenter → Directory Mappings → Add**, ID `media-data`, path
   `/tank/data`, node = this host.
2. Create the VM as usual (q35, OVMF/UEFI, Debian 13 guest OS type), then
   **VM → Hardware → Add → PCI Device** for the A380 (`0000:03:00.0`),
   and **VM → Hardware → Add → Virtiofs** pointing at the `media-data`
   mapping.

Start the VM and install Debian 13 (see `docs/runbooks/02-vm-bootstrap.md`).

## 5. Troubleshooting

**Checking IOMMU groups.** If passthrough fails or other devices misbehave,
list the IOMMU groups to see what shares a group with the GPU (ideally,
nothing that must stay on the host):

```bash
find /sys/kernel/iommu_groups/ -type l
```
Expected output:
```
/sys/kernel/iommu_groups/1/devices/0000:00:01.0
/sys/kernel/iommu_groups/12/devices/0000:03:00.0
/sys/kernel/iommu_groups/12/devices/0000:04:00.0
```
(Representative — look for the A380's PCI address, e.g. `0000:03:00.0`,
among the group members.)

**The GPU is still bound to `i915` or `xe` after reboot.** Re-check
`lspci -nnk -s <addr>`. If `Kernel driver in use:` still shows `i915`/`xe`:
- Confirm `/etc/modprobe.d/vfio.conf` has the `softdep i915 pre: vfio-pci`
  and `softdep xe pre: vfio-pci` lines (both drivers exist on modern
  kernels; DG2 cards can bind to either depending on kernel version).
- Confirm `update-initramfs -u -k all` actually ran. It only runs when
  `10-iommu-vfio.sh` detected a change, so if it reports `no changes needed`
  the files are correct but the initramfs may be stale. Force a rebuild
  (see the next entry).
- Reboot again — `softdep` ordering only takes effect from the *next* boot
  using the rebuilt initramfs.

**`10-iommu-vfio.sh --apply` failed during `update-initramfs`,
`proxmox-boot-tool refresh` or `update-grub`.** The script stops with
`'<command>' failed; ... re-run: FORCE_REFRESH=1 ...`. Both refreshes run
last, after every config file is written, so a plain re-run would see the
files as already correct and skip the refresh that failed. Fix the cause the
command printed (a full `/boot` or ESP is common), then re-run with
`FORCE_REFRESH=1`, which re-runs both refreshes regardless of file state:
```bash
FORCE_REFRESH=1 scripts/host/10-iommu-vfio.sh           # dry-run: shows what it will re-run
FORCE_REFRESH=1 scripts/host/10-iommu-vfio.sh --apply
reboot
```
`FORCE_REFRESH` is environment only (ignored in `.env`). The same thing by
hand, in the same order, on a systemd-boot host (`/etc/kernel/cmdline`
exists; the Proxmox default on ZFS root):
```bash
update-initramfs -u -k all
proxmox-boot-tool refresh
```
or on a GRUB host (`/etc/default/grub`):
```bash
update-initramfs -u -k all
update-grub
```

**`10-iommu-vfio.sh` says `has no double-quoted GRUB_CMDLINE_LINUX_DEFAULT`
or `edit of ... did not take effect`.** The script only edits the
standard form `GRUB_CMDLINE_LINUX_DEFAULT="..."` and re-reads the file
after editing it. Change the line in `/etc/default/grub` to that form
(e.g. `GRUB_CMDLINE_LINUX_DEFAULT="quiet"`, double quotes, no trailing
comment), or add `intel_iommu=on iommu=pt` inside the quotes by hand, then
re-run the script.

**`20-create-vm.sh` stopped half-way.** If `qm create` succeeded but a
later `qm set --hostpci0` or `--virtiofs0` failed, every plain re-run
refuses with `VMID 200 already exists`. Fix the cause first (the failing
command's error; e.g. a wrong `GPU_PCI` or a missing directory mapping),
then pick one:
- **Resume** (keeps the VM): `RESUME=1` skips `qm create` for an existing
  VMID and only runs the `qm set` lines whose setting is missing from
  `qm config`. It refuses unless that VM is named `VM_NAME` (`media-01`),
  so it never modifies some other VM that happens to use the VMID, and
  warns if an existing `hostpci0` doesn't point at the A380:
  ```bash
  RESUME=1 scripts/host/20-create-vm.sh           # dry-run: shows what's left
  RESUME=1 scripts/host/20-create-vm.sh --apply
  ```
  Or run the remaining `qm set` lines from the dry-run output by hand.
- **Start over** (the VM has no OS installed yet, so nothing is lost):
  ```bash
  qm destroy 200
  scripts/host/20-create-vm.sh --apply
  ```

**The guest's i915 driver fails to initialize the GPU** (blank/black
console, or `dmesg` in the guest shows i915 errors). This is the scenario
`20-create-vm.sh` prints a fallback for. Switch the passthrough to
"primary GPU" mode:
```bash
qm set 200 --vga none
qm set 200 --hostpci0 0000:03:00.0,pcie=1,x-vga=1
```
`x-vga=1` tells Proxmox to treat the A380 as the VM's primary display
adapter, which some Intel GPUs require to initialize correctly under KVM.

**Resizable BAR not actually enabled**, despite the BIOS toggle. Confirm on
the host:
```bash
lspci -vv -s 0000:03:00.0 | grep -i 'resizable'
```
Expected output:
```
		Resizable BAR: bit 0 (256MB) supported, bit 14 (256GB) enabled
```
(This is what a host with ReBAR correctly enabled prints.) If nothing
prints, or the enabled bit doesn't match a supported size, re-check the
BIOS setting — some boards only expose ReBAR when CSM/legacy boot is fully
disabled.

**Proxmox VE older than 8.4.** `20-create-vm.sh` refuses:
```
[ERROR] PVE 8.3 is older than the required 8.4 (pve-manager/8.3.1/...)
```
Directory mappings (used for the virtiofs share) require PVE 8.4+. Upgrade
Proxmox, or use the NFS fallback below, which works on any PVE version with
an NFS server enabled.

## Fallback: NFS instead of virtiofs

If virtiofs is unavailable (older PVE, or virtiofs proves unreliable on
your hardware), export `tank/data` over NFS instead.

On the Proxmox host:
```bash
apt install nfs-kernel-server
```
Add a line to `/etc/exports`, restricted to the VM's IP address (replace
`10.0.0.50` with the actual VM IP):
```
/tank/data 10.0.0.50(rw,sync,no_subtree_check,no_root_squash)
```
Then:
```bash
exportfs -ra
systemctl enable --now nfs-server
```

In the VM, replace the virtiofs fstab line with an NFS one (matching the
export above; replace `10.0.0.1` with the host's IP):
```
10.0.0.1:/tank/data /data nfs defaults,nofail 0 0
```

Because this changes the mount type, tell `scripts/vm/verify.sh` to accept
it: run it as `ALLOW_NFS=1 scripts/vm/verify.sh` instead of plain
`scripts/vm/verify.sh`. Without `ALLOW_NFS=1`, the `data-mount` check only
accepts `virtiofs` and will FAIL on an NFS mount.
