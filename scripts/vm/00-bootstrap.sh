#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SYSROOT="${SYSROOT:-}"
DIR_MAPPING_ID="${DIR_MAPPING_ID:-media-data}"
DATA_ROOT="${DATA_ROOT:-/data}"
MEDIA_USER="${MEDIA_USER:-${SUDO_USER:-}}"

usage() {
  cat <<EOF
Bootstrap the Debian 13 media VM: enable non-free-firmware, install the
Intel VA-API driver and tools, install Docker from Docker's apt repo, add
$MEDIA_USER to the docker/render/video groups, mount /data via virtiofs, and
create the external "proxy" Docker network.

Dry-run by default: prints the commands and file changes it would make.
Pass --apply to actually make them; --apply requires root. Reboot after
--apply for group membership and driver changes to take full effect.

Usage: 00-bootstrap.sh [--apply] [--help]

Environment variables (defaults):
  DIR_MAPPING_ID=$DIR_MAPPING_ID   Proxmox directory mapping id for /data.
  DATA_ROOT=$DATA_ROOT             Mountpoint for the virtiofs share.
  MEDIA_USER=<\$SUDO_USER>          User to add to docker/render/video.
  DOCKER_CODENAME=<auto>           Override the Docker apt repo suite name
                                    if the VM's codename isn't yet supported
                                    upstream (e.g. DOCKER_CODENAME=bookworm).
  SYSROOT=<empty>                   Root prefix for system files (testing).
EOF
}

parse_common_args "$@"
load_env
require_root

[[ -n "$MEDIA_USER" ]] || die "MEDIA_USER is empty; set MEDIA_USER or run via sudo (SUDO_USER)"

os_release="${SYSROOT}/etc/os-release"
[[ -f "$os_release" ]] || die "os-release not found at $os_release"

os_id="$(grep -m1 '^ID=' "$os_release" | cut -d= -f2- | tr -d '"')"
os_codename="$(grep -m1 '^VERSION_CODENAME=' "$os_release" | cut -d= -f2- | tr -d '"')"
[[ "$os_id" == "debian" ]] || die "this script only supports Debian (found ID=$os_id)"
if [[ "$os_codename" != "trixie" ]]; then
  log_warn "expected Debian 13 (trixie), found VERSION_CODENAME=$os_codename"
fi

DOCKER_CODENAME="${DOCKER_CODENAME:-$os_codename}"

# --- 1: enable non-free-firmware in the Debian sources -------------------
sources_file="${SYSROOT}/etc/apt/sources.list.d/debian.sources"
if [[ -f "$sources_file" ]]; then
  if grep -q '^Components:' "$sources_file" && ! grep -q '^Components:.*non-free-firmware' "$sources_file"; then
    run_sh "sed -i -E 's/^Components:.*/Components: main contrib non-free non-free-firmware/' \"$sources_file\""
  else
    log_info "non-free-firmware already enabled in $sources_file"
  fi
else
  log_warn "debian.sources not found at $sources_file; skipping firmware component check"
fi

# --- 2: apt update --------------------------------------------------------
run apt-get update

# --- 3: firmware, VA driver, tools ---------------------------------------
firmware_pkg="firmware-intel-graphics"
if [[ $APPLY -eq 1 ]] && ! apt-cache show firmware-intel-graphics >/dev/null 2>&1; then
  log_warn "firmware-intel-graphics not found; falling back to firmware-misc-nonfree"
  firmware_pkg="firmware-misc-nonfree"
fi
run apt-get install -y "$firmware_pkg" intel-media-va-driver-non-free vainfo intel-gpu-tools qemu-guest-agent ca-certificates curl git

# --- 4: Docker apt repo reachability check --------------------------------
docker_release_url="https://download.docker.com/linux/debian/dists/${DOCKER_CODENAME}/Release"
if [[ $APPLY -eq 1 ]]; then
  if ! curl -fsI --retry 2 --max-time 15 "$docker_release_url" >/dev/null; then
    die "cannot reach Docker repo for $DOCKER_CODENAME (check network/proxy first; if the codename is unsupported, rerun with DOCKER_CODENAME=bookworm)"
  fi
else
  run curl -fsI --retry 2 --max-time 15 "$docker_release_url"
fi

# --- 5: Docker apt repo setup ---------------------------------------------
keyring_dir="${SYSROOT}/etc/apt/keyrings"
keyring_file="$keyring_dir/docker.asc"
run install -m 0755 -d "$keyring_dir"
run curl -fsSL https://download.docker.com/linux/debian/gpg -o "$keyring_file"

docker_sources_file="${SYSROOT}/etc/apt/sources.list.d/docker.sources"
docker_sources_desired="Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${DOCKER_CODENAME}
Components: stable
Signed-By: ${keyring_file}"
docker_sources_current=""
[[ -f "$docker_sources_file" ]] && docker_sources_current="$(cat "$docker_sources_file")"
if [[ "$docker_sources_current" != "$docker_sources_desired" ]]; then
  run_sh "mkdir -p \"$(dirname "$docker_sources_file")\" && cat > \"$docker_sources_file\" <<'DOCKERSOURCES'
$docker_sources_desired
DOCKERSOURCES"
else
  log_info "$docker_sources_file already up to date"
fi

# --- 6: install Docker ------------------------------------------------------
run apt-get update
run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# --- 7: group membership ----------------------------------------------------
run usermod -aG docker,render,video "$MEDIA_USER"

# --- 8: qemu-guest-agent -----------------------------------------------------
run systemctl enable --now qemu-guest-agent

# --- 9: virtiofs mount ------------------------------------------------------
run mkdir -p "$DATA_ROOT"

fstab_file="${SYSROOT}/etc/fstab"
fstab_line="$DIR_MAPPING_ID $DATA_ROOT virtiofs defaults,nofail 0 0"
if [[ -f "$fstab_file" ]] && grep -q "^${DIR_MAPPING_ID} " "$fstab_file"; then
  log_info "fstab already has a $DIR_MAPPING_ID entry"
else
  run_sh "printf '%s\\n' \"$fstab_line\" >> \"$fstab_file\""
fi

# --- 10: mount ---------------------------------------------------------------
run mount -a

# --- 11: proxy Docker network -------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker network inspect proxy >/dev/null 2>&1; then
  log_info "docker network proxy already exists"
else
  run docker network create proxy
fi

log_info "next: reboot"
log_info "next: sudo scripts/mkdirs.sh"
log_info "next: scripts/vm/verify.sh"
