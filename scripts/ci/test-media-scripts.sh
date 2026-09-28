#!/usr/bin/env bash
# shellcheck disable=SC2016
# (SC2016: single-quoted snippets below are expanded later by jq or bash -c.)
#
# scripts/ci/test-media-scripts.sh
#
# Tests scripts/vm/30-split-4k.sh and scripts/vm/verify-media.sh against the
# stub docker/curl from scripts/ci/make-api-stubs.sh, the synthetic JSON in
# scripts/ci/fixtures/media/ and a temp DATA_ROOT with real directories and
# small files. API keys are dummies written into a temp APPDATA_ROOT. Needs
# no root, no Docker daemon and no network.
# Prints "ok <case>" per case and exits 1 on the first failure.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPLIT="$REPO/scripts/vm/30-split-4k.sh"
VERIFY="$REPO/scripts/vm/verify-media.sh"
FIX="$REPO/scripts/ci/fixtures/media"
# verify-media's good set is layered over 02-03's converged API fixtures
# (SAB, download clients, indexers, Prowlarr apps, root folders).
API_FIX="$REPO/scripts/ci/fixtures/api"

T="$(mktemp -d)"
BG_PID=""
cleanup() {
  [[ -z "$BG_PID" ]] || kill "$BG_PID" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

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
# check-min-versions.sh reads `docker compose config --images`: the eight
# minimum images, as the real compose.yaml pins them.
STUB_IMAGES="$(awk '!/^#/ && NF == 2 { print $1 ":" $2 }' "$REPO/config/min-versions.txt")"
export STUB_IMAGES

# --- synthetic appdata ----------------------------------------------------------
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

export STUB_LOG="$T/api.log" STUB_STATE="$T/state"
SPLIT_UP="sonarr sonarr-anime sonarr-4k radarr radarr-4k"
CORE_UP="sabnzbd prowlarr sonarr sonarr-anime sonarr-4k radarr radarr-4k lidarr plex seerr tautulli"

# reset_stub: empty request log and call sequences, default stub env.
reset_stub() {
  rm -rf "$STUB_STATE"
  : > "$STUB_LOG"
  unset STUB_HEALTH
  export STUB_RUNNING=""
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

# ==============================================================================
# 30-split-4k.sh
# ==============================================================================
# The HD library on disk: one dir and a small file per title.
MOVIES=("Big 4K Movie (2019)" "HD Movie (2018)" "Unmonitored 4K Movie (2017)" "Tagged 4K Movie (2016)" "Scope Movie (2015)")
SHOWS=("UHD Show" "Mixed Show" "HD Show")
make_library() {
  local m
  rm -rf "$DATA_ROOT"
  mkdir -p "$DATA_ROOT"/media/{tv,anime-tv,tv-4k,movies,anime-movies,movies-4k,music} \
    "$DATA_ROOT"/usenet/complete/{tv,tv-4k,movies,movies-4k,music,anime} "$DATA_ROOT/usenet/incomplete"
  for m in "${MOVIES[@]}"; do
    mkdir -p "$DATA_ROOT/media/movies/$m"
    printf 'x\n' > "$DATA_ROOT/media/movies/$m/movie.mkv"
  done
  mkdir -p "$DATA_ROOT/media/anime-movies/Anime 4K Movie (2021)"
  printf 'x\n' > "$DATA_ROOT/media/anime-movies/Anime 4K Movie (2021)/movie.mkv"
  for m in "${SHOWS[@]}"; do
    mkdir -p "$DATA_ROOT/media/tv/$m/Season 01"
    printf 'x\n' > "$DATA_ROOT/media/tv/$m/Season 01/e01.mkv"
  done
}

# split_fixtures [overlay-dir]: a fresh copy of the split set.
split_fixtures() {
  rm -rf "$T/fx" "$APPDATA_ROOT/.migration"/split-4k-*
  cp -R "$FIX/split" "$T/fx"
  if [[ -n "${1:-}" ]]; then
    cp -R "$1/." "$T/fx/"
  fi
  export STUB_FIXTURES="$T/fx"
  reset_stub
}

# newest <glob-suffix>: the newest split-4k-* file matching it.
newest() {
  find "$APPDATA_ROOT/.migration" -maxdepth 1 -name "split-4k-*$1" | sort | tail -n 1
}

# --- 1. dry-run plan ------------------------------------------------------------
make_library
split_fixtures
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT"
expect split-plan 0 \
  '\[INFO\] plan: 3 move, 1 skip-mixed, 1 check, anime-4k=1 -> .*/split-4k-[0-9]{8}-[0-9]{6}\.tsv$' \
  '\[INFO\] skip-mixed: series sonarr 2 Mixed Show$' \
  '\[INFO\] check: movie radarr 15 Scope Movie$' \
  "^DRY-RUN: mv -T -- '$DATA_ROOT/media/movies/Big 4K Movie \(2019\)' '$DATA_ROOT/media/movies-4k/Big 4K Movie \(2019\)'$" \
  "^DRY-RUN: mv -T -- '$DATA_ROOT/media/tv/UHD Show' '$DATA_ROOT/media/tv-4k/UHD Show'$" \
  '3 titles to move \(dry-run'
PLAN="$(newest .tsv)"
[[ "$PLAN" != *manifest* && -f "$PLAN" ]] || fail split-plan "no plan TSV written"
[[ "$(stat -c %a "$PLAN")" == 600 ]] || fail split-plan "plan TSV mode is not 600"
[[ "$(head -n 1 "$PLAN")" == $'kind\tinstance\tid\ttitle\tsrc\tdst\tfiles\taction' ]] || fail split-plan "plan header"
got="$(tail -n +2 "$PLAN" | cut -f1-3,7,8 | tr '\t' ' ')"
want="movie radarr 11 1 move
movie radarr 13 1 move
movie radarr 15 1 check
series sonarr 1 2 move
series sonarr 2 2 skip-mixed"
[[ "$got" == "$want" ]] || fail split-plan "plan rows:"$'\n'"$got"
grep -qF $'series\tsonarr\t1\tUHD Show\t/data/media/tv/UHD Show\t/data/media/tv-4k/UHD Show\t2\tmove' "$PLAN" \
  || fail split-plan "series row src/dst"
[[ -z "$(mutating)" ]] || fail split-plan "dry-run made changes: $(mutating)"
[[ -d "$DATA_ROOT/media/movies/Big 4K Movie (2019)" && -z "$(ls -A "$DATA_ROOT/media/movies-4k")" ]] \
  || fail split-plan "dry-run moved files"
[[ -z "$(newest .manifest.tsv)" ]] || fail split-plan "dry-run wrote a manifest"
no_secrets split-plan "$OUT"
# A re-run after an apply: moved titles are tagged 4k-only in HD -> 0 moves.
jq 'map(if .id == 11 or .id == 13 then .tags += [7] else . end)' "$FIX/split/radarr/GET_api_v3_movie.json" \
  > "$T/fx/radarr/GET_api_v3_movie.json"
jq 'map(if .id == 1 then .tags += [5] else . end)' "$FIX/split/sonarr/GET_api_v3_series.json" \
  > "$T/fx/sonarr/GET_api_v3_series.json"
printf '[{"id":5,"label":"4k-only"}]\n' > "$T/fx/sonarr/GET_api_v3_tag.json"
reset_stub
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --apply
expect split-rerun 0 '\[INFO\] plan: 0 move, 1 skip-mixed, 1 check, anime-4k=1' '\[INFO\] nothing to move'
[[ -z "$(mutating)" ]] || fail split-rerun "a re-run made changes"
ok "split dry-run: move/skip-mixed/check rows, anime-4k=1, nothing moved; a re-run plans 0 moves"

# --- 2. missing 4K profile ------------------------------------------------------
split_fixtures
run_capture env STUB_RUNNING="$SPLIT_UP" QP_4K_RADARR=Nope "$SPLIT"
expect split-profile 1 "radarr-4k: quality profile 'Nope' not found; available: Any, Ultra-HD, HD-1080p"
split_fixtures "$FIX/split-noprofile"
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --apply
expect split-profile 1 "sonarr-4k: quality profile 'Ultra-HD' not found; available: Any, HD-1080p, UHD Bluray \+ WEB \(set QP_4K_SONARR\)"
[[ -z "$(mutating)" ]] || fail split-profile "changes made"
run_capture env STUB_RUNNING="$SPLIT_UP" QP_4K_SONARR="UHD Bluray + WEB" "$SPLIT"
expect split-profile 0 '\[INFO\] plan: 3 move'
ok "a missing 4K profile exits 1 listing the available names; QP_4K_* selects another"

# --- 3. preflight ---------------------------------------------------------------
make_library
split_fixtures
mkdir -p "$DATA_ROOT/media/tv-4k/UHD Show"
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --apply
expect split-preflight 1 \
  "\[ERROR\] preflight: series sonarr 1 UHD Show: $DATA_ROOT/media/tv-4k/UHD Show already exists" \
  'preflight failed for 1 of 3 move rows; nothing moved'
for m in "Big 4K Movie (2019)" "Unmonitored 4K Movie (2017)"; do
  [[ -f "$DATA_ROOT/media/movies/$m/movie.mkv" ]] || fail split-preflight "$m moved despite the failed preflight"
done
[[ -z "$(mutating)" ]] || fail split-preflight "changes made"
[[ -z "$(newest .manifest.tsv)" ]] || fail split-preflight "manifest written"
# A missing source, and a source outside the HD root, fail the same way.
rmdir "$DATA_ROOT/media/tv-4k/UHD Show"
rm -rf "$DATA_ROOT/media/movies/Big 4K Movie (2019)"
jq 'map(if .id == 13 then .path = "/data/media/other/Unmonitored 4K Movie (2017)" else . end)' \
  "$FIX/split/radarr/GET_api_v3_movie.json" > "$T/fx/radarr/GET_api_v3_movie.json"
reset_stub
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --apply
expect split-preflight 1 \
  "movie radarr 11 Big 4K Movie: $DATA_ROOT/media/movies/Big 4K Movie \(2019\) is missing" \
  'movie radarr 13 Unmonitored 4K Movie: /data/media/other/Unmonitored 4K Movie \(2017\) is not under /data/media/movies/' \
  'preflight failed for 2 of 3 move rows'
[[ -d "$DATA_ROOT/media/tv/UHD Show" ]] || fail split-preflight "series moved"
ok "preflight: an existing dst, a missing src or a src outside the HD root exits 1 with nothing moved"

# --- 4. apply -------------------------------------------------------------------
make_library
split_fixtures
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --apply
expect split-apply 0 "\[INFO\] moved 3/3: series 'UHD Show' -> sonarr-4k id 41" '\[INFO\] split: 3 titles moved'
for m in "Big 4K Movie (2019)" "Unmonitored 4K Movie (2017)"; do
  [[ -f "$DATA_ROOT/media/movies-4k/$m/movie.mkv" && ! -e "$DATA_ROOT/media/movies/$m" ]] || fail split-apply "$m not moved"
done
[[ -f "$DATA_ROOT/media/tv-4k/UHD Show/Season 01/e01.mkv" && ! -e "$DATA_ROOT/media/tv/UHD Show" ]] || fail split-apply "UHD Show not moved"
[[ -d "$DATA_ROOT/media/tv/Mixed Show" && -d "$DATA_ROOT/media/movies/Scope Movie (2015)" ]] \
  || fail split-apply "the mixed series or the check movie was moved"
# Per row, in order: lookup GET, POST to the 4K instance, 4K rescan, PUT to
# HD, HD rescan.
seq_of() { grep -E "$1" "$STUB_LOG" | sed 's/ body=.*//'; }
got="$(seq_of '^(GET (radarr|sonarr)-4k /api/v3/(movie|series)/lookup|POST (radarr|sonarr)(-4k)? /api/v3/(movie|series|command)|PUT (radarr|sonarr) )')"
want="GET radarr-4k /api/v3/movie/lookup/tmdb?tmdbId=1011
POST radarr-4k /api/v3/movie
POST radarr-4k /api/v3/command
PUT radarr /api/v3/movie/11
POST radarr /api/v3/command
GET radarr-4k /api/v3/movie/lookup/tmdb?tmdbId=1013
POST radarr-4k /api/v3/movie
POST radarr-4k /api/v3/command
PUT radarr /api/v3/movie/13
POST radarr /api/v3/command
GET sonarr-4k /api/v3/series/lookup?term=tvdb%3A2001
POST sonarr-4k /api/v3/series
POST sonarr-4k /api/v3/command
PUT sonarr /api/v3/series/1
POST sonarr /api/v3/command"
[[ "$got" == "$want" ]] || fail split-apply "calls out of order:"$'\n'"$got"
bodies "POST radarr-4k /api/v3/movie" | jq -se '
  length == 2 and all(.[]; .qualityProfileId == 4 and .rootFolderPath == "/data/media/movies-4k" and .monitored == true
    and .addOptions == {searchForMovie: false} and (has("id") | not))
  and .[0].path == "/data/media/movies-4k/Big 4K Movie (2019)" and .[0].tmdbId == 1011' >/dev/null \
  || fail split-apply "radarr-4k add payloads"
bodies "POST sonarr-4k /api/v3/series" | jq -e '.addOptions.monitor == "existing" and .addOptions.searchForMissingEpisodes == false
  and .path == "/data/media/tv-4k/UHD Show" and .tvdbId == 2001 and .qualityProfileId == 4' >/dev/null \
  || fail split-apply "sonarr-4k add payload"
# The lookup says seasonFolder false (as for any series not in the library);
# the add takes seasonFolder and seriesType from the HD item.
bodies "POST sonarr-4k /api/v3/series" | jq -e '.seasonFolder == true and .seriesType == "standard"' >/dev/null \
  || fail split-apply "sonarr-4k add payload: seasonFolder/seriesType not taken from HD"
grep -qF '"seasonFolder":true' <<<"$(bodies "POST sonarr-4k /api/v3/series")" \
  || fail split-apply 'series POST lacks "seasonFolder":true'
grep -qF '"monitor":"existing"' "$STUB_LOG" || fail split-apply 'series POST lacks "monitor":"existing"'
bodies "POST radarr-4k /api/v3/command" | jq -se 'map(.movieId) == [31, 32] and all(.[]; .name == "RescanMovie")' >/dev/null \
  || fail split-apply "radarr-4k rescans"
# HD rescans (HD ids), so HD drops hasFile/episodeFileCount right away.
bodies "POST radarr /api/v3/command" | jq -se 'map(.movieId) == [11, 13] and all(.[]; .name == "RescanMovie")' >/dev/null \
  || fail split-apply "radarr HD rescans after the PUT"
bodies "POST sonarr /api/v3/command" | jq -se 'length == 1 and .[0] == {name: "RescanSeries", seriesId: 1}' >/dev/null \
  || fail split-apply "sonarr HD rescan after the PUT"
bodies "PUT radarr /api/v3/movie/11" | jq -e '.monitored == false and .tags == [7] and .id == 11' >/dev/null \
  || fail split-apply "radarr HD PUT: monitored false + tag 7"
bodies "POST sonarr /api/v3/tag" | jq -e '.label == "4k-only"' >/dev/null || fail split-apply "sonarr tag not created"
bodies "PUT sonarr /api/v3/series/1" | jq -e '.monitored == false and .tags == [5] and all(.seasons[]; .monitored == false)' >/dev/null \
  || fail split-apply "sonarr HD PUT: monitored false, seasons unmonitored, tag 5"
! grep -qE '^[A-Z]+ [a-z-]+ /api/v3/(movie|series)/(2|12|15)( |$)' "$STUB_LOG" || fail split-apply "mixed/HD/check titles touched"
MAN="$(newest .manifest.tsv)"
[[ -f "$MAN" ]] || fail split-apply "no manifest"
[[ "$(head -n 1 "$MAN")" == $'kind\tinstance\tid\ttitle\tsrc\tdst\tfiles\taction\tnew_id\tprior' ]] \
  || fail split-apply "manifest header"
# prior: the HD monitored state before the split (13 was unmonitored;
# UHD Show's season 0 was unmonitored, and episode 1002 of the monitored
# season 1), read before the mv.
[[ "$(tail -n +2 "$MAN" | cut -f1-3,7-10 | tr '\t' ' ')" == 'movie radarr 11 1 move 31 {"m":true}
movie radarr 13 1 move 32 {"m":false}
series sonarr 1 2 move 41 {"m":true,"s":{"0":false,"1":true,"2":true},"e":[1002]}' ]] || fail split-apply "manifest rows:"$'\n'"$(cat "$MAN")"
[[ "$(grep -nE '^GET sonarr /api/v3/episode\?seriesId=1$|^PUT sonarr /api/v3/series/1 ' "$STUB_LOG" | cut -d: -f2 | cut -c1-24)" \
  == $'GET sonarr /api/v3/episo\nPUT sonarr /api/v3/serie' ]] || fail split-apply "episode list not read before the HD PUT"
# The new_id rewrite leaves no temp file behind; the manifest stays mode 600.
[[ -z "$(find "$APPDATA_ROOT/.migration" -name '.split-4k-manifest.*')" ]] || fail split-apply "manifest temp file left"
[[ "$(stat -c %a "$MAN")" == 600 ]] || fail split-apply "manifest mode is not 600"
no_secrets split-apply "$OUT"
ok "split --apply: moved on disk, add+rescan in 4K (HD seasonFolder), unmonitor+tag+rescan in HD (per row, in order), manifest with new ids and prior (unmonitored episodes in e)"

# --- 5. undo --------------------------------------------------------------------
# post_split_fixtures: HD as the apply left it (unmonitored, every season
# too, tagged 4k-only).
post_split_fixtures() {
  printf '[{"id":5,"label":"4k-only"}]\n' > "$T/fx/sonarr/GET_api_v3_tag.json"
  jq 'map(if .id == 1 then .monitored = false | .tags = [5] | .seasons |= map(.monitored = false) else . end)' \
    "$FIX/split/sonarr/GET_api_v3_series.json" > "$T/fx/sonarr/GET_api_v3_series.json"
  jq 'map(if .id == 11 or .id == 13 then .monitored = false | .tags = [7] else . end)' \
    "$FIX/split/radarr/GET_api_v3_movie.json" > "$T/fx/radarr/GET_api_v3_movie.json"
}
reset_stub
post_split_fixtures
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN"
expect split-undo-dry 0 "^DRY-RUN: DELETE sonarr-4k /api/v3/series/41\?deleteFiles=false$" \
  "^DRY-RUN: mv -T -- $MAN $MAN.undone$" 'undo of 3 rows \(dry-run'
[[ -z "$(mutating)" && -f "$MAN" && -d "$DATA_ROOT/media/tv-4k/UHD Show" ]] || fail split-undo-dry "dry-run changed something"
reset_stub
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN" --apply
expect split-undo 0 '\[INFO\] undone: 3 rows'
for m in "Big 4K Movie (2019)" "Unmonitored 4K Movie (2017)"; do
  [[ -f "$DATA_ROOT/media/movies/$m/movie.mkv" && ! -e "$DATA_ROOT/media/movies-4k/$m" ]] || fail split-undo "$m not moved back"
done
[[ -f "$DATA_ROOT/media/tv/UHD Show/Season 01/e01.mkv" && ! -e "$DATA_ROOT/media/tv-4k/UHD Show" ]] || fail split-undo "UHD Show not moved back"
got="$(seq_of '^(DELETE|PUT) ')"
want="DELETE sonarr-4k /api/v3/series/41?deleteFiles=false
PUT sonarr /api/v3/series/1
PUT sonarr /api/v3/episode/monitor
DELETE radarr-4k /api/v3/movie/32?deleteFiles=false
PUT radarr /api/v3/movie/13
DELETE radarr-4k /api/v3/movie/31?deleteFiles=false
PUT radarr /api/v3/movie/11"
[[ "$got" == "$want" ]] || fail split-undo "undo calls not in reverse row order:"$'\n'"$got"
# The monitored state from prior: season 0 and movie 13 were unmonitored
# before the split and stay so.
bodies "PUT sonarr /api/v3/series/1" | jq -e '.monitored == true and .tags == []
  and (.seasons | map({(.seasonNumber | tostring): .monitored}) | add) == {"0": false, "1": true, "2": true}' >/dev/null \
  || fail split-undo "sonarr HD: prior monitored state (season 0 false) not restored, or tag kept"
bodies "PUT radarr /api/v3/movie/13" | jq -e '.monitored == false and .tags == []' >/dev/null \
  || fail split-undo "radarr movie 13: prior monitored=false not restored, or tag kept"
bodies "PUT radarr /api/v3/movie/11" | jq -e '.monitored == true and .tags == []' >/dev/null \
  || fail split-undo "radarr movie 11 not re-monitored without the tag"
refute split-undo '\[WARN\]'
# Sonarr re-monitors every episode of season 1 on that PUT; episode 1002,
# unmonitored before the split, is unmonitored again.
bodies "PUT sonarr /api/v3/episode/monitor" | jq -se '. == [{episodeIds: [1002], monitored: false}]' >/dev/null \
  || fail split-undo "episode 1002 not unmonitored again after the HD PUT"
expect split-undo 0 '\[INFO\] PUT sonarr /api/v3/episode/monitor$'
# The HD state a clean undo leaves (compared with a resumed undo in 5c).
CLEAN_UNDO="$(grep -E '^(PUT|DELETE) ' "$STUB_LOG")"
bodies "POST sonarr /api/v3/command" | jq -e '.name == "RescanSeries" and .seriesId == 1' >/dev/null || fail split-undo "HD not rescanned"
[[ -f "$MAN.undone" && ! -e "$MAN" ]] || fail split-undo "manifest not renamed to .undone"
# A second undo of the same (now renamed) manifest is refused.
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN" --apply
expect split-undo 1 "no manifest $MAN"
no_secrets split-undo "$OUT"
ok "split --undo --apply: moved back, 4K item deleted (deleteFiles=false), HD monitored state from prior, in reverse order"

# --- 5a. a manifest without prior (older header): all re-monitored, [WARN] -------
make_library
split_fixtures
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --apply
expect split-undo-legacy 0 '\[INFO\] split: 3 titles moved'
MAN="$(newest .manifest.tsv)"
# A malformed prior fails the undo preflight, with nothing moved.
cp "$MAN" "$T/man.bak"
sed -i '2 s/\t{[^\t]*}$/\t{"m":"yes"}/' "$MAN"
reset_stub
post_split_fixtures
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN" --apply
expect split-undo-legacy 1 '\[ERROR\] undo preflight: malformed row: movie' 'undo preflight failed for 1 of 3 rows; nothing moved'
[[ -z "$(mutating)" && -d "$DATA_ROOT/media/movies-4k/Big 4K Movie (2019)" ]] || fail split-undo-legacy "changes despite a malformed prior"
# The older format: the same rows without the prior column.
cut -f1-9 "$T/man.bak" > "$MAN"
reset_stub
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN" --apply
expect split-undo-legacy 0 "\[WARN\] $MAN has no prior column \(older manifest\)" '\[INFO\] undone: 3 rows'
bodies "PUT sonarr /api/v3/series/1" | jq -e '.monitored == true and .tags == [] and all(.seasons[]; .monitored == true)' >/dev/null \
  || fail split-undo-legacy "sonarr HD not re-monitored (seasons too) without the tag"
bodies "PUT radarr /api/v3/movie/13" | jq -e '.monitored == true and .tags == []' >/dev/null \
  || fail split-undo-legacy "radarr HD not re-monitored"
[[ -d "$DATA_ROOT/media/tv/UHD Show" && -f "$MAN.undone" ]] || fail split-undo-legacy "not undone"
ok "an older manifest (no prior) re-monitors everything with a [WARN]; a malformed prior fails the undo preflight"

# --- 5b. a failure after a row's mv: reported, and --undo recovers it -----------
make_library
split_fixtures
printf '500\n' > "$T/fx/sonarr-4k/GET_api_v3_series_lookup_term_tvdb%3A2001.http"
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --apply
MAN="$(newest .manifest.tsv)"
expect split-partial 1 'GET sonarr-4k /api/v3/series/lookup\?term=tvdb%3A2001 -> HTTP 500' \
  "\[ERROR\] row 3 partially applied; run --undo $MAN$"
[[ "$(tail -n 1 "$MAN" | cut -f2,3,9,10)" == $'sonarr\t1\t-\t{"m":true,"s":{"0":false,"1":true,"2":true},"e":[1002]}' ]] \
  || fail split-partial "partial row not in the manifest with new_id - and its prior"
! grep -q '^PUT sonarr ' "$STUB_LOG" || fail split-partial "HD series changed after a failed add"
reset_stub
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN" --apply
expect split-partial-undo 0 '\[INFO\] undone: 3 rows'
[[ -d "$DATA_ROOT/media/tv/UHD Show" && -d "$DATA_ROOT/media/movies/Big 4K Movie (2019)" ]] || fail split-partial-undo "not moved back"
! grep -q '^DELETE sonarr-4k ' "$STUB_LOG" || fail split-partial-undo "DELETE for a row that was never added"
[[ "$(grep -c '^DELETE radarr-4k ' "$STUB_LOG")" -eq 2 ]] || fail split-partial-undo "movie rows not deleted from radarr-4k"
ok "a failure after a row's mv names the row and the manifest; --undo --apply reverses the partial row too"

# --- 5c. an undo that stops mid-way can be re-run -------------------------------
make_library
split_fixtures
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --apply
expect split-undo-resume 0 '\[INFO\] split: 3 titles moved'
MAN="$(newest .manifest.tsv)"
# Undo runs rows 3, 2, 1; row 2's DELETE fails after its folder moved back.
reset_stub
post_split_fixtures
printf '500\n' > "$T/fx/radarr-4k/DELETE_api_v3_movie_32_deleteFiles_false.http"
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN" --apply
expect split-undo-resume 1 'DELETE radarr-4k /api/v3/movie/32\?deleteFiles=false -> HTTP 500' \
  "\[ERROR\] undo stopped at row 2; re-run the same --undo command to continue$"
[[ -f "$MAN" && ! -e "$MAN.undone" ]] || fail split-undo-resume "manifest renamed although a row failed"
[[ -d "$DATA_ROOT/media/movies/Unmonitored 4K Movie (2017)" && ! -e "$DATA_ROOT/media/movies-4k/Unmonitored 4K Movie (2017)" \
  && -d "$DATA_ROOT/media/movies-4k/Big 4K Movie (2019)" ]] || fail split-undo-resume "row 2 not moved back or row 1 touched"
FIRST_LOG="$(cat "$STUB_LOG")"
# The re-run: row 3 (fully undone) and row 2 (moved back) are resumed:
# no mv; row 3's 4K series is gone (404 counts as done), row 2's DELETE
# now works; their HD PUTs and rescans are sent again.
rm -f "$T/fx/radarr-4k/DELETE_api_v3_movie_32_deleteFiles_false.http"
printf '404\n' > "$T/fx/sonarr-4k/DELETE_api_v3_series_41_deleteFiles_false.http"
reset_stub
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN" --apply
expect split-undo-resume 0 '\[INFO\] undone: 3 rows' \
  '\[INFO\] row 3: /data/media/tv-4k/UHD Show is gone and /data/media/tv/UHD Show exists \(moved back by an earlier undo\); not moving it$' \
  '\[INFO\] row 2: /data/media/movies-4k/Unmonitored 4K Movie \(2017\) is gone and .* not moving it$' \
  '\[INFO\] DELETE sonarr-4k /api/v3/series/41\?deleteFiles=false: already deleted \(HTTP 404\)$' \
  '\[INFO\] DELETE radarr-4k /api/v3/movie/32\?deleteFiles=false$'
refute split-undo-resume 'row 1: .*not moving it'
for m in "Big 4K Movie (2019)" "Unmonitored 4K Movie (2017)"; do
  [[ -f "$DATA_ROOT/media/movies/$m/movie.mkv" && ! -e "$DATA_ROOT/media/movies-4k/$m" ]] || fail split-undo-resume "$m not moved back"
done
[[ -f "$DATA_ROOT/media/tv/UHD Show/Season 01/e01.mkv" && ! -e "$DATA_ROOT/media/tv-4k/UHD Show" ]] || fail split-undo-resume "UHD Show not moved back"
[[ -f "$MAN.undone" && ! -e "$MAN" ]] || fail split-undo-resume "manifest not renamed to .undone"
# Final state = a clean undo: the re-run sends the same DELETE/PUT requests
# (same bodies, same order) as the clean undo in case 5, and every 4K item
# was deleted (41 in the first run, 32 and 31 in the re-run).
[[ "$(grep -E '^(PUT|DELETE) ' "$STUB_LOG")" == "$CLEAN_UNDO" ]] \
  || fail split-undo-resume "re-run requests differ from a clean undo:"$'\n'"$(grep -E '^(PUT|DELETE) ' "$STUB_LOG")"
grep -qx 'DELETE sonarr-4k /api/v3/series/41?deleteFiles=false' <<<"$FIRST_LOG" || fail split-undo-resume "series 41 not deleted in the first run"
no_secrets split-undo-resume "$OUT"
ok "an undo that stops at a row (exit 1, re-run hint) re-runs to the clean-undo state: no second mv, 404 on DELETE counts as done"

# --- 5d. an empty src recreated by an HD rescan does not block undo -------------
make_library
split_fixtures
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --apply
MAN="$(newest .manifest.tsv)"
reset_stub
post_split_fixtures
# A file in the recreated src: refused, nothing moved.
mkdir -p "$DATA_ROOT/media/tv/UHD Show"
printf 'x\n' > "$DATA_ROOT/media/tv/UHD Show/new.nfo"
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN" --apply
expect split-undo-emptysrc 1 \
  '\[ERROR\] undo preflight: series sonarr 1 UHD Show: /data/media/tv/UHD Show already exists and is not an empty directory' \
  'undo preflight failed for 1 of 3 rows; nothing moved'
refute split-undo-emptysrc 'undo stopped at row'
[[ -z "$(mutating)" && -d "$DATA_ROOT/media/tv-4k/UHD Show" && -f "$MAN" ]] || fail split-undo-emptysrc "changes despite a non-empty src"
# The same src, empty (as createEmptySeriesFolders leaves it): removed, then undone.
rm "$DATA_ROOT/media/tv/UHD Show/new.nfo"
mkdir -p "$DATA_ROOT/media/movies/Big 4K Movie (2019)"
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN"
expect split-undo-emptysrc 0 "^DRY-RUN: rmdir -- '$DATA_ROOT/media/tv/UHD Show'$" \
  '\[INFO\] row 3: removing the empty /data/media/tv/UHD Show \(recreated by an HD rescan\)$'
[[ -d "$DATA_ROOT/media/tv/UHD Show" && -z "$(mutating)" ]] || fail split-undo-emptysrc "dry-run changed something"
reset_stub
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN" --apply
expect split-undo-emptysrc 0 '\[INFO\] undone: 3 rows' '\[INFO\] row 1: removing the empty /data/media/movies/Big 4K Movie \(2019\)'
[[ -f "$DATA_ROOT/media/tv/UHD Show/Season 01/e01.mkv" && ! -e "$DATA_ROOT/media/tv-4k/UHD Show" ]] || fail split-undo-emptysrc "UHD Show not moved back"
[[ -f "$DATA_ROOT/media/movies/Big 4K Movie (2019)/movie.mkv" && ! -e "$DATA_ROOT/media/movies/Big 4K Movie (2019)/Big 4K Movie (2019)" ]] \
  || fail split-undo-emptysrc "Big 4K Movie not moved back in place"
[[ "$(grep -E '^(PUT|DELETE) ' "$STUB_LOG")" == "$CLEAN_UNDO" ]] || fail split-undo-emptysrc "requests differ from a clean undo"
ok "undo removes an empty src dir before the mv; a src with a file in it is refused with nothing moved"

# --- 5e. prior with e: validated; older prior values without e still undo ------
make_library
split_fixtures
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --apply
MAN="$(newest .manifest.tsv)"
cp "$MAN" "$T/man.bak"
sed -i '4 s/"e":\[1002\]/"e":["x"]/' "$MAN"
reset_stub
post_split_fixtures
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN" --apply
expect split-undo-prior-e 1 '\[ERROR\] undo preflight: malformed row: series' 'nothing moved'
[[ -z "$(mutating)" ]] || fail split-undo-prior-e "changes despite a malformed e"
sed 's/,"e":\[1002\]//' "$T/man.bak" > "$MAN"
reset_stub
run_capture env STUB_RUNNING="$SPLIT_UP" "$SPLIT" --undo "$MAN" --apply
expect split-undo-prior-e 0 '\[INFO\] undone: 3 rows'
refute split-undo-prior-e '\[WARN\]'
! grep -q '^PUT sonarr /api/v3/episode/monitor' "$STUB_LOG" || fail split-undo-prior-e "episode PUT without e"
ok "a malformed prior e fails the undo preflight; a prior without e undoes with no episode PUT"

# --- 6. CLI ---------------------------------------------------------------------
run_capture "$SPLIT" --bogus
expect split-cli 2
run_capture "$SPLIT" --undo
expect split-cli 2
run_capture "$SPLIT" --help
expect split-cli 0 'Usage: 30-split-4k.sh'
ok "split: unknown flag or --undo without a manifest exits 2, --help exits 0"

# ==============================================================================
# verify-media.sh
# ==============================================================================
IDS="compose-healthy image-versions arr-rootfolders library-adopted no-regrab sab-categories download-clients prowlarr-sync 4k-split plex-sections plex-watched plex-counts plex-hw seerr-servers jellyfin"
SINCE='GET_api_v3_history_since_date_2026-09-28T00%3A00%3A00Z_eventType_grabbed'

# verify_fixtures: converged API set + the verify good set, and the
# baseline, baseline ids, split plan and manifest in APPDATA_ROOT.
verify_fixtures() {
  rm -rf "$T/fx" "$APPDATA_ROOT/.migration"
  cp -R "$API_FIX/converged" "$T/fx"
  cp -R "$FIX/verify/good/." "$T/fx/"
  cp -R "$FIX/verify/migration" "$APPDATA_ROOT/.migration"
  export STUB_FIXTURES="$T/fx"
  reset_stub
}
# run_verify: verify-media.sh with every core service up.
run_verify() {
  run_capture env STUB_RUNNING="$CORE_UP" PLEX_PAGE_SIZE=2 "$VERIFY"
}
# line_of <id>: the result line of one check.
line_of() {
  grep -E "^(PASS|FAIL|SKIP) $1( |$)" <<<"$OUT" || true
}
# result <case> <PASS|FAIL|SKIP> <id> [<detail pattern>]
result() {
  local l
  l="$(line_of "$3")"
  [[ "$l" == "$2 $3"* ]] || fail "$1" "expected $2 $3, got: ${l:-nothing}"
  if [[ -n "${4:-}" ]] && ! grep -qE -- "$4" <<<"$l"; then
    fail "$1" "$3 detail does not match: $4"
  fi
}

# --- 7. all good ----------------------------------------------------------------
make_library
verify_fixtures
run_verify
expect verify-good 0 '^RESULT: 14 pass, 0 fail, 1 skip$'
[[ "$(grep -cE '^PASS ' <<<"$OUT")" -eq 14 ]] || fail verify-good "not 14 PASS lines"
result verify-good PASS plex-hw 'decode=vaapi encode=vaapi'
result verify-good SKIP jellyfin 'not running'
result verify-good PASS 4k-split 'mixed=1'
result verify-good PASS library-adopted 'sonarr 19\+6>=25; sonarr-anime 12\+0>=12; radarr 2\+1>=3'
result verify-good PASS plex-watched 'watched movies\+episodes=5 >= baseline 5'
[[ "$(grep -oE '^(PASS|FAIL|SKIP) [a-z0-9-]+' <<<"$OUT" | cut -d' ' -f2 | paste -sd' ' -)" == "$IDS" ]] \
  || fail verify-good "check IDs not in the spec order"
[[ -z "$(mutating)" ]] || fail verify-good "verify made a mutating call: $(mutating)"
[[ -s "$STUB_LOG" ]] || fail verify-good "no API call logged"
no_secrets verify-good "$OUT"
no_secrets verify-good "$(cat "$T/bin/calls.log")"
ok "verify all good: 14 PASS (plex-hw included), jellyfin SKIP, spec order, read-only, exit 0"

# Manifests are read by header name: an older one (no prior) and one with
# the columns in another order count the same.
VMAN="$APPDATA_ROOT/.migration/split-4k-20260928-120000.manifest.tsv"
for form in legacy reordered; do
  if [[ $form == legacy ]]; then
    cut -f1-9 "$FIX/verify/migration/${VMAN##*/}" > "$VMAN"
  else
    awk -F'\t' -v OFS='\t' '{ print $10, $9, $1, $2, $3, $4, $5, $6, $8, $7 }' "$FIX/verify/migration/${VMAN##*/}" > "$VMAN"
  fi
  reset_stub
  run_verify
  expect "verify-manifest-$form" 0 '^RESULT: 14 pass, 0 fail, 1 skip$'
  result "verify-manifest-$form" PASS library-adopted 'sonarr 19\+6>=25; sonarr-anime 12\+0>=12; radarr 2\+1>=3'
done
# (the reordered manifest's new_id still protects the 4K series from a re-grab)
printf '[{"id":900,"eventType":"grabbed","date":"2026-09-28T10:00:00Z","sourceTitle":"X","seriesId":1}]\n' \
  > "$T/fx/sonarr-4k/$SINCE.json"
reset_stub
run_verify
result verify-manifest-reordered FAIL no-regrab 're-grabbed: sonarr-4k seriesId=1 '
verify_fixtures  # the good set again for the next case
ok "verify reads manifests by header name: an older manifest (no prior) and reordered columns count the same"

# --- 8. unhealthy service -------------------------------------------------------
reset_stub
run_capture env STUB_RUNNING="$CORE_UP" STUB_HEALTH="sonarr=unhealthy" PLEX_PAGE_SIZE=2 "$VERIFY"
expect verify-unhealthy 1 '^RESULT: 13 pass, 1 fail, 1 skip$'
result verify-unhealthy FAIL compose-healthy 'sonarr=running/unhealthy'
reset_stub
run_capture env STUB_RUNNING="${CORE_UP/ tautulli/}" PLEX_PAGE_SIZE=2 "$VERIFY"
expect verify-unhealthy 1
result verify-unhealthy FAIL compose-healthy 'tautulli=absent'
ok "an unhealthy or missing core service fails compose-healthy (exit 1)"

# --- 9. old root left -------------------------------------------------------------
verify_fixtures
printf '[{"id":1,"path":"/data/shows/"},{"id":7,"path":"/data/media/tv/"}]\n' > "$T/fx/sonarr/GET_api_v3_rootfolder.json"
jq '.[0].path = "/data/movies/Movie A (2001)"' "$FIX/verify/good/radarr/GET_api_v3_movie.json" > "$T/fx/radarr/GET_api_v3_movie.json"
run_verify
expect verify-oldroot 1
result verify-oldroot FAIL arr-rootfolders 'sonarr roots=/data/media/tv,/data/shows \(want /data/media/tv\); radarr: 1 items under'
ok "a leftover old root folder or item path fails arr-rootfolders"

# --- 10. regrab -----------------------------------------------------------------
grab() { # grab <field> <id> <date>
  jq -n --arg f "$1" --argjson id "$2" --arg d "$3" '[{id: 900, eventType: "grabbed", date: $d, sourceTitle: "Some.Release.1080p",
    ($f): $id}]'
}
verify_fixtures
grab episodeId 101 2026-09-28T10:00:00Z > "$T/fx/sonarr/$SINCE.json"
run_verify
expect verify-regrab 1
result verify-regrab FAIL no-regrab 're-grabbed: sonarr episodeId=101 Some\.Release\.1080p; other=0'
verify_fixtures
grab episodeId 999 2026-09-28T10:00:00Z > "$T/fx/sonarr/$SINCE.json"
run_verify
expect verify-regrab 0
result verify-regrab PASS no-regrab 'other=1$'
verify_fixtures
grab seriesId 1 2026-09-28T10:00:00Z > "$T/fx/sonarr-4k/$SINCE.json"
run_verify
expect verify-regrab 1
result verify-regrab FAIL no-regrab 're-grabbed: sonarr-4k seriesId=1 '
# history/since 404 -> paged /history, filtered by date >= baseline.
verify_fixtures
printf '404\n' > "$T/fx/radarr/$SINCE.http"
jq -n '{page: 1, pageSize: 250, totalRecords: 3, records: [
  {id: 3, movieId: 30, eventType: "grabbed", date: "2026-09-29T08:00:00Z", sourceTitle: "New.Movie.2026"},
  {id: 2, movieId: 21, eventType: "downloadFolderImported", date: "2026-09-28T20:00:00Z", sourceTitle: "Movie.A"},
  {id: 1, movieId: 21, eventType: "grabbed", date: "2026-09-20T08:00:00Z", sourceTitle: "Movie.A.Old"}]}' \
  > "$T/fx/radarr/GET_api_v3_history_page_1_pageSize_250_sortKey_date_sortDirection_descending_eventType_1.json"
run_verify
expect verify-regrab-fallback 0
result verify-regrab-fallback PASS no-regrab 'other=1$'
grep -qx 'GET radarr /api/v3/history?page=1&pageSize=250&sortKey=date&sortDirection=descending&eventType=1' "$STUB_LOG" \
  || fail verify-regrab-fallback "no fallback to the paged /history"
jq '.records[0].movieId = 23' "$T/fx/radarr/GET_api_v3_history_page_1_pageSize_250_sortKey_date_sortDirection_descending_eventType_1.json" \
  > "$T/h.json" && mv "$T/h.json" "$T/fx/radarr/GET_api_v3_history_page_1_pageSize_250_sortKey_date_sortDirection_descending_eventType_1.json"
reset_stub
run_verify
result verify-regrab-fallback FAIL no-regrab 're-grabbed: radarr movieId=23 New\.Movie\.2026; other=0'
ok "no-regrab: baseline and split items fail, new grabs are other=<n>, a history/since 404 falls back to /history"

# --- 11. torrent leftover ---------------------------------------------------------
verify_fixtures
jq '. + [{id: 9, enable: true, protocol: "torrent", name: "qBittorrent", implementation: "QBittorrent",
  fields: [{name: "host", value: "qbittorrent"}, {name: "port", value: 8080}]}]' \
  "$API_FIX/converged/sonarr/GET_api_v3_downloadclient.json" > "$T/fx/sonarr/GET_api_v3_downloadclient.json"
jq '. + [{id: 3, name: "OldTracker", protocol: "torrent", enable: true}]' \
  "$API_FIX/converged/radarr/GET_api_v3_indexer.json" > "$T/fx/radarr/GET_api_v3_indexer.json"
run_verify
expect verify-torrent 1
result verify-torrent FAIL download-clients 'sonarr: 2 clients \(Sabnzbd,QBittorrent\); radarr: 1 torrent indexers'
ok "a qBittorrent client or a torrent indexer fails download-clients"

# --- 12. 4K leak -------------------------------------------------------------------
verify_fixtures
jq '. + [{id: 24, title: "Leak Movie", path: "/data/media/movies/Leak Movie (2019)", hasFile: true, monitored: true, tags: []}]' \
  "$FIX/verify/good/radarr/GET_api_v3_movie.json" > "$T/fx/radarr/GET_api_v3_movie.json"
printf '[{"id":124,"quality":{"quality":{"name":"WEBDL-2160p","resolution":2160}},"mediaInfo":{"resolution":"3840x2160"}}]\n' \
  > "$T/fx/radarr/GET_api_v3_moviefile_movieId_24.json"
run_verify
expect verify-4k-leak 1
result verify-4k-leak FAIL 4k-split "radarr movie 24 'Leak Movie'; mixed=1"
# The skip-mixed series is exempt only while the newest plan lists it.
verify_fixtures
printf '[{"id":31,"quality":{"quality":{"resolution":2160}}}]\n' > "$T/fx/sonarr/GET_api_v3_episodefile_seriesId_3.json"
run_verify
result verify-4k-mixed PASS 4k-split 'mixed=1'
printf 'kind\tinstance\tid\ttitle\tsrc\tdst\tfiles\taction\n' > "$APPDATA_ROOT/.migration/split-4k-20260929-000000.tsv"
reset_stub
run_verify
result verify-4k-mixed FAIL 4k-split "sonarr series 3 'Mixed Show'; mixed=0"
rm -f "$APPDATA_ROOT/.migration"/split-4k-*.tsv
reset_stub
run_verify
result verify-4k-mixed SKIP 4k-split 'no split-4k-\*\.tsv plan'
ok "4k-split fails on a monitored HD item with a 2160p file unless the newest plan lists it skip-mixed"

# --- 13. Plex ------------------------------------------------------------------------
verify_fixtures
jq '.MediaContainer.Setting |= map(if .id == "autoEmptyTrash" then .value = true else . end)' \
  "$FIX/verify/good/plex/GET_:_prefs.json" > "$T/fx/plex/GET_:_prefs.json"
jq '.MediaContainer.Directory[1].Location += [{"id": 9, "path": "/data/shows"}]' \
  "$FIX/verify/good/plex/GET_library_sections.json" > "$T/fx/plex/GET_library_sections.json"
run_verify
expect verify-plex-sections 1
result verify-plex-sections FAIL plex-sections 'TV Shows=/data/media/tv,/data/shows; TV Shows at /data/shows; autoEmptyTrash=true \(want 0\)'
verify_fixtures
jq '.plex_watched = 6' "$FIX/verify/migration/baseline.json" > "$APPDATA_ROOT/.migration/baseline.json"
run_verify
result verify-plex-watched FAIL plex-watched 'watched movies\+episodes=5 < baseline 6; do not empty the Plex trash'
jq '.plex_watched = -1' "$FIX/verify/migration/baseline.json" > "$APPDATA_ROOT/.migration/baseline.json"
reset_stub
run_verify
result verify-plex-watched SKIP plex-watched 'plex_watched=-1 .*spot-check'
grep -q 'X-Plex-Container-Start=2&X-Plex-Container-Size=2' <<<"$(cat "$STUB_LOG")" \
  && fail verify-plex-watched "pages fetched although the baseline is -1"
verify_fixtures
run_verify
grep -qx 'GET plex /library/sections/2/all?type=4&X-Plex-Container-Start=2&X-Plex-Container-Size=2' "$STUB_LOG" \
  || fail verify-plex-watched "second page of TV Shows not fetched"
C2="$T/fx/plex/GET_library_sections_2_all_X-Plex-Container-Start_0_X-Plex-Container-Size_0.json"
printf '{"MediaContainer":{"size":0,"totalSize":2}}\n' > "$C2"
reset_stub
run_verify
expect verify-plex-counts 1
result verify-plex-counts FAIL plex-counts 'TV Shows plex=2 sonarr=3 \(-1\).*\(tolerance 0\)$'
reset_stub
run_capture env STUB_RUNNING="$CORE_UP" PLEX_PAGE_SIZE=2 PLEX_COUNT_TOLERANCE=1 "$VERIFY"
result verify-plex-counts PASS plex-counts 'TV Shows plex=2 sonarr=3 \(-1\)'
printf '{"MediaContainer":{"size":0,"totalSize":4}}\n' > "$C2"
reset_stub
run_verify
result verify-plex-counts PASS plex-counts 'TV Shows plex=4 sonarr=3 \(\+1\)'
printf '{"MediaContainer":{"size":0}}\n' > "$T/fx/plex/GET_status_sessions.json"
reset_stub
run_verify
expect verify-plex-hw 0
result verify-plex-hw SKIP plex-hw 'no transcode session; play a title with a forced transcode'
printf '{"MediaContainer":{"size":1,"Metadata":[{"TranscodeSession":{"transcodeHwRequested":1,"transcodeHwEncoding":"vaapi"}}]}}\n' \
  > "$T/fx/plex/GET_status_sessions.json"
reset_stub
run_verify
result verify-plex-hw PASS plex-hw 'encode=vaapi'
printf '{"MediaContainer":{"size":1,"Metadata":[{"TranscodeSession":{"transcodeHwRequested":false,"videoDecision":"transcode"}}]}}\n' \
  > "$T/fx/plex/GET_status_sessions.json"
reset_stub
run_verify
result verify-plex-hw FAIL plex-hw '1 transcode sessions, none hardware'
ok "plex: trash/section/location, watched vs baseline (-1 SKIP), counts with tolerance, HW session (none SKIP)"

# --- 13b. Seerr --------------------------------------------------------------------
verify_fixtures
jq 'map(if .hostname == "sonarr-anime" then .isDefault = true else . end) + [{name: "Old", hostname: "192.168.1.5", port: 8989, is4k: false, isDefault: false}]' \
  "$FIX/verify/good/seerr/GET_api_v1_settings_sonarr.json" > "$T/fx/seerr/GET_api_v1_settings_sonarr.json"
jq '.libraries |= map(if .name == "TV 4K" then .enabled = false else . end)' \
  "$FIX/verify/good/seerr/GET_api_v1_settings_plex.json" > "$T/fx/seerr/GET_api_v1_settings_plex.json"
run_verify
result verify-seerr FAIL seerr-servers 'sonarr sonarr-anime: is4k=false isDefault=true port=8989; sonarr: unexpected server Old at 192\.168\.1\.5; plex library TV 4K not enabled'
printf '404\n' > "$T/fx/seerr/GET_api_v1_settings_radarr.http"
reset_stub
run_verify
result verify-seerr FAIL seerr-servers 'GET seerr /api/v1/settings/radarr -> HTTP 404 \(Seerr settings API path not found'
ok "seerr-servers: wrong default/extra server/disabled library fail; a settings 404 fails with a hint"

# --- 14. no baseline --------------------------------------------------------------
verify_fixtures
rm -f "$APPDATA_ROOT/.migration/baseline.json"
run_verify
expect verify-nobaseline 0 '^RESULT: 11 pass, 0 fail, 4 skip$'
for id in library-adopted no-regrab plex-watched; do
  result verify-nobaseline SKIP "$id" 'no .*baseline\.json'
done
result verify-nobaseline PASS sab-categories 'pre-baseline job check skipped'
ok "without baseline.json: library-adopted, no-regrab, plex-watched SKIP; sab-categories skips its baseline part"

# --- 14b. API errors and bad responses fail one check, not the run ---------------
verify_fixtures
run_capture env STUB_RUNNING="$CORE_UP" PLEX_PAGE_SIZE=2 STUB_HTTP_prowlarr=500 "$VERIFY"
expect verify-api-error 1 '^RESULT: 12 pass, 2 fail, 1 skip$'
result verify-api-error FAIL download-clients 'GET prowlarr /api/v1/downloadclient -> HTTP 500'
result verify-api-error FAIL prowlarr-sync 'GET prowlarr /api/v1/applications -> HTTP 500'
no_secrets verify-api-error "$OUT"
printf 'not json\n' > "$T/fx/plex/GET_status_sessions.json"
reset_stub
run_verify
result verify-bad-json FAIL plex-hw 'unexpected error'
[[ "$(line_of seerr-servers)" == PASS* ]] || fail verify-bad-json "checks after the bad response did not run"
reset_stub
run_capture env STUB_RUNNING="$CORE_UP" PLEX_PAGE_SIZE=2 STUB_IMAGES="lscr.io/linuxserver/sonarr:4.0.19.2979-ls320" "$VERIFY"
result verify-images FAIL image-versions 'BELOW-MIN: lscr.io/linuxserver/sonarr:4.0.19.2979-ls320'
ok "an API error or unparsable response fails only its check, naming the service; image-versions uses check-min-versions"

# --- 14c. jellyfin running ------------------------------------------------------------
verify_fixtures
mkdir -p "$T/fx/jellyfin"
printf 'Healthy' > "$T/fx/jellyfin/GET_health.json"
run_capture env STUB_RUNNING="$CORE_UP jellyfin" PLEX_PAGE_SIZE=2 "$VERIFY"
expect verify-jellyfin 0 '^RESULT: 15 pass, 0 fail, 0 skip$'
result verify-jellyfin PASS jellyfin '/health Healthy; /dev/dri present'
reset_stub
run_capture env STUB_RUNNING="$CORE_UP jellyfin" STUB_EXEC_RC_jellyfin=1 PLEX_PAGE_SIZE=2 "$VERIFY"
result verify-jellyfin FAIL jellyfin '/dev/dri missing'
ok "jellyfin running: /health Healthy and /dev/dri PASS; no /dev/dri FAILs"

# --- 15. watch-import PASS ----------------------------------------------------------
HIST="GET_api_v3_history_eventType_3_sortKey_date_sortDirection_descending_pageSize_5.json"
# import_later <ln|cp>: after a second, a download appears in complete/tv;
# two seconds later it is imported into media/tv (ln = same inode, like a
# move within one filesystem; cp = a copy) and the history shows it.
import_later() {
  (
    rel="Show A/Season 01/Show A - S01E01.mkv"
    src="$DATA_ROOT/usenet/complete/tv/Show.A.S01E01/show.a.s01e01.mkv"
    sleep 1
    mkdir -p "${src%/*}"
    printf 'episode\n' > "$src"
    sleep 2
    mkdir -p "$DATA_ROOT/media/tv/Show A/Season 01"
    "$1" "$src" "$DATA_ROOT/media/tv/$rel"
    jq -n --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg r "$rel" '{page: 1, pageSize: 5, totalRecords: 1, records: [
      {id: 77, episodeId: 106, seriesId: 1, eventType: "downloadFolderImported", date: $d,
       data: {droppedPath: "/data/usenet/complete/tv/Show.A.S01E01/show.a.s01e01.mkv", importedPath: ("/data/media/tv/" + $r)}}]}' \
      > "$T/hist.tmp"
    mv "$T/hist.tmp" "$T/fx/sonarr/$HIST"
  ) &
  BG_PID=$!
}
make_library
verify_fixtures
import_later ln
run_capture env STUB_RUNNING="$CORE_UP" WATCH_INTERVAL=1 WATCH_TIMEOUT=30 "$VERIFY" --watch-import sonarr
wait "$BG_PID"
BG_PID=""
ino="$(stat -c %i "$DATA_ROOT/media/tv/Show A/Season 01/Show A - S01E01.mkv")"
expect verify-watch 0 "^PASS import sonarr inode=$ino$" "watching $DATA_ROOT/usenet/complete/tv for a sonarr import"
[[ -z "$(mutating)" ]] || fail verify-watch "watch-import made changes"
grep -q '^GET sonarr /api/v3/history?eventType=3&sortKey=date&sortDirection=descending&pageSize=5$' "$STUB_LOG" \
  || fail verify-watch "history not polled"
# A copy (new inode) is not an atomic import.
make_library
verify_fixtures
import_later cp
run_capture env STUB_RUNNING="$CORE_UP" WATCH_INTERVAL=1 WATCH_TIMEOUT=30 "$VERIFY" --watch-import sonarr
wait "$BG_PID"
BG_PID=""
expect verify-watch-copy 1 '^FAIL import sonarr inode [0-9]+ of /data/media/tv/Show A/Season 01/Show A - S01E01\.mkv is not among the completed downloads'
ok "--watch-import: PASS on an inode match with a completed download; a copy FAILs"

# --- 16. watch-import timeout ----------------------------------------------------------
verify_fixtures
run_capture env STUB_RUNNING="$CORE_UP" WATCH_INTERVAL=1 WATCH_TIMEOUT=2 "$VERIFY" --watch-import radarr
expect verify-watch-timeout 1 '^FAIL import radarr no import within 2s$'
ok "--watch-import FAILs after WATCH_TIMEOUT with no import"

# --- 17. CLI --------------------------------------------------------------------------
run_capture "$VERIFY" --bogus
expect verify-cli 2
run_capture "$VERIFY" --watch-import
expect verify-cli 2
run_capture "$VERIFY" --watch-import plex
expect verify-cli 2
run_capture "$VERIFY" --help
expect verify-cli 0 'Usage: verify-media.sh'
ok "verify: unknown flag or a bad --watch-import service exits 2, --help exits 0"

printf 'all media script tests passed\n'
