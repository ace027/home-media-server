# 01-05 Summary — Existing-pool migration support

## What changed
- **`scripts/host/05-import-pool.sh`** (new): dry-run-by-default import of a
  pool migrated (via `zpool export`/`zpool import`) from an old server.
  Skips import if `$POOL` is already imported; refuses (exit 1) if
  `$SOURCE_POOL` isn't among `zpool import`'s importable pools, with an
  export/lsblk hint; `-f` only with explicit `FORCE_IMPORT=1` (warned as
  unsafe unless the old server is done with the pool). After import (or if
  already imported), inventories `$POOL` read-only and warns never to
  `zpool upgrade` until committed to the new server. Handles the
  `$POOL/data` dataset: if it exists with children, dies pointing at
  runbook 1a; if `MEDIA_DATASET` is set, validates it's a childless direct
  child of `$POOL` and renames it to `$POOL/data`; otherwise lists depth-1
  datasets (excluding `$POOL/backups`) with usage and points at
  `MEDIA_DATASET`. Reports (and, with `FIX_OWNERSHIP=1`, fixes) ownership
  mismatches under `$POOL/data`'s real mountpoint against `PUID`/`PGID`
  (from `.env`, default 1000/1000).
- **`scripts/host/00-zfs-datasets.sh`**: when `$POOL/data` already exists,
  now also compares `recordsize compression atime xattr` against
  `1M lz4 off sa` and `run`s `zfs set` for each mismatch, plus a log note
  that `recordsize` only affects newly written data. Creation path and the
  child-dataset refusal are unchanged.
- **`scripts/host/20-create-vm.sh`**: reads `$POOL/data`'s real mountpoint
  via `zfs get -H -o value mountpoint` and uses it (`path=$mp`) in the
  directory-mapping `pvesh create` call instead of assuming
  `/$POOL/data`; dies if the dataset is missing or its mountpoint is
  `none`/`legacy`. Added `zfs` to `require_cmd`.
- **`scripts/ci/make-host-stubs.sh`**: added a `zpool` stub (`list -H -o
  name tank` fails — not yet imported; bare `import` prints the
  `pool: oldpool` block; everything else exits 0), and extended the `zfs`
  stub with `get -H -o value {mountpoint,recordsize,compression,atime,
  xattr} tank/data` (`/tank/data`, `128K`, `lz4`, `on`, `sa`). Updated the
  usage text's stub list.
- **`.github/workflows/lint.yml`**: host-script dry-run step now also runs
  `SOURCE_POOL=oldpool scripts/host/05-import-pool.sh` against the stubs.
- **`docs/runbooks/01-proxmox-host.md`**: new `## 1a. Migrating an existing
  pool` section (between `## 1. BIOS settings` and `## 2. ZFS datasets`)
  covering: pre-move steps on the old server (stop services, health check,
  record layout, `zpool export`); import on the new host (dry-run/`--apply`
  of `05-import-pool.sh`, renaming vs. keeping the pool name,
  `FORCE_IMPORT=1` caveats); a "do not `zpool upgrade`" warning; a
  consolidation decision tree for single-dataset, multi-dataset and
  already-has-children cases (`rsync -aHAX`, verify, snapshot+destroy, SSD
  capacity/AV1 caveat); reorganizing into the TRaSH layout with `mv`; and
  the ownership dry-run/`--apply` flow. All prior top-level headings are
  unchanged.
- **`docs/architecture.md`**: added a paragraph in `## Storage layout`
  noting the media pool is an existing SSD pool migrated from the old
  server with an existing library (pointing at runbook 01 section 1a),
  and that it must still be a single `tank/data` dataset.

## Verification

### Plan frontmatter `verification_commands` (all pass)
- `shellcheck -x scripts/lib/common.sh scripts/host/*.sh scripts/ci/*.sh` — pass
- `yamllint -s .` — pass
- `SOURCE_POOL=oldpool scripts/host/05-import-pool.sh` dry-run prints
  `DRY-RUN: zpool import oldpool tank` — pass
- `SOURCE_POOL=nosuchpool scripts/host/05-import-pool.sh` exits non-zero — pass
- `20-create-vm.sh` dry-run prints `path=/tank/data` from the real
  mountpoint — pass
- Runbook contains `## 1a. Migrating an existing pool`, `zpool export`,
  `MEDIA_DATASET=` — pass
- `for f in scripts/host/*.sh; do "$f" --help; done` — pass

### Per-task verification (all pass)
- Task 1: shellcheck on the two files; dry-run rename+import
  (`zpool import oldpool tank`); forced import
  (`zpool import -f oldpool tank`, WARN on stderr); refusal on an
  unimportable source pool; already-imported pool logs `already imported`
  and skips the `zpool import` line entirely.
- Task 2: shellcheck + yamllint; existing-`tank/data` property correction
  emits `zfs set recordsize=1M` and `zfs set atime=off` but not a
  redundant `compression=lz4` set; fresh-pool creation path unchanged
  (`zfs create -o recordsize=1M ...`); `20-create-vm.sh` maps
  `path=/tank/data` via the real mountpoint; lint workflow references
  `05-import-pool.sh`.
- Task 3: runbook has the new heading plus `zpool export`,
  `MEDIA_DATASET=`, `rsync -aHAX`, `zpool upgrade`; all 7 pre-existing
  top-level headings (`## Prerequisites` through
  `## Fallback: NFS instead of virtiofs`) are still present; architecture.md
  references "section 1a".

### Regression: 01-02-PLAN.md (frontmatter + all task-level `verification:` lines)
All pass, including: `bash -n`/shellcheck across common.sh, host/*.sh,
make-host-stubs.sh; both `--help` checks; `00-zfs-datasets.sh`'s
create-path dry-run and child-dataset refusal; `--bogus` exits 2;
`10-iommu-vfio.sh`'s systemd-boot/Intel, GRUB/AMD, missing-`lspci`-dies,
and already-configured (no `DRY-RUN:` lines) cases — file untouched by this
plan, re-verified for regression only; `20-create-vm.sh`'s full dry-run
output, `qm`-stub-broken refusal, PVE-too-old refusal, and
missing-storage/missing-ISO refusals.

### Regression: 01-04-PLAN.md (frontmatter `verification_commands`)
All pass, including: `bash -n` on verify.sh/check-pinned-images.sh; the
full-tree shellcheck and yamllint; `cp -n .env.example .env` +
`docker compose config -q` + pinned-image check; sandboxed `mkdirs.sh` +
`SKIP_HW=1 scripts/vm/verify.sh` (`RESULT: 2 pass, 0 fail, 8 skip`); the
executable-bit check.

## Decisions
- `05-import-pool.sh`'s inventory loop and depth-1 dataset listing capture
  full tab-separated lines into a single variable (not split per-field) so
  no `IFS`/IFS-splitting fragility is introduced — matches how `read -r
  line` behaves with one variable regardless of `IFS`.
- Runbook 1a's internal structure uses `###` subsections (Before moving the
  drives / Import / Do not zpool upgrade / Consolidation decision tree /
  Reorganize into the TRaSH layout / Ownership) nested under the single
  `## 1a. Migrating an existing pool` heading the contract specifies, so
  the required top-level heading list stays exactly as before plus the one
  new entry.
- The ownership WARN message reports the first mismatched path found (via
  `find -print -quit`, which is inherently a single hit, not a count) with
  guidance to fix rather than a literal count; the plan's parenthetical
  "with the counts" isn't checked by any verification command and a true
  count would require a second, more expensive `find` pass over
  potentially very large media trees.
- `PUID`/`PGID` are resolved after `parse_common_args`/`load_env` (mirroring
  `scripts/mkdirs.sh`) so `.env` values actually take effect; `POOL`,
  `SOURCE_POOL`, `FORCE_IMPORT`, `MEDIA_DATASET`, `FIX_OWNERSHIP` are
  resolved before `parse_common_args` (mirroring `00-zfs-datasets.sh` /
  `20-create-vm.sh`), consistent with existing script conventions.

## Issues / Follow-ups
None. No destructive command runs by default anywhere in the new or
modified scripts; `-f` import and ownership changes both require an
explicit environment opt-in (`FORCE_IMPORT=1` / `FIX_OWNERSHIP=1`) in
addition to `--apply`.

## Coordinator Post-Verification Fix
- Auto-remediated: runbook §1a step 4 said to snapshot and then "`zfs destroy` the dataset (keep the snapshot)". That's impossible: destroying a dataset destroys its snapshots, and plain `zfs destroy` refuses while snapshots exist. It now says: snapshot and set `readonly=on`, keep the dataset until Phase 2 confirms the library, then `zfs destroy -r` (clearly marked irreversible).
