# shellcheck shell=bash
# scripts/lib/arr.sh
#
# API helper for the VM scripts that talk to SABnzbd, the *arr apps,
# Prowlarr, Plex and Seerr: service IP/port/key lookup, curl calls with the
# key kept out of argv, dry-run-aware mutations, a masked-field-aware state
# compare, and command polling.
#
# Sourced only, after common.sh:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/arr.sh"
#
# Apps are reached on their container IP on the `proxy` network (never a
# published port), so this keeps working after Phase 3 removes the ports.
# API keys are read at runtime from $APPDATA_ROOT, validated, and written
# only to curl's stdin (`curl -K -`), so they never show up in `ps`.
#
# Every function returns non-zero on failure (never relying on the caller's
# errexit), so it is safe inside `if`, `||` and `$(...)`.
#
# Call arr_mutate (and helpers that use it) directly, not inside `$(...)`:
# a subshell would lose the count_mutations increment. Redirect stdout to a
# file to capture a response.

if ! declare -F log_info >/dev/null; then
  printf '[ERROR] %s\n' "arr.sh: source scripts/lib/common.sh first" >&2
  return 1
fi

DC=(docker compose --project-directory "$REPO_ROOT")

# Number of mutating calls made (or printed, in dry-run) by arr_mutate.
count_mutations=0

# arr_port <svc>: the app's in-container port.
arr_port() {
  case "$1" in
    sonarr|sonarr-anime|sonarr-4k) printf '8989\n' ;;
    radarr|radarr-4k) printf '7878\n' ;;
    lidarr) printf '8686\n' ;;
    prowlarr) printf '9696\n' ;;
    sabnzbd) printf '8080\n' ;;
    plex) printf '32400\n' ;;
    seerr) printf '5055\n' ;;
    tautulli) printf '8181\n' ;;
    jellyfin) printf '8096\n' ;;
    *) die "arr_port: unknown service '$1'" ;;
  esac
}

# arr_base <svc>: the API prefix of an *arr app or Prowlarr.
arr_base() {
  case "$1" in
    sonarr|sonarr-anime|sonarr-4k|radarr|radarr-4k) printf '/api/v3\n' ;;
    lidarr|prowlarr) printf '/api/v1\n' ;;
    *) die "arr_base: no *arr API for '$1'" ;;
  esac
}

# svc_ip <svc>: the container's IP on the proxy network.
svc_ip() {
  local svc="$1" id ip
  id="$("${DC[@]}" ps -q "$svc")" || die "docker compose ps failed for $svc"
  [[ -n "$id" ]] || die "$svc not running"
  ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "proxy"}}{{.IPAddress}}{{end}}' "$id")" \
    || die "docker inspect failed for $svc"
  [[ -n "$ip" ]] || die "$svc not running"
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "$svc: unexpected proxy IP"
  printf '%s\n' "$ip"
}

# svc_key <svc>: prints the app's API key (or Plex token), read with
# sed/jq (never `source`) and validated. A missing file or a value that
# fails validation dies without ever printing the value.
svc_key() {
  local svc="$1" root="${APPDATA_ROOT:-/opt/appdata}" file key="" re
  case "$svc" in
    sonarr|sonarr-anime|sonarr-4k|radarr|radarr-4k|lidarr|prowlarr)
      file="$root/$svc/config.xml"
      re='^[a-f0-9]{32}$'
      if [[ -r "$file" ]]; then
        key="$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$file" 2>/dev/null | head -n 1)" || key=""
      fi
      ;;
    sabnzbd)
      file="$root/sabnzbd/sabnzbd.ini"
      re='^[a-f0-9]{32}$'
      if [[ -r "$file" ]]; then
        key="$(sed -n 's/^api_key *= *//p' "$file" 2>/dev/null | head -n 1 | tr -d '\r')" || key=""
      fi
      ;;
    seerr)
      file="$root/seerr/settings.json"
      re='^[A-Za-z0-9+/=_-]{16,}$'
      if [[ -r "$file" ]]; then
        key="$(jq -r '.main.apiKey // empty' "$file" 2>/dev/null)" || key=""
      fi
      ;;
    plex)
      file="$root/plex/Library/Application Support/Plex Media Server/Preferences.xml"
      re='^[A-Za-z0-9_-]{16,}$'
      if [[ -r "$file" ]]; then
        key="$(sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$file" 2>/dev/null | head -n 1)" || key=""
      fi
      ;;
    *)
      die "missing/invalid API key for $svc"
      ;;
  esac
  if [[ -z "$key" || ! "$key" =~ $re ]]; then
    die "missing/invalid API key for $svc"
  fi
  printf '%s\n' "$key"
}

# api <svc> <METHOD> <path> [body-file]
#
# Calls the app and prints the response body. The URL, the key header (or
# SABnzbd's apikey= parameter) and the content type go to curl as a config
# on stdin; argv holds only the method, the options and the body file name.
# Non-2xx: prints "<METHOD> <svc> <path> -> HTTP <code>" to stderr and
# returns 1. curl's exit 22 (--fail-with-body on >=400) is captured, not fatal.
api() {
  local svc="$1" method="$2" path="$3" body="${4:-}"
  local ip port key tmp code rc=0 url
  [[ "$method" =~ ^(GET|POST|PUT|DELETE)$ ]] || die "api: invalid method '$method'"
  # The path goes into a quoted curl config line: no quotes, backslashes
  # or whitespace.
  if [[ "$path" != /* || "$path" == *[[:space:]\"\\]* ]]; then
    die "api: invalid path for $svc"
  fi
  if [[ -n "$body" && ! -r "$body" ]]; then
    die "api: body file not readable: $body"
  fi
  ip="$(svc_ip "$svc")" || return 1
  port="$(arr_port "$svc")" || return 1
  key="$(svc_key "$svc")" || return 1
  url="http://$ip:$port$path"
  tmp="$(mktemp)" || return 1

  local args=(-sS --fail-with-body --max-time 30 -X "$method" -K - -o "$tmp" -w '%{http_code}')
  if [[ -n "$body" ]]; then
    args+=(--data-binary "@$body")
  fi

  code="$(
    {
      case "$svc" in
        sabnzbd)
          if [[ "$url" == *\?* ]]; then
            printf 'url = "%s&apikey=%s"\n' "$url" "$key"
          else
            printf 'url = "%s?apikey=%s"\n' "$url" "$key"
          fi
          ;;
        plex)
          printf 'url = "%s"\n' "$url"
          printf 'header = "X-Plex-Token: %s"\n' "$key"
          ;;
        *)
          printf 'url = "%s"\n' "$url"
          printf 'header = "X-Api-Key: %s"\n' "$key"
          ;;
      esac
      printf 'header = "Accept: application/json"\n'
      if [[ -n "$body" ]]; then
        printf 'header = "Content-Type: application/json"\n'
      fi
    } | curl "${args[@]}"
  )" || rc=$?

  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  # rc 22 is the expected --fail-with-body exit for >=400; anything else
  # (e.g. 7, connection refused) is worth showing.
  local why=""
  if [[ $rc -ne 0 && $rc -ne 22 ]]; then
    why=" (curl exit $rc)"
  fi
  printf '%s %s %s -> HTTP %s%s\n' "$method" "$svc" "$path" "${code:-000}" "$why" >&2
  return 1
}

# sab_path <mode> [k=v ...]: prints the SABnzbd API path
# /api?mode=<mode>&output=json&k=<v, URL-encoded>... (without the key,
# which api adds). Used with sab_api (reads) and arr_mutate (changes).
sab_path() {
  local mode="$1" kv k v enc p
  shift
  if [[ ! "$mode" =~ ^[a-z_]+$ ]]; then
    log_error "sab_path: invalid mode '$mode'"
    return 1
  fi
  p="/api?mode=$mode&output=json"
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    if [[ "$kv" != *=* || ! "$k" =~ ^[a-z_]+$ ]]; then
      log_error "sab_path: invalid parameter '$k'"
      return 1
    fi
    enc="$(jq -rn --arg v "$v" '$v | @uri')" || return 1
    p+="&$k=$enc"
  done
  printf '%s\n' "$p"
}

# sab_api <mode> [k=v ...]: read-only SABnzbd calls (get_config, version,
# queue, history listing). Changes go through
# `arr_mutate sabnzbd GET "$(sab_path ...)"` so they are dry-run by default.
sab_api() {
  local p
  p="$(sab_path "$@")" || return 1
  api sabnzbd GET "$p"
}

# wait_cmd <svc> <command-json-response>: polls GET {base}/command/<id>
# every WAIT_INTERVAL seconds (default 3) until the status is completed
# (return 0), failed/aborted (die), or WAIT_TIMEOUT seconds (default 600)
# have passed (die).
wait_cmd() {
  local svc="$1" resp="$2" id base out status start
  local interval="${WAIT_INTERVAL:-3}" timeout="${WAIT_TIMEOUT:-600}"
  id="$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)" || id=""
  [[ "$id" =~ ^[0-9]+$ ]] || die "$svc: command response has no id"
  base="$(arr_base "$svc")" || return 1
  start=$SECONDS
  while :; do
    out="$(api "$svc" GET "$base/command/$id")" || return 1
    status="$(jq -r '.status // empty' <<<"$out" 2>/dev/null)" || status=""
    case "$status" in
      completed) return 0 ;;
      failed|aborted) die "$svc: command $id $status" ;;
    esac
    if (( SECONDS - start >= timeout )); then
      die "$svc: command $id still '${status:-unknown}' after ${timeout}s"
    fi
    sleep "$interval"
  done
}

# arr_redact: jq filter (stdin -> compact JSON) that replaces the values of
# apiKey, password and any *Key/*key property, and of fields[] entries whose
# name matches or whose privacy is apiKey/password, with "***".
arr_redact() {
  jq -c '
    def secret: test("^(apiKey|password)$|[Kk]ey$");
    walk(
      if type == "object" then
        with_entries(
          if (.key | secret) and ((.value | type) != "object") and ((.value | type) != "array")
          then .value = "***" else . end)
        | if has("value") and (((.name | type) == "string" and (.name | secret))
                               or ((.privacy // "") | IN("apiKey", "password")))
          then .value = "***" else . end
      else . end)'
}

# arr_mutate <svc> <METHOD> <path> [body-file]
#
# Dry-run (APPLY=0): prints "DRY-RUN: <METHOD> <svc> <path> <redacted
# compact body>". --apply: calls api and prints the response. Either way
# count_mutations is incremented (call it directly, not in `$(...)`).
arr_mutate() {
  local svc="$1" method="$2" path="$3" body="${4:-}" shown=""
  count_mutations=$((count_mutations + 1))
  if [[ "${APPLY:-0}" -eq 1 ]]; then
    api "$svc" "$method" "$path" "$body"
    return
  fi
  if [[ -n "$body" ]]; then
    shown="$(arr_redact <"$body")" || die "arr_mutate: body for $method $svc $path is not JSON"
  fi
  printf 'DRY-RUN: %s %s %s%s\n' "$method" "$svc" "$path" "${shown:+ $shown}"
}

# arr_change <svc> <METHOD> <path> [body-file]: arr_mutate for a change
# whose response is not needed. Dry-run prints the DRY-RUN line; --apply
# discards the response and logs "[INFO] <METHOD> <svc> <path>".
arr_change() {
  if [[ "${APPLY:-0}" -eq 1 ]]; then
    arr_mutate "$@" >/dev/null || return 1
    log_info "$2 $1 $3"
  else
    arr_mutate "$@"
  fi
}

# arr_command <svc> <body-file>: POST {base}/command through arr_mutate;
# with --apply, waits for it with wait_cmd, otherwise prints the DRY-RUN line.
arr_command() {
  local svc="$1" body="$2" base out rc=0
  base="$(arr_base "$svc")" || return 1
  out="$(mktemp)" || return 1
  arr_mutate "$svc" POST "$base/command" "$body" >"$out" || rc=$?
  if [[ $rc -eq 0 ]]; then
    if [[ "${APPLY:-0}" -eq 1 ]]; then
      log_info "POST $svc $base/command $(jq -c '{name}' "$body" 2>/dev/null || true); waiting"
      wait_cmd "$svc" "$(cat "$out")" || rc=$?
    else
      cat "$out"
    fi
  fi
  rm -f "$out"
  return "$rc"
}

# same_state <desired-file> <current-file>
#
# Returns 0 if the two provider resources (download client, application)
# match on the keys that matter: the top-level enable, implementation, name
# and syncLevel, and the field values of host, port, useSsl, baseUrl,
# prowlarrUrl, the category fields, syncCategories and animeSyncCategories.
# A field that either side masks as "********", or whose privacy is not
# "normal", is ignored, so a second --apply makes 0 mutations on real apps.
same_state() {
  jq -e -n --slurpfile d "$1" --slurpfile c "$2" '
    def compared: ["host", "port", "useSsl", "baseUrl", "prowlarrUrl",
                   "tvCategory", "movieCategory", "musicCategory",
                   "syncCategories", "animeSyncCategories"];
    def hidden: [(.fields // [])[]
                 | select(.value == "********" or ((.privacy // "normal") != "normal"))
                 | .name];
    def norm($skip): {enable, implementation, name, syncLevel,
      fields: ([(.fields // [])[]
                | select(.name as $n | (compared | any(. == $n)) and ($skip | all(. != $n)))
                | {name, value: (.value | if type == "array" then sort else . end)}]
               | sort_by(.name))};
    (($d[0] | hidden) + ($c[0] | hidden)) as $skip
    | ($d[0] | norm($skip)) == ($c[0] | norm($skip))' >/dev/null
}

# running_services: the compose services currently running, one per line.
running_services() {
  "${DC[@]}" ps --status running --services
}

# require_healthy <svc...>: dies unless each service is running with
# health "healthy" (docker compose ps --format json; array or NDJSON).
require_healthy() {
  local json svc state
  json="$("${DC[@]}" ps --format json)" || die "docker compose ps failed"
  for svc in "$@"; do
    state="$(jq -rs --arg s "$svc" '
      [.[] | if type == "array" then .[] else . end
       | select(.Service == $s) | "\(.State)/\(.Health // "")"][0] // "absent"' <<<"$json")" \
      || die "cannot parse docker compose ps output"
    if [[ "$state" != "running/healthy" ]]; then
      die "$svc is not running and healthy ($state): docker compose up -d $svc"
    fi
  done
}

# ensure_root_folder <svc> <path> <rootfolder-list-file>: adds <path> as a
# root folder unless the list (a GET {base}/rootfolder response) already has
# it (trailing / ignored). Lidarr also needs the lowest quality and
# metadata profile ids.
ensure_root_folder() {
  local svc="$1" path="$2" list="$3" base body qp mp out rc=0
  if jq -e --arg p "$path" 'any(.[]? | objects; ((.path // "") | sub("/+$"; "")) == $p)' \
       "$list" >/dev/null 2>&1; then
    return 0
  fi
  base="$(arr_base "$svc")" || return 1
  body="$(mktemp)" || return 1
  if [[ "$svc" == lidarr ]]; then
    out="$(api "$svc" GET "$base/qualityprofile")" || { rm -f "$body"; return 1; }
    qp="$(jq -r '[.[]? | objects | .id | numbers] | min // empty' <<<"$out")" || qp=""
    out="$(api "$svc" GET "$base/metadataprofile")" || { rm -f "$body"; return 1; }
    mp="$(jq -r '[.[]? | objects | .id | numbers] | min // empty' <<<"$out")" || mp=""
    if [[ ! "$qp" =~ ^[0-9]+$ || ! "$mp" =~ ^[0-9]+$ ]]; then
      rm -f "$body"
      die "$svc: no quality/metadata profile to add root folder $path"
    fi
    jq -n --arg p "$path" --argjson q "$qp" --argjson m "$mp" \
      '{name: "Music", path: $p, defaultQualityProfileId: $q, defaultMetadataProfileId: $m}' >"$body"
  else
    jq -n --arg p "$path" '{path: $p}' >"$body"
  fi
  arr_change "$svc" POST "$base/rootfolder" "$body" || rc=$?
  rm -f "$body"
  return "$rc"
}
