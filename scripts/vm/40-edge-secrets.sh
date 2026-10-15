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
# Secrets only the owner can supply: two Cloudflare API tokens, one per consumer.
MANUAL=(cf_dns_api_token cf_ddns_api_token)
# Minimum size of a generated secret that is kept; anything shorter is a failed write.
MIN_BYTES=48
CF_PERMS="Zone:Zone:Read and Zone:DNS:Edit, this zone only"

# manual_use <name>: what the Cloudflare token is for.
manual_use() {
  case "$1" in
    cf_dns_api_token) printf 'Traefik ACME DNS-01' ;;
    cf_ddns_api_token) printf 'cloudflare-ddns' ;;
  esac
}

usage() {
  cat <<EOF
Create the edge secret files under secrets/ that Compose mounts as Docker
secrets. Never overwrites an existing file and never prints a secret value.

Generated (48 random alphanumeric characters, mode 0400):
  ${GENERATED[*]}
Supplied by you (never created here; reported as MISSING until the file exists),
two separate Cloudflare API tokens, each with $CF_PERMS:
  cf_dns_api_token   for Traefik's ACME DNS-01 challenge
  cf_ddns_api_token  for cloudflare-ddns
(No Client IP Address Filtering on them: the WAN IP is dynamic, so a filter would
lock DDNS out the moment the IP changes.)

Dry-run by default: prints "DRY-RUN: create <name>" or "KEEP <name> (exists)"
per secret. Pass --apply to create the missing files: each is written to a
temporary file in SECRETS_DIR (umask 077), set to mode 0400 (and chown to
PUID:PGID when run as root), then renamed into place.

An existing generated secret is kept only if it is a regular file (not a
symlink) of at least $MIN_BYTES bytes; an existing Cloudflare token only if it is
a non-empty regular file. Anything else prints "INVALID <name> (<reason>)", is
left untouched, and makes the script exit 1: remove the file and re-run.

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

# invalid_reason <path> <min bytes>: prints why an existing path must not be kept
# (nothing when it is a regular, non-symlink file of at least <min bytes> bytes).
invalid_reason() {
  local path="$1" min="$2" size
  if [[ -L "$path" ]]; then
    printf 'a symlink'
  elif [[ ! -f "$path" ]]; then
    printf 'not a regular file'
  else
    size="$(stat -c %s -- "$path")"
    if [[ "$size" -lt "$min" ]]; then
      printf '%s bytes, want at least %s' "$size" "$min"
    fi
  fi
}

# write_secret <name>: generate into a temp file next to the target, set mode and
# owner, check the size, then rename it into place (never a partial file at <name>).
TMP_FILE=""
trap '[[ -z "$TMP_FILE" ]] || rm -f -- "$TMP_FILE"' EXIT
write_secret() {
  local name="$1" path="$SECRETS_DIR/$1"
  TMP_FILE="$(mktemp "$SECRETS_DIR/.$name.XXXXXX")"
  gen_secret >"$TMP_FILE"
  chmod 0400 "$TMP_FILE"
  if [[ $EUID -eq 0 ]]; then
    chown "$PUID:$PGID" "$TMP_FILE"
  fi
  [[ "$(stat -c %s -- "$TMP_FILE")" -eq $MIN_BYTES ]] || die "short write for $name; nothing replaced"
  mv -f -T -- "$TMP_FILE" "$path"
  TMP_FILE=""
}

if [[ $APPLY -eq 1 ]]; then
  mkdir -p "$SECRETS_DIR"
fi

invalid=0
for name in "${GENERATED[@]}"; do
  path="$SECRETS_DIR/$name"
  if [[ -e "$path" || -L "$path" ]]; then
    reason="$(invalid_reason "$path" "$MIN_BYTES")"
    if [[ -n "$reason" ]]; then
      printf 'INVALID %s (%s; remove it and re-run)\n' "$name" "$reason"
      invalid=1
    else
      printf 'KEEP %s (exists)\n' "$name"
    fi
  elif [[ $APPLY -eq 1 ]]; then
    write_secret "$name"
    printf 'CREATED %s\n' "$name"
  else
    printf 'DRY-RUN: create %s\n' "$name"
  fi
done

for name in "${MANUAL[@]}"; do
  path="$SECRETS_DIR/$name"
  if [[ -e "$path" || -L "$path" ]]; then
    reason="$(invalid_reason "$path" 1)"
    if [[ -n "$reason" ]]; then
      printf 'INVALID %s (%s; remove it and paste the token again)\n' "$name" "$reason"
      invalid=1
    else
      printf 'KEEP %s (exists)\n' "$name"
    fi
  else
    printf 'MISSING %s: paste a Cloudflare API token (%s; %s) into %s\n' \
      "$name" "$CF_PERMS" "$(manual_use "$name")" "$path"
  fi
done

exit "$invalid"
