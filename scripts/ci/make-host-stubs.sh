#!/usr/bin/env bash
# shellcheck disable=SC2016
# (SC2016: the single-quoted stub bodies below are written verbatim into
# generated scripts on disk, where their $-expressions expand at stub
# runtime, not here.)
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<'EOF'
Create stub Proxmox/ZFS command-line tools so scripts/host/*.sh can be
exercised without real Proxmox/ZFS hardware.

Usage: make-host-stubs.sh <dir> [--help]

Creates <dir> and writes executable stub commands into it: zfs, lspci, qm,
pvesh, pveversion, hostname, pvesm. Each stub appends its invocation
(command name + args) to <dir>/calls.log. Prepend <dir> to PATH before
running a host script against these stubs.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

DIR="${1:-}"
if [[ -z "$DIR" ]]; then
  usage >&2
  exit 2
fi

mkdir -p "$DIR"

write_stub() {
  local name="$1" body="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "$0 $*" >> %q/calls.log\n' "$DIR"
    printf '%s\n' "$body"
  } > "$DIR/$name"
  chmod +x "$DIR/$name"
}

write_stub zfs '
case "$*" in
  "list -H -o name tank")
    echo "tank"
    exit 0
    ;;
  "list -H -o name tank/data")
    exit 1
    ;;
  "list -H -o name tank/backups")
    exit 1
    ;;
  "list -H -r -o name tank/data")
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

write_stub lspci '
case "$*" in
  "-Dnn -d 8086:56a5")
    echo "0000:03:00.0 VGA compatible controller [0300]: Intel Corporation DG2 [Arc A380] [8086:56a5] (rev 05)"
    exit 0
    ;;
  "-Dnn -d 8086:4f92")
    echo "0000:04:00.0 Audio device [0403]: Intel Corporation DG2 Audio Controller [8086:4f92]"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

write_stub qm '
case "$1" in
  status)
    id="$2"
    echo "Configuration file '"'"'nodes/pve/qemu-server/${id}.conf'"'"' does not exist" >&2
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
'

write_stub pvesh '
case "$*" in
  "get /cluster/mapping/dir/"*)
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
'

write_stub pveversion '
echo "pve-manager/9.0.6/49c767b70aeb6660 (running kernel: 6.14.8-2-pve)"
'

write_stub hostname '
echo "pve"
'

write_stub pvesm '
case "$*" in
  "status -storage local-zfs")
    echo "local-zfs zfspool active 1 1000000000 500000000"
    exit 0
    ;;
  "status -storage "*)
    exit 1
    ;;
  "list local --content iso")
    echo "local:iso/debian-13-amd64-netinst.iso iso 123456789"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

log_info "stub tools written to $DIR"
