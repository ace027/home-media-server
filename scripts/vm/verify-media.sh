#!/usr/bin/env bash
# shellcheck disable=SC2317
# (SC2317: the check_* functions and their helpers are called indirectly,
# by name, from run_check.)
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/arr.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/arr.sh"

# .env first, then defaults, so .env values are not masked by the defaults.
load_env
APPDATA_ROOT="${APPDATA_ROOT:-/opt/appdata}"
DATA_ROOT="${DATA_ROOT:-/data}"
PLEX_COUNT_TOLERANCE="${PLEX_COUNT_TOLERANCE:-0}"
PLEX_PAGE_SIZE="${PLEX_PAGE_SIZE:-200}"
WATCH_INTERVAL="${WATCH_INTERVAL:-5}"
WATCH_TIMEOUT="${WATCH_TIMEOUT:-1800}"

# The 11 core services (R2.1).
CORE=(sabnzbd prowlarr sonarr sonarr-anime sonarr-4k radarr radarr-4k lidarr plex seerr tautulli)
ARRS=(sonarr sonarr-anime sonarr-4k radarr radarr-4k lidarr)
VIDEO=(sonarr sonarr-anime sonarr-4k radarr radarr-4k)

# The wiring table (spec, 25-arr-wire.sh): root folders, SAB category field
# and category per *arr instance.
declare -A ROOTS=(
  [sonarr]=/data/media/tv
  [sonarr-anime]=/data/media/anime-tv
  [sonarr-4k]=/data/media/tv-4k
  [radarr]="/data/media/movies /data/media/anime-movies"
  [radarr-4k]=/data/media/movies-4k
  [lidarr]=/data/media/music
)
declare -A CAT_FIELD=(
  [sonarr]=tvCategory [sonarr-anime]=tvCategory [sonarr-4k]=tvCategory
  [radarr]=movieCategory [radarr-4k]=movieCategory [lidarr]=musicCategory
)
declare -A CATEGORY=(
  [sonarr]=tv [sonarr-anime]=anime [sonarr-4k]=tv-4k
  [radarr]=movies [radarr-4k]=movies-4k [lidarr]=music
)
SAB_CATS='["*","tv","tv-4k","movies","movies-4k","music","anime"]'

# Plex sections (title -> locations) and the *arr count each is held to.
PLEX_SECTIONS='{
  "Movies": ["/data/media/anime-movies", "/data/media/movies"],
  "TV Shows": ["/data/media/tv"],
  "Anime TV": ["/data/media/anime-tv"],
  "Music": ["/data/media/music"],
  "Movies 4K": ["/data/media/movies-4k"],
  "TV 4K": ["/data/media/tv-4k"]}'
declare -A PLEX_ARR=(["Movies"]=radarr ["TV Shows"]=sonarr ["Anime TV"]=sonarr-anime
                     ["Movies 4K"]=radarr-4k ["TV 4K"]=sonarr-4k)
PLEX_COUNTED=("Movies" "TV Shows" "Anime TV" "Movies 4K" "TV 4K")

# Seerr: the five *arr servers (hostname -> is4k, isDefault, port) and the
# Plex libraries that must be enabled.
SEERR_RADARR='{"radarr": [false, true, 7878], "radarr-4k": [true, true, 7878]}'
SEERR_SONARR='{"sonarr": [false, true, 8989], "sonarr-4k": [true, true, 8989], "sonarr-anime": [false, false, 8989]}'
SEERR_LIBS='["Movies", "TV Shows", "Anime TV", "Movies 4K", "TV 4K"]'

usage() {
  cat <<EOF
Phase 2 acceptance gate for the media stack. Read-only: it only reads the
apps' APIs and writes nothing outside a temp dir it removes on exit.

Runs 15 checks, in order, each printing one line:
  PASS <id> <detail>
  FAIL <id> <detail>
  SKIP <id> <reason>
Check IDs: compose-healthy, image-versions, arr-rootfolders,
library-adopted, no-regrab, sab-categories, download-clients,
prowlarr-sync, 4k-split, plex-sections, plex-watched, plex-counts,
plex-hw, seerr-servers, jellyfin.

Ends with: RESULT: <n> pass, <n> fail, <n> skip
Exits 1 if any check FAILs, 0 otherwise. A check whose API call fails is
a FAIL naming the service; the other checks still run.

--watch-import <svc> instead watches one import (runbook step 10): it
records the inode of every file that appears in /data/usenet/complete/<cat>
(<cat> from the wiring table), and when <svc>'s history shows a newer
downloadFolderImported record, checks that its importedPath has one of
those inodes and is on the same device. Prints
"PASS import <svc> inode=<n>" (exit 0), or "FAIL import <svc> <reason>"
(exit 1), at the latest after WATCH_TIMEOUT seconds.

Usage: verify-media.sh [--help]
       verify-media.sh --watch-import <svc> [--help]
(<svc>: ${ARRS[*]}. --apply is accepted for CLI consistency but has
no effect: this script only reads.)

Environment variables (defaults; normally from .env):
  APPDATA_ROOT=$APPDATA_ROOT     API keys, baseline.json, split plans
  DATA_ROOT=$DATA_ROOT
  PLEX_COUNT_TOLERANCE=$PLEX_COUNT_TOLERANCE      plex-counts: allowed shortfall per section
  PLEX_PAGE_SIZE=$PLEX_PAGE_SIZE         plex-watched: items per Plex page
  WATCH_INTERVAL=$WATCH_INTERVAL           --watch-import: seconds between polls
  WATCH_TIMEOUT=$WATCH_TIMEOUT         --watch-import: seconds before FAIL
EOF
}

# --- arguments: --watch-import locally, the rest by parse_common_args ---------------
WATCH=""
rest=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch-import)
      if [[ $# -lt 2 || -z "${CATEGORY[$2]:-}" ]]; then
        usage >&2
        exit 2
      fi
      WATCH="$2"
      shift 2
      ;;
    *)
      rest+=("$1")
      shift
      ;;
  esac
done
parse_common_args "${rest[@]}"

# --- validation ------------------------------------------------------------------
require_safe_path APPDATA_ROOT "$APPDATA_ROOT"
require_safe_path DATA_ROOT "$DATA_ROOT"
require_match PLEX_COUNT_TOLERANCE "$PLEX_COUNT_TOLERANCE" '^[0-9]+$' "a whole number"
require_match PLEX_PAGE_SIZE "$PLEX_PAGE_SIZE" '^[1-9][0-9]*$' "a positive whole number"
require_match WATCH_INTERVAL "$WATCH_INTERVAL" '^[1-9][0-9]*$' "a positive whole number of seconds"
require_match WATCH_TIMEOUT "$WATCH_TIMEOUT" '^[0-9]+$' "a whole number of seconds"
require_cmd docker curl jq find stat

MIGRATION="$APPDATA_ROOT/.migration"
BASELINE="$MIGRATION/baseline.json"

umask 077
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# list <item...>: the items joined with "; " (for one-line details).
list() {
  local first="$1"
  shift
  printf '%s' "$first"
  [[ $# -eq 0 ]] || printf '; %s' "$@"
}

# on_disk </data/...>: the VM path of an in-container /data path.
on_disk() {
  printf '%s%s\n' "$DATA_ROOT" "${1#/data}"
}

# fetch <svc> <path> <file>: GET into <file>. On failure sets ERR to the
# error line (e.g. "GET sonarr /api/v3/series -> HTTP 500") and returns 1.
ERR=""
fetch() {
  if api "$1" GET "$2" >"$3" 2>"$W/err"; then
    return 0
  fi
  ERR="$(grep -v '^$' "$W/err" | tail -n 1)" || true
  ERR="${ERR#\[ERROR\] }"
  [[ -n "$ERR" ]] || ERR="GET $1 $2 failed"
  return 1
}

# cfile <svc> <path>: the cache file for a GET; cget <svc> <path>: GET it
# once per run (checks share the item lists).
cfile() {
  local n="$1_$2"
  printf '%s/c-%s.json\n' "$W" "${n//[^A-Za-z0-9_-]/_}"
}
cget() {
  local f
  f="$(cfile "$1" "$2")"
  [[ -s "$f" ]] && return 0
  fetch "$1" "$2" "$f"
}

# items <svc>: the path of the item list (series, movie or artist) of an
# *arr instance; call cget "$svc" "$(items_path "$svc")" first.
items_path() {
  case "$1" in
    sonarr*) printf '/api/v3/series\n' ;;
    radarr*) printf '/api/v3/movie\n' ;;
    lidarr) printf '/api/v1/artist\n' ;;
  esac
}

# The same 4K test as 30-split-4k.sh: max(quality resolution, mediaInfo
# height) >= 2160, or mediaInfo width >= 3200.
# shellcheck disable=SC2016  # jq program: its $vars are jq's, not the shell's
JQ_4K='
  def mi: ((.mediaInfo.resolution // "") | tostring
           | capture("^(?<w>[0-9]+)x(?<h>[0-9]+)$") // null
           | if . == null then null else {w: (.w | tonumber), h: (.h | tonumber)} end);
  def is4k: ((((.quality.quality.resolution // 0) | tonumber? // 0) >= 2160)
             or (mi as $m | $m != null and ($m.h >= 2160 or $m.w >= 3200)));'

# manifests: the split manifests that still count (undone ones are renamed).
manifests() {
  find "$MIGRATION" -maxdepth 1 -type f -name 'split-4k-*.manifest.tsv' 2>/dev/null | sort
}

# manifest_rows: per manifest data row, "<instance>\t<files>\t<new_id>",
# found by header name (so extra columns such as prior do not matter). A
# manifest whose header lacks one of them contributes nothing.
manifest_rows() {
  local m
  while IFS= read -r m; do
    awk -F'\t' -v OFS='\t' '
      NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
      col["instance"] && col["files"] && col["new_id"] { print $col["instance"], $col["files"], $col["new_id"] }' "$m"
  done < <(manifests)
}

# baseline_cut: the baseline time as epoch seconds (empty if unreadable).
baseline_cut() {
  jq -r '.created | sub("\\.[0-9]+"; "") | fromdateiso8601' "$BASELINE" 2>/dev/null || true
}

# ==============================================================================
# --watch-import
# ==============================================================================
if [[ -n "$WATCH" ]]; then
  svc="$WATCH" cat="${CATEGORY[$WATCH]}"
  complete="$DATA_ROOT/usenet/complete"
  dir="$complete/$cat"
  [[ -d "$dir" ]] || { printf 'FAIL import %s %s is missing\n' "$svc" "$dir"; exit 1; }
  dev_complete="$(stat -c %d "$complete")"
  base="$(arr_base "$svc")"
  start="$(date +%s)"
  : >"$W/seen"
  log_info "watching $dir for a $svc import (timeout ${WATCH_TIMEOUT}s); make or approve the request now"
  while :; do
    # path -> inode of every file that appeared since the start (ctime:
    # unrar restores archived mtimes).
    find "$dir" -type f -newerct "@$start" -printf '%i %p\n' 2>/dev/null >>"$W/seen" || true
    if fetch "$svc" "$base/history?eventType=3&sortKey=date&sortDirection=descending&pageSize=5" "$W/hist.json"; then
      mapfile -t imported < <(jq -r --argjson s "$start" '
        .records[]? | objects
        | select(((.date // "") | sub("\\.[0-9]+"; "") | fromdateiso8601? // 0) >= $s)
        | .data.importedPath // empty' "$W/hist.json")
      if [[ ${#imported[@]} -gt 0 ]]; then
        why=""
        for p in "${imported[@]}"; do
          if [[ "$p" != /data/* ]]; then
            why="importedPath $p is not under /data"
            continue
          fi
          f="$(on_disk "$p")"
          if ! read -r ino dev < <(stat -c '%i %d' -- "$f" 2>/dev/null); then
            why="importedPath $p not found at $f"
          elif [[ "$dev" != "$dev_complete" ]]; then
            why="$p is on device $dev, $complete on $dev_complete"
          elif awk -v i="$ino" '$1 == i { found = 1 } END { exit !found }' "$W/seen"; then
            printf 'PASS import %s inode=%s\n' "$svc" "$ino"
            exit 0
          else
            why="inode $ino of $p is not among the completed downloads in $dir (copied, not moved?)"
          fi
        done
        printf 'FAIL import %s %s\n' "$svc" "$why"
        exit 1
      fi
    else
      log_warn "$ERR"
    fi
    if (( $(date +%s) - start >= WATCH_TIMEOUT )); then
      printf 'FAIL import %s no import within %ss\n' "$svc" "$WATCH_TIMEOUT"
      exit 1
    fi
    sleep "$WATCH_INTERVAL"
  done
fi

# ==============================================================================
# Checks
# ==============================================================================
# Each check runs in its own subshell (see run_check) and prints exactly
# one result line with pass, fail or skip; run_check counts them.
pass() {
  local id="$1"; shift
  printf 'PASS %s %s\n' "$id" "$*"
}

fail() {
  local id="$1"; shift
  printf 'FAIL %s %s\n' "$id" "$*"
}

skip() {
  local id="$1"; shift
  printf 'SKIP %s %s\n' "$id" "$*"
}

# --- 1: compose-healthy ------------------------------------------------------------
check_compose_healthy() {
  local json bad
  if ! json="$("${DC[@]}" ps --format json 2>/dev/null)"; then
    fail compose-healthy "docker compose ps failed"
    return 0
  fi
  bad="$(jq -rs --args '
    [.[] | if type == "array" then .[] else . end | objects] as $ps
    | [$ARGS.positional[] as $s
       | ([$ps[] | select(.Service == $s) | "\(.State)/\(.Health // "")"][0] // "absent") as $st
       | select($st != "running/healthy") | "\($s)=\($st)"] | join(" ")' "${CORE[@]}" <<<"$json")" \
    || { fail compose-healthy "cannot parse docker compose ps output"; return 0; }
  if [[ -z "$bad" ]]; then
    pass compose-healthy "${#CORE[@]} services running (healthy)"
  else
    fail compose-healthy "not running and healthy: $bad"
  fi
}

# --- 2: image-versions --------------------------------------------------------------
check_image_versions() {
  local out rc=0
  out="$("$REPO_ROOT/scripts/ci/check-min-versions.sh" 2>&1)" || rc=$?
  out="$(grep -v '^$' <<<"$out" | paste -sd ';' -)"
  if [[ $rc -eq 0 ]]; then
    pass image-versions "$out"
  else
    fail image-versions "${out:-check-min-versions.sh exited $rc}"
  fi
}

# --- 3: arr-rootfolders ------------------------------------------------------------
check_arr_rootfolders() {
  local svc base f got want issues=() olds=0 n
  for svc in "${ARRS[@]}"; do
    base="$(arr_base "$svc")"
    if ! cget "$svc" "$base/rootfolder"; then
      issues+=("$ERR")
      continue
    fi
    f="$(cfile "$svc" "$base/rootfolder")"
    got="$(jq -r '[.[]? | objects | .path // "" | sub("/+$"; "")] | sort | join(",")' "$f")"
    want="$(tr ' ' '\n' <<<"${ROOTS[$svc]}" | sort | paste -sd, -)"
    [[ "$got" == "$want" ]] || issues+=("$svc roots=${got:-none} (want $want)")
  done
  for svc in "${VIDEO[@]}"; do
    if ! cget "$svc" "$(items_path "$svc")"; then
      issues+=("$ERR")
      continue
    fi
    n="$(jq '[.[]? | objects | select((.path // "") | test("^/data/(shows|movies|anime)(/|$)"))] | length' \
      "$(cfile "$svc" "$(items_path "$svc")")")"
    if (( n > 0 )); then
      issues+=("$svc: $n items under /data/{shows,movies,anime}")
      olds=$((olds + n))
    fi
  done
  if [[ ${#issues[@]} -eq 0 ]]; then
    pass arr-rootfolders "${#ARRS[@]} instances match the wiring table; 0 items under old roots"
  else
    fail arr-rootfolders "$(list "${issues[@]}")"
  fi
}

# --- 4: library-adopted ------------------------------------------------------------
check_library_adopted() {
  if [[ ! -r "$BASELINE" ]]; then
    skip library-adopted "no $BASELINE"
    return 0
  fi
  local svc cur moved want key parts=() bad=0
  for svc in sonarr sonarr-anime radarr; do
    if ! cget "$svc" "$(items_path "$svc")"; then
      fail library-adopted "$ERR"
      return 0
    fi
    if [[ "$svc" == radarr ]]; then
      key=items_with_files
      cur="$(jq '[.[]? | objects | select(.hasFile == true)] | length' "$(cfile "$svc" /api/v3/movie)")"
    else
      key=files
      cur="$(jq '[.[]? | objects | .statistics.episodeFileCount // 0 | tonumber? // 0] | add // 0' \
        "$(cfile "$svc" /api/v3/series)")"
    fi
    moved="$(manifest_rows | awk -F'\t' -v s="$svc" '$1 == s { n += $2 } END { print n + 0 }')"
    want="$(jq -r --arg s "$svc" --arg k "$key" '.[$k][$s] // empty' "$BASELINE")"
    if [[ ! "$want" =~ ^[0-9]+$ ]]; then
      fail library-adopted "baseline.json has no $key.$svc"
      return 0
    fi
    if (( cur + moved >= want )); then
      parts+=("$svc $cur+$moved>=$want")
    else
      parts+=("$svc $cur+$moved<$want")
      bad=1
    fi
  done
  if [[ $bad -eq 0 ]]; then
    pass library-adopted "$(list "${parts[@]}") (current+moved vs baseline)"
  else
    fail library-adopted "$(list "${parts[@]}") (current+moved vs baseline)"
  fi
}

# grabs_since <svc> <created> <cut> <out-file>: the grabbed history records
# since the baseline, as a JSON array. Uses history/since, falling back to
# the paged /history (sorted newest first) on a 404.
grabs_since() {
  local svc="$1" created="$2" cut="$3" out="$4" base date page=1 total
  base="$(arr_base "$svc")"
  date="$(jq -rn --arg d "$created" '$d | @uri')"
  if api "$svc" GET "$base/history/since?date=$date&eventType=grabbed" >"$W/since.json" 2>"$W/err"; then
    jq --argjson cut "$cut" '[.[]? | objects | select((.eventType // "grabbed") == "grabbed")
      | select(((.date // "") | sub("\\.[0-9]+"; "") | fromdateiso8601? // 0) >= $cut)]' "$W/since.json" >"$out"
    return 0
  fi
  if ! grep -q 'HTTP 404$' "$W/err"; then
    ERR="$(tail -n 1 "$W/err")"
    ERR="${ERR#\[ERROR\] }"
    return 1
  fi
  printf '[]\n' >"$out"
  while (( page <= 200 )); do
    fetch "$svc" "$base/history?page=$page&pageSize=250&sortKey=date&sortDirection=descending&eventType=1" "$W/page.json" \
      || return 1
    jq -s --argjson cut "$cut" '.[0] + [.[1].records[]? | objects
      | select(.eventType == "grabbed" or .eventType == 1)
      | select(((.date // "") | sub("\\.[0-9]+"; "") | fromdateiso8601? // 0) >= $cut)]' "$out" "$W/page.json" >"$W/acc.json"
    mv "$W/acc.json" "$out"
    total="$(jq -r '.totalRecords // 0' "$W/page.json")"
    # Stop at the last page, or at the first record older than the baseline.
    if (( page * 250 >= total )) || jq -e --argjson cut "$cut" \
         'any(.records[]? | objects; ((.date // "") | sub("\\.[0-9]+"; "") | fromdateiso8601? // 0) < $cut)' \
         "$W/page.json" >/dev/null; then
      break
    fi
    page=$((page + 1))
  done
}

# --- 5: no-regrab -------------------------------------------------------------------
check_no_regrab() {
  if [[ ! -r "$BASELINE" ]]; then
    skip no-regrab "no $BASELINE"
    return 0
  fi
  local created cut svc field ids hits=() other=0 n
  created="$(jq -r '.created // empty' "$BASELINE")"
  cut="$(baseline_cut)"
  if [[ -z "$created" || ! "$cut" =~ ^[0-9]+$ ]]; then
    fail no-regrab "cannot read .created from $BASELINE"
    return 0
  fi
  for svc in sonarr sonarr-anime radarr sonarr-4k radarr-4k; do
    if ! grabs_since "$svc" "$created" "$cut" "$W/grabs-$svc.json"; then
      fail no-regrab "$ERR"
      return 0
    fi
    # Protected ids: baseline items with files (HD), or items the split
    # created (4K, the manifests' new_id).
    case "$svc" in
      sonarr|sonarr-anime|radarr)
        if [[ ! -r "$MIGRATION/baseline-ids/$svc.txt" ]]; then
          fail no-regrab "missing $MIGRATION/baseline-ids/$svc.txt"
          return 0
        fi
        grep -E '^[0-9]+$' "$MIGRATION/baseline-ids/$svc.txt" | jq -s . >"$W/ids.json"
        field=episodeId
        [[ "$svc" != radarr ]] || field=movieId
        ;;
      *)
        manifest_rows | awk -F'\t' -v s="${svc%-4k}" '$1 == s && $3 ~ /^[0-9]+$/ { print $3 }' | jq -s . >"$W/ids.json"
        field=seriesId
        [[ "$svc" != radarr-4k ]] || field=movieId
        ;;
    esac
    while IFS= read -r line; do
      [[ -n "$line" ]] && hits+=("$svc $line")
    done < <(jq -r --slurpfile ids "$W/ids.json" --arg f "$field" '
      .[] | select(.[$f] as $i | $ids[0] | any(. == $i))
      | "\($f)=\(.[$f]) \(.sourceTitle // "?" | gsub("[\\t\\r\\n]"; " "))"' "$W/grabs-$svc.json")
    n="$(jq --slurpfile ids "$W/ids.json" --arg f "$field" '[.[] | select(.[$f] as $i | $ids[0] | any(. == $i) | not)] | length' \
      "$W/grabs-$svc.json")"
    other=$((other + n))
  done
  if [[ ${#hits[@]} -eq 0 ]]; then
    pass no-regrab "0 re-grabs of baseline or split items since $created; other=$other"
  else
    fail no-regrab "re-grabbed: $(list "${hits[@]}"); other=$other"
  fi
}

# --- 6: sab-categories --------------------------------------------------------------
check_sab_categories() {
  local cfg="$W/sab-config.json" issues=() cut note=""
  if ! fetch sabnzbd "$(sab_path get_config)" "$cfg"; then
    fail sab-categories "$ERR"
    return 0
  fi
  jq -e --argjson want "$SAB_CATS" '[.config.categories[]? | objects | .name] | sort == ($want | sort)' "$cfg" >/dev/null \
    || issues+=("categories $(jq -r '[.config.categories[]? | objects | .name] | join(",")' "$cfg") (want $(jq -r 'join(",")' <<<"$SAB_CATS"))")
  local wrong
  wrong="$(jq -r '[.config.categories[]? | objects | select(.name != "*" and ((.dir // "") | tostring) != .name)
    | "\(.name)->\(.dir // "")"] | join(",")' "$cfg")"
  [[ -z "$wrong" ]] || issues+=("category dirs $wrong")
  [[ "$(jq -r '.config.misc.download_dir // ""' "$cfg")" == /data/usenet/incomplete ]] \
    || issues+=("download_dir=$(jq -r '.config.misc.download_dir // ""' "$cfg")")
  [[ "$(jq -r '.config.misc.complete_dir // ""' "$cfg")" == /data/usenet/complete ]] \
    || issues+=("complete_dir=$(jq -r '.config.misc.complete_dir // ""' "$cfg")")

  if [[ -r "$BASELINE" ]]; then
    cut="$(baseline_cut)"
    if [[ ! "$cut" =~ ^[0-9]+$ ]]; then
      issues+=("cannot read .created from $BASELINE")
    elif ! fetch sabnzbd "$(sab_path queue)" "$W/sab-queue.json" || ! fetch sabnzbd "$(sab_path history)" "$W/sab-history.json"; then
      issues+=("$ERR")
    else
      jq -e --argjson cut "$cut" 'any(.queue.slots[]? | objects; (.time_added | tonumber? // $cut) < $cut)' \
        "$W/sab-queue.json" >/dev/null && issues+=("queue holds jobs from before the baseline")
      jq -e --argjson cut "$cut" 'any(.history.slots[]? | objects; (.completed | tonumber? // $cut) < $cut)' \
        "$W/sab-history.json" >/dev/null && issues+=("history holds jobs from before the baseline")
    fi
  else
    note=" (no baseline.json: pre-baseline job check skipped)"
  fi
  if [[ ${#issues[@]} -eq 0 ]]; then
    pass sab-categories "7 categories, dirs = names, /data/usenet/{incomplete,complete}$note"
  else
    fail sab-categories "$(list "${issues[@]}")"
  fi
}

# --- 7: download-clients ------------------------------------------------------------
check_download_clients() {
  local svc base f bad issues=()
  for svc in "${ARRS[@]}" prowlarr; do
    base="$(arr_base "$svc")"
    if ! cget "$svc" "$base/downloadclient"; then
      issues+=("$ERR")
      continue
    fi
    f="$(cfile "$svc" "$base/downloadclient")"
    bad="$(jq -r --arg cf "${CAT_FIELD[$svc]:-}" --arg cat "${CATEGORY[$svc]:-}" '
      [.[]? | objects] as $c
      | if ($c | length) != 1 then "\($c | length) clients (\([$c[] | .implementation // "?"] | join(",")))"
        else $c[0] as $d | ([$d.fields[]? | {(.name): .value}] | add // {}) as $f
          | if $d.implementation != "Sabnzbd" then "client is \($d.implementation)"
            elif $f.host != "sabnzbd" or (($f.port | tostring) != "8080") then "SABnzbd at \($f.host):\($f.port)"
            elif $cf != "" and $f[$cf] != $cat then "\($cf)=\($f[$cf]) (want \($cat))"
            else empty end
        end' "$f")"
    [[ -z "$bad" ]] || issues+=("$svc: $bad")
    [[ "$svc" == prowlarr ]] && continue
    if ! cget "$svc" "$base/indexer"; then
      issues+=("$ERR")
      continue
    fi
    bad="$(jq '[.[]? | objects | select(.protocol == "torrent")] | length' "$(cfile "$svc" "$base/indexer")")"
    [[ "$bad" == 0 ]] || issues+=("$svc: $bad torrent indexers")
  done
  if [[ ${#issues[@]} -eq 0 ]]; then
    pass download-clients "${#ARRS[@]} *arr + prowlarr: one SABnzbd client each (sabnzbd:8080, own category); 0 torrent indexers"
  else
    fail download-clients "$(list "${issues[@]}")"
  fi
}

# --- 8: prowlarr-sync -----------------------------------------------------------------
check_prowlarr_sync() {
  local issues=() svc base f n want_hosts
  if ! cget prowlarr /api/v1/applications || ! cget prowlarr /api/v1/indexer || ! cget prowlarr /api/v1/indexerproxy; then
    fail prowlarr-sync "$ERR"
    return 0
  fi
  want_hosts="$(printf '%s\n' "${ARRS[@]}" | sort | paste -sd, -)"
  f="$(cfile prowlarr /api/v1/applications)"
  n="$(jq -r '[.[]? | objects] | "\(length) \([.[] | select(.syncLevel != "fullSync") | .name] | join(","))"' "$f")"
  [[ "$n" == "6 " ]] || issues+=("apps: $n (want 6, all fullSync)")
  local hosts
  hosts="$(jq -r '[.[]? | objects | [.fields[]? | select(.name == "baseUrl") | .value | strings
                   | capture("^[A-Za-z][A-Za-z0-9+.-]*://(?<h>[^:/?#]+)") | .h | ascii_downcase][0] // "?"]
                  | sort | join(",")' "$f")"
  [[ "$hosts" == "$want_hosts" ]] || issues+=("app hosts $hosts (want $want_hosts)")
  f="$(cfile prowlarr /api/v1/indexer)"
  n="$(jq '[.[]? | objects | select(.protocol == "torrent")] | length' "$f")"
  [[ "$n" == 0 ]] || issues+=("$n torrent indexers")
  jq '[.[]? | objects | select(.protocol == "usenet" and .enable == true) | .name]' "$f" >"$W/usenet.json"
  [[ "$(jq length "$W/usenet.json")" -ge 1 ]] || issues+=("no enabled usenet indexer")
  n="$(jq '[.[]? | objects] | length' "$(cfile prowlarr /api/v1/indexerproxy)")"
  [[ "$n" == 0 ]] || issues+=("$n indexer proxies")
  for svc in "${ARRS[@]}"; do
    base="$(arr_base "$svc")"
    if ! cget "$svc" "$base/indexer"; then
      issues+=("$ERR")
      continue
    fi
    n="$(jq -r --slurpfile u "$W/usenet.json" '
      [.[]? | objects | .name // "" | select(endswith(" (Prowlarr)"))] as $p
      | if ($p | length) == 0 then "no (Prowlarr) indexer"
        else [$p[] | sub(" \\(Prowlarr\\)$"; "") as $n | select($u[0] | any(. == $n) | not) | $n]
             | if length > 0 then "unknown (Prowlarr) indexers: \(join(","))" else empty end
        end' "$(cfile "$svc" "$base/indexer")")"
    [[ -z "$n" ]] || issues+=("$svc: $n")
  done
  if [[ ${#issues[@]} -eq 0 ]]; then
    pass prowlarr-sync "6 apps fullSync; $(jq length "$W/usenet.json") usenet indexers, 0 torrent, 0 proxies; each *arr has synced (Prowlarr) indexers"
  else
    fail prowlarr-sync "$(list "${issues[@]}")"
  fi
}

# --- 9: 4k-split ------------------------------------------------------------------------
check_4k_split() {
  local plan svc kind fpath id leaks=() mixed items ids=()
  plan="$(find "$MIGRATION" -maxdepth 1 -type f -name 'split-4k-*.tsv' ! -name '*.manifest.tsv' 2>/dev/null | sort | tail -n 1)"
  if [[ -z "$plan" ]]; then
    skip 4k-split "no split-4k-*.tsv plan (run scripts/vm/30-split-4k.sh)"
    return 0
  fi
  mixed="$(awk -F'\t' 'NR > 1 && $8 == "skip-mixed"' "$plan" | wc -l)"
  for svc in radarr sonarr; do
    if [[ "$svc" == radarr ]]; then
      kind=movie fpath="/api/v3/moviefile?movieId="
    else
      kind=series fpath="/api/v3/episodefile?seriesId="
    fi
    if ! cget "$svc" "$(items_path "$svc")"; then
      fail 4k-split "$ERR"
      return 0
    fi
    items="$(cfile "$svc" "$(items_path "$svc")")"
    # Monitored HD items with files, outside anime (never split) and not
    # listed skip-mixed in the newest plan.
    mapfile -t ids < <(awk -F'\t' -v s="$svc" 'NR > 1 && $2 == s && $8 == "skip-mixed" { print $3 }' "$plan" | jq -s . \
      | jq -r --slurpfile it "$items" '. as $mixed | $it[0][]? | objects
          | select(.monitored == true)
          | select(if has("hasFile") then .hasFile == true else ((.statistics.episodeFileCount // 1) > 0) end)
          | select((.path // "") | startswith("/data/media/anime-movies/") | not)
          | select(.id as $i | $mixed | any(. == $i) | not)
          | "\(.id)\t\(.title // "?")"')
    for id in "${ids[@]}"; do
      local title="${id#*$'\t'}"
      id="${id%%$'\t'*}"
      [[ "$id" =~ ^[0-9]+$ ]] || continue
      if ! cget "$svc" "$fpath$id"; then
        fail 4k-split "$ERR"
        return 0
      fi
      if jq -e "$JQ_4K"' any(.[]? | objects; is4k)' "$(cfile "$svc" "$fpath$id")" >/dev/null; then
        leaks+=("$svc $kind $id '$title'")
      fi
    done
  done
  if [[ ${#leaks[@]} -eq 0 ]]; then
    pass 4k-split "no monitored HD item has a >=2160p file; mixed=$mixed (${plan##*/})"
  else
    fail 4k-split "monitored HD items with >=2160p files: $(list "${leaks[@]}"); mixed=$mixed"
  fi
}

# --- 10: plex-sections ---------------------------------------------------------------
check_plex_sections() {
  local bad trash
  if ! cget plex /library/sections || ! fetch plex /:/prefs "$W/plex-prefs.json"; then
    fail plex-sections "$ERR"
    return 0
  fi
  bad="$(jq -r --argjson want "$PLEX_SECTIONS" '
    [.MediaContainer.Directory[]? | objects] as $d
    | ([$want | to_entries[] | .key as $t | .value as $w
        | ([$d[] | select(.title == $t)][0]) as $s
        | if $s == null then "missing section \($t)"
          else ([$s.Location[]? | .path | sub("/+$"; "")] | sort) as $got
            | if $got == ($w | sort) then empty else "\($t)=\($got | join(","))" end
          end]
       + [$d[] | .title as $t | .Location[]? | .path | select(startswith("/data/media/") | not) | "\($t) at \(.)"])
    | join("; ")' "$(cfile plex /library/sections)")"
  trash="$(jq -r '[.MediaContainer.Setting[]? | objects | select(.id == "autoEmptyTrash") | .value | tostring][0] // "unset"' \
    "$W/plex-prefs.json")"
  case "$trash" in
    false|0) ;;
    *) bad="${bad:+$bad; }autoEmptyTrash=$trash (want 0)" ;;
  esac
  if [[ -z "$bad" ]]; then
    pass plex-sections "6 sections at /data/media/*; autoEmptyTrash=0"
  else
    fail plex-sections "$bad"
  fi
}

# plex_section_keys <type>: "key<TAB>title" of each section of that type.
plex_section_keys() {
  jq -r --arg t "$1" '.MediaContainer.Directory[]? | objects | select(.type == $t)
    | "\(.key)\t\(.title)"' "$(cfile plex /library/sections)"
}

# --- 11: plex-watched ---------------------------------------------------------------
check_plex_watched() {
  if [[ ! -r "$BASELINE" ]]; then
    skip plex-watched "no $BASELINE"
    return 0
  fi
  local want key type total start n watched=0 page
  want="$(jq -r '.plex_watched // -1' "$BASELINE")"
  if [[ "$want" == -1 ]]; then
    skip plex-watched "baseline plex_watched=-1 (Plex DB unreadable at restore); spot-check watched titles in the Plex UI (runbook step 6)"
    return 0
  fi
  if [[ ! "$want" =~ ^[0-9]+$ ]]; then
    fail plex-watched "baseline plex_watched=$want is not a number"
    return 0
  fi
  if ! cget plex /library/sections; then
    fail plex-watched "$ERR"
    return 0
  fi
  for type in movie:1 show:4; do
    while IFS=$'\t' read -r key _; do
      [[ "$key" =~ ^[0-9]+$ ]] || continue
      start=0
      while :; do
        page="/library/sections/$key/all?type=${type#*:}&X-Plex-Container-Start=$start&X-Plex-Container-Size=$PLEX_PAGE_SIZE"
        if ! fetch plex "$page" "$W/plex-page.json"; then
          fail plex-watched "$ERR"
          return 0
        fi
        read -r n total < <(jq -r '[((.MediaContainer.Metadata // []) | length), (.MediaContainer.totalSize // 0)] | @tsv' "$W/plex-page.json")
        watched=$((watched + $(jq '[.MediaContainer.Metadata[]? | objects | select((.viewCount // 0 | tonumber? // 0) > 0)] | length' \
          "$W/plex-page.json")))
        start=$((start + n))
        (( n > 0 && start < total )) || break
      done
    done < <(plex_section_keys "${type%%:*}")
  done
  if (( watched >= want )); then
    pass plex-watched "watched movies+episodes=$watched >= baseline $want"
  else
    fail plex-watched "watched movies+episodes=$watched < baseline $want; do not empty the Plex trash (runbook Troubleshooting)"
  fi
}

# arr_count <svc>: items with files (radarr*: hasFile; sonarr*: series with
# episode files).
arr_count() {
  local svc="$1"
  cget "$svc" "$(items_path "$svc")" || return 1
  jq '[.[]? | objects | select(if has("hasFile") then .hasFile == true
       else ((.statistics.episodeFileCount // 0 | tonumber? // 0) > 0) end)] | length' "$(cfile "$svc" "$(items_path "$svc")")"
}

# --- 12: plex-counts -----------------------------------------------------------------
check_plex_counts() {
  local title key svc arr plex parts=() bad=0
  if ! cget plex /library/sections; then
    fail plex-counts "$ERR"
    return 0
  fi
  for title in "${PLEX_COUNTED[@]}"; do
    svc="${PLEX_ARR[$title]}"
    key="$(jq -r --arg t "$title" '[.MediaContainer.Directory[]? | objects | select(.title == $t) | .key][0] // empty' \
      "$(cfile plex /library/sections)")"
    if [[ ! "$key" =~ ^[0-9]+$ ]]; then
      parts+=("$title: no such section")
      bad=1
      continue
    fi
    if ! fetch plex "/library/sections/$key/all?X-Plex-Container-Start=0&X-Plex-Container-Size=0" "$W/plex-count.json"; then
      fail plex-counts "$ERR"
      return 0
    fi
    plex="$(jq -r '.MediaContainer.totalSize // .MediaContainer.size // 0' "$W/plex-count.json")"
    if ! arr="$(arr_count "$svc")"; then
      fail plex-counts "$ERR"
      return 0
    fi
    parts+=("$title plex=$plex $svc=$arr ($(printf '%+d' $((plex - arr))))")
    (( plex >= arr - PLEX_COUNT_TOLERANCE )) || bad=1
  done
  if [[ $bad -eq 0 ]]; then
    pass plex-counts "$(list "${parts[@]}")"
  else
    fail plex-counts "$(list "${parts[@]}") (tolerance $PLEX_COUNT_TOLERANCE)"
  fi
}

# --- 13: plex-hw ---------------------------------------------------------------------
check_plex_hw() {
  local verdict
  if ! fetch plex /status/sessions "$W/plex-sessions.json"; then
    fail plex-hw "$ERR"
    return 0
  fi
  verdict="$(jq -r '
    def yes: . == true or . == 1 or . == "1" or . == "true";
    [.MediaContainer.Metadata[]? | objects | .TranscodeSession // empty | objects] as $t
    | if ($t | length) == 0 then "none"
      else ([$t[] | select((.transcodeHwRequested | yes)
                           and (((.transcodeHwDecoding // "") != "") or ((.transcodeHwEncoding // "") != "")))][0]) as $hw
        | if $hw then "hw decode=\($hw.transcodeHwDecoding // "-") encode=\($hw.transcodeHwEncoding // "-")"
          else "sw \($t | length)" end
      end' "$W/plex-sessions.json")"
  case "$verdict" in
    none) skip plex-hw "no transcode session; play a title with a forced transcode (lower the quality in the player) and re-run" ;;
    hw*) pass plex-hw "transcodeHwRequested with ${verdict#hw }" ;;
    *) fail plex-hw "${verdict#sw } transcode sessions, none hardware (check Settings > Transcoder > hardware acceleration and /dev/dri)" ;;
  esac
}

# --- 14: seerr-servers --------------------------------------------------------------
check_seerr_servers() {
  local kind want bad=() hint=""
  for kind in radarr sonarr; do
    if ! fetch seerr "/api/v1/settings/$kind" "$W/seerr-$kind.json"; then
      [[ "$ERR" == *"HTTP 404"* ]] && hint=" (Seerr settings API path not found; check the servers in the Seerr UI, spec Open Question 3)"
      fail seerr-servers "$ERR$hint"
      return 0
    fi
    if [[ "$kind" == radarr ]]; then want="$SEERR_RADARR"; else want="$SEERR_SONARR"; fi
    while IFS= read -r line; do
      [[ -n "$line" ]] && bad+=("$line")
    done < <(jq -r --argjson want "$want" --arg k "$kind" '
      [.[]? | objects] as $s
      | ($want | to_entries[] | .key as $h | .value as $v
         | [$s[] | select(.hostname == $h)] as $m
         | if ($m | length) != 1 then "\($k): \($m | length) servers with hostname \($h)"
           elif [$m[0].is4k, $m[0].isDefault, $m[0].port] != $v
             then "\($k) \($h): is4k=\($m[0].is4k) isDefault=\($m[0].isDefault) port=\($m[0].port)"
           else empty end),
        ($s[] | select(.hostname as $h | $want | has($h) | not) | "\($k): unexpected server \(.name) at \(.hostname)")' \
      "$W/seerr-$kind.json")
  done
  if ! fetch seerr /api/v1/settings/plex "$W/seerr-plex.json"; then
    [[ "$ERR" == *"HTTP 404"* ]] && hint=" (Seerr settings API path not found; spec Open Question 3)"
    fail seerr-servers "$ERR$hint"
    return 0
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] && bad+=("$line")
  done < <(jq -r --argjson libs "$SEERR_LIBS" '
    (if .ip != "plex" or ((.port | tostring) != "32400") then "plex at \(.ip):\(.port) (want plex:32400)" else empty end),
    ([.libraries[]? | objects | select(.enabled == true) | .name] as $on
     | $libs[] | select(. as $l | $on | any(. == $l) | not) | "plex library \(.) not enabled")' "$W/seerr-plex.json")
  if [[ ${#bad[@]} -eq 0 ]]; then
    pass seerr-servers "Radarr, Radarr 4K, Sonarr, Sonarr 4K, Sonarr Anime by hostname; plex:32400 with 5 libraries"
  else
    fail seerr-servers "$(list "${bad[@]}")"
  fi
}

# --- 15: jellyfin ---------------------------------------------------------------------
check_jellyfin() {
  local running ip health
  running="$(running_services 2>/dev/null)" || running=""
  if ! grep -qx jellyfin <<<"$running"; then
    skip jellyfin "not running (optional: docker compose --profile jellyfin up -d jellyfin)"
    return 0
  fi
  if ! ip="$(svc_ip jellyfin 2>/dev/null)"; then
    fail jellyfin "no proxy IP for jellyfin"
    return 0
  fi
  # /health needs no key (Jellyfin has no key source in arr.sh).
  health="$(curl -fsS --max-time 10 "http://$ip:$(arr_port jellyfin)/health" 2>/dev/null)" || health=""
  if [[ "$health" != Healthy ]]; then
    fail jellyfin "/health returned '${health:-nothing}'"
  elif ! "${DC[@]}" exec -T jellyfin test -e /dev/dri >/dev/null 2>&1; then
    fail jellyfin "/dev/dri missing in the container"
  else
    pass jellyfin "/health Healthy; /dev/dri present"
  fi
}

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# run_check <id>: runs check_<id> (dashes as _) in a subshell with errexit,
# so an unexpected response (bad JSON, a missing field) fails that one
# check instead of aborting the run; the GET cache in $W is shared.
run_check() {
  local id="$1" rc line
  set +e
  ( set -e; "check_${id//-/_}" ) >"$W/check.out" 2>"$W/check.err"
  rc=$?
  set -e
  line="$(grep -E "^(PASS|FAIL|SKIP) $id( |\$)" "$W/check.out" | tail -n 1)" || line=""
  if [[ -z "$line" ]]; then
    line="FAIL $id unexpected error (rc=$rc): $(grep -v '^$' "$W/check.err" | tail -n 1)"
  fi
  printf '%s\n' "$line"
  case "$line" in
    PASS*) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL*) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    SKIP*) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac
}

for id in compose-healthy image-versions arr-rootfolders library-adopted no-regrab \
          sab-categories download-clients prowlarr-sync 4k-split plex-sections \
          plex-watched plex-counts plex-hw seerr-servers jellyfin; do
  run_check "$id"
done

printf 'RESULT: %d pass, %d fail, %d skip\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
exit 0
