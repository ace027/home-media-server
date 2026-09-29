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

# Old root -> new root, per restored instance. In-container /data is the
# VM's $DATA_ROOT, so /data/<x> is checked on disk as $DATA_ROOT/<x>.
REMAP_SVCS=(sonarr sonarr-anime radarr)
declare -A OLD=([sonarr]=/data/shows [sonarr-anime]=/data/anime [radarr]=/data/movies)
declare -A NEW=([sonarr]=/data/media/tv [sonarr-anime]=/data/media/anime-tv [radarr]=/data/media/movies)
MUSIC_ROOT=/data/media/music

usage() {
  cat <<EOF
Move the restored Sonarr, Sonarr Anime and Radarr from the old /data roots
to /data/media/*, through each app's own API and without moving any file
(editor PUT with moveFiles:false). Lidarr gets its /data/media/music root.

Per instance, in order:
  1. turn autoUnmonitorPreviouslyDownloaded{Episodes,Movies} off (before
     any rescan, so paths that look missing can't unmonitor the library);
  2. add the new root folder if missing;
  3. move every item under the old root to the new one (moveFiles:false);
  4. with --apply, re-read the items and exit 1 if any is still under the
     old root (the old root is then kept);
  5. delete the old root folder;
  6. only if items moved: rescan, and wait for it.

  sonarr        /data/shows   -> /data/media/tv
  sonarr-anime  /data/anime   -> /data/media/anime-tv
  radarr        /data/movies  -> /data/media/movies

Refuses (exit 1) while sabnzbd or prowlarr is running (no grabs while paths
are in flux), unless sonarr, sonarr-anime, radarr and lidarr are running
and healthy, if a new root dir is missing under \$DATA_ROOT, or if any item
to move has no folder at <new root>/<folder name> under \$DATA_ROOT (a
rescan would drop its files while it stays monitored). These checks run
before any change, in dry-run too. A re-run makes no changes and prints
"no changes".

Dry-run by default: reads the apps and prints each change as
"DRY-RUN: <METHOD> <svc> <path> <body>" (secrets shown as ***). Pass
--apply to make the changes. Run as the media user (docker group).

Usage: 20-arr-remap.sh [--apply] [--help]

Environment variables (defaults; normally from .env):
  APPDATA_ROOT=$APPDATA_ROOT   (API keys are read from here at runtime)
  DATA_ROOT=$DATA_ROOT
EOF
}

parse_common_args "$@"

require_safe_path APPDATA_ROOT "$APPDATA_ROOT"
require_safe_path DATA_ROOT "$DATA_ROOT"
require_cmd docker curl jq

# on_disk </data/...>: the VM path of an in-container /data path.
on_disk() {
  printf '%s%s\n' "$DATA_ROOT" "${1#/data}"
}

# --- preconditions ---------------------------------------------------------------
running="$(running_services)" || die "docker compose ps failed"
for svc in sabnzbd prowlarr; do
  if grep -qx -- "$svc" <<<"$running"; then
    die "stop sabnzbd and prowlarr first: docker compose stop sabnzbd prowlarr"
  fi
done
require_healthy sonarr sonarr-anime radarr lidarr
for svc in "${REMAP_SVCS[@]}"; do
  [[ -d "$(on_disk "${NEW[$svc]}")" ]] || die "missing new root dir $(on_disk "${NEW[$svc]}") (run scripts/mkdirs.sh)"
done
[[ -d "$(on_disk "$MUSIC_ROOT")" ]] || die "missing new root dir $(on_disk "$MUSIC_ROOT") (run scripts/mkdirs.sh)"

umask 077
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

declare -A MOVED=()
declare -A KIND=([sonarr]=series [sonarr-anime]=series [radarr]=movie)

# --- every item WITH FILES must already have its folder on the new pool ------
# The rescan after the editor call drops the file records of an item whose
# folder is missing, while the item stays monitored: that means re-downloads.
# An item with no files has no records to drop (the *arr apps only create a
# folder once a file exists: unreleased movies, series added but not yet
# downloaded), so a missing folder there is only reported.
# Checked for all instances before any change (also in dry-run); the item
# lists read here are reused by step 3. If the app doesn't say whether an
# item has files, it is treated as having them.
missing=()
missing_empty=()
for svc in "${REMAP_SVCS[@]}"; do
  api "$svc" GET "$(arr_base "$svc")/${KIND[$svc]}" >"$W/$svc-items.json"
  mapfile -d '' -t fields < <(jq -j --arg o "${OLD[$svc]}/" '
    def has_files:
      if .hasFile != null then .hasFile
      elif .statistics.episodeFileCount != null then (.statistics.episodeFileCount > 0)
      else true end;
    .[]? | objects | select((.path // "") | startswith($o))
    | ((.path | sub("/+$"; "") | split("/") | last), "\u0000", (has_files | tostring), "\u0000")' \
    "$W/$svc-items.json")
  for ((i = 0; i + 1 < ${#fields[@]}; i += 2)); do
    name="${fields[i]}"
    dir="$(on_disk "${NEW[$svc]}/$name")"
    [[ -n "$name" && -d "$dir" ]] && continue
    if [[ "${fields[i + 1]}" == true ]]; then
      missing+=("$dir")
    else
      missing_empty+=("$dir")
    fi
  done
done
if [[ ${#missing[@]} -gt 0 ]]; then
  die "folder missing on the new pool; nothing changed: $(printf '%s, ' "${missing[@]}" | sed 's/, $//')"
fi
if [[ ${#missing_empty[@]} -gt 0 ]]; then
  log_info "${#missing_empty[@]} title(s) have no files yet and no folder on the new pool; nothing to protect: $(printf '%s, ' "${missing_empty[@]}" | sed 's/, $//')"
fi

# remap_instance <svc>
remap_instance() {
  local svc="$1" old="${OLD[$1]}" new="${NEW[$1]}" base kind="${KIND[$1]}" ids_key field rescan
  local mm_id ids n left old_id
  base="$(arr_base "$svc")"
  case "$svc" in
    sonarr|sonarr-anime)
      ids_key=seriesIds rescan=RescanSeries
      field=autoUnmonitorPreviouslyDownloadedEpisodes
      ;;
    radarr)
      ids_key=movieIds rescan=RescanMovie
      field=autoUnmonitorPreviouslyDownloadedMovies
      ;;
  esac

  # 1. Unmonitor-deleted off, before anything can trigger a scan.
  api "$svc" GET "$base/config/mediamanagement" >"$W/mm.json"
  case "$(jq -r --arg f "$field" '.[$f] | if . == null then "missing" else tostring end' "$W/mm.json")" in
    true)
      jq --arg f "$field" '.[$f] = false' "$W/mm.json" >"$W/mm-new.json"
      mm_id="$(jq -r '.id // empty' "$W/mm.json")"
      if [[ "$mm_id" =~ ^[0-9]+$ ]]; then
        arr_change "$svc" PUT "$base/config/mediamanagement/$mm_id" "$W/mm-new.json"
      else
        arr_change "$svc" PUT "$base/config/mediamanagement" "$W/mm-new.json"
      fi
      ;;
    false) ;;
    *) die "$svc: config/mediamanagement has no boolean $field; refusing to remap" ;;
  esac

  # 2. New root folder.
  api "$svc" GET "$base/rootfolder" >"$W/rf.json"
  ensure_root_folder "$svc" "$new" "$W/rf.json"

  # 3. Items under the old root -> new root, DB paths only (the list read
  #    by the folder check).
  ids="$(jq -c --arg o "$old/" '[.[]? | objects | select((.path // "") | startswith($o)) | .id]' "$W/$svc-items.json")"
  n="$(jq 'length' <<<"$ids")"
  if (( n > 0 )); then
    jq -n --arg k "$ids_key" --argjson ids "$ids" --arg r "$new" \
      '{($k): $ids, rootFolderPath: $r, moveFiles: false}' >"$W/editor.json"
    arr_change "$svc" PUT "$base/$kind/editor" "$W/editor.json"

    # 4. Nothing may be left under the old root before it is deleted.
    if [[ $APPLY -eq 1 ]]; then
      api "$svc" GET "$base/$kind" >"$W/items-after.json"
      left="$(jq -r --arg o "$old/" '[.[]? | objects | select((.path // "") | startswith($o)) | .id] | join(",")' "$W/items-after.json")"
      if [[ -n "$left" ]]; then
        die "$svc: items still under $old/ after the editor call (ids: $left); old root folder kept"
      fi
    fi
  fi

  # 5. Old root folder (with or without a trailing /).
  old_id="$(jq -r --arg o "$old" \
    '[.[]? | objects | select(((.path // "") | sub("/+$"; "")) == $o) | .id][0] // empty' "$W/rf.json")"
  if [[ -n "$old_id" ]]; then
    [[ "$old_id" =~ ^[0-9]+$ ]] || die "$svc: unexpected root folder id"
    arr_change "$svc" DELETE "$base/rootfolder/$old_id"
  fi

  # 6. Rescan only if items moved: a converged instance makes no call.
  if (( n > 0 )); then
    jq -n --arg c "$rescan" '{name: $c}' >"$W/cmd.json"
    arr_command "$svc" "$W/cmd.json"
  fi
  MOVED[$svc]="$n"
}

for svc in "${REMAP_SVCS[@]}"; do
  remap_instance "$svc"
done

# Lidarr had no root folder before; it gets the music root.
api lidarr GET "$(arr_base lidarr)/rootfolder" >"$W/lidarr-rf.json"
ensure_root_folder lidarr "$MUSIC_ROOT" "$W/lidarr-rf.json"

for svc in "${REMAP_SVCS[@]}"; do
  log_info "$svc: ${MOVED[$svc]} items ${OLD[$svc]} -> ${NEW[$svc]}"
done
if [[ $count_mutations -eq 0 ]]; then
  log_info "no changes"
elif [[ $APPLY -eq 0 ]]; then
  log_info "$count_mutations changes (dry-run; pass --apply to make them)"
else
  log_info "$count_mutations changes"
fi
log_info "next: docker compose up -d sabnzbd && scripts/vm/25-arr-wire.sh --only sab"
