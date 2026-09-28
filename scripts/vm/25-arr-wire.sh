#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/arr.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/arr.sh"

# .env first, then defaults, so .env values are not masked by the defaults.
load_env
APPDATA_ROOT="${APPDATA_ROOT:-/opt/appdata}"
LAN_IP="${LAN_IP:-}"

# Services that must be running and healthy for a full run (R2.1).
CORE=(sabnzbd prowlarr sonarr sonarr-anime sonarr-4k radarr radarr-4k lidarr plex seerr tautulli)
ARRS=(sonarr sonarr-anime sonarr-4k radarr radarr-4k lidarr)

# Per-*arr desired state: root folders, SAB category field and category.
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

# SABnzbd categories (each dir = its name) and old ones to delete.
SAB_CATS=(tv tv-4k movies movies-4k music anime)
SAB_OLD_CATS=(series anime-series software)
SAB_DOWNLOAD_DIR=/data/usenet/incomplete
SAB_COMPLETE_DIR=/data/usenet/complete

# Prowlarr applications: name|service|implementation. baseUrl is
# http://<service>:<port>; Sonarr Anime syncs anime categories only.
APPS=(
  "Sonarr|sonarr|Sonarr"
  "Sonarr Anime|sonarr-anime|Sonarr"
  "Sonarr 4K|sonarr-4k|Sonarr"
  "Radarr|radarr|Radarr"
  "Radarr 4K|radarr-4k|Radarr"
  "Lidarr|lidarr|Lidarr"
)
PROWLARR_URL=http://prowlarr:9696
# Old apps whose host marks them for deletion (never matched by name).
STALE_APP_HOSTS='["animesonarr","nzbget","qbittorrent"]'

usage() {
  cat <<EOF
Wire SABnzbd, the six *arr instances and Prowlarr for Usenet only, with
the TRaSH categories, and sync Prowlarr to all six apps. Idempotent: a
second --apply makes no changes and prints "no changes" (masked ********
fields in the apps' responses are ignored).

SAB part (first, and the only part with --only sab):
  download_dir=$SAB_DOWNLOAD_DIR, complete_dir=$SAB_COMPLETE_DIR;
  host_whitelist += sabnzbd,<hostname -s>,\$LAN_IP (merged, deduplicated);
  categories ${SAB_CATS[*]} (dir = name); delete ${SAB_OLD_CATS[*]};
  purge queue/history jobs older than .migration/baseline.json "created";
  --only sab: pause the queue, so nothing downloads before the wiring.
Each *arr (${ARRS[*]}):
  add missing root folders; delete non-SABnzbd download clients; upsert the
  "SABnzbd" client (host sabnzbd, port 8080, its category); delete torrent
  indexers and all remote path mappings.
Prowlarr:
  delete torrent indexers, indexer proxies and non-SABnzbd clients; upsert
  its SABnzbd client (empty category); upsert the 6 apps (fullSync;
  matched by baseUrl host, then name) and delete the rest (e.g.
  animesonarr); then, only if this run changed anything,
  ApplicationIndexerSync. Finally resume the SAB queue if
  it is paused.

Preconditions: --only sab needs sabnzbd running; a full run needs
${CORE[*]} running and healthy.

Dry-run by default: reads the apps and prints each change as
"DRY-RUN: <METHOD> <svc> <path> <body>" (secrets shown as ***). Pass
--apply to make the changes. Run as the media user (docker group).

Usage: 25-arr-wire.sh [--only sab] [--apply] [--help]

Options:
  --only sab   Only the SAB part (runbook step 7, before the *arr apps and
               Prowlarr run together with SAB).

Environment variables (defaults; normally from .env):
  APPDATA_ROOT=$APPDATA_ROOT   (API keys are read from here at runtime)
  LAN_IP=${LAN_IP:-<unset>}
EOF
}

# --- arguments: --only locally, the rest by parse_common_args ------------------
ONLY=""
rest=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      ONLY="$2"
      shift 2
      ;;
    *)
      rest+=("$1")
      shift
      ;;
  esac
done
parse_common_args "${rest[@]}"
if [[ -n "$ONLY" && "$ONLY" != sab ]]; then
  usage >&2
  exit 2
fi

# --- validation ------------------------------------------------------------------
require_safe_path APPDATA_ROOT "$APPDATA_ROOT"
require_match LAN_IP "$LAN_IP" '^([0-9]{1,3}\.){3}[0-9]{1,3}$' "the VM's LAN IPv4 address, set in .env"
if [[ "$LAN_IP" == 0.0.0.0 || "$LAN_IP" == 255.255.255.255 ]]; then
  die "invalid LAN_IP '$LAN_IP': LAN_IP must be the VM's own LAN address"
fi
require_cmd docker curl jq hostname
HOST_S="$(hostname -s)"
require_match hostname "$HOST_S" '^[A-Za-z0-9][A-Za-z0-9-]*$' "a short host name"

# --- preconditions ---------------------------------------------------------------
if [[ "$ONLY" == sab ]]; then
  running="$(running_services)" || die "docker compose ps failed"
  grep -qx sabnzbd <<<"$running" || die "sabnzbd is not running: docker compose up -d sabnzbd"
else
  require_healthy "${CORE[@]}"
fi

umask 077
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# ids <file> <jq-filter>: the ids the filter selects from a list response,
# one per line. Callers validate them (in the main shell, so die works).
ids() {
  jq -r "[.[]? | objects | $2 | .id] | .[] | tostring" "$1"
}

# delete_ids <svc> <path-prefix> <file> <jq-filter>
delete_ids() {
  local svc="$1" prefix="$2" id list=()
  mapfile -t list < <(ids "$3" "$4")
  for id in "${list[@]}"; do
    [[ "$id" =~ ^[0-9]+$ ]] || die "$svc: unexpected id '$id' under $prefix"
    arr_change "$svc" DELETE "$prefix/$id"
  done
}

# sab_change <mode> [k=v ...]: a SAB change, dry-run by default and counted.
sab_change() {
  local p
  p="$(sab_path "$@")"
  arr_change sabnzbd GET "$p"
}

# ==============================================================================
# SABnzbd
# ==============================================================================
sab_part() {
  local cfg="$W/sab-config.json" k v cur c merged current cut baseline
  sab_api get_config >"$cfg"

  # 1. Download dirs.
  for k in download_dir complete_dir; do
    if [[ "$k" == download_dir ]]; then v="$SAB_DOWNLOAD_DIR"; else v="$SAB_COMPLETE_DIR"; fi
    cur="$(jq -r --arg k "$k" '.config.misc[$k] // "" | tostring' "$cfg")"
    if [[ "$cur" != "$v" ]]; then
      sab_change set_config section=misc keyword="$k" value="$v"
    fi
  done

  # 2. host_whitelist: current entries, then sabnzbd,<host>,<LAN_IP>;
  #    trimmed, deduplicated, order kept.
  # Two lines out: the current list, normalized, then the merged list.
  { IFS= read -r current; IFS= read -r merged; } < <(jq -r --arg add "sabnzbd,$HOST_S,$LAN_IP" '
    def entries: (if type == "array" then join(",") else tostring end)
                 | split(",") | map(sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(length > 0));
    (.config.misc.host_whitelist // "" | entries) as $cur
    | ($cur | join(",")),
      (reduce ($cur + ($add | entries))[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)
       | join(","))' "$cfg")
  [[ -n "$merged" ]] || die "sabnzbd: cannot read host_whitelist from get_config"
  if [[ "$current" != "$merged" ]]; then
    sab_change set_config section=misc keyword=host_whitelist value="$merged"
  fi

  # 3. Categories: create, or fix the dir.
  for c in "${SAB_CATS[@]}"; do
    cur="$(jq -r --arg c "$c" \
      '[.config.categories[]? | objects | select(.name == $c) | (.dir // "" | tostring)][0] // "(missing)"' "$cfg")"
    if [[ "$cur" != "$c" ]]; then
      sab_change set_config section=categories keyword="$c" dir="$c"
    fi
  done

  # 4. Old categories.
  for c in "${SAB_OLD_CATS[@]}"; do
    if jq -e --arg c "$c" 'any(.config.categories[]? | objects; .name == $c)' "$cfg" >/dev/null; then
      sab_change del_config section=categories keyword="$c"
    fi
  done

  # 5. Jobs from before the baseline point at files that are gone.
  sab_api queue >"$W/sab-queue.json"
  baseline="$APPDATA_ROOT/.migration/baseline.json"
  if [[ -r "$baseline" ]]; then
    cut="$(jq -r '.created | fromdateiso8601' "$baseline" 2>/dev/null)" || cut=""
    [[ "$cut" =~ ^[0-9]+$ ]] || die "cannot read .created from $baseline"
    if jq -e --argjson cut "$cut" \
         'any(.queue.slots[]? | objects; (.time_added | tonumber?) < $cut)' "$W/sab-queue.json" >/dev/null; then
      sab_change queue name=purge del_files=1
    fi
    sab_api history >"$W/sab-history.json"
    if jq -e --argjson cut "$cut" \
         'any(.history.slots[]? | objects; (.completed | tonumber?) < $cut)' "$W/sab-history.json" >/dev/null; then
      sab_change history name=delete value=all del_files=1
    fi
  else
    log_info "no $baseline; skipping the pre-baseline queue/history purge"
  fi

  # 6. --only sab: hold downloads until the *arr apps and Prowlarr are wired.
  if [[ "$ONLY" == sab ]] && ! jq -e '.queue.paused == true' "$W/sab-queue.json" >/dev/null; then
    sab_change pause
  fi
}

# ==============================================================================
# Download client upsert (*arr and Prowlarr)
# ==============================================================================
# upsert_sab_client <svc> <downloadclient-list-file> [<category-field> <category>]
upsert_sab_client() {
  local svc="$1" dclist="$2" cf="${3:-}" cat="${4:-}" base schema="$W/$1-dc-schema.json"
  local desired="$W/$1-dc-desired.json" cur="$W/$1-dc-current.json" id extra
  base="$(arr_base "$svc")"
  api "$svc" GET "$base/downloadclient/schema" >"$schema"
  jq '[.[]? | objects | select(.implementation == "Sabnzbd")][0] // empty' "$schema" >"$W/$svc-dc-sab.json"
  [[ -s "$W/$svc-dc-sab.json" ]] || die "$svc: no Sabnzbd entry in downloadclient/schema"
  jq -e --arg need "host,port,useSsl,apiKey${cf:+,$cf}" \
    '($need | split(",")) - [.fields[]?.name] | length == 0' "$W/$svc-dc-sab.json" >/dev/null \
    || die "$svc: Sabnzbd schema lacks one of host, port, useSsl, apiKey${cf:+, $cf}"

  # The SAB key goes to jq on stdin, never in argv.
  printf '%s' "$SAB_KEY" | jq --rawfile key /dev/stdin --arg cf "$cf" --arg cat "$cat" '
    del(.presets) | .name = "SABnzbd" | .enable = true
    | .removeCompletedDownloads = true | .removeFailedDownloads = true
    | .fields |= map(
        if .name == "host" then .value = "sabnzbd"
        elif .name == "port" then .value = 8080
        elif .name == "useSsl" then .value = false
        elif .name == "apiKey" then .value = $key
        elif $cf != "" and .name == $cf then .value = $cat
        else . end)' "$W/$svc-dc-sab.json" >"$desired"

  # The existing client: by name, else the first Sabnzbd one.
  jq '([.[]? | objects | select(.name == "SABnzbd")][0]
       // [.[]? | objects | select(.implementation == "Sabnzbd")][0]) // empty' "$dclist" >"$cur"
  if [[ -s "$cur" ]]; then
    id="$(jq -r '.id' "$cur")"
    [[ "$id" =~ ^[0-9]+$ ]] || die "$svc: unexpected download client id"
    extra="$(jq -r --argjson id "$id" \
      '[.[]? | objects | select(.implementation == "Sabnzbd" and .id != $id) | .name] | join(", ")' "$dclist")"
    [[ -z "$extra" ]] || log_warn "$svc: extra SABnzbd clients left in place: $extra"
    if ! same_state "$desired" "$cur"; then
      jq --argjson id "$id" '.id = $id' "$desired" >"$desired.put"
      arr_change "$svc" PUT "$base/downloadclient/$id" "$desired.put"
    fi
  else
    arr_change "$svc" POST "$base/downloadclient" "$desired"
  fi
}

# ==============================================================================
# *arr instances
# ==============================================================================
wire_arr() {
  local svc="$1" base root
  base="$(arr_base "$svc")"

  api "$svc" GET "$base/rootfolder" >"$W/$svc-rf.json"
  for root in ${ROOTS[$svc]}; do
    ensure_root_folder "$svc" "$root" "$W/$svc-rf.json"
  done

  api "$svc" GET "$base/downloadclient" >"$W/$svc-dc.json"
  delete_ids "$svc" "$base/downloadclient" "$W/$svc-dc.json" 'select(.implementation != "Sabnzbd")'
  upsert_sab_client "$svc" "$W/$svc-dc.json" "${CAT_FIELD[$svc]}" "${CATEGORY[$svc]}"

  api "$svc" GET "$base/indexer" >"$W/$svc-ix.json"
  delete_ids "$svc" "$base/indexer" "$W/$svc-ix.json" 'select(.protocol == "torrent")'

  api "$svc" GET "$base/remotepathmapping" >"$W/$svc-rpm.json"
  delete_ids "$svc" "$base/remotepathmapping" "$W/$svc-rpm.json" '.'
}

# ==============================================================================
# Prowlarr
# ==============================================================================
wire_prowlarr() {
  local p=prowlarr base row name svc impl url id key taken="[]"
  local apps="$W/apps.json" schema="$W/apps-schema.json" desired cur
  base="$(arr_base "$p")"

  api "$p" GET "$base/indexer" >"$W/p-ix.json"
  delete_ids "$p" "$base/indexer" "$W/p-ix.json" 'select(.protocol == "torrent")'
  api "$p" GET "$base/indexerproxy" >"$W/p-proxy.json"
  delete_ids "$p" "$base/indexerproxy" "$W/p-proxy.json" '.'

  api "$p" GET "$base/downloadclient" >"$W/p-dc.json"
  delete_ids "$p" "$base/downloadclient" "$W/p-dc.json" 'select(.implementation != "Sabnzbd")'
  # Prowlarr's client gets no category: the schema default "prowlarr" is
  # not a SAB category, and the save-time category test would reject it.
  upsert_sab_client "$p" "$W/p-dc.json" category ""

  api "$p" GET "$base/applications" >"$apps"
  api "$p" GET "$base/applications/schema" >"$schema"
  for row in "${APPS[@]}"; do
    IFS='|' read -r name svc impl <<<"$row"
    url="http://$svc:$(arr_port "$svc")"
    desired="$W/app-$svc-desired.json"
    cur="$W/app-$svc-current.json"

    jq --arg i "$impl" '[.[]? | objects | select(.implementation == $i)][0] // empty' "$schema" >"$desired.schema"
    [[ -s "$desired.schema" ]] || die "prowlarr: no $impl entry in applications/schema"
    jq -e --arg need "prowlarrUrl,baseUrl,apiKey,syncCategories$([[ $svc == sonarr-anime ]] && printf ',animeSyncCategories')" \
      '($need | split(",")) - [.fields[]?.name] | length == 0' "$desired.schema" >/dev/null \
      || die "prowlarr: $impl application schema lacks a required field"

    # The app's key goes to jq on stdin, never in argv.
    key="$(svc_key "$svc")"
    printf '%s' "$key" | jq --rawfile key /dev/stdin --arg name "$name" --arg url "$url" \
      --arg purl "$PROWLARR_URL" --argjson anime "$([[ $svc == sonarr-anime ]] && echo true || echo false)" '
      del(.presets) | .name = $name | .syncLevel = "fullSync"
      | .fields |= map(
          if .name == "prowlarrUrl" then .value = $purl
          elif .name == "baseUrl" then .value = $url
          elif .name == "apiKey" then .value = $key
          elif $anime and .name == "syncCategories" then .value = []
          elif $anime and .name == "animeSyncCategories" then .value = [5070]
          else . end)' "$desired.schema" >"$desired"
    key=""

    # Match an existing app by the host in its baseUrl, then by name
    # (never an app whose host marks it stale).
    id="$(jq -r --arg h "$svc" --arg n "$name" --argjson taken "$taken" --argjson stale "$STALE_APP_HOSTS" '
      def host: ([.fields[]? | select(.name == "baseUrl") | .value | strings
                  | capture("^[A-Za-z][A-Za-z0-9+.-]*://(?<h>[^:/?#]+)") | .h][0] // "") | ascii_downcase;
      [.[]? | objects | select(.id as $i | $taken | all(. != $i))] as $free
      | ([$free[] | select(host == $h)][0]
         // [$free[] | select(.name == $n and (host as $x | $stale | all(. != $x)))][0])
      | .id // empty' "$apps")"
    if [[ -n "$id" ]]; then
      [[ "$id" =~ ^[0-9]+$ ]] || die "prowlarr: unexpected application id"
      taken="$(jq -c --argjson id "$id" '. + [$id]' <<<"$taken")"
      jq --argjson id "$id" '.[] | select(.id == $id)' "$apps" >"$cur"
      if ! same_state "$desired" "$cur"; then
        jq --argjson id "$id" '.id = $id' "$desired" >"$desired.put"
        arr_change "$p" PUT "$base/applications/$id" "$desired.put"
      fi
    else
      arr_change "$p" POST "$base/applications" "$desired"
    fi
  done

  # Everything not matched above (old animesonarr, nzbget, qbittorrent, ...).
  local leftover=()
  mapfile -t leftover < <(ids "$apps" "select(.id as \$i | $taken | all(. != \$i))")
  for id in "${leftover[@]}"; do
    log_info "prowlarr: removing app $(jq -r --argjson id "$id" '.[] | select(.id == $id) | .name // "?"' "$apps")"
    arr_change "$p" DELETE "$base/applications/$id"
  done

  # Sync only after a change, so a converged run makes 0 mutating calls.
  if [[ $count_mutations -gt 0 ]]; then
    jq -n '{name: "ApplicationIndexerSync", forceSync: true}' >"$W/sync.json"
    arr_command "$p" "$W/sync.json"
  fi
}

# ==============================================================================
# Main
# ==============================================================================
SAB_KEY="$(svc_key sabnzbd)"

sab_part

if [[ "$ONLY" != sab ]]; then
  for svc in "${ARRS[@]}"; do
    wire_arr "$svc"
  done
  wire_prowlarr

  # Resume the queue left paused by --only sab, as the very last step.
  sab_api queue >"$W/sab-queue-end.json"
  if jq -e '.queue.paused == true' "$W/sab-queue-end.json" >/dev/null; then
    sab_change resume
  fi
fi

if [[ $count_mutations -eq 0 ]]; then
  log_info "no changes"
elif [[ $APPLY -eq 0 ]]; then
  log_info "$count_mutations changes (dry-run; pass --apply to make them)"
else
  log_info "$count_mutations changes"
fi
if [[ "$ONLY" == sab ]]; then
  log_info "next: docker compose up -d && scripts/vm/25-arr-wire.sh"
fi
