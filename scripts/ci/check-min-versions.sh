#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<EOF
Fail if any image in a compose file's resolved config is older than the
minimum tag listed for its repo in config/min-versions.txt (the versions
the migrated databases were written by). Images whose repo is not listed
are ignored. Profiled services are included (COMPOSE_PROFILES=jellyfin).

Tags are normalized before comparing: a leading "v" is stripped, a
trailing "-ls<N>" is split off as the linuxserver build number (0 if
absent), and any "-<hex>" segment of 7+ hex characters (the Plex build
hash) is dropped. The remaining versions are compared with "sort -V";
if they are equal, the ls numbers are compared numerically.

Usage: check-min-versions.sh [compose-file] [--help]

Arguments:
  compose-file    Path to the compose file to check (default: compose.yaml
                  at the repo root).

Environment:
  MIN_FILE        Minimum-version list (default: config/min-versions.txt
                  at the repo root).

Output: "BELOW-MIN: <image> < <repo>:<min-tag>" per failure (exit 1),
"NO-IMAGES: ..." if no listed repo is used at all (exit 1), otherwise
"OK: <n> images at or above minimum" (exit 0).
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

FILE="${1:-$REPO_ROOT/compose.yaml}"
MIN_FILE="${MIN_FILE:-$REPO_ROOT/config/min-versions.txt}"

require_cmd docker sort
[[ -f "$FILE" ]] || die "compose file not found: $FILE"
[[ -f "$MIN_FILE" ]] || die "min-versions file not found: $MIN_FILE"

# repo -> minimum tag, from "<repo> <min-tag>" lines (comments and blanks skipped).
declare -A MIN_TAG=()
while read -r repo tag _; do
  [[ -z "$repo" || "$repo" == \#* ]] && continue
  [[ -n "$tag" ]] || die "malformed line in $MIN_FILE (expected '<repo> <min-tag>'): $repo"
  MIN_TAG["$repo"]="$tag"
done < "$MIN_FILE"

# normalize <tag>
#
# Prints "<version> <ls>" for a tag, e.g.
#   v2.17.2-ls240                  -> 2.17.2 240
#   1.43.4.10903-e5521bd8c-ls324   -> 1.43.4.10903 324
#   v3.4.1                         -> 3.4.1 0
normalize() {
  local tag="${1#v}" ls=0 part out=""
  if [[ "$tag" =~ ^(.*)-ls([0-9]+)$ ]]; then
    tag="${BASH_REMATCH[1]}"
    ls="${BASH_REMATCH[2]}"
  fi
  local -a parts
  IFS='-' read -r -a parts <<<"$tag"
  for part in "${parts[@]}"; do
    # Drop the build-hash segment (7+ hex chars, e.g. Plex's "e5521bd8c").
    [[ "$part" =~ ^[0-9a-f]{7,}$ ]] && continue
    out+="${out:+-}$part"
  done
  printf '%s %s\n' "$out" "$((10#$ls))"
}

# at_or_above <cur-tag> <min-tag>: returns 0 if cur >= min.
at_or_above() {
  local cur_ver cur_ls min_ver min_ls
  read -r cur_ver cur_ls < <(normalize "$1")
  read -r min_ver min_ls < <(normalize "$2")
  if [[ "$cur_ver" == "$min_ver" ]]; then
    (( cur_ls >= min_ls ))
    return
  fi
  [[ "$(printf '%s\n' "$min_ver" "$cur_ver" | sort -V | head -1)" == "$min_ver" ]]
}

images="$(COMPOSE_PROFILES=jellyfin docker compose -f "$FILE" config --images)" \
  || die "docker compose config --images failed for $FILE"

below=0
count=0

while IFS= read -r image; do
  [[ -z "$image" ]] && continue

  # Drop a digest suffix, then split "<repo>:<tag>" on the last ":" after
  # the last "/", so a registry port (host:5000/repo) is not taken for a tag.
  ref="${image%@*}"
  last_component="${ref##*/}"
  if [[ "$last_component" != *:* ]]; then
    [[ -n "${MIN_TAG[$ref]+x}" ]] && log_warn "no tag to compare, skipped: $image"
    continue
  fi
  tag="${ref##*:}"
  repo="${ref%:*}"
  [[ -n "${MIN_TAG[$repo]+x}" ]] || continue

  count=$((count + 1))
  if ! at_or_above "$tag" "${MIN_TAG[$repo]}"; then
    printf 'BELOW-MIN: %s < %s:%s\n' "$image" "$repo" "${MIN_TAG[$repo]}"
    below=$((below + 1))
  fi
done <<<"$images"

if [[ $count -eq 0 ]]; then
  printf 'NO-IMAGES: no listed image found in %s\n' "$FILE"
  exit 1
fi

if [[ $below -gt 0 ]]; then
  exit 1
fi

printf 'OK: %d images at or above minimum\n' "$count"
exit 0
