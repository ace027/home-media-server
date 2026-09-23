# Plan 01-02 Summary: Script Library & Proxmox Host Scripts

## Status: Complete

## Files Created
- `scripts/lib/common.sh` — shared bash library (sourced, not executed): `log_info`/`log_warn`/`log_error`, `die`, `parse_common_args`, `run`, `run_sh`, `require_root`, `require_cmd`, `load_env`, `REPO_ROOT`.
- `scripts/ci/make-host-stubs.sh` — generates stub `zfs`, `lspci`, `qm`, `pvesh`, `pveversion`, `hostname`, `pvesm` executables (each logging argv to `calls.log`) so the host scripts can be tested without Proxmox/ZFS hardware.
- `scripts/host/00-zfs-datasets.sh` — dry-run-by-default creation of `tank/data` (recordsize=1M, lz4, atime=off, xattr=sa) and `tank/backups` (zstd); refuses when the pool is missing or `tank/data` has child datasets.
- `scripts/host/10-iommu-vfio.sh` — detects the Arc A380 (8086:56a5) and its audio function (8086:4f92) via `lspci`, adds IOMMU kernel params for Intel or AMD CPUs (systemd-boot `cmdline` or GRUB), writes `/etc/modules-load.d/vfio.conf` and `/etc/modprobe.d/vfio.conf`, and rebuilds the initramfs only when something changed.
- `scripts/host/20-create-vm.sh` — validates PVE ≥ 8.4, storage, and ISO presence; refuses if the VMID already exists or the GPU can't be identified uniquely; creates the directory mapping, the q35/OVMF VM, GPU passthrough (`--hostpci0`), and the virtiofs share (`--virtiofs0`).

All five scripts/library files are executable where applicable and pass `shellcheck -x` with zero findings.

## Verification Commands Run and Passed
```
for f in scripts/lib/common.sh scripts/host/*.sh scripts/ci/make-host-stubs.sh; do bash -n "$f" || exit 1; done
shellcheck -x scripts/lib/common.sh scripts/host/*.sh scripts/ci/make-host-stubs.sh
for f in scripts/host/*.sh; do "$f" --help >/dev/null || exit 1; done
d=$(mktemp -d) && scripts/ci/make-host-stubs.sh "$d/bin" && PATH="$d/bin:$PATH" scripts/host/00-zfs-datasets.sh | grep -q 'DRY-RUN: zfs create -o recordsize=1M'
d=$(mktemp -d) && scripts/ci/make-host-stubs.sh "$d/bin" && PATH="$d/bin:$PATH" scripts/host/20-create-vm.sh | grep -q 'DRY-RUN: qm set 200 --hostpci0 0000:03:00.0,pcie=1'
```
Plus every task-level `<verify>` block in the plan (dry-run content checks, idempotent/already-configured SYSROOT re-run producing zero `DRY-RUN:` lines, and all negative/refusal cases: bogus arg → exit 2, unknown zfs child datasets → exit 1 with no create, no/several GPUs found → exit 1, `qm status` succeeding → exit 1, PVE < 8.4 → exit 1, missing storage/ISO → exit 1).

All commands exited 0 (or the expected non-zero code for refusal tests).

## Decisions
- `run_sh` string construction embeds already-resolved shell variables (e.g. `${VFIO_IDS}`, `${missing}`, file paths) directly into the printed/executed string at script-authoring time, rather than passing them as separate `printf` arguments, so dry-run output shows literal values instead of format placeholders — required for the plan's exact-string grep checks.
- `# shellcheck source=scripts/lib/common.sh` directives use a path relative to the shellcheck invocation directory (repo root), which is how ShellCheck resolves `source=` in this setup (confirmed empirically); a path relative to the linted file's own directory did not resolve.
- GPU/audio detection matches the spec's `lspci -Dnn -d <id>` approach; `GPU_PCI` overrides detection entirely when set, consistent with the spec's "GPU_PCI optional; auto-detected" contract and the "asks for GPU_PCI" failure-mode language.
- Idempotency for the vfio config files is content-equality based (exact desired text vs. current file contents), and for the cmdline/GRUB line is a whole-word "is this token already present" check — both avoid needless rewrites and initramfs rebuilds on re-run.

## Issues
None.

## Errors
None.

## Notes for Downstream Plans
- Plans 01-03 and 01-04 depend on `scripts/lib/common.sh`'s function contract (`log_*`, `die`, `parse_common_args`, `run`, `run_sh`, `require_root`, `require_cmd`, `load_env`, `REPO_ROOT`) exactly as documented in the spec's "API and Type Contracts" section; it is unchanged from that contract.
- No host script was run with `--apply` in this environment, per the plan's forbidden actions.
- Files touched are exactly `files_modified`: `scripts/lib/common.sh`, `scripts/host/00-zfs-datasets.sh`, `scripts/host/10-iommu-vfio.sh`, `scripts/host/20-create-vm.sh`, `scripts/ci/make-host-stubs.sh`. No `files_forbidden` paths were touched (verified via `git status --porcelain`, which shows only the new `scripts/` tree).

## Coordinator Post-Verification Fix
- Auto-remediated: `run()` in `scripts/lib/common.sh` printed dry-run commands with `$*`, so arguments containing shell metacharacters (e.g. `--boot "order=scsi0;ide2"`) were not copy-paste safe. It now single-quotes only arguments containing characters outside `[A-Za-z0-9_./:=,@%+-]`, so it prints `--boot 'order=scsi0;ide2'`. Round-trip via `eval` was verified. All plan verification commands and shellcheck still pass; the `--apply` path is unchanged.
