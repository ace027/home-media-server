#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

POOL="${POOL:-tank}"

usage() {
  cat <<EOF
Create the ZFS datasets this project needs on the Proxmox host:
$POOL/data (hardlink-safe media storage) and $POOL/backups.

Dry-run by default: prints the commands it would run. Pass --apply to
actually run them; --apply requires root.

Usage: 00-zfs-datasets.sh [--apply] [--help]

Environment variables (defaults):
  POOL=$POOL   ZFS pool name.
EOF
}

parse_common_args "$@"
load_env
require_root
require_cmd zfs

if ! zfs list -H -o name "$POOL" >/dev/null 2>&1; then
  die "pool $POOL not found"
fi

if zfs list -H -o name "$POOL/data" >/dev/null 2>&1; then
  children="$(zfs list -H -r -o name "$POOL/data" | grep -v "^${POOL}/data$" || true)"
  if [[ -n "$children" ]]; then
    log_error "child datasets break hardlinks: $children"
    exit 1
  fi
  log_info "$POOL/data exists"
else
  run zfs create -o recordsize=1M -o compression=lz4 -o atime=off -o xattr=sa "$POOL/data"
fi

if zfs list -H -o name "$POOL/backups" >/dev/null 2>&1; then
  log_info "$POOL/backups exists"
else
  run zfs create -o compression=zstd "$POOL/backups"
fi

log_info "next: run 10-iommu-vfio.sh"
