#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

GPU_PCI="${GPU_PCI:-}"
GPU_ID="${GPU_ID:-8086:56a5}"
AUDIO_ID="${AUDIO_ID:-8086:4f92}"
SYSROOT="${SYSROOT:-}"

usage() {
  cat <<EOF
Configure IOMMU and bind the Intel Arc A380 (and its audio function) to
vfio-pci, so it can be passed through to the media VM. Edits the kernel
cmdline (systemd-boot or GRUB, whichever is present), writes
/etc/modules-load.d/vfio.conf and /etc/modprobe.d/vfio.conf, and rebuilds
the initramfs if anything changed.

Dry-run by default: prints the commands and file changes it would make.
Pass --apply to actually make them; --apply requires root. A reboot is
required after --apply for the new binding to take effect.

Usage: 10-iommu-vfio.sh [--apply] [--help]

Environment variables (defaults):
  GPU_PCI=<auto-detected>   PCI address of the GPU (e.g. 0000:03:00.0).
                            Set this to override auto-detection, or to
                            resolve an ambiguous/failed detection.
  GPU_ID=$GPU_ID           PCI vendor:device ID of the Arc A380.
  AUDIO_ID=$AUDIO_ID           PCI vendor:device ID of the A380's audio function.
  SYSROOT=<empty>           Root prefix for system files (for testing).
EOF
}

parse_common_args "$@"
load_env
require_root
require_cmd lspci

# --- 1/2: detect the GPU -----------------------------------------------
detect_addr() {
  # Prints the PCI address (first field) of every lspci match for the
  # given vendor:device id, one per line.
  local id="$1"
  lspci -Dnn -d "$id" 2>/dev/null | awk '{print $1}'
}

if [[ -n "$GPU_PCI" ]]; then
  log_info "using GPU_PCI override: $GPU_PCI"
else
  gpu_matches="$(detect_addr "$GPU_ID")"
  gpu_count=0
  if [[ -n "$gpu_matches" ]]; then
    gpu_count=$(printf '%s\n' "$gpu_matches" | wc -l)
  fi
  if [[ "$gpu_count" -eq 0 ]]; then
    die "no Arc A380 ($GPU_ID) found; set GPU_PCI"
  elif [[ "$gpu_count" -gt 1 ]]; then
    die "multiple Arc A380 candidates found for $GPU_ID: $(tr '\n' ' ' <<< "$gpu_matches"); set GPU_PCI"
  fi
  GPU_PCI="$gpu_matches"
  log_info "detected GPU: $GPU_PCI"
fi

# --- 3: detect the audio function --------------------------------------
audio_matches="$(detect_addr "$AUDIO_ID")"
if [[ -z "$audio_matches" ]]; then
  log_warn "no audio device ($AUDIO_ID) found; binding GPU only"
  VFIO_IDS="$GPU_ID"
else
  audio_addr="$(printf '%s\n' "$audio_matches" | head -n1)"
  log_info "detected audio: $audio_addr"
  VFIO_IDS="$GPU_ID,$AUDIO_ID"
fi

# --- 4: CPU vendor -> IOMMU cmdline params ------------------------------
cpuinfo="${SYSROOT}/proc/cpuinfo"
[[ -f "$cpuinfo" ]] || die "cpuinfo not found at $cpuinfo"
vendor="$(grep -m1 -o -E 'GenuineIntel|AuthenticAMD' "$cpuinfo" || true)"
case "$vendor" in
  GenuineIntel)
    IOMMU_PARAMS="intel_iommu=on iommu=pt"
    ;;
  AuthenticAMD)
    IOMMU_PARAMS="iommu=pt"
    ;;
  *)
    die "unsupported or undetected CPU vendor in $cpuinfo"
    ;;
esac
log_info "CPU vendor: $vendor -> params: $IOMMU_PARAMS"

# --- 5: bootloader cmdline ----------------------------------------------
CHANGED=0

missing_params() {
  # Prints the params (from IOMMU_PARAMS) not already present as whole
  # words in the given string.
  local haystack=" $1 " p
  for p in $IOMMU_PARAMS; do
    case "$haystack" in
      *" $p "*) ;;
      *) printf '%s ' "$p" ;;
    esac
  done
}

cmdline_file="${SYSROOT}/etc/kernel/cmdline"
grub_file="${SYSROOT}/etc/default/grub"

if [[ -f "$cmdline_file" ]]; then
  current="$(cat "$cmdline_file")"
  missing="$(missing_params "$current")"
  missing="${missing% }"
  if [[ -n "$missing" ]]; then
    run_sh "sed -i 's/\$/ ${missing}/' \"$cmdline_file\""
    run proxmox-boot-tool refresh
    CHANGED=1
  else
    log_info "cmdline already configured"
  fi
elif [[ -f "$grub_file" ]]; then
  current="$(grep -m1 '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/')"
  missing="$(missing_params "$current")"
  missing="${missing% }"
  if [[ -n "$missing" ]]; then
    run_sh "sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=\")(.*)(\")\$/\\1\\2 ${missing}\\3/' \"$grub_file\""
    run update-grub
    CHANGED=1
  else
    log_info "cmdline already configured"
  fi
else
  die "no supported bootloader config found"
fi

# --- 6: /etc/modules-load.d/vfio.conf ------------------------------------
modules_file="${SYSROOT}/etc/modules-load.d/vfio.conf"
modules_desired="$(printf 'vfio\nvfio_iommu_type1\nvfio_pci\n')"
modules_current=""
[[ -f "$modules_file" ]] && modules_current="$(cat "$modules_file")"
if [[ "$modules_current" != "${modules_desired%$'\n'}" ]]; then
  run_sh "mkdir -p \"$(dirname "$modules_file")\" && printf 'vfio\\nvfio_iommu_type1\\nvfio_pci\\n' > \"$modules_file\""
  CHANGED=1
fi

# --- 7: /etc/modprobe.d/vfio.conf ----------------------------------------
modprobe_file="${SYSROOT}/etc/modprobe.d/vfio.conf"
modprobe_desired="options vfio-pci ids=${VFIO_IDS}
softdep i915 pre: vfio-pci
softdep xe pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci"
modprobe_current=""
[[ -f "$modprobe_file" ]] && modprobe_current="$(cat "$modprobe_file")"
if [[ "$modprobe_current" != "$modprobe_desired" ]]; then
  run_sh "mkdir -p \"$(dirname "$modprobe_file")\" && printf 'options vfio-pci ids=${VFIO_IDS}\\nsoftdep i915 pre: vfio-pci\\nsoftdep xe pre: vfio-pci\\nsoftdep snd_hda_intel pre: vfio-pci\\n' > \"$modprobe_file\""
  CHANGED=1
fi

# --- 8: rebuild initramfs if anything changed ----------------------------
if [[ "$CHANGED" -eq 1 ]]; then
  run update-initramfs -u -k all
  log_warn "reboot required for the new IOMMU/vfio configuration to take effect"
  log_info "after reboot, verify with: dmesg | grep -e DMAR -e IOMMU"
  log_info "after reboot, verify with: lspci -nnk -s ${GPU_PCI} (expect: Kernel driver in use: vfio-pci)"
else
  log_info "no changes needed; A380 ($GPU_PCI) already configured for vfio-pci"
fi
