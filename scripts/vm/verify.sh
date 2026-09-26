#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# .env first, then defaults, so .env values are not masked by the defaults.
load_env
DATA_ROOT="${DATA_ROOT:-/data}"
SKIP_HW="${SKIP_HW:-0}"
RENDER_NODE="${RENDER_NODE:-/dev/dri/renderD128}"
ALLOW_NFS="${ALLOW_NFS:-0}"

usage() {
  cat <<EOF
Single acceptance gate for the media VM. Read-only: never mutates the
system, except for a pair of temporary files it creates and removes to
prove hardlinks work between /data/usenet and /data/media.

Runs 10 checks, in order, each printing one line:
  PASS <id> <detail>
  FAIL <id> <detail>
  SKIP <id> <reason>
Check IDs: gpu, vaapi-av1, vaapi-hevc, vaapi-h264, data-mount, tree,
hardlink, docker, network, compose.

Ends with: RESULT: <n> pass, <n> fail, <n> skip
Exits 1 if any check FAILs, 0 otherwise.

Usage: verify.sh [--apply] [--help]
(--apply is accepted for CLI consistency with other scripts but has no
effect: this script always just checks.)

Environment variables (defaults):
  DATA_ROOT=$DATA_ROOT                 Root of the media/download tree.
  SKIP_HW=$SKIP_HW                     1 skips GPU/VAAPI/data-mount checks
                                        (sandbox/CI mode).
  RENDER_NODE=$RENDER_NODE             DRM render node to probe.
  ALLOW_NFS=$ALLOW_NFS                 1 also accepts nfs/nfs4 for
                                        data-mount (NFS fallback).
EOF
}

parse_common_args "$@"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() {
  local id="$1"; shift
  printf 'PASS %s %s\n' "$id" "$*"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  local id="$1"; shift
  printf 'FAIL %s %s\n' "$id" "$*"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip() {
  local id="$1"; shift
  printf 'SKIP %s %s\n' "$id" "$*"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

# --- 1: gpu ------------------------------------------------------------
check_gpu() {
  if [[ "$SKIP_HW" == "1" ]]; then
    skip gpu "SKIP_HW=1"
    return 0
  fi
  local kver
  kver="$(uname -r)"
  if [[ -c "$RENDER_NODE" ]]; then
    pass gpu "$RENDER_NODE is a character device, kernel $kver"
  else
    fail gpu "$RENDER_NODE is not a character device, kernel $kver; see docs/runbooks/01-proxmox-host.md#5-troubleshooting"
  fi
}

# --- 2-4: vaapi-av1, vaapi-hevc, vaapi-h264 -----------------------------
check_vaapi() {
  if [[ "$SKIP_HW" == "1" ]]; then
    skip vaapi-av1 "SKIP_HW=1"
    skip vaapi-hevc "SKIP_HW=1"
    skip vaapi-h264 "SKIP_HW=1"
    return 0
  fi

  if ! command -v vainfo >/dev/null 2>&1; then
    fail vaapi-av1 "vainfo not installed"
    fail vaapi-hevc "vainfo not installed"
    fail vaapi-h264 "vainfo not installed"
    return 0
  fi

  local vainfo_out
  vainfo_out="$(vainfo --display drm --device "$RENDER_NODE" 2>/dev/null || true)"

  if grep -Eq 'VAProfileAV1Profile0.*VAEntrypointEncSliceLP' <<<"$vainfo_out"; then
    pass vaapi-av1 "AV1 low-power encode entrypoint found"
  else
    fail vaapi-av1 "VAProfileAV1Profile0/VAEntrypointEncSliceLP not found in vainfo output"
  fi

  if grep -Eq 'VAProfileHEVCMain10.*VAEntrypointEncSlice' <<<"$vainfo_out"; then
    pass vaapi-hevc "HEVC Main10 encode entrypoint found"
  else
    fail vaapi-hevc "VAProfileHEVCMain10/VAEntrypointEncSlice not found in vainfo output"
  fi

  if grep -Eq 'VAProfileH264Main.*VAEntrypointEncSlice' <<<"$vainfo_out"; then
    pass vaapi-h264 "H264 Main encode entrypoint found"
  else
    fail vaapi-h264 "VAProfileH264Main/VAEntrypointEncSlice not found in vainfo output"
  fi
}

# --- 5: data-mount -------------------------------------------------------
check_data_mount() {
  if [[ "$SKIP_HW" == "1" ]]; then
    skip data-mount "SKIP_HW=1"
    return 0
  fi

  local types="virtiofs"
  [[ "$ALLOW_NFS" == "1" ]] && types="virtiofs,nfs,nfs4"

  local mnt_out
  if mnt_out="$(findmnt -n -t "$types" "$DATA_ROOT" 2>/dev/null)" && [[ -n "$mnt_out" ]]; then
    pass data-mount "$DATA_ROOT is mounted ($mnt_out)"
  else
    fail data-mount "$DATA_ROOT is not mounted as $types"
  fi
}

# --- 6: tree --------------------------------------------------------------
# The same 15 entries mkdirs.sh creates (see scripts/mkdirs.sh DIRS).
TREE_ENTRIES=(
  "usenet/incomplete"
  "usenet/complete/tv"
  "usenet/complete/tv-4k"
  "usenet/complete/movies"
  "usenet/complete/movies-4k"
  "usenet/complete/music"
  "usenet/complete/anime"
  "media/tv"
  "media/tv-4k"
  "media/movies"
  "media/movies-4k"
  "media/anime-tv"
  "media/anime-movies"
  "media/music"
  "transcode"
)

check_tree() {
  if [[ ! -d "$DATA_ROOT" ]]; then
    fail tree "DATA_ROOT missing: $DATA_ROOT"
    return 0
  fi

  local missing=() entry
  for entry in "${TREE_ENTRIES[@]}"; do
    [[ -d "$DATA_ROOT/$entry" ]] || missing+=("$entry")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    pass tree "all ${#TREE_ENTRIES[@]} entries present under $DATA_ROOT"
  else
    fail tree "missing: ${missing[*]}"
  fi
}

# --- 7: hardlink ------------------------------------------------------------
check_hardlink() {
  if [[ ! -d "$DATA_ROOT" ]]; then
    fail hardlink "DATA_ROOT missing: $DATA_ROOT"
    return 0
  fi

  local src="$DATA_ROOT/usenet/complete/.verify-hardlink-$$"
  local dst="$DATA_ROOT/media/.verify-hardlink-$$"

  trap 'rm -f "$src" "$dst" 2>/dev/null || true' RETURN

  if [[ ! -d "$(dirname "$src")" || ! -d "$(dirname "$dst")" ]]; then
    fail hardlink "source/target directory missing under $DATA_ROOT"
    return 0
  fi

  if ! : > "$src" 2>/dev/null; then
    fail hardlink "could not create $src"
    return 0
  fi

  local ln_err
  if ! ln_err="$(ln "$src" "$dst" 2>&1)"; then
    # Keep the FAIL line to a single line, and only call it cross-device
    # when the two parent directories really are on different devices.
    ln_err="${ln_err//$'\n'/ }"
    local src_dir dst_dir dev_src dev_dst reason
    src_dir="$(dirname "$src")"
    dst_dir="$(dirname "$dst")"
    dev_src="$(stat -c %d "$src_dir" 2>/dev/null || echo "?")"
    dev_dst="$(stat -c %d "$dst_dir" 2>/dev/null || echo "?")"
    if [[ "$dev_src" != "$dev_dst" ]]; then
      reason="cross-device: $src_dir on dev $dev_src, $dst_dir on dev $dev_dst"
    else
      reason="same device $dev_src"
    fi
    fail hardlink "ln $src -> $dst failed ($reason): ${ln_err:-no error output}"
    return 0
  fi

  local inode_src inode_dst link_count
  inode_src="$(stat -c %i "$src" 2>/dev/null || echo "")"
  inode_dst="$(stat -c %i "$dst" 2>/dev/null || echo "")"
  link_count="$(stat -c %h "$src" 2>/dev/null || echo "0")"

  if [[ -n "$inode_src" && "$inode_src" == "$inode_dst" && "$link_count" == "2" ]]; then
    pass hardlink "inode $inode_src shared, link count 2"
  else
    fail hardlink "inode mismatch: src=$inode_src dst=$inode_dst (link count $link_count)"
  fi
}

# --- 8-10: docker, network, compose -----------------------------------------
check_docker_network_compose() {
  local docker_present=0
  if command -v docker >/dev/null 2>&1; then
    docker_present=1
  fi

  local docker_ok=0
  if [[ $docker_present -eq 1 ]]; then
    local ver
    if ver="$(timeout 5 docker version --format '{{.Server.Version}}' 2>/dev/null)" && [[ -n "$ver" ]]; then
      if timeout 5 docker compose version >/dev/null 2>&1; then
        pass docker "server $ver, compose plugin available"
        docker_ok=1
      else
        fail docker "docker compose version failed"
      fi
    else
      if [[ "$SKIP_HW" == "1" ]]; then
        skip docker "docker unavailable (SKIP_HW=1)"
      else
        fail docker "daemon unreachable (timeout or error)"
      fi
    fi
  else
    if [[ "$SKIP_HW" == "1" ]]; then
      skip docker "docker unavailable (SKIP_HW=1)"
    else
      fail docker "docker not found on PATH"
    fi
  fi

  if [[ $docker_ok -eq 1 ]]; then
    if timeout 5 docker network inspect proxy >/dev/null 2>&1; then
      pass network "proxy network exists"
    elif [[ "$SKIP_HW" == "1" ]]; then
      skip network "proxy network not found (SKIP_HW=1)"
    else
      fail network "proxy network not found; run: docker network create proxy"
    fi
  else
    if [[ "$SKIP_HW" == "1" ]]; then
      skip network "docker unavailable (SKIP_HW=1)"
    else
      fail network "docker unavailable"
    fi
  fi

  if [[ $docker_ok -eq 1 ]]; then
    if [[ ! -f "$REPO_ROOT/.env" ]]; then
      fail compose "copy .env.example to .env"
    elif timeout 15 docker compose -f "$REPO_ROOT/compose.yaml" config -q 2>/dev/null; then
      pass compose "compose.yaml config is valid"
    else
      fail compose "docker compose config -q failed"
    fi
  else
    if [[ "$SKIP_HW" == "1" ]]; then
      skip compose "docker unavailable (SKIP_HW=1)"
    else
      fail compose "docker unavailable"
    fi
  fi
}

check_gpu
check_vaapi
check_data_mount
check_tree
check_hardlink
check_docker_network_compose

printf 'RESULT: %d pass, %d fail, %d skip\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
exit 0
