#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# .env first, then defaults, so .env values are not masked by the defaults.
load_env
SECRETS_DIR="${SECRETS_DIR:-$REPO_ROOT/secrets}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Secrets this script generates (48 random alphanumeric characters each).
GENERATED=(authentik_secret_key authentik_pg_password authentik_bootstrap_password crowdsec_bouncer_key)
# Secrets only the owner can supply.
MANUAL=(cf_dns_api_token)

usage() {
  cat <<EOF
Create the edge secret files under secrets/ that Compose mounts as Docker
secrets. Never overwrites an existing file and never prints a secret value.

Generated (48 random alphanumeric characters, mode 0400):
  ${GENERATED[*]}
Supplied by you (never created here; reported as MISSING until the file exists):
  ${MANUAL[*]}  (a Cloudflare API token, Zone:DNS:Edit on this zone only)

Dry-run by default: prints "DRY-RUN: create <name>" or "KEEP <name> (exists)"
per secret. Pass --apply to create the missing files (umask 077; chown to
PUID:PGID when run as root).

Usage: 40-edge-secrets.sh [--apply] [--help]

Environment variables (defaults; normally from .env):
  SECRETS_DIR=$SECRETS_DIR
  PUID=$PUID
  PGID=$PGID
EOF
}

parse_common_args "$@"

require_safe_path SECRETS_DIR "$SECRETS_DIR"
require_match PUID "$PUID" '^[0-9]+$' "a numeric uid"
require_match PGID "$PGID" '^[0-9]+$' "a numeric gid"

umask 077

# gen_secret: 48 random alphanumeric characters on stdout, no trailing newline.
gen_secret() {
  local s=""
  while [[ ${#s} -lt 48 ]]; do
    s+="$(head -c 96 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' || true)"
  done
  printf '%s' "${s:0:48}"
}

if [[ $APPLY -eq 1 ]]; then
  mkdir -p "$SECRETS_DIR"
fi

for name in "${GENERATED[@]}"; do
  path="$SECRETS_DIR/$name"
  if [[ -e "$path" ]]; then
    printf 'KEEP %s (exists)\n' "$name"
  elif [[ $APPLY -eq 1 ]]; then
    gen_secret >"$path"
    chmod 0400 "$path"
    if [[ $EUID -eq 0 ]]; then
      chown "$PUID:$PGID" "$path"
    fi
    printf 'CREATED %s\n' "$name"
  else
    printf 'DRY-RUN: create %s\n' "$name"
  fi
done

for name in "${MANUAL[@]}"; do
  path="$SECRETS_DIR/$name"
  if [[ -e "$path" ]]; then
    printf 'KEEP %s (exists)\n' "$name"
  else
    printf 'MISSING %s: paste a Cloudflare API token (Zone:DNS:Edit, this zone only) into %s\n' "$name" "$path"
  fi
done
