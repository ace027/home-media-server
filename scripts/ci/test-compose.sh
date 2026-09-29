#!/usr/bin/env bash
# scripts/ci/test-compose.sh
#
# Compose structure tests (spec 02 "Compose contract" and "Acceptance
# Checks"): config variants, the single-/data rule, the published-port
# rule, synthetic fixtures, and check-min-versions.sh fixtures.
# Prints "ok <name>" per check; exits 1 on the first failure.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# The tests pick each file set explicitly; a caller's or .env's compose
# selection must not leak in (-f compose.yaml overrides COMPOSE_FILE).
unset COMPOSE_FILE COMPOSE_PROFILES LAN_IP

LAN=(env COMPOSE_FILE=compose.yaml:compose.lan.yaml LAN_IP=127.0.0.1)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ok() { printf 'ok %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" >&2
  exit 1
}

# --- 1. Config variants -------------------------------------------------------
[[ -f .env ]] || cp -n .env.example .env
docker compose -f compose.yaml config -q || fail "config (default)"
ok "config default"
docker compose -f compose.yaml --profile jellyfin config -q || fail "config --profile jellyfin"
ok "config jellyfin profile"
"${LAN[@]}" docker compose config -q || fail "config with compose.lan.yaml"
ok "config lan override"

if docker compose -f compose.yaml config --services | grep -qx jellyfin; then
  fail "jellyfin present without its profile"
fi
if "${LAN[@]}" docker compose config --services | grep -qx jellyfin; then
  fail "jellyfin present without its profile (lan override)"
fi
docker compose -f compose.yaml --profile jellyfin config --services | grep -qx jellyfin \
  || fail "jellyfin missing with --profile jellyfin"
ok "jellyfin profile only"

# --- 2. LAN override without LAN_IP fails clearly ----------------------------
rc=0
out="$(LAN_IP='' COMPOSE_FILE=compose.yaml:compose.lan.yaml docker compose config -q 2>&1)" || rc=$?
[[ $rc -ne 0 ]] || fail "lan override accepted an empty LAN_IP"
grep -q 'set LAN_IP' <<<"$out" || fail "empty LAN_IP error lacks 'set LAN_IP'" "$out"
ok "lan override requires LAN_IP"

# --- 3. Single /data mount ------------------------------------------------------
# No service mounts /data (or a /data/ subpath) more than once, and the only
# allowed subpath target is /data/media, read-only.
full="$(docker compose -f compose.yaml --profile jellyfin config --format json)"
bad="$(jq -r '
  .services | to_entries[]
  | .key as $svc
  | [.value.volumes[]? | select(.target | test("^/data(/|$)"))] as $d
  | (if ($d | length) > 1 then "\($svc): \($d | length) /data mounts" else empty end),
    ($d[] | select(.target != "/data")
      | if .target != "/data/media" then "\($svc): /data subpath \(.target)"
        elif (.read_only // false) != true then "\($svc): /data/media not read-only"
        else empty end)
' <<<"$full")"
[[ -z "$bad" ]] || fail "single /data" "$bad"
[[ "$(jq '[.services[].volumes[]? | select(.target == "/data/media")] | length' <<<"$full")" -eq 2 ]] \
  || fail "single /data: expected /data/media:ro on plex and jellyfin"
ok "single /data"

# --- 4. Only 32400 is published -------------------------------------------------
pub="$(jq -c '[.services[].ports[]?.published] | unique' <<<"$full")"
[[ "$pub" == '["32400"]' ]] || fail "published ports without override: $pub (want [\"32400\"])"
ok "only 32400 without override"

# --- 4b. Every service gets explicit DNS servers (overridable) -------------------
nodns="$(jq -r '.services | to_entries[] | select((.value.dns // []) != ["1.1.1.1","8.8.8.8"]) | .key' <<<"$full")"
[[ -z "$nodns" ]] || fail "services without the default dns [1.1.1.1, 8.8.8.8]: $nodns"
ovr="$(DNS_PRIMARY=192.0.2.53 DNS_SECONDARY=192.0.2.54 docker compose -f compose.yaml --profile jellyfin config --format json)"
[[ "$(jq -c '[.services[].dns] | unique' <<<"$ovr")" == '[["192.0.2.53","192.0.2.54"]]' ]] \
  || fail "DNS_PRIMARY/DNS_SECONDARY did not override the container dns"
ok "container dns"

lan="$("${LAN[@]}" docker compose --profile jellyfin config --format json)"
n_admin="$(jq '[.services[].ports[]? | select(.published != "32400")] | length' <<<"$lan")"
[[ "$n_admin" -eq 11 ]] || fail "lan override: expected 11 admin ports, got $n_admin"
unbound="$(jq -r '.services | to_entries[] | .key as $svc
  | .value.ports[]? | select(.published != "32400" and .host_ip != "127.0.0.1")
  | "\($svc): \(.host_ip // "0.0.0.0"):\(.published)"' <<<"$lan")"
[[ -z "$unbound" ]] || fail "lan override: admin ports not bound to LAN_IP" "$unbound"
ok "lan override binds admin ports to LAN_IP"

# --- 5. Fixtures are synthetic --------------------------------------------------
if [[ -d scripts/ci/fixtures ]]; then
  out=$({ grep -rEo '[a-f0-9]{32}' scripts/ci/fixtures 2>/dev/null || true; } \
    | { grep -v 0123456789abcdef0123456789abcdef || true; })
  [[ -z "$out" ]] || fail "fixtures: non-dummy 32-hex strings found" "$out"
  ok "fixtures synthetic"
else
  ok "fixtures (none yet)"
fi

# --- 6/7. check-min-versions.sh fixtures ---------------------------------------
# write_compose <file> <image...>: one service per image.
write_compose() {
  local file="$1" i=0 image
  shift
  printf 'services:\n' > "$file"
  for image in "$@"; do
    i=$((i + 1))
    printf '  s%d:\n    image: %s\n' "$i" "$image" >> "$file"
  done
}

# expect_min <name> <want-rc> <compose-file> -> sets $out
expect_min() {
  local name="$1" want="$2" file="$3" rc=0
  out="$(scripts/ci/check-min-versions.sh "$file" 2>&1)" || rc=$?
  [[ $rc -eq $want ]] || fail "$name: exit $rc, want $want" "$out"
}

scripts/ci/check-min-versions.sh >/dev/null || fail "min-versions: repo compose.yaml"
ok "min-versions repo"

write_compose "$tmp/below.yaml" \
  lscr.io/linuxserver/sonarr:4.0.19.2979-ls320 \
  ghcr.io/seerr-team/seerr:v3.4.0 \
  lscr.io/linuxserver/plex:1.43.4.10903-e5521bd8c-ls323
expect_min "min-versions downgrade" 1 "$tmp/below.yaml"
[[ "$(grep -c '^BELOW-MIN: ' <<<"$out")" -eq 3 ]] || fail "min-versions downgrade: want 3 BELOW-MIN" "$out"
for image in sonarr:4.0.19.2979-ls320 seerr:v3.4.0 plex:1.43.4.10903-e5521bd8c-ls323; do
  grep -q "^BELOW-MIN: .*/$image < " <<<"$out" || fail "min-versions downgrade: $image not reported" "$out"
done
ok "min-versions downgrade fails"

write_compose "$tmp/none.yaml" alpine:3.20
expect_min "min-versions no images" 1 "$tmp/none.yaml"
grep -q '^NO-IMAGES: ' <<<"$out" || fail "min-versions no images: want NO-IMAGES" "$out"
ok "min-versions no listed image fails"

write_compose "$tmp/plex.yaml" lscr.io/linuxserver/plex:1.43.4.10903-e5521bd8c-ls325
expect_min "min-versions plex hash" 0 "$tmp/plex.yaml"
grep -q '^OK: 1 images at or above minimum' <<<"$out" || fail "min-versions plex hash: want OK" "$out"
ok "min-versions plex hash newer passes"

# A newer version passes even with a lower ls number; ls only breaks ties.
write_compose "$tmp/newer.yaml" lscr.io/linuxserver/sonarr:4.0.20.1-ls1
expect_min "min-versions newer version" 0 "$tmp/newer.yaml"
ok "min-versions newer version passes"

printf 'PASS: test-compose\n'
