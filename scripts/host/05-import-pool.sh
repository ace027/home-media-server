#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# FORCE_IMPORT and FIX_OWNERSHIP are deliberately environment-only: they are
# assigned before load_env, so a stray line in .env can never turn on a
# forced import or a recursive chown.
FORCE_IMPORT="${FORCE_IMPORT:-0}"
FIX_OWNERSHIP="${FIX_OWNERSHIP:-0}"

# .env next, then the remaining defaults, so .env values are not masked.
load_env
POOL="${POOL:-tank}"
SOURCE_POOL="${SOURCE_POOL:-$POOL}"
MEDIA_DATASET="${MEDIA_DATASET:-}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

usage() {
  cat <<EOF
Safely import an existing ZFS pool (migrated on its SSDs from another
server) as $POOL, inventory it, optionally consolidate its media dataset
into $POOL/data, and report/fix its ownership.

Dry-run by default: prints the commands it would run. Pass --apply to
actually run them; --apply requires root. Never imports with -f unless you
explicitly opt in; never destroys or overwrites data.

Usage: 05-import-pool.sh [--apply] [--help]

Environment variables (defaults):
  POOL=$POOL                 Pool name on this (new) host.
  SOURCE_POOL=\$POOL           Pool name it had on the old server.
  FORCE_IMPORT=$FORCE_IMPORT                 Set to 1 to pass -f to zpool import
                               (environment only; ignored in .env).
  MEDIA_DATASET=              Existing dataset (e.g. $POOL/media) to rename to
                               $POOL/data.
  FIX_OWNERSHIP=$FIX_OWNERSHIP               Set to 1 to chown/chmod mismatched files
                               (environment only; ignored in .env).
  PUID=1000                   Owner uid to enforce under $POOL/data.
  PGID=1000                   Owner gid to enforce under $POOL/data.

See docs/runbooks/01-proxmox-host.md section "1a. Migrating an existing
pool" for the full procedure.
EOF
}

parse_common_args "$@"
require_match FORCE_IMPORT "$FORCE_IMPORT" '^[01]$' "0 or 1"
require_match FIX_OWNERSHIP "$FIX_OWNERSHIP" '^[01]$' "0 or 1"
require_match PUID "$PUID" '^[0-9]+$' "a numeric uid"
require_match PGID "$PGID" '^[0-9]+$' "a numeric gid"
require_root
require_cmd zpool zfs

# --- 1: import (skipped if already imported) --------------------------------
if zpool list -H -o name "$POOL" >/dev/null 2>&1; then
  log_info "pool $POOL already imported"
else
  import_output="$(zpool import 2>&1 || true)"
  if ! printf '%s\n' "$import_output" | grep -qE "^[[:space:]]*pool: ${SOURCE_POOL}\$"; then
    die "pool $SOURCE_POOL not found among importable pools. On the old server run 'zpool export $SOURCE_POOL' before moving the drives, then check the disks are detected (lsblk)"
  fi

  import_args=(zpool import)
  if [[ "$FORCE_IMPORT" == "1" ]]; then
    log_warn "-f import is only safe once the old server no longer uses the pool"
    import_args+=(-f)
  fi
  import_args+=("$SOURCE_POOL")
  if [[ "$SOURCE_POOL" != "$POOL" ]]; then
    import_args+=("$POOL")
  fi
  run "${import_args[@]}"

  if [[ $APPLY -ne 1 ]]; then
    log_info "re-run after import (with --apply) to inventory the pool"
    exit 0
  fi
fi

# --- 2: inventory (read-only) ------------------------------------------------
zfs list -H -r -o name,used,avail,mountpoint,recordsize "$POOL" | while IFS=$'\t' read -r line; do
  log_info "  $line"
done
log_warn "do not run 'zpool upgrade $POOL' until you are sure you won't move the pool back to the old server"

# --- 3: data dataset ----------------------------------------------------------
if zfs list -H -o name "$POOL/data" >/dev/null 2>&1; then
  children="$(zfs list -H -r -o name "$POOL/data" | grep -v "^${POOL}/data\$" || true)"
  if [[ -n "$children" ]]; then
    die "child datasets under $POOL/data break hardlinks: $children; see runbook 01 section 1a for consolidation"
  fi
  if [[ -n "$MEDIA_DATASET" ]]; then
    log_info "MEDIA_DATASET=$MEDIA_DATASET ignored because $POOL/data already exists"
  fi
elif [[ -n "$MEDIA_DATASET" ]]; then
  if ! zfs list -H -o name "$MEDIA_DATASET" >/dev/null 2>&1; then
    die "MEDIA_DATASET=$MEDIA_DATASET not found"
  fi
  case "$MEDIA_DATASET" in
    "$POOL"/*)
      if [[ "${MEDIA_DATASET#"$POOL"/}" == */* ]]; then
        die "MEDIA_DATASET=$MEDIA_DATASET must be a direct child of $POOL"
      fi
      ;;
    *)
      die "MEDIA_DATASET=$MEDIA_DATASET must be a direct child of $POOL"
      ;;
  esac
  md_children="$(zfs list -H -r -o name "$MEDIA_DATASET" | grep -v "^${MEDIA_DATASET}\$" || true)"
  if [[ -n "$md_children" ]]; then
    die "MEDIA_DATASET=$MEDIA_DATASET has child datasets: $md_children; see runbook 01 section 1a, 'multiple datasets'"
  fi
  run zfs rename "$MEDIA_DATASET" "$POOL/data"
else
  log_info "depth-1 datasets under $POOL (excluding $POOL/backups):"
  zfs list -H -r -o name,used "$POOL" 2>/dev/null | while IFS=$'\t' read -r name used; do
    rest="${name#"$POOL"/}"
    if [[ "$name" == "$POOL"/* && "$rest" != */* && "$name" != "$POOL/backups" ]]; then
      log_info "  $name ($used)"
    fi
  done
  log_info "set MEDIA_DATASET=<pool>/<dataset> to rename your main media dataset to $POOL/data, or leave unset to have 00-zfs-datasets.sh create an empty one; see runbook section 1a"
fi

# --- 4: ownership --------------------------------------------------------------
if zfs list -H -o name "$POOL/data" >/dev/null 2>&1; then
  mnt="$(zfs get -H -o value mountpoint "$POOL/data" 2>/dev/null || true)"
  mounted="$(zfs get -H -o value mounted "$POOL/data" 2>/dev/null || true)"
  if [[ -z "$mnt" || "$mnt" == "none" || "$mnt" == "legacy" ]]; then
    log_warn "$POOL/data has no usable mountpoint ($mnt); ownership not checked"
  elif [[ "$mounted" != "yes" || ! -d "$mnt" ]]; then
    log_warn "$POOL/data not mounted at $mnt; ownership not checked (zfs mount $POOL/data, then re-run)"
  else
    first="$(find "$mnt" -xdev \( ! -uid "$PUID" -o ! -gid "$PGID" \) -print -quit 2>/dev/null || true)"
    if [[ -n "$first" ]]; then
      log_warn "found files under $mnt not owned by $PUID:$PGID (e.g. $first)"
      if [[ "$FIX_OWNERSHIP" == "1" ]]; then
        run chown -R "$PUID:$PGID" "$mnt"
        run chmod -R u=rwX,g=rwX,o=rX "$mnt"
        if [[ $APPLY -eq 1 ]]; then
          log_info "ownership fixed: $mnt is now $PUID:$PGID (re-run without --apply to confirm 'ownership OK')"
        fi
      else
        log_info "run: chown -R $PUID:$PGID $mnt"
        log_info "run: chmod -R u=rwX,g=rwX,o=rX $mnt"
        log_info "set FIX_OWNERSHIP=1 to apply automatically"
      fi
    else
      log_info "ownership OK"
    fi
  fi
fi

log_info "next: run 00-zfs-datasets.sh"
