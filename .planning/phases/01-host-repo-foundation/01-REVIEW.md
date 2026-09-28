# Phase 1: Host & Repo Foundation — Review Summary

## Result: PASSED

- **Cycles used**: 3 of 3
- **Mode**: Dynamic review panel (3 reviewers, domain rubrics)
- **Reviewers**: testing-qa-verification-specialist (Production Readiness), engineering-infrastructure-devops (Operational Readiness), engineering-security-engineer (Safety & Security)
- **Completed**: 2026-09-26
- **Fix commits**: `5d72178` (cycle 1), `0a01d43` (cycle 2)

## Findings Summary

| Category | Found | Resolved |
|----------|-------|----------|
| Blockers | 2 | 2 |
| Warnings (must-fix) | 9 | 9 |
| Suggestions fixed along the way | 17 | 17 |
| Suggestions deferred | 14 | — |

## Verdicts by Cycle

| Reviewer | Cycle 1 | Cycle 2 | Cycle 3 |
|----------|---------|---------|---------|
| testing-qa-verification-specialist | NEEDS WORK | NEEDS WORK | PASS |
| engineering-infrastructure-devops | NEEDS WORK | PASS | PASS |
| engineering-security-engineer | PASS | PASS | PASS |

## Findings Detail (must-fix)

| # | Severity | File | Issue | Fix Applied | Cycle Fixed |
|---|----------|------|-------|-------------|-------------|
| 1 | BLOCKER | scripts/vm/00-bootstrap.sh | Guard only checked `non-free-firmware`; the Debian 13 installer default (`main non-free-firmware`) never got `non-free`, so `intel-media-va-driver-non-free` failed to install | Per-component whole-word check (contrib, non-free, non-free-firmware); dies with `apt modernize-sources` hint on legacy sources.list; runbook output regenerated | 1 |
| 2 | BLOCKER | docs/runbooks/02-vm-bootstrap.md §1 | Setting a root password in the installer leaves `media` without sudo | Leave root password empty; `su -` fallback; `groups` check | 1 |
| 3 | WARNING | runbook 02 §2 | git not installed on netinst; `sudo git clone` left a root-owned checkout | Install git first; `install -d -o media`; clone as media | 1 |
| 4 | WARNING | .github/workflows/lint.yml | CI never dry-ran vfio/bootstrap, didn't assert outputs, no mkdirs re-run, no pinned-image negative test | Added fake-SYSROOT steps with output assertions, second mkdirs run, `nginx:latest` negative fixture | 1 |
| 5 | WARNING | scripts/host/10-iommu-vfio.sh | Failed initramfs/bootloader refresh never retried on re-run | `FORCE_REFRESH=1`; refreshes moved after all writes with separate `BOOT_CHANGED` tracking (cycle 2 fix); GRUB/cmdline edits self-verify; CI regression step | 1, 2 |
| 6 | WARNING | scripts/host/20-create-vm.sh | Half-configured VM was a dead end | `RESUME=1` (applies only missing hostpci0/virtiofs0; requires `name: $VM_NAME`); runbook §5 recovery | 1, 2 |
| 7 | WARNING | scripts/vm/verify.sh | Every hardlink failure reported as cross-device; stderr discarded | ln stderr in FAIL detail; `stat -L` device compare; runbook Permission-denied bullet | 1, 2 |
| 8 | WARNING | runbook 01 §1a step 0, .gitignore | Old-VM dumps (`_inspect.json`, `_compose-resolved.yml`) contain live secrets, world-readable, not ignored | Written under `umask 077`; dir 700; never-commit warning; revoke old Twingate/VPN creds; delete on old VM; gitignore entries | 1, 2 |
| 9 | WARNING | scripts/host/20-create-vm.sh | Existing dir mapping accepted without checking node/path | Reads `pvesh get` JSON, dies unless this node maps to the tank/data mountpoint; CI guard step | 2 |

Other fixes applied: `load_env` before defaults (`.env` values were ignored) with FORCE_IMPORT/FIX_OWNERSHIP/FORCE_REFRESH/RESUME environment-only; unreadable `.env` warns; ERR trap naming the failing step; mounted check before the ownership scan; `--is_mountpoint yes` on `tank-iso`; input validation for every value interpolated into shell strings (GPU_ID/AUDIO_ID/GPU_PCI, DOCKER_CODENAME, DIR_MAPPING_ID, DATA_ROOT, SYSROOT, VMID, PUID/PGID, 0/1 flags, mountpoint); `sudo DOCKER_CODENAME=` order; `/proc/cmdline` post-reboot check; §1a wording; docker-group root-equivalence note.

## Deferred Suggestions (not required for approval)

- vfio.conf / cmdline backups before overwrite (security, cycle 1 #3)
- `zpool import -N` then inspect mountpoints (security #4)
- `mv -n` in reorganize examples; exact per-folder delete commands (security #5)
- Docker apt key fingerprint check (security #9)
- Pin `actions/checkout` to a SHA; pin yamllint version (security #10)
- `APPDATA_ROOT` mode 2770 instead of 2775 (security #11)
- SYSROOT/MEDIA_USER environment-only (security N7, INFO)
- Bootloader detection via `proxmox-boot-tool status` / `/etc/kernel/proxmox-boot-uuids` (devops, cycles 1–3)
- Run the Docker repo curl check in dry-run too (devops)
- `timeout` around `vainfo` and surface its error (qa)
- `mkdirs.sh` warning when `/data` is not a mountpoint (qa)
- `pvesh get` non-"not found" errors fall through to create (security R1, devops S3)
- Validate SOURCE_POOL/POOL/MEDIA_DATASET/VM_NAME (security R2, R4)
- hostpci0 prefix warning false-positives on short/all-function forms; cosmetic mapping log/traceback; python3 required on fresh-host path (qa, devops)

## Outstanding Owner Acceptance (outside the review)

Success criteria 4 and 5 (`vainfo` encode entrypoints; virtiofs `/data` hardlink) need real hardware. Follow runbook 01 (from §1a) then runbook 02, run `scripts/vm/verify.sh` on the VM, and record `RESULT: 10 pass, 0 fail, 0 skip` in runbook 02's Acceptance record. GitHub issue #1 stays open until then.

## Post-Review Polish
Skipped by coordinator: the phase's scripts are hardware-facing and were just verified byte-for-byte against runbook outputs; a behaviour-neutral polish pass would reopen that surface. Run `/legion:polish` separately if wanted.
