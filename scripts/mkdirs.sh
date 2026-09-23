#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<EOF
Create the TRaSH-guide /data tree and the appdata root. Idempotent: safe to
re-run any number of times.

Unlike the host/VM scripts, this script always applies its changes; it only
ever creates directories, so there is no dry-run mode. --apply is accepted
for a consistent CLI but is ignored (a no-op).

Usage: mkdirs.sh [--apply] [--help]

Environment variables (defaults):
  DATA_ROOT=/data              Root of the media/download tree.
  APPDATA_ROOT=/opt/appdata    Root for per-service application data.
  PUID=1000                    Owner uid for created directories (root only).
  PGID=1000                    Owner gid for created directories (root only).
EOF
}

parse_common_args "$@"
if [[ $APPLY -eq 1 ]]; then
  log_info "mkdirs always applies"
fi

load_env

DATA_ROOT="${DATA_ROOT:-/data}"
APPDATA_ROOT="${APPDATA_ROOT:-/opt/appdata}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

umask 002

# The 14 TRaSH leaf directories plus transcode/ (15 entries total under
# DATA_ROOT). See docs/architecture.md "Storage layout".
DIRS=(
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

created=0
existing=0
warned_chown=0

secure_dir() {
  local path="$1"
  chmod 2775 "$path"
  if [[ $EUID -eq 0 ]]; then
    chown "$PUID:$PGID" "$path"
  elif [[ $warned_chown -eq 0 ]]; then
    log_warn "not root: skipping chown"
    warned_chown=1
  fi
}

for entry in "${DIRS[@]}"; do
  path="$DATA_ROOT/$entry"
  if [[ -d "$path" ]]; then
    existing=$((existing + 1))
    continue
  fi

  # Walk the path components under DATA_ROOT, so newly-created parent
  # directories (e.g. usenet/complete when only usenet/incomplete exists so
  # far) get the same mode/ownership treatment as the leaf.
  new_components=()
  component="$DATA_ROOT"
  rel="${entry}"
  IFS='/' read -r -a parts <<< "$rel"
  for part in "${parts[@]}"; do
    component="$component/$part"
    [[ -d "$component" ]] || new_components+=("$component")
  done

  mkdir -p "$path"
  created=$((created + 1))
  log_info "created $path"
  for component in "${new_components[@]}"; do
    secure_dir "$component"
  done
done

if [[ -d "$APPDATA_ROOT" ]]; then
  existing=$((existing + 1))
else
  mkdir -p "$APPDATA_ROOT"
  created=$((created + 1))
  log_info "created $APPDATA_ROOT"
  secure_dir "$APPDATA_ROOT"
fi

log_info "created $created, existing $existing"
