#!/usr/bin/env bash
# shellcheck disable=SC2016
# (SC2016: single-quoted snippets below are evaluated later by the lib
# runner or written into wrapper scripts, where their $-expressions expand.)
#
# scripts/ci/test-arr-scripts.sh
#
# Tests scripts/lib/arr.sh, scripts/vm/20-arr-remap.sh and
# scripts/vm/25-arr-wire.sh against the stub docker/curl from
# scripts/ci/make-api-stubs.sh and the synthetic JSON in
# scripts/ci/fixtures/api/. API keys are dummies written into a temp
# APPDATA_ROOT. Needs no root, no Docker daemon and no network.
# Prints "ok <case>" per case and exits 1 on the first failure.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMAP="$REPO/scripts/vm/20-arr-remap.sh"
WIRE="$REPO/scripts/vm/25-arr-wire.sh"
FIX="$REPO/scripts/ci/fixtures/api"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

ok() { printf 'ok %s\n' "$1"; }
fail() {
  printf 'FAIL %s: %s\n' "$1" "$2" >&2
  if [[ -n "${OUT:-}" ]]; then
    printf -- '--- output ---\n%s\n--------------\n' "$OUT" >&2
  fi
  if [[ -s "${STUB_LOG:-/nonexistent}" ]]; then
    printf -- '--- stub log ---\n%s\n----------------\n' "$(cat "$STUB_LOG")" >&2
  fi
  exit 1
}

# run_capture <cmd...>: sets OUT (stdout+stderr) and RC, never exits.
run_capture() {
  RC=0
  OUT="$("$@" 2>&1)" || RC=$?
}

# expect <case> <rc> [<grep -E pattern>...]: the last run_capture exited
# <rc> and its output matches every pattern.
expect() {
  local name="$1" rc="$2" pattern
  shift 2
  [[ $RC -eq $rc ]] || fail "$name" "exit $RC, expected $rc"
  for pattern in "$@"; do
    grep -qE -- "$pattern" <<<"$OUT" || fail "$name" "output does not match: $pattern"
  done
}

# refute <case> <grep -E pattern>: the last output does not match.
refute() {
  if grep -qE -- "$2" <<<"$OUT"; then
    fail "$1" "output unexpectedly matches: $2"
  fi
}

# Dummy secrets: they must never show up in any output or argv.
KEY=0123456789abcdef0123456789abcdef
SEERR_KEY='ZHVtbXlrZXlkdW1teWtleQ=='
PLEX_TOKEN=dummytoken0123456789
no_secrets() {
  local name="$1" text="$2" s
  for s in "$KEY" "$SEERR_KEY" "$PLEX_TOKEN"; do
    if grep -qF -- "$s" <<<"$text"; then
      fail "$name" "a dummy secret appeared in output/argv"
    fi
  done
}

# --- stubs -----------------------------------------------------------------------
"$REPO/scripts/ci/make-api-stubs.sh" "$T/bin" 2>/dev/null
export PATH="$T/bin:$PATH"

# --- synthetic appdata, data tree and baseline -----------------------------------
export APPDATA_ROOT="$T/appdata" DATA_ROOT="$T/data" LAN_IP=192.168.50.16
export WAIT_INTERVAL=0 WAIT_TIMEOUT=5
for s in sonarr sonarr-anime sonarr-4k radarr radarr-4k lidarr prowlarr; do
  mkdir -p "$APPDATA_ROOT/$s"
  printf '<Config>\n  <UrlBase></UrlBase>\n  <ApiKey>%s</ApiKey>\n</Config>\n' "$KEY" > "$APPDATA_ROOT/$s/config.xml"
done
mkdir -p "$APPDATA_ROOT/sabnzbd" "$APPDATA_ROOT/seerr" "$APPDATA_ROOT/.migration" \
  "$APPDATA_ROOT/plex/Library/Application Support/Plex Media Server"
printf '[misc]\nport = 8080\napi_key = %s\n' "$KEY" > "$APPDATA_ROOT/sabnzbd/sabnzbd.ini"
printf '{"main":{"apiKey":"%s","applicationTitle":"Seerr"}}\n' "$SEERR_KEY" > "$APPDATA_ROOT/seerr/settings.json"
printf '<?xml version="1.0" encoding="utf-8"?>\n<Preferences PlexOnlineToken="%s" autoEmptyTrash="0"/>\n' "$PLEX_TOKEN" \
  > "$APPDATA_ROOT/plex/Library/Application Support/Plex Media Server/Preferences.xml"
# baseline "created" = 2026-09-28T00:00:00Z = 1790553600
printf '{"created":"2026-09-28T00:00:00Z","stage":"20260928-000000"}\n' > "$APPDATA_ROOT/.migration/baseline.json"
mkdir -p "$DATA_ROOT"/media/{tv,anime-tv,tv-4k,movies,anime-movies,movies-4k,music}
# The folders the initial fixtures' items move into (the remap checks them).
mkdir -p "$DATA_ROOT/media/tv/Show A" "$DATA_ROOT/media/tv/Show B" \
  "$DATA_ROOT/media/anime-tv/Anime A" "$DATA_ROOT/media/anime-tv/Anime B" \
  "$DATA_ROOT/media/movies/Movie A (2001)" "$DATA_ROOT/media/movies/Movie B (2002)"

HOST_S="$(hostname -s)"
ARR_UP="sonarr sonarr-anime radarr lidarr"
CORE_UP="sabnzbd prowlarr sonarr sonarr-anime sonarr-4k radarr radarr-4k lidarr plex seerr tautulli"
export STUB_LOG="$T/api.log" STUB_STATE="$T/state"

# reset_stub: empty request log and call sequences, default stub env.
reset_stub() {
  rm -rf "$STUB_STATE"
  : > "$STUB_LOG"
  unset STUB_HTTP_prowlarr STUB_EXPECT_KEY STUB_HEALTH
  export STUB_RUNNING=""
}

# use_fixtures <set>: a fresh copy of a fixture set (editable per case).
use_fixtures() {
  rm -rf "$T/fx"
  cp -R "$FIX/$1" "$T/fx"
  find "$T/fx" -type f -exec sed -i "s/@HOSTNAME@/$HOST_S/g" {} +
  export STUB_FIXTURES="$T/fx"
  reset_stub
}

# mutating: the logged requests that change state (POST/PUT/DELETE, and the
# SAB GET modes that change something).
mutating() {
  grep -E '^(POST|PUT|DELETE) |^GET sabnzbd /api\?mode=(set_config|del_config|pause|resume)&|^GET sabnzbd /api\?mode=(queue|history)&output=json&name=' \
    "$STUB_LOG" || true
}

# bodies <METHOD svc path>: the JSON bodies logged for exactly that request.
bodies() {
  grep -F -- "$1 body=" "$STUB_LOG" | sed 's/^[^ ]* [^ ]* [^ ]* body=//'
}

# Library runner: sources common.sh + arr.sh and evals its argument.
cat > "$T/libcall" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "$REPO/scripts/lib/common.sh"
source "$REPO/scripts/lib/arr.sh"
code="\$1"
shift
eval "\$code"
EOF
chmod +x "$T/libcall"

# ==============================================================================
# 1. svc_key: per-service validation, never printing a bad value
# ==============================================================================
reset_stub
run_capture "$T/libcall" 'svc_key seerr'
expect svc-key 0
[[ "$OUT" == "$SEERR_KEY" ]] || fail svc-key "seerr base64 key not returned"
run_capture "$T/libcall" 'svc_key sonarr; svc_key sabnzbd; svc_key plex'
expect svc-key 0
[[ "$OUT" == "$KEY"$'\n'"$KEY"$'\n'"$PLEX_TOKEN" ]] || fail svc-key "sonarr/sabnzbd/plex keys not returned"

B="$T/bad"
mkdir -p "$B/seerr" "$B/sabnzbd" "$B/radarr"
printf '{"main":{"apiKey":"not a key; rm -rf /"}}\n' > "$B/seerr/settings.json"
printf '[misc]\napi_key = 0123456789ABCDEF0123456789ABCDEF\n' > "$B/sabnzbd/sabnzbd.ini"
printf '<Config><ApiKey>deadbeef</ApiKey></Config>\n' > "$B/radarr/config.xml"
run_capture env APPDATA_ROOT="$B" "$T/libcall" 'svc_key seerr'
expect svc-key-invalid 1 'missing/invalid API key for seerr'
refute svc-key-invalid 'not a key'
run_capture env APPDATA_ROOT="$B" "$T/libcall" 'svc_key sabnzbd'
expect svc-key-invalid 1 'missing/invalid API key for sabnzbd'
refute svc-key-invalid '0123456789ABCDEF'
run_capture env APPDATA_ROOT="$B" "$T/libcall" 'svc_key radarr'
expect svc-key-invalid 1 'missing/invalid API key for radarr'
refute svc-key-invalid 'deadbeef'
run_capture env APPDATA_ROOT="$B" "$T/libcall" 'svc_key lidarr'
expect svc-key-missing 1 'missing/invalid API key for lidarr'
ok "svc_key validates per service and never prints a bad key"

# ==============================================================================
# 2. api: the key reaches the app via curl's stdin, never argv
# ==============================================================================
mkdir -p "$T/wrap"
cat > "$T/wrap/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/wrap/argv.log"
exec "$T/bin/curl" "\$@"
EOF
chmod +x "$T/wrap/curl"
reset_stub
printf '{"name":"x"}\n' > "$T/body.json"
run_capture env PATH="$T/wrap:$PATH" STUB_RUNNING="sonarr sabnzbd" STUB_EXPECT_KEY="$KEY" \
  "$T/libcall" 'api sonarr GET /api/v3/system/status; api sabnzbd GET "$(sab_path version)"; api sonarr POST /api/v3/tag "$1"' "$T/body.json"
expect api-argv 0
run_capture env PATH="$T/wrap:$PATH" STUB_RUNNING="seerr" STUB_EXPECT_KEY="$SEERR_KEY" \
  "$T/libcall" 'api seerr GET /api/v1/settings/main'
expect api-argv 0
run_capture env PATH="$T/wrap:$PATH" STUB_RUNNING="plex" STUB_EXPECT_KEY="$PLEX_TOKEN" \
  "$T/libcall" 'api plex GET /library/sections'
expect api-argv 0
[[ -s "$T/wrap/argv.log" ]] || fail api-argv "curl wrapper recorded nothing"
grep -q -- '-K -' "$T/wrap/argv.log" || fail api-argv "curl was not given -K -"
no_secrets api-argv "$(cat "$T/wrap/argv.log" "$T/bin/calls.log")"
no_secrets api-argv "$(cat "$STUB_LOG")"
grep -qx 'GET sabnzbd /api?mode=version&output=json' "$STUB_LOG" || fail api-argv "SAB apikey not stripped/logged"
grep -qx 'POST sonarr /api/v3/tag body={"name":"x"}' "$STUB_LOG" || fail api-argv "body not sent via --data-binary"
# A wrong key is rejected by the stub (proves the key is actually sent).
run_capture env STUB_RUNNING="sonarr" STUB_EXPECT_KEY=ffffffffffffffffffffffffffffffff \
  "$T/libcall" 'api sonarr GET /api/v3/system/status'
expect api-401 1 '^GET sonarr /api/v3/system/status -> HTTP 401$'
no_secrets api-401 "$OUT"
run_capture env STUB_RUNNING="" "$T/libcall" 'api sonarr GET /api/v3/system/status'
expect api-not-running 1 'sonarr not running'
ok "api sends the key on curl's stdin only (argv, logs and errors are key-free)"

# 2b. arr_mutate dry-run: redacted body, no call, counted.
reset_stub
printf '{"name":"SABnzbd","apiKey":"%s","fields":[{"name":"apiKey","value":"%s"},{"name":"password","value":"hunter2"},{"name":"nzbKey","value":"k2"},{"name":"host","value":"sabnzbd"}]}\n' \
  "$KEY" "$KEY" > "$T/secret-body.json"
run_capture env STUB_RUNNING="sonarr" "$T/libcall" \
  'arr_mutate sonarr PUT /api/v3/downloadclient/2 "$1"; arr_mutate sonarr DELETE /api/v3/indexer/1; echo "count=$count_mutations"' \
  "$T/secret-body.json"
expect arr-mutate-dry 0 '^DRY-RUN: PUT sonarr /api/v3/downloadclient/2 \{"name":"SABnzbd","apiKey":"\*\*\*"' \
  '"name":"host","value":"sabnzbd"' '^DRY-RUN: DELETE sonarr /api/v3/indexer/1$' '^count=2$'
refute arr-mutate-dry 'hunter2|"k2"'
no_secrets arr-mutate-dry "$OUT"
[[ ! -s "$STUB_LOG" ]] || fail arr-mutate-dry "dry-run made an API call"
ok "arr_mutate dry-run redacts secrets, makes no call and counts"

# 2c. same_state: masked/privacy fields ignored; compared keys matter.
mkdir -p "$T/ss"
jq -n --arg k "$KEY" '{name:"SABnzbd",implementation:"Sabnzbd",enable:true,fields:[
  {name:"host",value:"sabnzbd",privacy:"normal"},{name:"port",value:8080,privacy:"normal"},
  {name:"apiKey",value:$k,privacy:"apiKey"},{name:"tvCategory",value:"tv",privacy:"normal"},
  {name:"recentTvPriority",value:0,privacy:"normal"}]}' > "$T/ss/desired.json"
jq '.id = 2 | .fields |= map(if .name == "apiKey" then .value = "********" elif .name == "recentTvPriority" then .value = -100 else . end)' \
  "$T/ss/desired.json" > "$T/ss/masked.json"
jq '.fields |= map(if .name == "tvCategory" then .value = "series" else . end)' "$T/ss/masked.json" > "$T/ss/cat.json"
jq '.syncLevel = "disabled"' "$T/ss/masked.json" > "$T/ss/sync.json"
jq '.fields |= map(if .name == "host" then .value = "********" else . end)' "$T/ss/cat.json" > "$T/ss/hostmask.json"
run_capture "$T/libcall" 'same_state "$1/desired.json" "$1/masked.json"' "$T/ss"
expect same-state-masked 0
run_capture "$T/libcall" 'same_state "$1/desired.json" "$1/cat.json"' "$T/ss"
expect same-state-category 1
run_capture "$T/libcall" 'same_state "$1/desired.json" "$1/sync.json"' "$T/ss"
expect same-state-synclevel 1
run_capture "$T/libcall" 'same_state "$1/desired.json" "$1/hostmask.json"' "$T/ss"
expect same-state-category 1
jq '.fields |= map(if .name == "host" then .value = "********" else . end)' "$T/ss/masked.json" > "$T/ss/hostonly.json"
jq '.fields |= map(if .name == "host" then .value = "old-sab" else . end)' "$T/ss/masked.json" > "$T/ss/hostdiff.json"
run_capture "$T/libcall" 'same_state "$1/desired.json" "$1/hostonly.json"' "$T/ss"
expect same-state-masked-compared 0
run_capture "$T/libcall" 'same_state "$1/desired.json" "$1/hostdiff.json"' "$T/ss"
expect same-state-host 1
ok "same_state ignores ******** and non-normal privacy fields, compares the rest"

# 2d. wait_cmd: completed / failed / timeout.
mkdir -p "$T/cmdfx/sonarr"
printf '{"id":7,"status":"failed"}\n' > "$T/cmdfx/sonarr/GET_api_v3_command_7.json"
printf '{"id":8,"status":"started"}\n' > "$T/cmdfx/sonarr/GET_api_v3_command_8.json"
printf '{"id":9,"status":"queued"}\n' > "$T/cmdfx/sonarr/GET_api_v3_command_9.json"
printf '{"id":9,"status":"completed"}\n' > "$T/cmdfx/sonarr/GET_api_v3_command_9.json.2"
printf '{"id":10,"status":"cancelled"}\n' > "$T/cmdfx/sonarr/GET_api_v3_command_10.json"
printf '{"id":11,"status":"orphaned"}\n' > "$T/cmdfx/sonarr/GET_api_v3_command_11.json"
reset_stub
run_capture env STUB_RUNNING=sonarr STUB_FIXTURES="$T/cmdfx" "$T/libcall" 'wait_cmd sonarr "{\"id\":9}"'
expect wait-cmd 0
[[ "$(grep -c 'GET sonarr /api/v3/command/9' "$STUB_LOG")" -eq 3 ]] || fail wait-cmd "did not poll until completed"
run_capture env STUB_RUNNING=sonarr STUB_FIXTURES="$T/cmdfx" "$T/libcall" 'wait_cmd sonarr "{\"id\":7}"'
expect wait-cmd-failed 1 'command 7 failed'
run_capture env STUB_RUNNING=sonarr STUB_FIXTURES="$T/cmdfx" WAIT_TIMEOUT=0 "$T/libcall" 'wait_cmd sonarr "{\"id\":8}"'
expect wait-cmd-timeout 1 'command 8 still queued in sonarr; re-running is safe; raise WAIT_TIMEOUT \(seconds\) for large libraries'
run_capture env STUB_RUNNING=sonarr STUB_FIXTURES="$T/cmdfx" "$T/libcall" 'wait_cmd sonarr "{\"id\":10}"'
expect wait-cmd-cancelled 1 'command 10 cancelled'
run_capture env STUB_RUNNING=sonarr STUB_FIXTURES="$T/cmdfx" "$T/libcall" 'wait_cmd sonarr "{\"id\":11}"'
expect wait-cmd-orphaned 1 'command 11 orphaned'
run_capture env STUB_RUNNING=sonarr "$T/libcall" 'wait_cmd sonarr "{}"'
expect wait-cmd-noid 1 'command response has no id'
ok "wait_cmd polls to completed, and dies on failed/cancelled/orphaned, timeout and a missing id"

# 2e. SABnzbd errors come back as HTTP 200 {"status":false,"error":...}.
mkdir -p "$T/sabfx/sabnzbd"
printf '{"status":false,"error":"Not implemented"}\n' \
  > "$T/sabfx/sabnzbd/GET_api_mode_set_config_output_json_section_misc_keyword_x_value_y.json"
printf '{"status":true}\n' > "$T/sabfx/sabnzbd/GET_api_mode_pause_output_json.json"
cp "$FIX/initial/sabnzbd/GET_api_mode_get_config_output_json.json" "$T/sabfx/sabnzbd/"
reset_stub
run_capture env STUB_RUNNING=sabnzbd STUB_FIXTURES="$T/sabfx" "$T/libcall" \
  'api sabnzbd GET "$(sab_path set_config section=misc keyword=x value=y)"'
expect sab-error 1 '^GET sabnzbd /api\?mode=set_config&output=json&section=misc&keyword=x&value=y -> SAB error: Not implemented$'
no_secrets sab-error "$OUT"
run_capture env STUB_RUNNING=sabnzbd STUB_FIXTURES="$T/sabfx" "$T/libcall" \
  'APPLY=1; arr_change sabnzbd GET "$(sab_path set_config section=misc keyword=x value=y)" || echo "rc=$?"'
expect sab-error-change 0 'SAB error: Not implemented' '^rc=1$'
refute sab-error-change '\[INFO\] GET sabnzbd'
# Reads (full objects) and {"status":true} are not errors.
run_capture env STUB_RUNNING=sabnzbd STUB_FIXTURES="$T/sabfx" "$T/libcall" \
  'sab_api get_config | jq -e .config.misc >/dev/null; api sabnzbd GET "$(sab_path pause)"'
expect sab-ok 0 '"status":true'
# And in the wire script: the first failed set_config stops the run.
use_fixtures initial
printf '{"status":false,"error":"Not implemented"}\n' \
  > "$T/fx/sabnzbd/GET_api_mode_set_config_output_json_section_misc_keyword_download_dir_value_%2Fdata%2Fusenet%2Fincomplete.json"
run_capture env STUB_RUNNING="sabnzbd" "$WIRE" --only sab --apply
expect sab-error-wire 1 'GET sabnzbd /api\?mode=set_config&output=json&section=misc&keyword=download_dir&value=%2Fdata%2Fusenet%2Fincomplete -> SAB error: Not implemented'
refute sab-error-wire 'changes$'
[[ "$(mutating | wc -l)" -eq 1 ]] || fail sab-error-wire "kept going after a SAB error: $(mutating)"
no_secrets sab-error-wire "$OUT"
ok "a SABnzbd HTTP 200 with status:false/error exits 1 (key-free); reads pass"

# 2g. Temp files go in the caller's work dir $W (removed by its EXIT trap),
# not $TMPDIR: an unusable TMPDIR does not matter when W is set.
mkdir -p "$T/wdir"
reset_stub
run_capture env STUB_RUNNING=sonarr STUB_FIXTURES="$FIX/initial" TMPDIR="$T/no-such-tmp" "$T/libcall" \
  'W="$1"; APPLY=1; api sonarr GET /api/v3/rootfolder >/dev/null; printf "{\"name\":\"RescanSeries\"}" >"$W/c.json"
   arr_command sonarr "$W/c.json"; echo "[]" >"$W/rf.json"; ensure_root_folder sonarr /data/x "$W/rf.json"; rm "$W/c.json" "$W/rf.json"' "$T/wdir"
expect tmp-in-w 0
[[ -z "$(ls -A "$T/wdir")" ]] || fail tmp-in-w "temp files left in W: $(ls -A "$T/wdir")"
ok "api/arr_command/ensure_root_folder temp files live in \$W"

# 2f. A relative COMPOSE_FILE (from .env, loaded after arr.sh is sourced)
# is made absolute under the repo, so scripts work from any dir.
reset_stub
rm -f "$T/bin/compose-env.log"
run_capture env -u COMPOSE_FILE STUB_RUNNING=sonarr bash -c 'cd /tmp && "$1" "$2"' _ "$T/libcall" \
  'export COMPOSE_FILE=compose.yaml:compose.lan.yaml; running_services; svc_ip sonarr'
expect compose-file-lib 0 '^sonarr$' '^172\.30\.0\.12$'
[[ "$(sort -u "$T/bin/compose-env.log")" == "COMPOSE_FILE=$REPO/compose.yaml:$REPO/compose.lan.yaml" ]] \
  || fail compose-file-lib "COMPOSE_FILE not absolute: $(sort -u "$T/bin/compose-env.log")"
use_fixtures converged
rm -f "$T/bin/compose-env.log"
run_capture env STUB_RUNNING="$ARR_UP" COMPOSE_FILE=compose.yaml:compose.lan.yaml bash -c 'cd /tmp && "$1"' _ "$REMAP"
expect compose-file-script 0 '\[INFO\] no changes$'
[[ -s "$T/bin/compose-env.log" ]] || fail compose-file-script "no compose call logged"
[[ "$(sort -u "$T/bin/compose-env.log")" == "COMPOSE_FILE=$REPO/compose.yaml:$REPO/compose.lan.yaml" ]] \
  || fail compose-file-script "COMPOSE_FILE not absolute: $(sort -u "$T/bin/compose-env.log")"
ok "a relative COMPOSE_FILE is made absolute under the repo (run from /tmp)"

# ==============================================================================
# 3. Remap preconditions
# ==============================================================================
use_fixtures initial
run_capture env STUB_RUNNING="$ARR_UP sabnzbd" "$REMAP"
expect remap-precondition 1 'stop sabnzbd and prowlarr first: docker compose stop sabnzbd prowlarr'
run_capture env STUB_RUNNING="$ARR_UP prowlarr" "$REMAP" --apply
expect remap-precondition 1 'stop sabnzbd and prowlarr first'
run_capture env STUB_RUNNING="$ARR_UP" STUB_HEALTH="radarr=starting" "$REMAP"
expect remap-precondition 1 'radarr is not running and healthy \(running/starting\)'
run_capture env STUB_RUNNING="sonarr sonarr-anime radarr" "$REMAP"
expect remap-precondition 1 'lidarr is not running and healthy \(absent\)'
run_capture env STUB_RUNNING="$ARR_UP" DATA_ROOT="$T/nodata" "$REMAP"
expect remap-precondition 1 "missing new root dir $T/nodata/media/tv"
[[ -z "$(mutating)" ]] || fail remap-precondition "a refused run made changes"
ok "remap refuses with sabnzbd/prowlarr running, an unhealthy app or a missing root dir"

# ==============================================================================
# 4. Remap dry-run
# ==============================================================================
use_fixtures initial
run_capture env STUB_RUNNING="$ARR_UP" "$REMAP"
expect remap-dry-run 0 \
  '^DRY-RUN: PUT sonarr /api/v3/config/mediamanagement/1 .*"autoUnmonitorPreviouslyDownloadedEpisodes":false' \
  '^DRY-RUN: POST sonarr /api/v3/rootfolder \{"path":"/data/media/tv"\}$' \
  '^DRY-RUN: PUT sonarr /api/v3/series/editor \{"seriesIds":\[1,2\],"rootFolderPath":"/data/media/tv","moveFiles":false\}$' \
  '^DRY-RUN: DELETE sonarr /api/v3/rootfolder/1$' \
  '^DRY-RUN: POST sonarr /api/v3/command \{"name":"RescanSeries"\}$' \
  '^DRY-RUN: PUT radarr /api/v3/movie/editor \{"movieIds":\[21,22\],"rootFolderPath":"/data/media/movies","moveFiles":false\}$' \
  '^DRY-RUN: PUT sonarr-anime /api/v3/config/mediamanagement/1 ' \
  '^DRY-RUN: POST lidarr /api/v1/rootfolder \{"name":"Music","path":"/data/media/music","defaultQualityProfileId":1,"defaultMetadataProfileId":1\}$' \
  '\[INFO\] sonarr: 2 items /data/shows -> /data/media/tv' \
  '\[INFO\] radarr: 2 items /data/movies -> /data/media/movies' \
  '\[INFO\] next: docker compose up -d sabnzbd && scripts/vm/25-arr-wire.sh --only sab'
refute remap-dry-run 'no changes'
[[ -z "$(mutating)" ]] || fail remap-dry-run "dry-run made mutating calls: $(mutating)"
no_secrets remap-dry-run "$OUT"
ok "remap dry-run prints the editor PUT (moveFiles:false) and makes no changes"

# ==============================================================================
# 5. Remap --apply: per-instance order
# ==============================================================================
use_fixtures initial
run_capture env STUB_RUNNING="$ARR_UP" "$REMAP" --apply
expect remap-apply 0 '\[INFO\] sonarr-anime: 2 items /data/anime -> /data/media/anime-tv'
for spec in "sonarr series 1" "sonarr-anime series 4" "radarr movie 1"; do
  read -r svc kind rf <<<"$spec"
  got="$(mutating | grep -E "^[A-Z]+ $svc " | sed 's/ body=.*//')"
  want="PUT $svc /api/v3/config/mediamanagement/1
POST $svc /api/v3/rootfolder
PUT $svc /api/v3/$kind/editor
DELETE $svc /api/v3/rootfolder/$rf
POST $svc /api/v3/command"
  [[ "$got" == "$want" ]] || fail remap-apply "$svc calls out of order:"$'\n'"$got"
  grep -q "^GET $svc /api/v3/command/1\$" "$STUB_LOG" || fail remap-apply "$svc rescan not awaited"
done
[[ "$(mutating | grep -c '^[A-Z]* lidarr ')" -eq 1 ]] || fail remap-apply "lidarr root folder not added once"
bodies "PUT sonarr /api/v3/series/editor" | jq -e '.moveFiles == false and .seriesIds == [1,2] and .rootFolderPath == "/data/media/tv"' >/dev/null \
  || fail remap-apply "sonarr editor body"
bodies "PUT radarr /api/v3/config/mediamanagement/1" | jq -e '.autoUnmonitorPreviouslyDownloadedMovies == false and .id == 1' >/dev/null \
  || fail remap-apply "radarr mediamanagement body"
bodies "POST sonarr /api/v3/command" | jq -e '.name == "RescanSeries"' >/dev/null || fail remap-apply "sonarr rescan body"
bodies "POST radarr /api/v3/command" | jq -e '.name == "RescanMovie"' >/dev/null || fail remap-apply "radarr rescan body"
no_secrets remap-apply "$OUT"
ok "remap --apply: unmonitor off, root add, editor, old root delete, rescan (in order)"

# ==============================================================================
# 6. Remap: items left under the old root after the editor call
# ==============================================================================
use_fixtures initial
cp "$T/fx/sonarr/GET_api_v3_series.json" "$T/fx/sonarr/GET_api_v3_series.json.1"
run_capture env STUB_RUNNING="$ARR_UP" "$REMAP" --apply
expect remap-leftover 1 'sonarr: items still under /data/shows/ after the editor call \(ids: 1,2\); old root folder kept'
! grep -q '^DELETE sonarr /api/v3/rootfolder' "$STUB_LOG" || fail remap-leftover "old root folder deleted"
! grep -q '^POST sonarr /api/v3/command' "$STUB_LOG" || fail remap-leftover "rescan after a failed remap"
# And a mediamanagement without the unmonitor field is refused before any change.
use_fixtures initial
printf '{"id":1,"recycleBin":""}\n' > "$T/fx/sonarr/GET_api_v3_config_mediamanagement.json"
run_capture env STUB_RUNNING="$ARR_UP" "$REMAP" --apply
expect remap-no-field 1 'sonarr: config/mediamanagement has no boolean autoUnmonitorPreviouslyDownloadedEpisodes'
[[ -z "$(mutating)" ]] || fail remap-no-field "changes made"
ok "remap exits 1 and keeps the old root when items are left under it"

# 6b. An item whose folder is not on the new pool: refused before any
# change, in dry-run and with --apply, naming the folder.
for mode in "" --apply; do
  use_fixtures initial
  jq '. + [{"id": 5, "title": "Show Gone", "path": "/data/shows/Show Gone"}]' \
    "$FIX/initial/sonarr/GET_api_v3_series.json" > "$T/fx/sonarr/GET_api_v3_series.json"
  run_capture env STUB_RUNNING="$ARR_UP" "$REMAP" ${mode:+"$mode"}
  expect "remap-folder-missing${mode}" 1 \
    "folder missing on the new pool; nothing changed: $T/data/media/tv/Show Gone\$"
  [[ -z "$(mutating)" ]] || fail "remap-folder-missing${mode}" "changes made: $(mutating)"
  ! grep -q 'series/editor' "$STUB_LOG" || fail "remap-folder-missing${mode}" "editor PUT sent"
  refute "remap-folder-missing${mode}" '^DRY-RUN:'
done
ok "remap refuses (dry-run too) when an item's folder is missing on the new pool"

# ==============================================================================
# 7. Wire --only sab
# ==============================================================================
use_fixtures initial
run_capture env STUB_RUNNING="sabnzbd" "$WIRE" --only sab
wl="oldvm.lan%2Coldvm%2Csabnzbd%2C$HOST_S%2C192.168.50.16"
expect wire-sab-dry 0 \
  '^DRY-RUN: GET sabnzbd /api\?mode=set_config&output=json&section=misc&keyword=download_dir&value=%2Fdata%2Fusenet%2Fincomplete$' \
  '^DRY-RUN: GET sabnzbd /api\?mode=set_config&output=json&section=misc&keyword=complete_dir&value=%2Fdata%2Fusenet%2Fcomplete$' \
  "^DRY-RUN: GET sabnzbd /api\\?mode=set_config&output=json&section=misc&keyword=host_whitelist&value=$wl\$" \
  '^DRY-RUN: GET sabnzbd /api\?mode=set_config&output=json&section=categories&keyword=tv&dir=tv$' \
  '^DRY-RUN: GET sabnzbd /api\?mode=set_config&output=json&section=categories&keyword=anime&dir=anime$' \
  '^DRY-RUN: GET sabnzbd /api\?mode=set_config&output=json&section=categories&keyword=movies&dir=movies$' \
  '^DRY-RUN: GET sabnzbd /api\?mode=del_config&output=json&section=categories&keyword=series$' \
  '^DRY-RUN: GET sabnzbd /api\?mode=del_config&output=json&section=categories&keyword=anime-series$' \
  '^DRY-RUN: GET sabnzbd /api\?mode=del_config&output=json&section=categories&keyword=software$' \
  '^DRY-RUN: GET sabnzbd /api\?mode=pause&output=json$' \
  '\[INFO\] 13 changes \(dry-run'
refute wire-sab-dry '^DRY-RUN: [A-Z]+ (sonarr|radarr|lidarr|prowlarr)'
refute wire-sab-dry 'mode=(queue|history)&output=json&name='
[[ -z "$(mutating)" ]] || fail wire-sab-dry "dry-run made SAB changes: $(mutating)"
no_secrets wire-sab-dry "$OUT"
reset_stub
run_capture env STUB_RUNNING="sabnzbd" "$WIRE" --only sab --apply
expect wire-sab-apply 0 '\[INFO\] 13 changes$'
[[ "$(mutating | wc -l)" -eq 13 ]] || fail wire-sab-apply "expected 13 SAB changes"
[[ "$(grep '^GET sabnzbd ' "$STUB_LOG" | tail -n 1)" == 'GET sabnzbd /api?mode=pause&output=json' ]] \
  || fail wire-sab-apply "last SAB call is not mode=pause"
! grep -qE '^[A-Z]+ (sonarr|radarr|lidarr|prowlarr)' "$STUB_LOG" || fail wire-sab-apply "--only sab touched other apps"
no_secrets wire-sab-apply "$OUT"
run_capture env STUB_RUNNING="" "$WIRE" --only sab
expect wire-sab-precondition 1 'sabnzbd is not running'
ok "wire --only sab: dirs, whitelist, categories as DRY-RUN only; --apply ends with mode=pause"

# 7b. Pre-baseline jobs are purged; newer ones and a missing baseline are not.
use_fixtures initial
jq '.queue.slots = [{"nzo_id":"SABnzbd_nzo_old","filename":"Old.Job","time_added":1700000000}]' \
  "$FIX/initial/sabnzbd/GET_api_mode_queue_output_json.json" > "$T/fx/sabnzbd/GET_api_mode_queue_output_json.json"
jq '.history.slots = [{"nzo_id":"SABnzbd_nzo_done","name":"Old.Done","completed":1700000500}]' \
  "$FIX/initial/sabnzbd/GET_api_mode_history_output_json.json" > "$T/fx/sabnzbd/GET_api_mode_history_output_json.json"
run_capture env STUB_RUNNING="sabnzbd" "$WIRE" --only sab
expect wire-sab-purge 0 \
  '^DRY-RUN: GET sabnzbd /api\?mode=queue&output=json&name=purge&del_files=1$' \
  '^DRY-RUN: GET sabnzbd /api\?mode=history&output=json&name=delete&value=all&del_files=1$'
jq '.queue.slots[0].time_added = 1800000000' "$T/fx/sabnzbd/GET_api_mode_queue_output_json.json" > "$T/q.json"
mv "$T/q.json" "$T/fx/sabnzbd/GET_api_mode_queue_output_json.json"
jq '.history.slots[0].completed = 1800000000' "$T/fx/sabnzbd/GET_api_mode_history_output_json.json" > "$T/h.json"
mv "$T/h.json" "$T/fx/sabnzbd/GET_api_mode_history_output_json.json"
reset_stub
run_capture env STUB_RUNNING="sabnzbd" "$WIRE" --only sab
expect wire-sab-nopurge 0
refute wire-sab-nopurge 'mode=(queue|history)&output=json&name='
reset_stub
run_capture env STUB_RUNNING="sabnzbd" APPDATA_ROOT="$T/appdata-nobaseline" "$WIRE" --only sab
expect wire-sab-nobaseline 1 'missing/invalid API key for sabnzbd'
mkdir -p "$T/appdata-nobaseline/sabnzbd"
cp "$APPDATA_ROOT/sabnzbd/sabnzbd.ini" "$T/appdata-nobaseline/sabnzbd/"
run_capture env STUB_RUNNING="sabnzbd" APPDATA_ROOT="$T/appdata-nobaseline" "$WIRE" --only sab
expect wire-sab-nobaseline 0 'skipping the pre-baseline queue/history purge'
refute wire-sab-nobaseline 'mode=(queue|history)&output=json&name='
ok "wire purges only queue/history jobs older than the baseline"

# ==============================================================================
# 8. Wire --apply on the initial fixtures
# ==============================================================================
use_fixtures initial
run_capture env STUB_RUNNING="$CORE_UP" "$WIRE" --apply
expect wire-apply 0 '\[INFO\] [0-9]+ changes$' '\[INFO\] prowlarr: removing app animesonarr'
for line in \
  'DELETE sonarr /api/v3/downloadclient/1' 'DELETE sonarr-anime /api/v3/downloadclient/1' \
  'DELETE sonarr /api/v3/indexer/1' 'DELETE sonarr-anime /api/v3/indexer/1' \
  'DELETE sonarr /api/v3/remotepathmapping/1' \
  'DELETE prowlarr /api/v1/indexer/1' 'DELETE prowlarr /api/v1/indexerproxy/1' \
  'DELETE prowlarr /api/v1/downloadclient/1' 'DELETE prowlarr /api/v1/applications/1'; do
  grep -qx -- "$line" "$STUB_LOG" || fail wire-apply "missing: $line"
done
! grep -qE '^DELETE [a-z-]+ /api/v[13]/indexer/2$' "$STUB_LOG" || fail wire-apply "a usenet indexer was deleted"
# SAB client per *arr: sonarr/sonarr-anime PUT (category differs), radarr
# untouched (equal apart from the masked key), the fresh ones POSTed.
bodies "PUT sonarr /api/v3/downloadclient/2" | jq -e --arg k "$KEY" '
  .id == 2 and .name == "SABnzbd" and .enable and .removeCompletedDownloads and .removeFailedDownloads
  and (.fields | map({(.name): .value}) | add) as $f
  | $f.host == "sabnzbd" and $f.port == 8080 and $f.useSsl == false and $f.apiKey == $k and $f.tvCategory == "tv"' >/dev/null \
  || fail wire-apply "sonarr SAB client PUT body"
bodies "PUT sonarr-anime /api/v3/downloadclient/2" | jq -e '(.fields | map({(.name): .value}) | add).tvCategory == "anime"' >/dev/null \
  || fail wire-apply "sonarr-anime category"
! grep -qE '^(PUT|POST) radarr /api/v3/downloadclient' "$STUB_LOG" || fail wire-apply "radarr SAB client rewritten despite equal (masked) state"
for spec in "sonarr-4k tvCategory tv-4k" "radarr-4k movieCategory movies-4k" "lidarr musicCategory music"; do
  read -r svc cf cat <<<"$spec"
  base=/api/v3
  [[ "$svc" == lidarr ]] && base=/api/v1
  bodies "POST $svc $base/downloadclient" | jq -e --arg cf "$cf" --arg cat "$cat" \
    '(.fields | map({(.name): .value}) | add) as $f | $f[$cf] == $cat and $f.host == "sabnzbd" and (has("id") | not)' >/dev/null \
    || fail wire-apply "$svc SAB client POST"
done
bodies "POST prowlarr /api/v1/downloadclient" | jq -e --arg k "$KEY" \
  '(.fields | map({(.name): .value}) | add) as $f | $f.host == "sabnzbd" and $f.apiKey == $k and $f.category == "*"' >/dev/null \
  || fail wire-apply "prowlarr SAB client POST (category must be \"*\")"
# SAB never gets a "prowlarr" category (it keeps its 7: *, and the 6 TRaSH ones).
! grep -q 'keyword=prowlarr' "$STUB_LOG" || fail wire-apply "a prowlarr SAB category was created"
# Root folders from the wiring table.
[[ "$(bodies "POST radarr /api/v3/rootfolder" | jq -r .path | paste -sd' ')" == "/data/media/movies /data/media/anime-movies" ]] \
  || fail wire-apply "radarr root folders"
bodies "POST lidarr /api/v1/rootfolder" | jq -e '.path == "/data/media/music" and .defaultQualityProfileId == 1 and .defaultMetadataProfileId == 1' >/dev/null \
  || fail wire-apply "lidarr root folder"
# Prowlarr apps.
bodies "POST prowlarr /api/v1/applications" | jq -se --arg k "$KEY" '
  (map(select(.name == "Sonarr Anime"))[0]) as $a
  | ($a.fields | map({(.name): .value}) | add) as $f
  | $a.syncLevel == "fullSync" and $f.animeSyncCategories == [5070] and $f.syncCategories == []
    and $f.baseUrl == "http://sonarr-anime:8989" and $f.prowlarrUrl == "http://prowlarr:9696" and $f.apiKey == $k
  and (map(.name) | sort) == ["Lidarr", "Radarr", "Radarr 4K", "Sonarr 4K", "Sonarr Anime"]
  and all(.[]; .syncLevel == "fullSync")' >/dev/null \
  || fail wire-apply "Prowlarr app POSTs (Sonarr Anime, 4K, Radarr, Lidarr)"
bodies "PUT prowlarr /api/v1/applications/2" | jq -e '.id == 2 and .name == "Sonarr" and .syncLevel == "fullSync"
  and ((.fields | map({(.name): .value}) | add).baseUrl == "http://sonarr:8989")' >/dev/null \
  || fail wire-apply "existing Sonarr app not PUT with fullSync"
bodies "POST prowlarr /api/v1/command" | jq -e '.name == "ApplicationIndexerSync" and .forceSync == true' >/dev/null \
  || fail wire-apply "ApplicationIndexerSync not posted"
grep -qx 'GET prowlarr /api/v1/command/1' "$STUB_LOG" || fail wire-apply "sync not awaited"
[[ "$(grep '^GET sabnzbd ' "$STUB_LOG" | tail -n 1)" == 'GET sabnzbd /api?mode=resume&output=json' ]] \
  || fail wire-apply "last SAB call is not mode=resume"
[[ "$(tail -n 1 "$STUB_LOG")" == 'GET sabnzbd /api?mode=resume&output=json' ]] || fail wire-apply "resume is not the last call"
no_secrets wire-apply "$OUT"
no_secrets wire-apply "$(cat "$T/bin/calls.log")"
ok "wire --apply: Usenet-only clients/indexers, 6 fullSync apps, stale app removed, sync, resume"

# 8b. Prowlarr app matching: by baseUrl host first (renaming the app), and
# never reusing an app whose host is stale, even if its name matches.
use_fixtures initial
jq --arg m '********' '[
  {id: 1, name: "Sonarr Anime", implementation: "Sonarr", syncLevel: "fullSync", fields: [
    {name: "prowlarrUrl", value: "http://prowlarr:9696"}, {name: "baseUrl", value: "http://animesonarr:8989"},
    {name: "apiKey", value: $m, privacy: "apiKey"}, {name: "syncCategories", value: []}, {name: "animeSyncCategories", value: [5070]}]},
  {id: 5, name: "Sonarr UHD", implementation: "Sonarr", syncLevel: "fullSync", fields: [
    {name: "prowlarrUrl", value: "http://prowlarr:9696"}, {name: "baseUrl", value: "http://SONARR-4K:8989/"},
    {name: "apiKey", value: $m, privacy: "apiKey"}, {name: "syncCategories", value: [5000]}, {name: "animeSyncCategories", value: [5070]}]}
  ]' -n > "$T/fx/prowlarr/GET_api_v1_applications.json"
# A schema default without anime categories: the script must still set them.
jq 'map(if .implementation == "Sonarr" then .fields |= map(if .name == "animeSyncCategories" then .value = [] else . end) else . end)' \
  "$FIX/initial/prowlarr/GET_api_v1_applications_schema.json" > "$T/fx/prowlarr/GET_api_v1_applications_schema.json"
run_capture env STUB_RUNNING="$CORE_UP" "$WIRE" --apply
expect wire-app-match 0 '\[INFO\] prowlarr: removing app Sonarr Anime'
grep -qx 'DELETE prowlarr /api/v1/applications/1' "$STUB_LOG" || fail wire-app-match "stale-host app not deleted"
! grep -q '^PUT prowlarr /api/v1/applications/1 ' "$STUB_LOG" || fail wire-app-match "stale-host app reused by name"
bodies "PUT prowlarr /api/v1/applications/5" | jq -e '.name == "Sonarr 4K" and .id == 5
  and ((.fields | map({(.name): .value}) | add).baseUrl == "http://sonarr-4k:8989")' >/dev/null \
  || fail wire-app-match "app not matched by baseUrl host (and renamed)"
bodies "POST prowlarr /api/v1/applications" | jq -se '
  (map(select(.name == "Sonarr Anime"))[0].fields | map({(.name): .value}) | add).animeSyncCategories == [5070]
  and (map(select(.name == "Sonarr"))[0].fields | map({(.name): .value}) | add).animeSyncCategories == []
  and (map(.name) | sort) == ["Lidarr", "Radarr", "Radarr 4K", "Sonarr", "Sonarr Anime"]' >/dev/null \
  || fail wire-app-match "app POSTs (Sonarr Anime must get animeSyncCategories [5070])"
ok "Prowlarr apps match by baseUrl host, then name; stale hosts are never reused"

# 8c. An existing Prowlarr SAB client with the schema's "prowlarr" category
# is PUT with SAB's default "*" (category is compared).
use_fixtures converged
jq 'map(.fields |= map(if .name == "category" then .value = "prowlarr" else . end))' \
  "$FIX/converged/prowlarr/GET_api_v1_downloadclient.json" > "$T/fx/prowlarr/GET_api_v1_downloadclient.json"
cp "$FIX/initial/prowlarr/POST_api_v1_command.json" "$T/fx/prowlarr/"
run_capture env STUB_RUNNING="$CORE_UP" "$WIRE" --apply
expect wire-prowlarr-category 0
bodies "PUT prowlarr /api/v1/downloadclient/3" | jq -e '.id == 3 and ((.fields | map({(.name): .value}) | add).category == "*")' >/dev/null \
  || fail wire-prowlarr-category "Prowlarr SAB client not PUT with category \"*\""
ok "an existing Prowlarr SAB client with category \"prowlarr\" is fixed to \"*\""

# 8d. The stub models Prowlarr's Category NotEmpty validation: an empty
# category is a 400 on POST and PUT (unless forceSave=true). A copy of the
# wire script that sends "" fails; the real one (above) does not. The copy
# lives in a scratch tree whose scripts/lib links to the real libs.
use_fixtures initial
mkdir -p "$T/ec/scripts/vm"
ln -sfn "$REPO/scripts/lib" "$T/ec/scripts/lib"
[[ ! -f "$REPO/.env" ]] || ln -sf "$REPO/.env" "$T/ec/.env"
sed 's/upsert_sab_client "\$p" "\$W\/p-dc.json" category "\*"/upsert_sab_client "$p" "$W\/p-dc.json" category ""/' \
  "$WIRE" > "$T/ec/scripts/vm/25-arr-wire.sh"
chmod +x "$T/ec/scripts/vm/25-arr-wire.sh"
grep -q 'p-dc.json" category ""$' "$T/ec/scripts/vm/25-arr-wire.sh" \
  || fail wire-prowlarr-empty-cat "could not make the empty-category copy"
run_capture env STUB_RUNNING="$CORE_UP" "$T/ec/scripts/vm/25-arr-wire.sh" --apply
expect wire-prowlarr-empty-cat 1 'POST prowlarr /api/v1/downloadclient -> HTTP 400'
bodies "POST prowlarr /api/v1/downloadclient" | jq -e '(.fields | map({(.name): .value}) | add).category == ""' >/dev/null \
  || fail wire-prowlarr-empty-cat "the copy did not send an empty category"
# Direct stub calls: PUT with "" -> 400 + validation body; forceSave=true or
# "*" -> 200; a non-downloadclient path is unaffected.
printf '%s' '{"id":3,"fields":[{"name":"category","value":""}]}' > "$T/empty-cat.json"
printf '%s' '{"id":3,"fields":[{"name":"category","value":"*"}]}' > "$T/star-cat.json"
for spec in "400 PUT downloadclient/3 empty-cat" "400 POST downloadclient empty-cat" \
            "200 PUT downloadclient/3?forceSave=true empty-cat" "200 PUT downloadclient/3 star-cat" \
            "200 POST applications empty-cat"; do
  read -r want m p f <<<"$spec"
  got="$(curl -sS -o "$T/stub-out.json" -w '%{http_code}' -X "$m" --data-binary "@$T/$f.json" \
    "http://172.30.0.11:9696/api/v1/$p" || true)"
  [[ "$got" == "$want" ]] || fail wire-prowlarr-empty-cat "stub: $m $p ($f) gave HTTP $got, want $want"
  if [[ "$want" == 400 ]]; then
    jq -e '.[0].propertyName == "Category" and .[0].isWarning' "$T/stub-out.json" >/dev/null \
      || fail wire-prowlarr-empty-cat "stub: no validation-error body for $m $p"
  fi
done
ok "an empty Prowlarr SAB category is rejected with HTTP 400 (stub models the validator)"

# ==============================================================================
# 9. Idempotency on converged fixtures (masked ******** everywhere)
# ==============================================================================
use_fixtures converged
run_capture env STUB_RUNNING="$CORE_UP" "$WIRE" --apply
expect wire-idempotent 0 '\[INFO\] no changes$'
[[ -z "$(mutating)" ]] || fail wire-idempotent "converged run made changes:"$'\n'"$(mutating)"
! grep -q ApplicationIndexerSync "$STUB_LOG" || fail wire-idempotent "sync ran without changes"
reset_stub
run_capture env STUB_RUNNING="$CORE_UP" "$WIRE"
expect wire-idempotent 0 '\[INFO\] no changes$'
refute wire-idempotent '^DRY-RUN:'
reset_stub
run_capture env STUB_RUNNING="$ARR_UP" "$REMAP" --apply
expect remap-idempotent 0 '\[INFO\] no changes$' '\[INFO\] sonarr: 0 items /data/shows -> /data/media/tv'
[[ -z "$(mutating)" ]] || fail remap-idempotent "converged remap made changes:"$'\n'"$(mutating)"
ok "converged fixtures: wire --apply and remap --apply make 0 mutating calls (no changes)"

# ==============================================================================
# 10. Non-2xx
# ==============================================================================
use_fixtures initial
run_capture env STUB_RUNNING="$CORE_UP" STUB_HTTP_prowlarr=500 "$WIRE"
expect wire-http-error 1 'GET prowlarr /api/v1/indexer -> HTTP 500'
no_secrets wire-http-error "$OUT"
reset_stub
run_capture env STUB_RUNNING="$CORE_UP" STUB_HTTP_prowlarr=500 "$WIRE" --apply
expect wire-http-error 1 'prowlarr .* -> HTTP 500'
no_secrets wire-http-error "$OUT"
ok "a non-2xx response exits 1 naming method, service and path, without the key"

# ==============================================================================
# 11. CLI errors
# ==============================================================================
run_capture "$REMAP" --bogus
expect cli-unknown 2
run_capture "$WIRE" --bogus
expect cli-unknown 2
run_capture "$WIRE" --only prowlarr
expect cli-unknown 2
run_capture "$WIRE" --only
expect cli-unknown 2
run_capture "$REMAP" --help
expect cli-help 0 'Usage: 20-arr-remap.sh'
run_capture "$WIRE" --help
expect cli-help 0 'Usage: 25-arr-wire.sh'
run_capture env LAN_IP=not-an-ip STUB_RUNNING=sabnzbd "$WIRE" --only sab
expect cli-lan-ip 1 "invalid LAN_IP"
for ip in 0.0.0.0 255.255.255.255; do
  run_capture env LAN_IP="$ip" STUB_RUNNING=sabnzbd "$WIRE" --only sab
  expect cli-lan-ip-reserved 1 "LAN_IP must be the VM's own LAN address"
done
ok "unknown flags exit 2, --help exits 0, a bad or 0.0.0.0/255.255.255.255 LAN_IP exits 1"

printf 'all arr script tests passed\n'
