# Spec: Phase 1 — Host & Repo Foundation

## Overview
Phase 1 builds everything later phases stand on. It has two parts:
- **R1:** a GitOps repo skeleton. A root `compose.yaml` includes six empty domain stack files, all of which share one service template, one external `proxy` network and one env contract.
- **R2:** re-runnable, dry-run-by-default scripts and literal runbooks that take the owner's Proxmox host from bare ZFS pool to a Debian 13 VM with the Arc A380 passed through, `/data` shared via virtiofs, and Docker installed.

Later phases only add `services:` entries to existing stack files. They never touch wiring, path conventions or the env contract. Hardware steps run on the owner's machine. The repo provides the tooling plus `scripts/vm/verify.sh`, the single acceptance check the owner runs. CI and sandbox runs check everything that can be checked without hardware.

Architecture approach: **Hybrid** (selected in `/legion:plan 1` step 3.5), combining:
- Minimal: empty stacks.
- Clean: `_common.yaml` via `extends`, the proxy network, host/vm script split, `verify.sh`.
- Pragmatic: CI lint.

## Requirements
| ID | Description | Priority | Acceptance Criteria |
|----|-------------|----------|---------------------|
| R1.1 | Root `compose.yaml` includes 6 stack files | Must | `cp .env.example .env && docker compose config -q` exits 0 |
| R1.2 | Shared service template via `extends` | Must | `grep -q 'base:' stacks/_common.yaml`; a temporary service extending it renders `restart: unless-stopped` |
| R1.3 | Env contract | Must | `.env.example` defines TZ, PUID, PGID, UMASK, DOMAIN, DATA_ROOT, APPDATA_ROOT |
| R1.4 | Secrets never committed | Must | `git check-ignore .env secrets/x` succeeds; `secrets/.gitkeep` is tracked |
| R1.5 | Pinned image tags | Must | `scripts/ci/check-pinned-images.sh` exits 0 and fails on a fixture using `:latest` or no tag |
| R1.6 | TRaSH `/data` tree | Must | `DATA_ROOT=$tmp scripts/mkdirs.sh` creates all 14 leaf dirs and is idempotent |
| R1.7 | Docs skeleton | Must | `docs/README.md`, `docs/architecture.md` and 2 runbooks exist with the required headings |
| R1.8 | CI lint | Should | `.github/workflows/lint.yml` runs compose config, shellcheck, yamllint and the pinned-tag check |
| R2.1 | ZFS datasets | Must | `scripts/host/00-zfs-datasets.sh` (dry-run) prints `zfs create` for `tank/data` (recordsize=1M) and `tank/backups`, with no child datasets under `tank/data` |
| R2.2 | IOMMU + vfio binding of A380 | Must | `scripts/host/10-iommu-vfio.sh` (dry-run) prints the cmdline and modprobe changes; refuses if no 8086:56a5 device is found |
| R2.3 | VM creation | Must | `scripts/host/20-create-vm.sh` (dry-run) prints `qm create` with q35, ovmf, cpu host, hostpci0 with pcie=1, and the virtiofs mapping |
| R2.4 | VM bootstrap | Must | `scripts/vm/00-bootstrap.sh` (dry-run) prints the firmware/VA driver/Docker install, the fstab virtiofs line and `docker network create proxy` |
| R2.5 | Hardware acceptance | Must | On the real VM, `scripts/vm/verify.sh` prints PASS for gpu, vaapi-av1, vaapi-hevc, vaapi-h264, data-mount, tree, hardlink, docker, network, compose; in sandbox mode it passes with hardware checks reported as SKIP |
| R2.6 | Host runbook | Must | `docs/runbooks/01-proxmox-host.md` covers BIOS, ZFS, IOMMU, vfio, directory mapping and VM creation, each with an expected-output block |

## Architecture
```
compose.yaml ──include──► stacks/{edge,media,arr,download,transcode,ops}.yaml
                               │  services: {}   (filled by Phases 2-5)
                               │  networks.proxy: {name: proxy, external: true}
                               └─ later services: extends: {file: _common.yaml, service: base}
.env (from .env.example) ──interpolated into every included file (verified)
scripts/lib/common.sh ◄── sourced by scripts/host/*.sh, scripts/vm/*.sh, scripts/mkdirs.sh
Proxmox host: host/00 → host/10 (reboot) → host/20 → install Debian 13 in VM
VM:           vm/00-bootstrap.sh → (reboot) → mkdirs.sh → vm/verify.sh
CI:           lint.yml → compose config · shellcheck · yamllint · check-pinned-images · sandbox mkdirs+verify
```

### Key Decisions
| Decision | Choice | Rationale | Alternatives Considered |
|----------|--------|-----------|-------------------------|
| Shared defaults | `stacks/_common.yaml` service `base`, pulled in with `extends:` | Tested locally (Compose v5.1.1): `extends` with `file:` works inside included files. YAML anchors don't cross `include:` boundaries. | Anchors in `compose.yaml` (don't work across includes); copy-paste per service (drifts) |
| Proxy network | `proxy` declared `external: true` identically in each stack file and created by `vm/00-bootstrap.sh` | Tested: identical duplicate external declarations merge cleanly. Each stack is self-describing, and Traefik (Phase 3) can join without editing other files. | Declared in one stack only (works, but depends on include order and hides the dependency) |
| Empty stacks | Each file is a phase-owner header comment plus `services: {}` | Placeholder services would start on `compose up` and lock in decisions early | Stub services for every later phase (Pragmatic; rejected) |
| Script safety | Every host/VM script is **dry-run by default**; `--apply` executes; root required only with `--apply` | Host scripts change the bootloader, ZFS and VMs. Dry-run lets CI and sandbox check the logic and lets the owner review first. | Execute by default (unsafe); Ansible (out of scope) |
| Re-running scripts | Every mutating step is guarded by an existence or state check (`zfs list`, `grep -q`, `qm status`, `docker network inspect`) | Safe to re-run after a partial failure | Assume a clean state (fragile) |
| GPU identification | Detect with `lspci -Dnn -d 8086:56a5`; `GPU_PCI` env var overrides; refuse if not found or several found without an override | IDs are verifiable: A380 = 8086:56a5, audio function 8086:4f92 | Hardcode a PCI address (breaks when the slot changes) |
| vfio binding | `/etc/modprobe.d/vfio.conf` contains `options vfio-pci ids=<gpu-id>,<audio-id>` (from detection: 8086:56a5, 8086:4f92) **plus** `softdep i915 pre: vfio-pci` and `softdep xe pre: vfio-pci`; `/etc/modules-load.d/vfio.conf` lists `vfio`, `vfio_iommu_type1`, `vfio_pci`; then `update-initramfs -u -k all` | `ids=` makes vfio-pci claim the card; softdep makes it load before i915/xe; initramfs-tools needs regenerating for early binding | softdep only (doesn't bind the device, per critique #1); driver_override udev rule (more moving parts) |
| Bootloader handling | `10-iommu-vfio.sh` edits `/etc/kernel/cmdline` + `proxmox-boot-tool refresh` if that file exists (systemd-boot/ZFS root), otherwise `/etc/default/grub` + `update-grub` | Proxmox on ZFS root uses systemd-boot; on ext4/LVM it uses GRUB | Supporting only one (breaks the other install type) |
| /data sharing | Proxmox directory mapping `media-data` → `/tank/data`, attached as `virtiofs0`, mounted in the VM through fstab `media-data /data virtiofs defaults,nofail 0 0` | Native in PVE 8.4+; no network stack. One dataset, so hardlinks work. | NFS from host (fallback documented in the runbook); passing disks through (loses host ZFS) |
| Directory ownership | `mkdirs.sh`: `chown PUID:PGID` on created dirs only when root (warn and skip otherwise), `chmod 2775` (setgid), umask 002 | TRaSH convention; the group keeps write access | 777 (insecure) |
| verify.sh modes | `SKIP_HW=1` skips the GPU, VAAPI and virtiofs mount checks (reported as SKIP) so CI can test the tree/hardlink/compose logic under a temporary `DATA_ROOT` | Keeps the owner's acceptance check and CI on the same script | Separate CI script (drifts) |
| CI | GitHub Actions `lint.yml` on push/PR: `docker compose config -q`, `shellcheck -x`, `yamllint -s`, `scripts/ci/check-pinned-images.sh`, sandbox `mkdirs.sh`+`verify.sh` | Catches Phase 1 criteria automatically for every later phase | No CI (Minimal; rejected in the hybrid) |

## API and Type Contracts
**Script CLI contract.** Applies to every script in `scripts/host/`, `scripts/vm/` and `scripts/mkdirs.sh`:
- `script.sh [--apply] [--help]`.
- Without `--apply`, each mutating command is printed prefixed with `DRY-RUN:` and exits 0. `mkdirs.sh` is the exception: it always applies, because it only creates directories, and runs without root when `DATA_ROOT` is writable.
- Exit codes: 0 success, 1 precondition failed, 2 usage error.
- Every script uses `set -Eeuo pipefail`, sources `scripts/lib/common.sh` via a path relative to its own location, and loads `.env` (repo root) if present. Environment variables override `.env`.

**`scripts/lib/common.sh` functions:**
- `log_info <msg>`, `log_warn <msg>`, `log_error <msg>` write to stderr with `[INFO]`/`[WARN]`/`[ERROR]` prefixes.
- `die <msg>` calls `log_error` and exits 1.
- `parse_common_args "$@"` sets `APPLY=0|1` and handles `--help` via the caller-defined `usage`.
- `run <cmd...>` prints `DRY-RUN: <cmd>` when `APPLY=0`, otherwise executes the command.
- `require_root` fails when `APPLY=1` and EUID≠0.
- `require_cmd <name...>`.
- `load_env` sources `$REPO_ROOT/.env` if present, without overriding variables already set.
- `REPO_ROOT` is derived from the location of `common.sh`.

**Test hooks:** host scripts read and write system files through `${SYSROOT:-}` (e.g. `${SYSROOT}/etc/kernel/cmdline`, `${SYSROOT}/proc/cpuinfo`), so tests can point them at a temp tree. Tests use stub `zfs`/`lspci`/`qm`/`pvesh`/`pveversion` executables created by `scripts/ci/make-host-stubs.sh <dir>` and prepended to `PATH`.

**Host script variables (defaults):**
- ZFS: `POOL=tank`.
- VM identity and size: `VMID=200`, `VM_NAME=media-01`, `VM_CORES=8`, `VM_MEMORY=20480`.
- VM storage and network: `VM_STORAGE=local-zfs`, `VM_DISK_GB=64`, `VM_BRIDGE=vmbr0`, `ISO=local:iso/debian-13-amd64-netinst.iso`.
- GPU and share: `GPU_PCI` (auto-detected), `DIR_MAPPING_ID=media-data`.

**VM script variables:** `DIR_MAPPING_ID=media-data`, `DATA_ROOT=/data`, `APPDATA_ROOT=/opt/appdata`, `MEDIA_USER` (defaults to `SUDO_USER`), PUID/PGID from `.env`.

**verify.sh output:**
- One line per check: `PASS <check-id> <detail>`, `FAIL <check-id> <detail>` or `SKIP <check-id> <reason>`.
- Final line: `RESULT: <n> pass, <n> fail, <n> skip`.
- Exits 1 if any check FAILs.
- Check IDs, in order: `gpu`, `vaapi-av1`, `vaapi-hevc`, `vaapi-h264`, `data-mount`, `tree`, `hardlink`, `docker`, `network`, `compose`.
- `docker`/`network`/`compose` are SKIP when docker is absent **and** `SKIP_HW=1`.

**VAAPI checks** grep `vainfo --display drm --device /dev/dri/renderD128` for:
- `vaapi-av1`: `VAProfileAV1Profile0.*VAEntrypointEncSliceLP`.
- `vaapi-hevc`: `VAProfileHEVCMain10.*VAEntrypointEncSlice` (LP or not).
- `vaapi-h264`: `VAProfileH264Main.*VAEntrypointEncSlice`.

**Compose contract:**
- `compose.yaml` top level is `name: media` + `include:` with exactly the 6 stack files, in the order edge, media, arr, download, transcode, ops.
- `_common.yaml` service `base` sets:
  - `restart: unless-stopped`
  - `security_opt: [no-new-privileges:true]`
  - `environment: {TZ: ${TZ}, PUID: ${PUID}, PGID: ${PGID}, UMASK: ${UMASK}}`
  - `logging: {driver: json-file, options: {max-size: "10m", max-file: "3"}}`
  - no `image`.

## File Placement
| Artifact | Path | Placement Rationale | Existing Pattern |
|----------|------|---------------------|------------------|
| Root compose | `compose.yaml` | Compose default filename | Design doc repo layout |
| Stack files | `stacks/{edge,media,arr,download,transcode,ops}.yaml` | Design doc layout | Design doc |
| Shared template | `stacks/_common.yaml` | Next to its consumers; relative `extends.file` | Tested pattern |
| Env contract | `.env.example` | Compose reads `.env` from the project dir | Design doc |
| Ignore rules | `.gitignore` | Repo root | — |
| Secrets dir | `secrets/.gitkeep` | Docker secrets source for later phases | Design doc |
| Script library | `scripts/lib/common.sh` | Shared by all scripts | — |
| Host scripts | `scripts/host/{00-zfs-datasets,10-iommu-vfio,20-create-vm}.sh` | Execution boundary: Proxmox host | Clean proposal |
| VM scripts | `scripts/vm/{00-bootstrap,verify}.sh` | Execution boundary: guest VM | Clean proposal |
| Tree script | `scripts/mkdirs.sh` | Named in the design doc and roadmap | Design doc |
| CI helper | `scripts/ci/check-pinned-images.sh` | CI-only tooling | — |
| CI workflow | `.github/workflows/lint.yml` | GitHub Actions convention | — |
| Lint config | `.yamllint.yaml` | yamllint default lookup | — |
| Docs | `README.md`, `docs/README.md`, `docs/architecture.md`, `docs/runbooks/01-proxmox-host.md`, `docs/runbooks/02-vm-bootstrap.md` | Design doc `docs/`; Phase 5 adds more runbooks to `docs/runbooks/` | Roadmap Phase 5 criteria |

## Data and Control Flow
1. The owner clones the repo onto the Proxmox host (or copies `scripts/`) and runs:
   - `host/00-zfs-datasets.sh` (dry-run, then `--apply`)
   - `host/10-iommu-vfio.sh --apply`, then reboots and runs the runbook check (`dmesg | grep -e DMAR -e IOMMU`, `lspci -nnk -s $GPU_PCI` shows `Kernel driver in use: vfio-pci`)
   - `host/20-create-vm.sh --apply`, which creates the `media-data` directory mapping if missing, then the VM.
2. The owner installs Debian 13 from the ISO (runbook lists installer choices: SSH server, no desktop), clones the repo in the VM, runs `cp .env.example .env`, edits it, then runs `scripts/vm/00-bootstrap.sh --apply` and reboots.
3. `sudo scripts/mkdirs.sh` builds the `/data` tree and `APPDATA_ROOT`. Then `scripts/vm/verify.sh` must print all PASS. The owner pastes the output into `docs/runbooks/02-vm-bootstrap.md` under "Acceptance record" (or reports it back).
4. On every push, CI runs lint and the sandbox checks.

## Compatibility Constraints
- Docker Compose ≥ v2.20 (`include:` support). The runbook pins installation from Docker's official apt repo; CI uses the runner's Compose.
- Proxmox VE ≥ 8.4 (virtiofs directory mappings). The runbook tells the owner to check with `pveversion`, and `20-create-vm.sh` refuses on < 8.4.
- The VM kernel must be ≥ 6.2 for DG2. Debian 13 ships 6.12; `verify.sh` reports `uname -r` in the `gpu` detail.
- The scripts are bash ≥ 5 and must pass `shellcheck -x` with no warnings.
- Scripts must not assume GNU-only flags beyond Debian/Proxmox defaults (both are Debian-based).
- No image is referenced in Phase 1, but `check-pinned-images.sh` must already enforce `repo:tag` (tag ≠ `latest`) or a digest for every image in `docker compose config --images`.

## Failure Modes
| Failure Mode | Expected Behavior | Verification |
|--------------|-------------------|--------------|
| `.env` missing when running compose | Interpolation error names the variable (`${TZ:?}` style is not used in Phase 1 because stacks are empty) | CI copies `.env.example` → `.env` first |
| Pool `tank` missing | `00-zfs-datasets.sh` exits 1 with "pool tank not found" | Dry-run on a machine without ZFS exits 1 (CI-safe: `require_cmd zfs` fails with a clear message) |
| `tank/data` already has child datasets | Script warns, lists them, and explains that hardlinks fail across them; exits 1 | Runbook check |
| No or several A380s found | `10-iommu-vfio.sh` exits 1 and asks for `GPU_PCI` | Covered in runbook |
| The host's i915/xe driver claims the A380 before vfio | `options vfio-pci ids=…` + softdeps in `/etc/modprobe.d/vfio.conf`, then `update-initramfs -u -k all`; runbook check shows `vfio-pci` in use | Runbook expected output |
| i915 fails to initialize inside the VM (per owner reports) | Runbook fallback: set `vga: none` and `x-vga=1` on hostpci0, and check ReBAR is enabled in BIOS | `verify.sh gpu` FAIL detail points to the runbook section |
| VMID already exists | `20-create-vm.sh` exits 1 without changes | Guarded by `qm status` |
| virtiofs not mounted at boot | fstab `nofail` lets the VM boot; `verify.sh data-mount` FAIL (`findmnt -t virtiofs /data` empty) | verify.sh |
| Hardlink fails (cross-device) | `verify.sh hardlink` FAIL, naming the two paths and inode numbers | Sandbox test |
| `mkdirs.sh` re-run | No errors, no changes to existing ownership outside created dirs | Run twice in CI |
| Docker apt repo lacks the VM's codename | `00-bootstrap.sh` checks `curl -fsI https://download.docker.com/linux/debian/dists/$VERSION_CODENAME/Release`; on failure it exits 1 with the override hint `DOCKER_CODENAME=bookworm` (env var honored by the script) | Runbook troubleshooting |
| `vaapi-av1` FAIL although `gpu` passes | Driver too old or firmware missing; runbook troubleshooting lists `dpkg -l intel-media-va-driver-non-free` (needs ≥ 23.x for DG2 AV1 encode), `dmesg | grep -i -e guc -e huc` | verify.sh detail + runbook |
| Unpinned image added later | CI `check-pinned-images.sh` fails and prints the offending image | Fixture test in the Phase 1 sandbox run |

## Acceptance Checks
| Check | Command or Evidence | Required |
|-------|---------------------|----------|
| Compose tree valid | `cp -n .env.example .env; docker compose config -q` | true |
| 6 stacks included | `docker compose config --format json` (no error); `grep -c 'stacks/' compose.yaml` = 6 | true |
| extends works | Temp overlay test in the plan's verify step renders `unless-stopped` | true |
| Secrets ignored | `git check-ignore -q .env && git check-ignore -q secrets/test.key` | true |
| Pinned-tag check | `scripts/ci/check-pinned-images.sh` exits 0; the fixture with `:latest` exits 1 | true |
| Shell lint | `shellcheck -x scripts/**/*.sh` | true |
| YAML lint | `yamllint -s .` | true |
| Tree + hardlink (sandbox) | `DATA_ROOT=$(mktemp -d) SKIP_HW=1 scripts/mkdirs.sh && … scripts/vm/verify.sh` exits 0 | true |
| Host scripts dry-run | Each host script `--help` exits 0; dry-run output contains the required commands (plan verify greps) | true |
| Runbooks complete | Required headings are present (plan verify greps) | true |
| Real hardware | Owner's `verify.sh` output, all PASS | true (owner-run; recorded as a user_setup checkpoint) |

## Deliverables
### Compose skeleton
- **Path:** `compose.yaml`, `stacks/_common.yaml`, `stacks/{edge,media,arr,download,transcode,ops}.yaml`
- **Purpose:** the include tree and shared template.
- **Key Content:**
  - The header of each stack file names the phase that will fill it: edge→3, media→2, arr→2/4, download→2, transcode→4, ops→5.
- **Dependencies:** none. **Size:** ~60 lines total.

### Env and secrets contract
- **Path:** `.env.example`, `.gitignore`, `secrets/.gitkeep`
- **Key Content:**
  - `.env.example` holds TZ=America/New_York, PUID=1000, PGID=1000, UMASK=002, DOMAIN=example.com, DATA_ROOT=/data, APPDATA_ROOT=/opt/appdata, each with a comment.
  - `.gitignore` covers `.env`, `secrets/*` (except `!secrets/.gitkeep`), `*.log` and `.DS_Store`.
- **Size:** ~30 lines.

### Script library and data tree
- **Path:** `scripts/lib/common.sh`, `scripts/mkdirs.sh`
- **Key Content:** functions per the API contract.
- **Ownership:** `mkdirs.sh` runs `chown PUID:PGID` only when EUID=0. When not root, it logs `[WARN] not root: skipping chown` and continues, so the non-root CI sandbox run passes. Modes (`chmod 2775`) are always applied.
- **mkdirs leaves (14):**
  - `usenet/incomplete`
  - `usenet/complete/{tv,tv-4k,movies,movies-4k,music,anime}`
  - `media/{tv,tv-4k,movies,movies-4k,anime-tv,anime-movies,music}`
  - also `transcode/` and `$APPDATA_ROOT`. `transcode/` is created but not counted among the 14 leaves.
- **Size:** ~80 + ~60 lines.

### Host scripts
- **Path:** `scripts/host/00-zfs-datasets.sh`, `10-iommu-vfio.sh`, `20-create-vm.sh`
- **Key Content:** as in Key Decisions.
  - `00-zfs-datasets.sh` sets `recordsize=1M compression=lz4 atime=off xattr=sa` on `tank/data` and `compression=zstd` on `tank/backups`.
  - `20-create-vm.sh` runs, in order:
    1. `pvesh create /cluster/mapping/dir --id media-data --map node=<node>,path=/tank/data` (if missing).
    2. `qm create $VMID --name $VM_NAME --machine q35 --bios ovmf --cpu host --cores $VM_CORES --memory $VM_MEMORY --balloon 0 --scsihw virtio-scsi-single --scsi0 $VM_STORAGE:$VM_DISK_GB,iothread=1,discard=on,ssd=1 --efidisk0 $VM_STORAGE:1,efitype=4m,pre-enrolled-keys=0 --net0 virtio,bridge=$VM_BRIDGE --ide2 $ISO,media=cdrom --ostype l26 --agent enabled=1 --onboot 1`.
    3. `qm set $VMID --hostpci0 $GPU_PCI,pcie=1`, using the full GPU function address (e.g. `0000:03:00.0`). The Arc's audio device sits on a separate bus behind the card's PCIe switch and is not needed for transcoding, so it is not passed through; it is still bound to vfio by ID.
    4. `qm set $VMID --virtiofs0 $DIR_MAPPING_ID,cache=auto`.
  - `--balloon 0` is needed because PCI passthrough requires fixed memory.
- **Size:** ~60/~110/~110 lines.

### VM scripts
- **Path:** `scripts/vm/00-bootstrap.sh`, `scripts/vm/verify.sh`
- **00-bootstrap.sh content:**
  - Enables the `contrib non-free non-free-firmware` components in `/etc/apt/sources.list.d/debian.sources`.
  - Installs `firmware-intel-graphics` (falling back to `firmware-misc-nonfree` if the package is unknown), `intel-media-va-driver-non-free`, `vainfo`, `intel-gpu-tools`, `qemu-guest-agent`, `ca-certificates`, `curl`, `git`.
  - Sets up Docker's apt repo, then installs `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`.
  - Runs `usermod -aG docker,render,video $MEDIA_USER` and adds the fstab line.
  - Creates the `/data` mountpoint and runs `mount -a`.
  - Runs `docker network create proxy` if missing.
- **verify.sh content:** as in the API contract.
- **Size:** ~120 + ~140 lines.

### CI
- **Path:** `.github/workflows/lint.yml`, `.yamllint.yaml`, `scripts/ci/check-pinned-images.sh`
- **`.yamllint.yaml`:** extends `default`, disables `document-start`, sets `line-length` max 160, sets `truthy: {check-keys: false}` (GitHub Actions' `on:` key would otherwise fail `-s`), and ignores `.planning/`.
- **Workflow:** `ubuntu-latest`, steps in order: checkout; `cp .env.example .env`; `docker compose config -q`; pinned check; `shellcheck -x`; `pip install yamllint && yamllint -s .`; sandbox mkdirs+verify.

### Docs
- **Path:** `README.md`, `docs/README.md`, `docs/architecture.md`, `docs/runbooks/01-proxmox-host.md`, `docs/runbooks/02-vm-bootstrap.md`
- **Required headings:**
  - Host runbook: `## Prerequisites`, `## 1. BIOS settings`, `## 2. ZFS datasets`, `## 3. IOMMU and vfio`, `## 4. Directory mapping and VM`, `## 5. Troubleshooting`, `## Fallback: NFS instead of virtiofs`.
  - VM runbook: `## Prerequisites`, `## 1. Install Debian 13`, `## 2. Bootstrap`, `## 3. Data tree`, `## 4. Verify`, `## Acceptance record`, `## Troubleshooting`.
  - Architecture: `## Overview`, `## Repository layout`, `## Storage layout`, `## Networking and exposure`, `## Service template`.
- **Size:** runbooks ~150-200 lines each.

## Open Questions
| # | Question | Impact | Default Chosen by Spec | Planning Effect |
|---|----------|--------|------------------------|-----------------|
| 1 | Is the owner's Proxmox root on ZFS (systemd-boot) or ext4/LVM (GRUB)? | Non-blocking | Script auto-detects via `/etc/kernel/cmdline` | Handle both |
| 2 | Exact `qm set --virtiofs0` syntax on the owner's PVE version | Non-blocking | `--virtiofs0 <mapping>,cache=auto` (PVE 8.4+ docs); runbook gives the GUI path as fallback | Script prints the command in dry-run; runbook includes GUI steps |
| 3 | Does the owner's host also have an Intel iGPU using i915? | Non-blocking | vfio binding by device ID (56a5/4f92) only affects the A380, plus softdep ordering | No change |
| 4 | Timezone | Non-blocking | `America/New_York` placeholder in `.env.example`; the owner edits `.env` | No change |
| 5 | Where will the Twingate connector run (design open question)? | Non-blocking | Not a Phase 1 concern; Phase 3 decides | None |
| 6 | Exact `pvesh create /cluster/mapping/dir` argument shape | Non-blocking | `--id media-data --map node=$(hostname),path=/tank/data`; the script checks `pvesh get /cluster/mapping/dir/media-data` first; runbook gives the GUI path (Datacenter → Directory Mappings) as fallback | Script + runbook |

## Complexity Assessment

**Rating:** Complex

| Metric | Value |
|--------|-------|
| Requirements | 2 (14 sub-requirements) |
| Deliverables | 21 files (new: 20, modify: 1 `README.md`, config: 3) |
| Estimated waves | 3 |
| Estimated plans | 4 |
| Competing proposals | Recommended (already run: Hybrid selected) |

**Rationale:** there are many new files across two execution boundaries (Proxmox host and VM) plus CI. The host scripts are high-risk because they touch the bootloader, ZFS and VMs, so they need dry-run safety and literal runbooks. Real-hardware acceptance can't be automated and is handed to the owner through `verify.sh`.

**Recommended next step:** decompose into 4 plans across 3 waves:
1. Compose skeleton and env contract, together with the script library and host scripts.
2. mkdirs and the VM scripts and runbook.
3. verify.sh, CI, and the sandbox validation.

## Revision History
| # | Section | Change | Reason |
|---|---------|--------|--------|
| 1 | Key Decisions, Failure Modes | Added `options vfio-pci ids=` and `update-initramfs -u -k all` to the vfio binding | Critique #1 (CRITICAL): softdep alone doesn't bind the device |
| 2 | CI deliverable | `.yamllint.yaml` sets `truthy.check-keys: false` | Critique #2 (HIGH): the `on:` key fails `yamllint -s` |
| 3 | Script library deliverable | chown only when root; warn otherwise | Critique #3 (HIGH): non-root CI sandbox would fail |
| 4 | Open Questions | Added the pvesh mapping syntax with a check and GUI fallback; kept `--virtiofs0 <id>,cache=auto` (`dirid` is the default key in the PVE `virtiofs[n]` property) | Critique #4 (MED) |
| 5 | Failure Modes | Docker repo codename check with a `DOCKER_CODENAME` override; VAAPI driver-version troubleshooting | Critique #5 (MED) and the assumption on iHD version |
| 7 | Deliverables → Host scripts | hostpci0 passes the GPU function only; audio (separate bus on Arc) is vfio-bound but not passed through. Added `SYSROOT` test prefix and stub-tool testing | Planning review: Arc audio is not a function of the GPU device |
| 6 | — | **Rejected:** efidisk `:1` stays. The PVE docs use `<storage>:1,efitype=4m` in `qm set -efidisk0`; the size is ignored and PVE allocates the correct EFI vars size | Critique #6 (LOW) is incorrect |

Critique verdict after revisions: **PASS**. All 5 CRITICAL/HIGH/MED findings resolved; 1 LOW rejected with evidence.
