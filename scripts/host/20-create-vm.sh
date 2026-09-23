#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

VMID="${VMID:-200}"
VM_NAME="${VM_NAME:-media-01}"
VM_CORES="${VM_CORES:-8}"
VM_MEMORY="${VM_MEMORY:-20480}"
VM_STORAGE="${VM_STORAGE:-local-zfs}"
VM_DISK_GB="${VM_DISK_GB:-64}"
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
ISO="${ISO:-local:iso/debian-13-amd64-netinst.iso}"
DIR_MAPPING_ID="${DIR_MAPPING_ID:-media-data}"
POOL="${POOL:-tank}"
GPU_PCI="${GPU_PCI:-}"
GPU_ID="${GPU_ID:-8086:56a5}"

usage() {
  cat <<EOF
Create the media VM on Proxmox: a Debian 13 (q35/OVMF) guest with the Arc
A380 passed through and the tank/data ZFS dataset shared in via virtiofs.

Dry-run by default: prints the commands it would run. Pass --apply to
actually run them; --apply requires root.

Usage: 20-create-vm.sh [--apply] [--help]

Environment variables (defaults):
  VMID=$VMID
  VM_NAME=$VM_NAME
  VM_CORES=$VM_CORES
  VM_MEMORY=$VM_MEMORY
  VM_STORAGE=$VM_STORAGE
  VM_DISK_GB=$VM_DISK_GB
  VM_BRIDGE=$VM_BRIDGE
  ISO=$ISO
  DIR_MAPPING_ID=$DIR_MAPPING_ID
  POOL=$POOL
  GPU_PCI=<auto-detected>   PCI address of the GPU (e.g. 0000:03:00.0).
  GPU_ID=$GPU_ID           PCI vendor:device ID used for auto-detection.
EOF
}

parse_common_args "$@"
load_env
require_root
require_cmd qm pvesh pveversion pvesm lspci zfs

# --- 1: detect the GPU (unless GPU_PCI is set) --------------------------
if [[ -z "$GPU_PCI" ]]; then
  gpu_matches="$(lspci -Dnn -d "$GPU_ID" 2>/dev/null | awk '{print $1}')"
  gpu_count=0
  [[ -n "$gpu_matches" ]] && gpu_count=$(printf '%s\n' "$gpu_matches" | wc -l)
  if [[ "$gpu_count" -eq 0 ]]; then
    die "no Arc A380 ($GPU_ID) found; set GPU_PCI"
  elif [[ "$gpu_count" -gt 1 ]]; then
    die "multiple Arc A380 candidates found for $GPU_ID: $(tr '\n' ' ' <<< "$gpu_matches"); set GPU_PCI"
  fi
  GPU_PCI="$gpu_matches"
  log_info "detected GPU: $GPU_PCI"
fi

# --- 2: PVE version >= 8.4 ----------------------------------------------
pve_version_line="$(pveversion)"
pve_version="$(printf '%s\n' "$pve_version_line" | sed -n 's#^pve-manager/\([0-9]*\.[0-9]*\).*#\1#p')"
[[ -n "$pve_version" ]] || die "could not parse PVE version from: $pve_version_line"
pve_major="${pve_version%%.*}"
pve_minor="${pve_version##*.}"
if (( pve_major < 8 || (pve_major == 8 && pve_minor < 4) )); then
  die "PVE $pve_version is older than the required 8.4 ($pve_version_line)"
fi
log_info "PVE version: $pve_version"

# --- 2a: storage exists ---------------------------------------------------
if ! pvesm status -storage "$VM_STORAGE" >/dev/null 2>&1; then
  die "storage $VM_STORAGE not found; set VM_STORAGE (e.g. local-lvm on non-ZFS-root hosts); see pvesm status"
fi

# --- 2b: ISO is uploaded ---------------------------------------------------
iso_store="${ISO%%:*}"
if ! pvesm list "$iso_store" --content iso 2>/dev/null | grep -qF "$ISO"; then
  die "ISO $ISO not found; upload the Debian 13 netinst ISO and set ISO=local:iso/<actual-filename>.iso (real names include the point release, e.g. debian-13.1.0-amd64-netinst.iso)"
fi

# --- 3: VMID must not already exist ---------------------------------------
if qm status "$VMID" >/dev/null 2>&1; then
  die "VMID $VMID already exists"
fi

# --- 4: directory mapping --------------------------------------------------
mp="$(zfs get -H -o value mountpoint "$POOL/data" 2>/dev/null)" || die "dataset $POOL/data not found; run 05-import-pool.sh / 00-zfs-datasets.sh first"
if [[ "$mp" == "none" || "$mp" == "legacy" ]]; then
  die "dataset $POOL/data not found; run 05-import-pool.sh / 00-zfs-datasets.sh first"
fi

if ! pvesh get "/cluster/mapping/dir/$DIR_MAPPING_ID" >/dev/null 2>&1; then
  run pvesh create /cluster/mapping/dir --id "$DIR_MAPPING_ID" --map "node=$(hostname),path=$mp"
fi

# --- 5: create the VM -------------------------------------------------------
run qm create "$VMID" --name "$VM_NAME" --machine q35 --bios ovmf --cpu host \
  --cores "$VM_CORES" --memory "$VM_MEMORY" --balloon 0 \
  --scsihw virtio-scsi-single --scsi0 "$VM_STORAGE:$VM_DISK_GB,iothread=1,discard=on,ssd=1" \
  --efidisk0 "$VM_STORAGE:1,efitype=4m,pre-enrolled-keys=0" \
  --net0 "virtio,bridge=$VM_BRIDGE" --ide2 "$ISO,media=cdrom" \
  --boot "order=scsi0;ide2" --ostype l26 --agent enabled=1 --onboot 1

# --- 6: GPU passthrough ------------------------------------------------------
run qm set "$VMID" --hostpci0 "$GPU_PCI,pcie=1"

# --- 7: virtiofs share -------------------------------------------------------
run qm set "$VMID" --virtiofs0 "$DIR_MAPPING_ID,cache=auto"

# --- 8: next steps ------------------------------------------------------------
log_info "next: start VM $VMID, install Debian 13, then follow docs/runbooks/02-vm-bootstrap.md"
log_info "fallback: if the guest's i915 fails to initialise, run:"
log_info "  qm set $VMID --vga none"
log_info "  qm set $VMID --hostpci0 $GPU_PCI,pcie=1,x-vga=1"
