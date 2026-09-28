#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# .env first, then defaults, so .env values are not masked by the defaults.
# (sudo resets the environment, so under sudo these come from .env; the
# stage/rollback timestamps are flags for the same reason.)
load_env
APPDATA_ROOT="${APPDATA_ROOT:-/opt/appdata}"
DATA_ROOT="${DATA_ROOT:-/data}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

SERVICES=(plex seerr tautulli sonarr sonarr-anime radarr lidarr prowlarr sabnzbd)
FRESH=(sonarr-4k radarr-4k jellyfin)
DC=(docker compose --project-directory "$REPO_ROOT")

# *arr/Prowlarr databases checked before the swap: <svc>/<file>.
ARR_DBS=(sonarr/sonarr.db sonarr-anime/sonarr.db radarr/radarr.db lidarr/lidarr.db prowlarr/prowlarr.db)
# Default ports (the arr_port table) for the UrlBase/Port report.
declare -A ARR_PORT=([sonarr]=8989 [sonarr-anime]=8989 [radarr]=7878 [lidarr]=8686 [prowlarr]=9696)
PLEX_PREFS_REL="Library/Application Support/Plex Media Server/Preferences.xml"
PLEX_DB_REL="Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"

usage() {
  cat <<EOF
Restore the old app configs staged by scripts/host/30-push-appdata.sh into
$APPDATA_ROOT, with rollback, or undo an earlier restore.

Restore mode, in order: integrity-check the staged *arr databases (as
PUID, read-only; nothing moves on failure), swap each staged dir into
place (existing dirs go to .rollback/<ts>, empty ones are removed), chown
PUID:PGID + chmod 700, delete *.pid, set Plex autoEmptyTrash="0" and drop
a stale TranscoderTempDirectory, point SABnzbd at /data/usenet/* and move
its old queue (admin/) aside, report non-default UrlBase/Port, create the
fresh service dirs, write .migration/baseline.json, remove the stage.

Refuses (exit 1, nothing moved) if any restored service is running, if
\$DATA_ROOT/{shows,movies,anime} exists, or if the stage holds an
unexpected entry or a symlink leading outside it.

Dry-run by default: runs the read-only checks, then prints the commands
it would run. Pass --apply to actually run them; --apply requires root.

Usage: 10-restore-appdata.sh [--stage <ts>] [--apply] [--help]
       10-restore-appdata.sh --rollback <ts> [--apply] [--help]

Options:
  --stage <ts>     Stage to restore, YYYYMMDD-HHMMSS (default: the newest
                   under \$APPDATA_ROOT/.staging).
  --rollback <ts>  Move .rollback/<ts>/<svc> back into place; the current
                   dirs go to .rollback/<ts>-undone.

Environment variables (defaults; normally from .env):
  APPDATA_ROOT=$APPDATA_ROOT
  DATA_ROOT=$DATA_ROOT
  PUID=$PUID
  PGID=$PGID
EOF
}

# --- arguments: --stage/--rollback locally, the rest by parse_common_args ---
TS=""
ROLLBACK_TS=""
rest=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage|--rollback)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      if [[ "$1" == "--stage" ]]; then TS="$2"; else ROLLBACK_TS="$2"; fi
      shift 2
      ;;
    *)
      rest+=("$1")
      shift
      ;;
  esac
done
parse_common_args "${rest[@]}"
if [[ -n "$TS" && -n "$ROLLBACK_TS" ]]; then
  usage >&2
  exit 2
fi

# --- validation ----------------------------------------------------------------
[[ -z "$TS" ]] || require_match "--stage" "$TS" '^[0-9]{8}-[0-9]{6}$' "YYYYMMDD-HHMMSS"
[[ -z "$ROLLBACK_TS" ]] || require_match "--rollback" "$ROLLBACK_TS" '^[0-9]{8}-[0-9]{6}$' "YYYYMMDD-HHMMSS"
require_safe_path APPDATA_ROOT "$APPDATA_ROOT"
require_safe_path DATA_ROOT "$DATA_ROOT"
require_match PUID "$PUID" '^[0-9]+$' "a numeric uid"
require_match PGID "$PGID" '^[0-9]+$' "a numeric gid"
require_cmd sqlite3 jq docker setpriv
require_root

# as_puid <cmd...>: run read-only tools as PUID:PGID when root; a non-root
# dry run just runs them as the current user.
as_puid() {
  if [[ $EUID -eq 0 ]]; then
    setpriv --reuid="$PUID" --regid="$PGID" --init-groups "$@"
  else
    "$@"
  fi
}

is_service() {
  local s
  for s in "${SERVICES[@]}"; do
    [[ "$s" == "$1" ]] && return 0
  done
  return 1
}

dir_is_empty() {
  [[ -d "$1" && -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

# --- precondition: none of the 9 services is running (both modes) -----------
running="$("${DC[@]}" ps --status running --services)" || die "docker compose ps failed"
busy=()
while IFS= read -r svc; do
  if [[ -n "$svc" ]] && is_service "$svc"; then
    busy+=("$svc")
  fi
done <<<"$running"
if [[ ${#busy[@]} -gt 0 ]]; then
  die "stop first: docker compose stop ${busy[*]}"
fi

# ==============================================================================
# Rollback mode
# ==============================================================================
if [[ -n "$ROLLBACK_TS" ]]; then
  RB="$APPDATA_ROOT/.rollback/$ROLLBACK_TS"
  UNDONE="$APPDATA_ROOT/.rollback/$ROLLBACK_TS-undone"
  [[ -d "$RB" ]] || die "no rollback dir $RB"
  saved=()
  while IFS= read -r -d '' e; do
    name="${e##*/}"
    [[ "$name" == "sabnzbd-admin" ]] && continue
    is_service "$name" || die "unexpected entry in $RB: $name"
    saved+=("$name")
  done < <(find "$RB" -mindepth 1 -maxdepth 1 -print0 | sort -z)

  undone_made=0
  for svc in "${saved[@]}"; do
    if [[ -e "$APPDATA_ROOT/$svc" || -L "$APPDATA_ROOT/$svc" ]]; then
      if [[ $undone_made -eq 0 ]]; then
        run mkdir -p -m 700 "$UNDONE"
        undone_made=1
      fi
      [[ ! -e "$UNDONE/$svc" ]] || die "$UNDONE/$svc already exists; move it away first"
      run mv -T "$APPDATA_ROOT/$svc" "$UNDONE/$svc"
    fi
    run mv -T "$RB/$svc" "$APPDATA_ROOT/$svc"
    log_info "$svc: restored from .rollback/$ROLLBACK_TS"
  done

  # sabnzbd-admin came from the restored sabnzbd dir: put it back into that dir,
  # which is in $UNDONE when an older sabnzbd dir was just rolled back.
  if [[ -d "$RB/sabnzbd-admin" ]]; then
    sab_home="$APPDATA_ROOT/sabnzbd"
    for svc in "${saved[@]}"; do
      [[ "$svc" == sabnzbd ]] && sab_home="$UNDONE/sabnzbd"
    done
    if [[ -e "$sab_home/admin" ]]; then
      log_warn "$sab_home/admin exists; left $RB/sabnzbd-admin in place"
    elif [[ ! -d "$sab_home" && $APPLY -eq 1 ]]; then
      log_warn "$sab_home missing; left $RB/sabnzbd-admin in place"
    else
      run mv -T "$RB/sabnzbd-admin" "$sab_home/admin"
    fi
  fi
  log_info "rolled back $ROLLBACK_TS"
  exit 0
fi

# ==============================================================================
# Restore mode: preconditions (nothing is moved until all of them pass)
# ==============================================================================
if [[ -z "$TS" ]]; then
  TS="$(find "$APPDATA_ROOT/.staging" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | tail -1 || true)"
  [[ -n "$TS" ]] || die "no stage found under $APPDATA_ROOT/.staging; run 30-push-appdata.sh on the host first"
  log_info "using newest stage $TS"
fi
STAGE="$APPDATA_ROOT/.staging/$TS"
RB="$APPDATA_ROOT/.rollback/$TS"
[[ -d "$STAGE" && ! -L "$STAGE" ]] || die "stage $STAGE not found"

# Top-level entries: a subset of the 9 names, each a real directory.
STAGED=()
while IFS= read -r -d '' e; do
  name="${e##*/}"
  is_service "$name" || die "unexpected entry in stage: $name"
  [[ -d "$e" && ! -L "$e" ]] || die "stage entry $name is not a directory"
  STAGED+=("$name")
done < <(find "$STAGE" -mindepth 1 -maxdepth 1 -print0 | sort -z)
[[ ${#STAGED[@]} -gt 0 ]] || die "stage $STAGE is empty"

# Symlinks must resolve inside the stage.
stage_real="$(realpath -m -- "$STAGE")"
while IFS= read -r -d '' l; do
  target="$(realpath -m -- "$l")"
  if [[ "$target" != "$stage_real" && "$target" != "$stage_real"/* ]]; then
    die "symlink leaves the stage: ${l#"$STAGE"/} -> $target"
  fi
done < <(find "$STAGE" -type l -print0)

# The old *arr roots must not exist (a scan would drop file records).
for old in shows movies anime; do
  if [[ -e "$DATA_ROOT/$old" || -L "$DATA_ROOT/$old" ]]; then
    die "$DATA_ROOT/$old exists; the restored apps still point at it until 20-arr-remap.sh; move or remove it first"
  fi
done

in_stage() {
  local s
  for s in "${STAGED[@]}"; do
    [[ "$s" == "$1" ]] && return 0
  done
  return 1
}

# src_dir <svc>: where to *read* a restored service's files. After an
# --apply swap that is $APPDATA_ROOT/<svc>; in a dry run nothing has moved,
# so it is still the staged copy. Commands always name the final path.
src_dir() {
  if [[ $APPLY -eq 1 ]]; then
    printf '%s\n' "$APPDATA_ROOT/$1"
  else
    printf '%s\n' "$STAGE/$1"
  fi
}

WARNINGS=()
warn() {
  log_warn "$*"
  WARNINGS+=("$*")
}

# --- 1: integrity of the staged *arr DBs (read-only, runs in dry-run too) ----
for rel in "${ARR_DBS[@]}"; do
  svc="${rel%%/*}"
  db="$STAGE/$rel"
  [[ -f "$db" ]] || continue
  result="$(as_puid sqlite3 -readonly "$db" 'PRAGMA integrity_check;' 2>&1)" || true
  if [[ "$result" != "ok" ]]; then
    die "integrity check failed: $svc (nothing was moved)"
  fi
  log_info "integrity ok: $rel"
done

# --- 2: swap each staged service into place ----------------------------------
run mkdir -p -m 700 "$RB"
for svc in "${STAGED[@]}"; do
  target="$APPDATA_ROOT/$svc"
  if dir_is_empty "$target" && [[ ! -L "$target" ]]; then
    run rmdir "$target"
  elif [[ -e "$target" || -L "$target" ]]; then
    [[ ! -e "$RB/$svc" ]] || die "$RB/$svc already exists; refusing to overwrite a saved dir"
    run mv -T "$target" "$RB/$svc"
    log_info "$svc: previous dir saved to .rollback/$TS/$svc"
  fi
  run mv -T "$STAGE/$svc" "$target"
done

# --- 3: ownership, mode, stale pid files --------------------------------------
for svc in "${STAGED[@]}"; do
  run chown -R "$PUID:$PGID" "$APPDATA_ROOT/$svc"
  run chmod 700 "$APPDATA_ROOT/$svc"
  run find "$APPDATA_ROOT/$svc" -name '*.pid' -delete
done

# --- 4: Plex prefs: no auto-empty-trash, no stale transcoder dir --------------
if in_stage plex; then
  P="$APPDATA_ROOT/plex/$PLEX_PREFS_REL"
  P_SRC="$(src_dir plex)/$PLEX_PREFS_REL"
  Pq="$(printf '%q' "$P")"
  if [[ -f "$P_SRC" ]]; then
    if grep -q 'autoEmptyTrash="' "$P_SRC"; then
      run_sh "sed -i 's/autoEmptyTrash=\"[^\"]*\"/autoEmptyTrash=\"0\"/' $Pq"
    else
      run_sh "sed -i '/<Preferences/ s#\\(.*\\)/>#\\1 autoEmptyTrash=\"0\"/>#' $Pq"
    fi
    if [[ $APPLY -eq 1 ]]; then
      grep -q 'autoEmptyTrash="0"' "$P" || die "could not set autoEmptyTrash=\"0\" in $P"
      log_info "plex: autoEmptyTrash=\"0\""
    fi
    if grep -q 'TranscoderTempDirectory="' "$P_SRC"; then
      ttd="$(sed -n 's/.*TranscoderTempDirectory="\([^"]*\)".*/\1/p' "$P_SRC" | head -1)"
      if [[ "$ttd" != /config* && "$ttd" != /transcode* ]]; then
        warn "plex: stale TranscoderTempDirectory=\"$ttd\"; removing it"
        run_sh "sed -i 's/ *TranscoderTempDirectory=\"[^\"]*\"//' $Pq"
      fi
    fi
  else
    log_warn "Preferences.xml missing; set 'Empty trash automatically' off in the Plex UI before any scan"
  fi
fi

# --- 5: SABnzbd offline: new dirs, old queue/history aside --------------------
if in_stage sabnzbd; then
  ini="$APPDATA_ROOT/sabnzbd/sabnzbd.ini"
  if [[ -f "$(src_dir sabnzbd)/sabnzbd.ini" ]]; then
    run_sh "sed -i -e 's#^download_dir *=.*#download_dir = /data/usenet/incomplete#' -e 's#^complete_dir *=.*#complete_dir = /data/usenet/complete#' $(printf '%q' "$ini")"
    if [[ $APPLY -eq 1 ]]; then
      if ! grep -qx 'download_dir = /data/usenet/incomplete' "$ini" \
          || ! grep -qx 'complete_dir = /data/usenet/complete' "$ini"; then
        warn "sabnzbd: download_dir/complete_dir not found in sabnzbd.ini; 25-arr-wire.sh --only sab sets them"
      fi
    fi
  else
    warn "sabnzbd: sabnzbd.ini missing; 25-arr-wire.sh --only sab sets the dirs"
  fi
  if [[ -d "$(src_dir sabnzbd)/admin" ]]; then
    run mv -T "$APPDATA_ROOT/sabnzbd/admin" "$RB/sabnzbd-admin"
    log_info "sabnzbd: old queue/history moved to .rollback/$TS/sabnzbd-admin"
  fi
fi

# --- 6: report non-default UrlBase/Port ---------------------------------------
for svc in sonarr sonarr-anime radarr lidarr prowlarr; do
  in_stage "$svc" || continue
  cfg="$(src_dir "$svc")/config.xml"
  [[ -f "$cfg" ]] || { warn "$svc: config.xml missing"; continue; }
  urlbase="$(sed -n 's:.*<UrlBase>\(.*\)</UrlBase>.*:\1:p' "$cfg" | head -1)"
  port="$(sed -n 's:.*<Port>\([0-9]*\)</Port>.*:\1:p' "$cfg" | head -1)"
  if [[ -n "$urlbase" || ( -n "$port" && "$port" != "${ARR_PORT[$svc]}" ) ]]; then
    warn "$svc UrlBase=$urlbase Port=${port:-default}; runbook Troubleshooting \"UrlBase\""
  fi
done

# --- 7: empty dirs for the fresh services -------------------------------------
for svc in "${FRESH[@]}"; do
  if [[ ! -e "$APPDATA_ROOT/$svc" ]]; then
    run install -d -m 700 -o "$PUID" -g "$PGID" "$APPDATA_ROOT/$svc"
  fi
done

# --- 8: baseline ---------------------------------------------------------------
MIG="$APPDATA_ROOT/.migration"

# count <var> <svc> <db-rel> <sql>: store one number from a restored DB,
# read-only as PUID, in <var>. (Not a $(...) function: its warnings must
# reach the WARNINGS array in this shell.)
count() {
  local var="$1" svc="$2" db="$APPDATA_ROOT/$2/$3" sql="$4" n
  if [[ ! -f "$db" ]]; then
    warn "$svc: $3 not restored; baseline count 0"
    printf -v "$var" '%s' 0
    return 0
  fi
  n="$(as_puid sqlite3 -readonly "$db" "$sql")" || die "baseline query failed: $svc"
  [[ "$n" =~ ^[0-9]+$ ]] || die "baseline query returned a non-numeric result: $svc"
  printf -v "$var" '%s' "$n"
}

if [[ $APPLY -eq 1 ]]; then
  f_sonarr=0 f_anime=0 f_radarr=0 i_sonarr=0 i_anime=0 i_radarr=0
  count f_sonarr sonarr sonarr.db 'select count(*) from EpisodeFiles;'
  count f_anime sonarr-anime sonarr.db 'select count(*) from EpisodeFiles;'
  count f_radarr radarr radarr.db 'select count(*) from MovieFiles;'
  f_lidarr=0
  lidarr_db="$APPDATA_ROOT/lidarr/lidarr.db"
  if [[ -f "$lidarr_db" ]] && as_puid sqlite3 -readonly "$lidarr_db" \
      "select 1 from sqlite_master where type='table' and name='TrackFiles';" | grep -qx 1; then
    count f_lidarr lidarr lidarr.db 'select count(*) from TrackFiles;'
  fi
  count i_sonarr sonarr sonarr.db 'select count(distinct SeriesId) from EpisodeFiles;'
  count i_anime sonarr-anime sonarr.db 'select count(distinct SeriesId) from EpisodeFiles;'
  count i_radarr radarr radarr.db 'select count(*) from Movies where MovieFileId>0;'

  plex_db="$APPDATA_ROOT/plex/$PLEX_DB_REL"
  plex_watched=-1
  if [[ -f "$plex_db" ]] && pw="$(as_puid sqlite3 -readonly "$plex_db" \
      'select count(*) from metadata_item_settings s join metadata_items m on m.guid=s.guid where s.account_id=1 and s.view_count>0 and m.metadata_type in (1,4);' 2>/dev/null)" \
      && [[ "$pw" =~ ^[0-9]+$ ]]; then
    plex_watched="$pw"
  else
    warn "plex: could not read the watched count from the Plex DB; plex_watched=-1 (spot-check watch state in the UI)"
  fi

  install -d -m 700 -o "$PUID" -g "$PGID" "$MIG" "$MIG/baseline-ids"
  (
    umask 077
    for pair in sonarr:"select Id from Episodes where EpisodeFileId>0;" \
                sonarr-anime:"select Id from Episodes where EpisodeFileId>0;" \
                radarr:"select Id from Movies where MovieFileId>0;"; do
      svc="${pair%%:*}" sql="${pair#*:}"
      out="$MIG/baseline-ids/$svc.txt"
      db="$APPDATA_ROOT/$svc/$svc.db"
      [[ "$svc" == sonarr-anime ]] && db="$APPDATA_ROOT/sonarr-anime/sonarr.db"
      if [[ -f "$db" ]]; then
        as_puid sqlite3 -readonly "$db" "$sql" > "$out" || die "baseline ids query failed: $svc"
      else
        : > "$out"
      fi
      chown "$PUID:$PGID" "$out"
    done

    jq -n \
      --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg stage "$TS" \
      --argjson f_sonarr "$f_sonarr" --argjson f_anime "$f_anime" \
      --argjson f_radarr "$f_radarr" --argjson f_lidarr "$f_lidarr" \
      --argjson i_sonarr "$i_sonarr" --argjson i_anime "$i_anime" --argjson i_radarr "$i_radarr" \
      --argjson plex_watched "$plex_watched" \
      '{created: $created, stage: $stage,
        files: {sonarr: $f_sonarr, "sonarr-anime": $f_anime, radarr: $f_radarr, lidarr: $f_lidarr},
        items_with_files: {sonarr: $i_sonarr, "sonarr-anime": $i_anime, radarr: $i_radarr},
        plex_watched: $plex_watched, warnings: $ARGS.positional}' \
      --args "${WARNINGS[@]}" > "$MIG/baseline.json"
    chown "$PUID:$PGID" "$MIG/baseline.json"
  )
  log_info "baseline: $MIG/baseline.json (files sonarr=$f_sonarr sonarr-anime=$f_anime radarr=$f_radarr lidarr=$f_lidarr, plex_watched=$plex_watched)"
else
  printf 'DRY-RUN: write baseline %s (and %s/baseline-ids/*.txt)\n' "$MIG/baseline.json" "$MIG"
fi

# --- 9: remove the (now empty) stage -------------------------------------------
run rmdir "$STAGE"

log_info "restored ${#STAGED[@]} services from $TS; next: docker compose up -d sonarr sonarr-anime radarr lidarr"
