# Plan 01-03 Summary: Data Tree Script, VM Bootstrap Script, and Runbooks

## Status: Complete

## Files Created
- `scripts/mkdirs.sh` — always-applying (no dry-run mode) script that builds
  the 14 TRaSH leaf directories plus `transcode/` under `DATA_ROOT`, and
  `APPDATA_ROOT`, with mode `2775` on every newly created path component
  (including newly created intermediate parents such as `usenet/` or
  `usenet/complete/`). Chowns to `PUID:PGID` only when `EUID == 0`; otherwise
  logs `[WARN] not root: skipping chown` once. Logs `created N, existing M`.
  `--apply` is accepted (per the shared CLI contract) but is a no-op logged
  as `mkdirs always applies`.
- `scripts/vm/00-bootstrap.sh` — dry-run-by-default Debian 13 VM bootstrap:
  enables `non-free-firmware` in `debian.sources` if missing, installs
  firmware/VA-API/tooling packages (falling back to `firmware-misc-nonfree`
  when `--apply` and `firmware-intel-graphics` isn't available), checks
  Docker's apt repo is reachable for `DOCKER_CODENAME` (dies with the
  `DOCKER_CODENAME=bookworm` hint on failure, `--apply` only), sets up
  Docker's apt repo and installs Docker + compose plugin, adds `MEDIA_USER`
  to `docker,render,video`, enables `qemu-guest-agent`, appends the virtiofs
  fstab line if missing, runs `mount -a`, and creates the `proxy` Docker
  network if absent. Dies if `ID != debian`, warns if not `trixie`, dies if
  `MEDIA_USER` is empty. All `/etc` paths honor `${SYSROOT}`.
- `docs/runbooks/01-proxmox-host.md` — literal host runbook: Prerequisites
  (PVE version, ISO upload with `pvesm list local --content iso`, storage
  check), BIOS settings, ZFS datasets, IOMMU/vfio, directory mapping and VM
  creation (script + GUI alternative), Troubleshooting (IOMMU groups, driver
  still bound to i915/xe, guest i915 init failure with the `x-vga=1`
  fallback, ReBAR check, PVE < 8.4), and an NFS fallback documenting
  `ALLOW_NFS=1 scripts/vm/verify.sh`. Every numbered step has a `bash`
  command block and an `Expected output:` block pasted verbatim from real
  dry-run runs against `scripts/ci/make-host-stubs.sh` stubs (temp-path
  prefixes stripped to show real `/etc/...` paths; the stub hostname `pve`
  replaced with `<your-node>` in the directory-mapping line). Hardware-only
  outputs (`dmesg`, `lspci -nnk`, ReBAR) are marked representative.
- `docs/runbooks/02-vm-bootstrap.md` — literal VM runbook: Debian 13 install
  choices and the `id media` uid/gid check, Bootstrap (dry-run then
  `--apply` then reboot, with the real captured dry-run output), Data tree
  (`sudo scripts/mkdirs.sh` real output, then `ls -la /data/media`), Verify
  (documents `scripts/vm/verify.sh`'s 10 ordered check IDs and the
  `RESULT: 10 pass, 0 fail, 0 skip` line, per plan 01-04's contract), an
  Acceptance record table (4 rows: `verify.sh` RESULT, hardlink on virtiofs,
  `vaapi-av1`, `gpu`/kernel version — empty cells for the owner), and
  Troubleshooting (`vaapi-av1` driver version + GuC/HuC, `data-mount`,
  `hardlink` cross-dataset/cache=never/NFS fallback, docker group re-login,
  Docker repo codename override).

## Verification Commands Run and Passed
```
bash -n scripts/mkdirs.sh && bash -n scripts/vm/00-bootstrap.sh && shellcheck -x scripts/mkdirs.sh scripts/vm/00-bootstrap.sh
d=$(mktemp -d) && DATA_ROOT=$d/data APPDATA_ROOT=$d/appdata scripts/mkdirs.sh && DATA_ROOT=$d/data APPDATA_ROOT=$d/appdata scripts/mkdirs.sh && test $(find $d/data -mindepth 1 -type d -empty | wc -l) -eq 15
d=$(mktemp -d) && mkdir -p $d/etc/apt/sources.list.d && printf 'VERSION_CODENAME=trixie\nID=debian\n' > $d/etc/os-release && printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: trixie trixie-updates\nComponents: main\n' > $d/etc/apt/sources.list.d/debian.sources && touch $d/etc/fstab && SYSROOT=$d MEDIA_USER=media scripts/vm/00-bootstrap.sh | grep -q 'DRY-RUN: docker network create proxy'
for h in '## Prerequisites' '## 1. BIOS settings' '## 2. ZFS datasets' '## 3. IOMMU and vfio' '## 4. Directory mapping and VM' '## 5. Troubleshooting' '## Fallback: NFS instead of virtiofs'; do grep -qF "$h" docs/runbooks/01-proxmox-host.md || exit 1; done
for h in '## Prerequisites' '## 1. Install Debian 13' '## 2. Bootstrap' '## 3. Data tree' '## 4. Verify' '## Acceptance record' '## Troubleshooting'; do grep -qF "$h" docs/runbooks/02-vm-bootstrap.md || exit 1; done
```
Plus every task-level `<verify>` block:
- Task 1: mode `2775` on `data/media/anime-movies`, idempotent second run
  prints `created 0`, and (added by this run to confirm the "chowns only as
  root" truth) a non-root run under the `ubuntu` uid printed
  `[WARN] not root: skipping chown` exactly once and left directories owned
  by `ubuntu:ubuntu` at `2775`.
- Task 2: the fresh-SYSROOT dry-run contains all seven required strings
  (`non-free-firmware`, `intel-media-va-driver-non-free`,
  `docker-compose-plugin`, the fstab line, `DRY-RUN: docker network create
  proxy`); the already-configured SYSROOT case shows no `sources` sed and no
  fstab append; the non-Debian case exits 1; the empty-`MEDIA_USER` case and
  the missing-`os-release` case both die with clear messages (spec's edge
  cases).
- Task 3: both heading sets present; `Expected output:` appears 11 times in
  the host runbook (≥4 required) and 5 times in the VM runbook (≥3
  required); all seven required content strings
  (`10-iommu-vfio.sh --apply`, `x-vga=1`, `RESULT: 10 pass, 0 fail, 0 skip`,
  `ALLOW_NFS=1`, `pvesm list local --content iso`, `id media`, `hardlink on
  virtiofs`) are present.

All commands exited 0. `min_lines` targets are met: `mkdirs.sh` 110 lines,
`00-bootstrap.sh` 141 lines, host runbook 342 lines, VM runbook 249 lines.

`git status --porcelain` after implementation shows only
`docs/runbooks/` and `scripts/mkdirs.sh` and `scripts/vm/` as new/untracked
— exactly `files_modified`; no `files_forbidden` path was touched.

## Decisions
- `mkdirs.sh` walks each leaf path's components under `DATA_ROOT` and
  chmod/chown-secures every component that didn't already exist (not just
  the leaf), matching the execution contract's "created path (and its
  created parents)" requirement — e.g. the first entry `usenet/incomplete`
  also secures the newly created `usenet/` parent, while a later entry like
  `usenet/complete/tv` only secures `usenet/complete` and `tv` since
  `usenet/` already exists by then.
- `00-bootstrap.sh` treats the Docker apt-repo reachability check specially:
  it only performs the real `curl -fsI` when `APPLY=1` (per the execution
  contract, "Only when `APPLY=1`"), but still prints it as a `DRY-RUN:` line
  via `run` in dry-run mode so the runbook's expected-output block shows it.
- The Docker `sources.list.d/docker.sources` file is written with
  `run_sh` using a heredoc (`cat > ... <<'DOCKERSOURCES' ... DOCKERSOURCES`)
  rather than a `printf` one-liner, because the desired content is
  multi-line deb822 and a heredoc keeps both the dry-run print and the
  `--apply` execution byte-identical without escaping newlines.
- Runbook "Expected output:" blocks are pasted verbatim from real dry-run
  runs of all three host scripts (`00-zfs-datasets.sh`, `10-iommu-vfio.sh`,
  `20-create-vm.sh`) and of `scripts/vm/00-bootstrap.sh` and
  `scripts/mkdirs.sh`, captured via `scripts/ci/make-host-stubs.sh` and a
  temp `SYSROOT` with `GenuineIntel` cpuinfo and an `/etc/kernel/cmdline`
  file (to exercise the systemd-boot cmdline path rather than GRUB). The
  temp-directory path prefix was stripped from the captured output (via
  `sed`) so the runbook shows the real `/etc/...` paths an owner would see,
  and the stub `hostname` output `pve` was replaced with `<your-node>` in
  the `pvesh create /cluster/mapping/dir` line, per the plan's instruction.
  Hardware-only outputs that cannot be captured in a sandbox (`dmesg`,
  `lspci -nnk` showing `vfio-pci`, the ReBAR `lspci -vv` grep) are marked
  "Representative" and use plausible, clearly-labeled sample lines.
- `scripts/vm/verify.sh` does not exist yet (it is plan 01-04's
  deliverable); the VM runbook's "Verify" section and Acceptance record
  document its contract exactly as specified in the spec (`API and Type
  Contracts` → verify.sh output, and this plan's execution contract), per
  the plan's explicit instruction to "document it by this contract."

## Issues
None. No verification command required a fix attempt.

## Errors
None. No host script was ever run with `--apply`; `mkdirs.sh` (which always
applies, by design and by spec) was only ever run against temporary
`DATA_ROOT`/`APPDATA_ROOT` trees under `mktemp -d`.

## Notes for Downstream Plans
- Plan 01-04 must implement `scripts/vm/verify.sh` to match exactly what
  `docs/runbooks/02-vm-bootstrap.md` documents: check IDs `gpu`,
  `vaapi-av1`, `vaapi-hevc`, `vaapi-h264`, `data-mount`, `tree`, `hardlink`,
  `docker`, `network`, `compose`, in that order, each printed as
  `PASS <id> ...` / `FAIL <id> ...` / `SKIP <id> ...`, ending with
  `RESULT: <n> pass, <n> fail, <n> skip`, and must honor `ALLOW_NFS=1` (also
  documented in the host runbook's NFS fallback) to accept `nfs`/`nfs4` for
  the `data-mount` check.
- Files touched are exactly `files_modified`:
  `scripts/mkdirs.sh`, `scripts/vm/00-bootstrap.sh`,
  `docs/runbooks/01-proxmox-host.md`, `docs/runbooks/02-vm-bootstrap.md`.
  No `files_forbidden` path was touched (verified via
  `git status --porcelain`).
