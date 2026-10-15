#!/usr/bin/env bash
# scripts/ci/test-plugins.sh
#
# Tests for scripts/vm/45-traefik-plugins.sh against local bare git repositories
# (no network): dry run, install on a matching commit, idempotent re-run, upgrade,
# and refusal on a commit mismatch, a malformed lock file or a non-plugin tree.
# Also dry-runs the repository's real config/traefik/plugins.lock.
# Prints "ok <name>" per check; exits 1 on the first failure.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
REPO="$PWD"
SH="$REPO/scripts/vm/45-traefik-plugins.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ok() { printf 'ok %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" >&2
  exit 1
}

g() { git -c user.name=ci -c user.email=ci@example.invalid -c init.defaultBranch=main "$@"; }

# --- fixture: module example.com/test/plug with tags v1.0.0 (annotated), v1.1.0 ---
MOD="example.com/test/plug"
W="$tmp/work"
mkdir -p "$W"
g -C "$W" init -q
printf 'displayName: Test plugin\ntype: middleware\nimport: %s\n' "$MOD" >"$W/.traefik.yml"
printf 'package plug\n\nconst Version = "1.0.0"\n' >"$W/plug.go"
g -C "$W" add -A
g -C "$W" commit -qm v1.0.0
g -C "$W" tag -a v1.0.0 -m v1.0.0
SHA1="$(g -C "$W" rev-parse HEAD)"
printf 'package plug\n\nconst Version = "1.1.0"\n' >"$W/plug.go"
g -C "$W" commit -qam v1.1.0
g -C "$W" tag v1.1.0
SHA2="$(g -C "$W" rev-parse HEAD)"
# A tag on a tree without .traefik.yml.
g -C "$W" rm -q .traefik.yml
g -C "$W" commit -qm broken
g -C "$W" tag v9.0.0
SHA9="$(g -C "$W" rev-parse HEAD)"
mkdir -p "$tmp/git/example.com/test"
g clone -q --bare "$W" "$tmp/git/$MOD"

export PLUGIN_GIT_URL_PREFIX="file://$tmp/git/"
lock() { printf '# test lock\n\n%s\n' "$*" >"$tmp/plugins.lock"; }
run() { LOCK_FILE="$tmp/plugins.lock" APPDATA_ROOT="$tmp/appdata" "$SH" "$@"; }
DEST="$tmp/appdata/traefik/plugins-local/src/$MOD"
leftovers() { find "$tmp/appdata/traefik/plugins-local" -maxdepth 1 -name '.stage-*' | head -n 1; }

# --- CLI -----------------------------------------------------------------------
grep -q 'plugins.lock' <<<"$("$SH" --help)" || fail "--help does not mention plugins.lock"
rc=0
"$SH" --bogus >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] || fail "--bogus exited $rc, want 2"
ok "--help exits 0; an unknown flag exits 2"

# --- dry run -------------------------------------------------------------------
lock "plug $MOD v1.0.0 $SHA1"
out="$(run)" || fail "dry run exited non-zero" "$out"
[[ "$out" == "DRY-RUN: install plug $MOD@v1.0.0 ($SHA1) -> $DEST" ]] || fail "unexpected dry-run output" "$out"
[[ ! -e "$tmp/appdata" ]] || fail "dry run created $tmp/appdata"
ok "dry run prints what it would fetch and creates nothing"

# --- install on match ----------------------------------------------------------
out="$(run --apply 2>&1)" || fail "--apply exited non-zero" "$out"
grep -qx "INSTALLED plug v1.0.0 ($SHA1)" <<<"$out" || fail "--apply did not report INSTALLED" "$out"
[[ -f "$DEST/.traefik.yml" ]] || fail "installed tree lacks .traefik.yml"
grep -q '"1.0.0"' "$DEST/plug.go" || fail "installed tree is not v1.0.0"
[[ ! -e "$DEST/.git" ]] || fail "installed tree still has .git"
[[ "$(cat "$DEST/.plugin-lock")" == "$MOD v1.0.0 $SHA1" ]] || fail "marker does not record module, tag and commit"
[[ -z "$(leftovers)" ]] || fail "staging directory left behind: $(leftovers)"
ok "--apply installs the locked commit without .git and records it"

out="$(run --apply 2>&1)" || fail "second --apply exited non-zero" "$out"
[[ "$out" == "KEEP plug v1.0.0 (installed)" ]] || fail "second --apply did not KEEP" "$out"
out="$(run)" || fail "dry run after install exited non-zero"
[[ "$out" == "KEEP plug v1.0.0 (installed)" ]] || fail "dry run after install did not KEEP" "$out"
ok "re-runs (dry run and --apply) keep an installed copy with the same commit"

# --- refuse on mismatch --------------------------------------------------------
lock "plug $MOD v1.1.0 $SHA1"
rc=0
out="$(run --apply 2>&1)" || rc=$?
[[ $rc -ne 0 ]] || fail "--apply with a wrong commit exited 0" "$out"
grep -q "is commit $SHA2, but plugins.lock says $SHA1; refusing to install" <<<"$out" \
  || fail "mismatch error does not name both commits" "$out"
grep -q '"1.0.0"' "$DEST/plug.go" || fail "a refused install changed the installed copy"
[[ "$(cat "$DEST/.plugin-lock")" == "$MOD v1.0.0 $SHA1" ]] || fail "a refused install changed the marker"
[[ -z "$(leftovers)" ]] || fail "staging directory left behind after a refusal"
rc=0
out="$(LOCK_FILE="$tmp/plugins.lock" APPDATA_ROOT="$tmp/fresh" "$SH" --apply 2>&1)" || rc=$?
[[ $rc -ne 0 && ! -e "$tmp/fresh/traefik/plugins-local/src/$MOD" ]] \
  || fail "a mismatch on a fresh install installed something" "$out"
ok "a commit mismatch aborts, installs nothing and keeps the existing copy"

# --- upgrade -------------------------------------------------------------------
lock "plug $MOD v1.1.0 $SHA2"
out="$(run --apply 2>&1)" || fail "upgrade --apply exited non-zero" "$out"
grep -qx "INSTALLED plug v1.1.0 ($SHA2)" <<<"$out" || fail "upgrade did not report INSTALLED" "$out"
grep -q '"1.1.0"' "$DEST/plug.go" || fail "upgrade did not replace the tree"
[[ -z "$(leftovers)" ]] || fail "staging directory left behind after an upgrade"
ok "a lock update replaces the installed copy"

# --- refuse a non-plugin tree and malformed locks ------------------------------
lock "plug $MOD v9.0.0 $SHA9"
rc=0
out="$(run --apply 2>&1)" || rc=$?
if [[ $rc -eq 0 ]] || ! grep -q 'has no .traefik.yml' <<<"$out"; then
  fail "a tree without .traefik.yml was not refused" "$out"
fi
grep -q '"1.1.0"' "$DEST/plug.go" || fail "a refused tree changed the installed copy"
for bad in "plug $MOD v1.0.0 ${SHA1:0:12}" "plug $MOD latest $SHA1" "plug $MOD v1.0.0" \
           "plug $MOD v1.0.0 $SHA1 extra" "Plug $MOD v1.0.0 $SHA1" "plug example.com/../x v1.0.0 $SHA1"; do
  lock "$bad"
  rc=0
  out="$(run 2>&1)" || rc=$?
  [[ $rc -eq 1 ]] || fail "malformed lock line '$bad' exited $rc, want 1" "$out"
done
ok "refuses a tree without .traefik.yml and malformed lock lines (short SHA, non-semver tag, field count, name, ..)"

# --- the real lock file --------------------------------------------------------
out="$(APPDATA_ROOT=/opt/appdata "$REPO/scripts/vm/45-traefik-plugins.sh")" || fail "dry run of the real lock exited non-zero" "$out"
n="$(grep -cvE '^[[:space:]]*(#|$)' "$REPO/config/traefik/plugins.lock")"
[[ "$(grep -c '^DRY-RUN: install ' <<<"$out")" -eq "$n" ]] || fail "real lock dry run does not list all $n plugins" "$out"
ok "the real plugins.lock dry-runs ($n plugins)"

echo "PASS: test-plugins"
