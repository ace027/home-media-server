#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/arr.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/arr.sh"

# .env first, then defaults, so .env values are not masked by the defaults.
load_env
APPDATA_ROOT="${APPDATA_ROOT:-/opt/appdata}"
DATA_ROOT="${DATA_ROOT:-/data}"
QP_4K_RADARR="${QP_4K_RADARR:-Ultra-HD}"
QP_4K_SONARR="${QP_4K_SONARR:-Ultra-HD}"

# HD instance -> item kind, HD root and 4K root (in-container paths; the VM
# path of /data/<x> is $DATA_ROOT/<x>). Anime is never split.
declare -A KIND=([radarr]=movie [sonarr]=series)
declare -A HD_ROOT=([radarr]=/data/media/movies [sonarr]=/data/media/tv)
declare -A UHD_ROOT=([radarr]=/data/media/movies-4k [sonarr]=/data/media/tv-4k)
ANIME_MOVIES=/data/media/anime-movies
TAG=4k-only
HEADER=$'kind\tinstance\tid\ttitle\tsrc\tdst\tfiles\taction'
# The manifest adds the id created in the 4K instance and the HD item's
# monitored state before the split (compact JSON, e.g.
# {"m":true,"s":{"0":false,"1":true}}; "s" only for series). Manifests
# written before "prior" existed end at new_id.
MANIFEST_HEADER="$HEADER"$'\tnew_id\tprior'
LEGACY_MANIFEST_HEADER="$HEADER"$'\tnew_id'
MIGRATION="$APPDATA_ROOT/.migration"

usage() {
  cat <<EOF
Split the 4K titles out of the HD libraries: titles whose every file is
>=2160p move from /data/media/{movies,tv} to /data/media/{movies-4k,tv-4k},
are added to radarr-4k/sonarr-4k, and are unmonitored and tagged $TAG in
radarr/sonarr. Mixed-resolution series are reported, never moved.

Plan (every run): reads radarr, sonarr and sonarr-anime and writes
  \$APPDATA_ROOT/.migration/split-4k-<ts>.tsv  (mode 600)
with the columns: ${HEADER//$'\t'/ }
  - a file is 4K if max(quality resolution, mediaInfo height) >= 2160 or
    the mediaInfo width is >= 3200 (scope releases such as 3840x1600);
  - action move: every file is 4K; skip-mixed: a series with some 4K
    files; check: quality and mediaInfo disagree about 4K (listed only);
  - titles already tagged $TAG in HD are skipped (a re-run plans 0 moves);
  - anime (sonarr-anime, radarr $ANIME_MOVIES) is not split, only
    counted as anime-4k=<n>.
Apply (--apply): preflights every move row first (dst absent, src present
under the HD root); any failure exits 1 with nothing moved. Then per row:
mv src dst; add it to the 4K instance from its lookup (the 4K profile,
path dst, monitored, no search; series monitor "existing"; series keep
the HD seasonFolder and seriesType); rescan it; unmonitor it (and every
season) in HD, tag it $TAG and rescan it in HD. Each row goes to
split-4k-<ts>.manifest.tsv with the id created in the 4K instance and the
HD monitored state before the split (column prior).
Undo (--undo <manifest>): in reverse row order, mv dst src, DELETE the 4K
item (deleteFiles=false), restore the HD item's monitored state (seasons
too) from prior, remove the tag and rescan it; then the manifest is
renamed to <manifest>.undone. A manifest without prior (older header)
re-monitors the item and every season, with a warning.

Dry-run by default: writes the plan, runs the preflight and prints each
move as "DRY-RUN: mv ...". Pass --apply to make the changes (also for
--undo). Needs radarr, radarr-4k, sonarr, sonarr-4k and sonarr-anime
running and healthy. Run as the media user (docker group).

Usage: 30-split-4k.sh [--apply] [--help]
       30-split-4k.sh --undo <manifest> [--apply] [--help]

Options:
  --undo <manifest>  Reverse the rows of a split-4k-<ts>.manifest.tsv.

Environment variables (defaults; normally from .env):
  APPDATA_ROOT=$APPDATA_ROOT   (API keys are read from here at runtime)
  DATA_ROOT=$DATA_ROOT
  QP_4K_RADARR=$QP_4K_RADARR   quality profile name in radarr-4k
  QP_4K_SONARR=$QP_4K_SONARR   quality profile name in sonarr-4k
EOF
}

# --- arguments: --undo locally, the rest by parse_common_args ----------------------
UNDO=""
rest=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --undo)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage >&2
        exit 2
      fi
      UNDO="$2"
      shift 2
      ;;
    *)
      rest+=("$1")
      shift
      ;;
  esac
done
parse_common_args "${rest[@]}"

# --- validation --------------------------------------------------------------------
require_safe_path APPDATA_ROOT "$APPDATA_ROOT"
require_safe_path DATA_ROOT "$DATA_ROOT"
[[ -n "$QP_4K_RADARR" && -n "$QP_4K_SONARR" ]] || die "QP_4K_RADARR and QP_4K_SONARR must not be empty"
require_cmd docker curl jq mv
if [[ -n "$UNDO" ]]; then
  [[ -f "$UNDO" ]] || die "no manifest $UNDO"
  UNDO="$(realpath -- "$UNDO")"
  require_safe_path "--undo" "$UNDO"
fi

umask 077
W="$(mktemp -d)"
MANIFEST=""
PARTIAL=""

# On a failed --apply, say what was left half-done and how to reverse it.
on_exit() {
  local rc=$? done_rows=0
  if [[ $rc -ne 0 && -n "$MANIFEST" && -f "$MANIFEST" ]]; then
    done_rows=$(($(wc -l <"$MANIFEST") - 1))
    if [[ -n "$PARTIAL" ]]; then
      log_error "row $PARTIAL partially applied; run --undo $MANIFEST"
    elif (( done_rows > 0 )); then
      log_error "stopped after $done_rows rows; run --undo $MANIFEST to reverse them"
    fi
  fi
  rm -rf "$W"
  exit "$rc"
}
trap on_exit EXIT

# on_disk </data/...>: the VM path of an in-container /data path.
on_disk() {
  printf '%s%s\n' "$DATA_ROOT" "${1#/data}"
}

# exists <path>: true for any file, dir or (even dangling) symlink.
exists() {
  [[ -e "$1" || -L "$1" ]]
}

# The 4K test, per file (quality.quality.resolution and mediaInfo.resolution
# "WxH"), and a title's action from its list of files.
# shellcheck disable=SC2016  # jq program: its $vars are jq's, not the shell's
JQ_4K='
  def mi: ((.mediaInfo.resolution // "") | tostring
           | capture("^(?<w>[0-9]+)x(?<h>[0-9]+)$") // null
           | if . == null then null else {w: (.w | tonumber), h: (.h | tonumber)} end);
  def q4k: (((.quality.quality.resolution // 0) | tonumber? // 0) >= 2160);
  def mi4k: (mi as $m | $m != null and ($m.h >= 2160 or $m.w >= 3200));
  def is4k: (q4k or mi4k);
  def disagree: (mi != null and (q4k != mi4k));
  def action: if length == 0 then "none"
              elif any(.[]; disagree) then "check"
              elif all(.[]; is4k) then "move"
              elif any(.[]; is4k) then "skip-mixed"
              else "none" end;'

# files_verdict <files-json>: prints "<action> <files> <any-4k>".
files_verdict() {
  jq -r "$JQ_4K"' [.[]? | objects] | "\(action) \(length) \(any(.[]; is4k))"' "$1"
}

# tag_id <tag-list-file>: the id of the 4k-only tag, or nothing.
tag_id() {
  jq -r --arg t "$TAG" '[.[]? | objects | select(.label == $t) | .id][0] // empty' "$1"
}

# rescan <svc> <movie|series> <id>: RescanMovie/RescanSeries for one item,
# then wait for it (arr_command).
rescan() {
  if [[ "$2" == movie ]]; then
    jq -n --argjson id "$3" '{name: "RescanMovie", movieId: $id}' >"$W/cmd.json"
  else
    jq -n --argjson id "$3" '{name: "RescanSeries", seriesId: $id}' >"$W/cmd.json"
  fi
  arr_command "$1" "$W/cmd.json"
}

# prior_of <item-file>: the item's monitored state as compact JSON,
# {"m":<bool>} plus "s":{"<seasonNumber>":<bool>,...} for series.
prior_of() {
  jq -c '{m: (.monitored != false)}
         + (if has("seasons")
            then {s: ([.seasons[]? | objects | {key: (.seasonNumber | tostring), value: (.monitored != false)}]
                      | from_entries)}
            else {} end)' "$1"
}

# prior_ok <json>: true if it is a prior value as prior_of writes it.
prior_ok() {
  jq -e 'type == "object" and (.m | type) == "boolean"
         and ((.s // {}) | type == "object" and all(.[]; type == "boolean"))' <<<"$1" >/dev/null 2>&1
}

# item_fields <item-file>: two lines, the title (tabs/newlines as spaces)
# and the path; "BAD" if the path holds a tab or newline.
item_fields() {
  jq -r '(.path // "" | tostring) as $p
         | if ($p | test("[\\t\\r\\n]")) then "BAD", "BAD"
           else ((.title // "?") | tostring | gsub("[\\t\\r\\n]+"; " ")), $p end' "$1"
}

# ==============================================================================
# Undo
# ==============================================================================
if [[ -n "$UNDO" ]]; then
  UNDO_HEAD="$(head -n 1 "$UNDO")"
  LEGACY=0
  if [[ "$UNDO_HEAD" == "$LEGACY_MANIFEST_HEADER" ]]; then
    LEGACY=1
    log_warn "$UNDO has no prior column (older manifest): every HD item and season is re-monitored"
  elif [[ "$UNDO_HEAD" != "$MANIFEST_HEADER" ]]; then
    die "$UNDO is not a split-4k manifest (header differs)"
  fi
  require_healthy radarr radarr-4k sonarr sonarr-4k

  # Rows, newest first, validated before anything is touched.
  mapfile -t ROWS < <(tail -n +2 "$UNDO" | tac)
  bad=()
  n=${#ROWS[@]}
  for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r kind inst id title src dst _ action new_id prior <<<"$row"
    if [[ "${KIND[$inst]:-}" != "$kind" || ! "$id" =~ ^[0-9]+$ || "$action" != move
          || ! "$new_id" =~ ^([0-9]+|-)$ || "$src" != "${HD_ROOT[$inst]}/"* || "$dst" != "${UHD_ROOT[$inst]}/"*
          || "$src$dst" == *"/../"* ]] || { [[ $LEGACY -eq 0 ]] && ! prior_ok "$prior"; }; then
      bad+=("malformed row: $row")
    elif ! exists "$(on_disk "$dst")"; then
      bad+=("$kind $inst $id $title: $dst is missing")
    elif exists "$(on_disk "$src")"; then
      bad+=("$kind $inst $id $title: $src already exists")
    fi
  done
  if [[ ${#bad[@]} -gt 0 ]]; then
    printf '[ERROR] undo preflight: %s\n' "${bad[@]}" >&2
    die "undo preflight failed for ${#bad[@]} of $n rows; nothing moved"
  fi

  declare -A UNDO_TAG=()
  for inst in radarr sonarr; do
    api "$inst" GET "/api/v3/${KIND[$inst]}" >"$W/$inst-items.json"
    api "$inst" GET /api/v3/tag >"$W/$inst-tags.json"
    UNDO_TAG[$inst]="$(tag_id "$W/$inst-tags.json")"
  done

  k=0
  for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r kind inst id title src dst _ action new_id prior <<<"$row"
    [[ $LEGACY -eq 0 ]] || prior=null
    k=$((k + 1))
    log_info "undo $k/$n: $kind $inst $id $title"
    run mv -T -- "$(on_disk "$dst")" "$(on_disk "$src")"
    if [[ "$new_id" != - ]]; then
      arr_change "$inst-4k" DELETE "/api/v3/$kind/$new_id?deleteFiles=false"
    fi
    jq --argjson id "$id" '.[]? | objects | select(.id == $id)' "$W/$inst-items.json" >"$W/item.json"
    [[ -s "$W/item.json" ]] || die "$inst: $kind $id not found"
    # The monitored state from prior; a season that prior does not list
    # (added since the split) keeps its current state. Legacy: all true.
    jq --argjson t "${UNDO_TAG[$inst]:-null}" --argjson p "$prior" '
      .tags = [(.tags // [])[] | select(. != $t)]
      | if $p == null then
          .monitored = true
          | if has("seasons") then .seasons |= map(.monitored = true) else . end
        else
          .monitored = $p.m
          | if has("seasons") then
              .seasons |= map((.seasonNumber | tostring) as $n
                              | if ($p.s // {} | has($n)) then .monitored = $p.s[$n] else . end)
            else . end
        end' "$W/item.json" >"$W/put.json"
    arr_change "$inst" PUT "/api/v3/$kind/$id" "$W/put.json"
    rescan "$inst" "$kind" "$id"
  done
  # A reversed manifest no longer counts for verify-media.sh.
  run mv -T -- "$UNDO" "$UNDO.undone"
  if [[ $APPLY -eq 1 ]]; then
    log_info "undone: $n rows from $UNDO"
  else
    log_info "undo of $n rows (dry-run; pass --apply to make it)"
  fi
  exit 0
fi

# ==============================================================================
# Plan
# ==============================================================================
require_healthy radarr radarr-4k sonarr sonarr-4k sonarr-anime

# 4K quality profiles, by name, in the 4K instances.
declare -A QP_NAME=([radarr]="$QP_4K_RADARR" [sonarr]="$QP_4K_SONARR")
declare -A QP_ID=()
for inst in radarr sonarr; do
  api "$inst-4k" GET /api/v3/qualityprofile >"$W/$inst-4k-qp.json"
  QP_ID[$inst]="$(jq -r --arg n "${QP_NAME[$inst]}" '[.[]? | objects | select(.name == $n) | .id][0] // empty' "$W/$inst-4k-qp.json")"
  if [[ ! "${QP_ID[$inst]}" =~ ^[0-9]+$ ]]; then
    die "$inst-4k: quality profile '${QP_NAME[$inst]}' not found; available: $(jq -r '[.[]? | objects | .name] | join(", ")' "$W/$inst-4k-qp.json") (set QP_4K_${inst^^})"
  fi
done

: >"$W/plan.tsv"
declare -A TAG_ID=()
declare -A COUNT=([move]=0 [skip-mixed]=0 [check]=0)
ANIME_4K=0
NOTES=()

# plan_instance <svc>: classifies each title with files. radarr and sonarr
# add TSV rows; sonarr-anime and radarr's anime-movies only count anime-4k.
plan_instance() {
  local svc="$1" kind files_path list="$W/$1-items.json" id action nfiles any4k
  local title path anime tag ids=()
  if [[ "$svc" == radarr ]]; then
    kind=movie files_path="/api/v3/moviefile?movieId="
  else
    kind=series files_path="/api/v3/episodefile?seriesId="
  fi
  api "$svc" GET "/api/v3/$kind" >"$list"
  tag=""
  if [[ "$svc" != sonarr-anime ]]; then
    api "$svc" GET /api/v3/tag >"$W/$svc-tags.json"
    tag="$(tag_id "$W/$svc-tags.json")"
    TAG_ID[$svc]="$tag"
  fi

  # Titles with files, not tagged 4k-only (monitored or not).
  mapfile -t ids < <(jq -r --argjson t "${tag:-null}" '
    .[]? | objects
    | select(if has("hasFile") then .hasFile == true else true end)
    | select(((.statistics.episodeFileCount // 1) | tonumber? // 1) > 0)
    | select(any((.tags // [])[]; . == $t) | not)
    | .id | tostring' "$list")
  for id in "${ids[@]}"; do
    [[ "$id" =~ ^[0-9]+$ ]] || die "$svc: unexpected $kind id '$id'"
    jq --argjson id "$id" '[.[]? | objects | select(.id == $id)][0]' "$list" >"$W/$svc-item-$id.json"
    { IFS= read -r title; IFS= read -r path; } < <(item_fields "$W/$svc-item-$id.json")
    [[ "$path" != BAD ]] || die "$svc: $kind $id has a tab or newline in its path"
    api "$svc" GET "$files_path$id" >"$W/$svc-files-$id.json"
    read -r action nfiles any4k < <(files_verdict "$W/$svc-files-$id.json")

    anime=0
    [[ "$svc" == sonarr-anime || "$path" == "$ANIME_MOVIES/"* ]] && anime=1
    if [[ $anime -eq 1 ]]; then
      [[ "$any4k" == true ]] && ANIME_4K=$((ANIME_4K + 1))
      continue
    fi
    [[ "$action" == none ]] && continue
    COUNT[$action]=$((COUNT[$action] + 1))
    [[ "$action" == move ]] || NOTES+=("$action: $kind $svc $id $title")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$svc" "$id" "$title" "$path" \
      "${UHD_ROOT[$svc]}/${path##*/}" "$nfiles" "$action" >>"$W/plan.tsv"
  done
}

plan_instance radarr
plan_instance sonarr
plan_instance sonarr-anime

install -d -m 700 "$MIGRATION"
TS="$(date +%Y%m%d-%H%M%S)"
while [[ -e "$MIGRATION/split-4k-$TS.tsv" ]]; do
  sleep 1
  TS="$(date +%Y%m%d-%H%M%S)"
done
PLAN="$MIGRATION/split-4k-$TS.tsv"
{ printf '%s\n' "$HEADER"; cat "$W/plan.tsv"; } >"$W/plan-out.tsv"
install -m 600 "$W/plan-out.tsv" "$PLAN"

log_info "plan: ${COUNT[move]} move, ${COUNT[skip-mixed]} skip-mixed, ${COUNT[check]} check, anime-4k=$ANIME_4K -> $PLAN"
for note in "${NOTES[@]}"; do
  log_info "$note"
done

# ==============================================================================
# Preflight: every move row, before anything moves
# ==============================================================================
mapfile -t MOVES < <(awk -F'\t' '$8 == "move"' "$W/plan.tsv")
if [[ ${#MOVES[@]} -eq 0 ]]; then
  log_info "nothing to move"
  exit 0
fi
bad=()
for row in "${MOVES[@]}"; do
  IFS=$'\t' read -r kind inst id title src dst _ _ <<<"$row"
  if [[ "$src" != "${HD_ROOT[$inst]}/"* || "$src" == *"/../"* || "${src##*/}" == .* ]]; then
    bad+=("$kind $inst $id $title: $src is not under ${HD_ROOT[$inst]}/")
  elif ! exists "$(on_disk "$src")"; then
    bad+=("$kind $inst $id $title: $(on_disk "$src") is missing")
  elif exists "$(on_disk "$dst")"; then
    bad+=("$kind $inst $id $title: $(on_disk "$dst") already exists")
  elif [[ ! -d "$(on_disk "${UHD_ROOT[$inst]}")" ]]; then
    bad+=("$kind $inst $id $title: $(on_disk "${UHD_ROOT[$inst]}") is missing (run scripts/mkdirs.sh)")
  fi
done
if [[ ${#bad[@]} -gt 0 ]]; then
  printf '[ERROR] preflight: %s\n' "${bad[@]}" >&2
  die "preflight failed for ${#bad[@]} of ${#MOVES[@]} move rows; nothing moved"
fi

if [[ $APPLY -eq 0 ]]; then
  for row in "${MOVES[@]}"; do
    IFS=$'\t' read -r kind inst id title src dst _ _ <<<"$row"
    run mv -T -- "$(on_disk "$src")" "$(on_disk "$dst")"
    log_info "then: add $kind '$title' to $inst-4k (${QP_NAME[$inst]}, $dst), unmonitor and tag $TAG in $inst"
  done
  log_info "${#MOVES[@]} titles to move (dry-run; review $PLAN, then pass --apply)"
  exit 0
fi

# ==============================================================================
# Apply
# ==============================================================================
MANIFEST="$MIGRATION/split-4k-$TS.manifest.tsv"
printf '%s\n' "$MANIFEST_HEADER" >"$MANIFEST"

# ensure_tag <svc>: TAG_ID[svc], creating the 4k-only tag if missing.
ensure_tag() {
  local svc="$1"
  [[ -n "${TAG_ID[$svc]:-}" ]] && return 0
  jq -n --arg t "$TAG" '{label: $t}' >"$W/tag.json"
  arr_mutate "$svc" POST /api/v3/tag "$W/tag.json" >"$W/tag-new.json"
  TAG_ID[$svc]="$(jq -r '.id // empty' "$W/tag-new.json")"
  [[ "${TAG_ID[$svc]}" =~ ^[0-9]+$ ]] || die "$svc: creating tag $TAG returned no id"
}

# apply_row <n> <row>
apply_row() {
  local n="$1" kind inst id title src dst uhd ext new_id prior lk="$W/lookup.json"
  IFS=$'\t' read -r kind inst id title src dst _ _ <<<"$2"
  uhd="$inst-4k"
  local item="$W/$inst-item-$id.json"
  # The HD monitored state from the plan's GET, before anything changes it.
  prior="$(prior_of "$item")"
  prior_ok "$prior" || die "$inst: $kind $id: cannot record its monitored state"

  run mv -T -- "$(on_disk "$src")" "$(on_disk "$dst")"
  PARTIAL="$n"
  printf '%s\t-\t%s\n' "$2" "$prior" >>"$MANIFEST"

  # Add payload from the 4K instance's own lookup.
  if [[ "$kind" == movie ]]; then
    ext="$(jq -r '.tmdbId // empty' "$item")"
    [[ "$ext" =~ ^[0-9]+$ ]] || die "$inst: movie $id has no tmdbId"
    api "$uhd" GET "/api/v3/movie/lookup/tmdb?tmdbId=$ext" >"$W/lookup-raw.json"
    jq 'if type == "array" then .[0] else . end' "$W/lookup-raw.json" >"$lk"
  else
    ext="$(jq -r '.tvdbId // empty' "$item")"
    [[ "$ext" =~ ^[0-9]+$ ]] || die "$inst: series $id has no tvdbId"
    api "$uhd" GET "/api/v3/series/lookup?term=$(jq -rn --arg t "tvdb:$ext" '$t | @uri')" >"$W/lookup-raw.json"
    jq --argjson x "$ext" '[.[]? | objects | select(.tvdbId == $x)][0] // empty' "$W/lookup-raw.json" >"$lk"
  fi
  [[ -s "$lk" && "$(jq -r 'type' "$lk")" == object ]] || die "$uhd: lookup found nothing for $kind $id ($title)"

  new_id="$(jq -r '.id // 0' "$lk")"
  if [[ "$new_id" =~ ^[1-9][0-9]*$ ]]; then
    log_info "$uhd already has $kind '$title' (id $new_id); not adding it again"
  else
    # Series keep the HD seasonFolder and seriesType: a lookup of a series
    # not yet in the library returns seasonFolder false.
    jq --argjson qp "${QP_ID[$inst]}" --arg root "${UHD_ROOT[$inst]}" --arg path "$dst" --arg kind "$kind" \
      --slurpfile hd "$item" '
      del(.id) | .qualityProfileId = $qp | .rootFolderPath = $root | .path = $path
      | .monitored = true | .tags = []
      | if $kind == "series" then
          .seasonFolder = (if ($hd[0].seasonFolder | type) == "boolean" then $hd[0].seasonFolder else true end)
          | .seriesType = ($hd[0].seriesType // "standard")
        else . end
      | .addOptions = (if $kind == "movie" then {searchForMovie: false}
                       else {searchForMissingEpisodes: false, monitor: "existing"} end)' "$lk" >"$W/add.json"
    arr_mutate "$uhd" POST "/api/v3/$kind" "$W/add.json" >"$W/added.json"
    new_id="$(jq -r '.id // empty' "$W/added.json")"
    [[ "$new_id" =~ ^[0-9]+$ ]] || die "$uhd: adding $kind '$title' returned no id"
  fi
  # The row's new_id: rewrite the last manifest line.
  sed -i '$ d' "$MANIFEST"
  printf '%s\t%s\t%s\n' "$2" "$new_id" "$prior" >>"$MANIFEST"

  rescan "$uhd" "$kind" "$new_id"

  # HD: unmonitored (every season too) and tagged, so an explicit HD
  # request can still re-monitor it.
  ensure_tag "$inst"
  jq --argjson t "${TAG_ID[$inst]}" '
    .monitored = false
    | .tags = ((.tags // []) + [$t] | unique)
    | if has("seasons") then .seasons |= map(.monitored = false) else . end' "$item" >"$W/put.json"
  arr_change "$inst" PUT "/api/v3/$kind/$id" "$W/put.json"
  # Rescan in HD, so it drops the moved files (hasFile/episodeFileCount)
  # now rather than at its next scheduled refresh.
  rescan "$inst" "$kind" "$id"
  PARTIAL=""
  log_info "moved $n/${#MOVES[@]}: $kind '$title' -> $uhd id $new_id"
}

k=0
for row in "${MOVES[@]}"; do
  k=$((k + 1))
  apply_row "$k" "$row"
done
log_info "split: ${#MOVES[@]} titles moved; manifest $MANIFEST (undo: scripts/vm/30-split-4k.sh --undo $MANIFEST --apply)"
