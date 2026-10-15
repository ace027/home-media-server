#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# .env first, then defaults, so .env values are not masked by the defaults.
load_env
APPDATA_ROOT="${APPDATA_ROOT:-/opt/appdata}"
LOCK_FILE="${LOCK_FILE:-$REPO_ROOT/config/traefik/plugins.lock}"
# Clone URL = PLUGIN_GIT_URL_PREFIX + module path. Tests point it at local bare repos.
PLUGIN_GIT_URL_PREFIX="${PLUGIN_GIT_URL_PREFIX:-https://}"

usage() {
  cat <<EOF
Install the Traefik plugins listed in config/traefik/plugins.lock as local
plugins, so Traefik never downloads code at start. For each "<name> <module>
<tag> <commit>" line: git clone <module> at <tag> into a temporary directory,
check that HEAD is exactly <commit> (abort on any mismatch), drop .git, and
move the tree into place:
  \${APPDATA_ROOT}/traefik/plugins-local/src/<module>
Traefik mounts plugins-local read-only (stacks/edge.yaml, localPlugins).

Idempotent: a plugin whose installed copy records the same module, tag and
commit is skipped ("KEEP <name> <tag> (installed)"). Other output lines:
  DRY-RUN: install <name> <module>@<tag> (<commit>) -> <dir>
  INSTALLED <name> <tag> (<commit>)
Exits 1 on a malformed lock file, a failed clone or a commit mismatch; nothing
is installed for that plugin and an existing copy is left as it was.

Dry-run by default (prints what it would fetch; needs no network). Pass --apply
to fetch and install (needs git and HTTPS access to github.com; no root).

Usage: 45-traefik-plugins.sh [--apply] [--help]

Environment variables (defaults; normally from .env):
  APPDATA_ROOT=$APPDATA_ROOT
  LOCK_FILE=$LOCK_FILE
  PLUGIN_GIT_URL_PREFIX=$PLUGIN_GIT_URL_PREFIX   (clone URL = prefix + module)
EOF
}

parse_common_args "$@"

require_safe_path APPDATA_ROOT "$APPDATA_ROOT"
[[ -f "$LOCK_FILE" ]] || die "lock file not found: $LOCK_FILE"

PLUGINS_DIR="$APPDATA_ROOT/traefik/plugins-local"
SRC_DIR="$PLUGINS_DIR/src"
# Written into every installed tree; its content is compared for idempotence.
MARKER=".plugin-lock"

# read_lock: prints "<name> <module> <tag> <commit>" per entry; dies on a bad line.
read_lock() {
  local line n=0 name module tag commit extra
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    read -r name module tag commit extra <<<"$line"
    [[ -z "${extra:-}" && -n "${commit:-}" ]] \
      || die "$LOCK_FILE:$n: want exactly 4 fields: <name> <module> <tag> <commit>"
    [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || die "$LOCK_FILE:$n: bad name '$name'"
    [[ "$module" =~ ^[A-Za-z0-9.-]+(/[A-Za-z0-9_.-]+)+$ && "$module" != *..* ]] \
      || die "$LOCK_FILE:$n: bad module '$module'"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$LOCK_FILE:$n: tag '$tag' is not vX.Y.Z"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "$LOCK_FILE:$n: commit '$commit' is not a 40-hex SHA"
    printf '%s %s %s %s\n' "$name" "$module" "$tag" "$commit"
  done <"$LOCK_FILE"
}

STAGE=""
cleanup() {
  [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"
}
trap cleanup EXIT

# install_plugin <name> <module> <tag> <commit>
install_plugin() {
  local name="$1" module="$2" tag="$3" commit="$4" dest head old=""
  dest="$SRC_DIR/$module"
  mkdir -p "$(dirname "$dest")"
  # Staged next to src/ (same filesystem, so the final mv is a rename), outside the
  # tree Traefik scans.
  STAGE="$(mktemp -d "$PLUGINS_DIR/.stage-$name.XXXXXX")"
  if ! git -c advice.detachedHead=false clone --quiet --depth 1 --single-branch \
      --branch "$tag" "$PLUGIN_GIT_URL_PREFIX$module" "$STAGE/tree" >&2; then
    die "$name: git clone of $PLUGIN_GIT_URL_PREFIX$module at $tag failed"
  fi
  head="$(git -C "$STAGE/tree" rev-parse HEAD)"
  if [[ "$head" != "$commit" ]]; then
    die "$name: $module $tag is commit $head, but plugins.lock says $commit; refusing to install (review the change, then update the lock)"
  fi
  [[ -f "$STAGE/tree/.traefik.yml" ]] || die "$name: $module $tag has no .traefik.yml (not a Traefik plugin)"
  rm -rf -- "$STAGE/tree/.git"
  printf '%s %s %s\n' "$module" "$tag" "$commit" >"$STAGE/tree/$MARKER"
  chmod -R u+rwX,go+rX,go-w "$STAGE/tree"
  if [[ -e "$dest" ]]; then
    # Swap: the old copy is moved aside and removed only after the new one is in place.
    old="$STAGE/old"
    mv -T -- "$dest" "$old"
  fi
  if ! mv -T -- "$STAGE/tree" "$dest"; then
    [[ -z "$old" ]] || mv -T -- "$old" "$dest"
    die "$name: cannot move the new tree to $dest; the previous copy was kept"
  fi
  rm -rf -- "$STAGE"
  STAGE=""
  printf 'INSTALLED %s %s (%s)\n' "$name" "$tag" "$commit"
}

lock_out="$(read_lock)" || exit 1
mapfile -t ENTRIES <<<"$lock_out"
[[ -n "$lock_out" ]] || die "no plugins in $LOCK_FILE"

if [[ $APPLY -eq 1 ]]; then
  require_cmd git
  umask 022
  mkdir -p "$SRC_DIR"
fi

for entry in "${ENTRIES[@]}"; do
  read -r name module tag commit <<<"$entry"
  dest="$SRC_DIR/$module"
  if [[ -f "$dest/$MARKER" && "$(cat "$dest/$MARKER")" == "$module $tag $commit" ]]; then
    printf 'KEEP %s %s (installed)\n' "$name" "$tag"
  elif [[ $APPLY -eq 1 ]]; then
    install_plugin "$name" "$module" "$tag" "$commit"
  else
    printf 'DRY-RUN: install %s %s@%s (%s) -> %s\n' "$name" "$module" "$tag" "$commit" "$dest"
  fi
done
