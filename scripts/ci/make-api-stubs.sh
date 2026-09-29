#!/usr/bin/env bash
# shellcheck disable=SC2016
# (SC2016: the quoted stub bodies below are written verbatim into generated
# scripts on disk, where their $-expressions expand at stub runtime, not here.)
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<'EOF'
Create stub docker, curl and ssh executables so the scripts that use
scripts/lib/arr.sh can run against synthetic API fixtures, with no Docker
daemon and no real apps.

Usage: make-api-stubs.sh <dir> [--help]

Creates <dir> and writes executable stubs into it. Every stub appends its
argv to <dir>/calls.log (arr.sh never puts a key in argv, so this log is
key-free too). Prepend <dir> to PATH before running a script.

Services and addresses: container id "id-<svc>", proxy IP 172.30.0.<n>:
  sabnzbd 10, prowlarr 11, sonarr 12, sonarr-anime 13, sonarr-4k 14,
  radarr 15, radarr-4k 16, lidarr 17, plex 18, seerr 19, tautulli 20,
  jellyfin 21.

docker:
  inspect [-f <fmt>] id-<svc>   prints the IP (or, if <fmt> mentions Health,
                                the service's health; State.Status/Running
                                prints its running state).
  compose [globals] ps -q [<svc>...]          id-<svc> per running service
  compose [globals] ps [--status running] --services
                                              $STUB_RUNNING, one per line
  compose [globals] ps --format json          one JSON object per running
                                              service: ID, Name, Service,
                                              State=running, Health
  compose [globals] config --images           $STUB_IMAGES (newline-separated)
  compose [globals] exec [opts] <svc> <cmd>   exit 1 unless <svc> is running;
                                              else prints STUB_EXEC_OUT_<svc_>
                                              (or STUB_EXEC_OUT) and exits with
                                              STUB_EXEC_RC_<svc_> (or STUB_EXEC_RC, 0)
  anything else                               exit 0
  Every compose call also appends "COMPOSE_FILE=<its value>" to
  <dir>/compose-env.log.

curl: reads url/header/request lines from a -K config (stdin with -K -),
plus -X, -H, --data-binary @f, -o, -w and a positional URL. Maps the IP (or
a service hostname) back to the service; a wrong port gives HTTP 000 and
exit 7. Strips apikey= and X-Plex-Token= from the query, then:
  - appends "METHOD svc path" to $STUB_LOG, plus " body=<compact JSON>" for
    non-GET requests with a body (the log records what the server received);
  - responds from $STUB_FIXTURES/<svc>/<name>.json, where <name> is
    "<METHOD>_<path+query>" with / ? & = . replaced by _, runs of _
    collapsed and a trailing _ removed (GET /api/v3/rootfolder ->
    GET_api_v3_rootfolder.json);
  - sequences: if <name>.json.1, .2, ... exist, call k (0-based) returns
    <name>.json.k (or the highest existing one below it; call 0 returns
    <name>.json), counted per svc and name under $STUB_STATE;
  - a missing fixture returns {} for GET and an empty body for other
    methods, with HTTP 200;
  - the status code is 200, or the content of <name>.http if present, or
    $STUB_HTTP_<svc with - as _> (e.g. STUB_HTTP_sonarr_anime=500), which
    wins over everything;
  - STUB_EXPECT_KEY=<key>: a request whose X-Api-Key / X-Plex-Token header
    or apikey= parameter differs gets HTTP 401;
  - a POST/PUT to prowlarr /api/v1/downloadclient[/<id>] whose body has a
    "category" field with an empty value, and no forceSave=true in the
    query, gets HTTP 400 with a validation-error body (Prowlarr's
    Category NotEmpty warning, which Create/Update reject);
  - writes the body to -o (or stdout), prints -w with %{http_code}
    substituted, and, like real curl --fail-with-body / -f, exits 22 when
    the code is >= 400.

ssh: STUB_SSH_RC=<n> makes it exit <n>; otherwise it runs its last argument
locally with bash -c (stdin passed through).

Defaults: STUB_LOG=<dir>/api.log, STUB_STATE=<dir>/state, STUB_RUNNING
empty, STUB_HEALTH entries "svc=<health>" (default healthy), STUB_FIXTURES
unset (every GET returns {}).
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

DIR="${1:-}"
if [[ -z "$DIR" || $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"

# write_stub <name>: the stub body comes from stdin; a header bakes in the
# stub dir and the argv log line.
write_stub() {
  local name="$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf '_STUB_HOME=%q\n' "$DIR"
    printf 'printf "%%s %%s\\n" %q "$*" >> "$_STUB_HOME/calls.log"\n' "$name"
    cat
  } > "$DIR/$name"
  chmod +x "$DIR/$name"
}

write_stub docker <<'EOF'
SVCS=(sabnzbd prowlarr sonarr sonarr-anime sonarr-4k radarr radarr-4k lidarr plex seerr tautulli jellyfin)

svc_n() {
  local i
  for i in "${!SVCS[@]}"; do
    if [[ "${SVCS[$i]}" == "$1" ]]; then
      printf '%s\n' "$((10 + i))"
      return 0
    fi
  done
  return 1
}
is_running() {
  local s
  for s in ${STUB_RUNNING:-}; do
    [[ "$s" == "$1" ]] && return 0
  done
  return 1
}
health_of() {
  local kv
  for kv in ${STUB_HEALTH:-}; do
    if [[ "${kv%%=*}" == "$1" ]]; then
      printf '%s\n' "${kv#*=}"
      return 0
    fi
  done
  printf 'healthy\n'
}
# env_for <prefix> <svc>: value of <prefix>_<svc with - as _>, else <prefix>.
env_for() {
  local var="$1_${2//-/_}"
  if [[ -n "${!var+x}" ]]; then
    printf '%s' "${!var}"
  else
    var="$1"
    printf '%s' "${!var:-}"
  fi
}

case "${1:-}" in
  inspect)
    shift
    fmt=""
    ids=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f|--format) fmt="$2"; shift 2 ;;
        --type) shift 2 ;;
        -*) shift ;;
        *) ids+=("$1"); shift ;;
      esac
    done
    rc=0
    for id in "${ids[@]}"; do
      svc="${id#id-}"
      if [[ "$id" != id-* ]] || ! n="$(svc_n "$svc")"; then
        printf 'Error: No such object: %s\n' "$id" >&2
        rc=1
        continue
      fi
      case "$fmt" in
        *Health*) health_of "$svc" ;;
        *State.Running*) if is_running "$svc"; then echo true; else echo false; fi ;;
        *State.Status*) if is_running "$svc"; then echo running; else echo exited; fi ;;
        "") printf '[{"Id":"%s","Name":"/%s","State":{"Status":"running"},"NetworkSettings":{"Networks":{"proxy":{"IPAddress":"172.30.0.%s"}}}}]\n' "$id" "$svc" "$n" ;;
        *) printf '172.30.0.%s\n' "$n" ;;
      esac
    done
    exit "$rc"
    ;;
  compose)
    shift
    # The COMPOSE_FILE each compose call saw (checks that it is absolute).
    printf 'COMPOSE_FILE=%s\n' "${COMPOSE_FILE-}" >> "$_STUB_HOME/compose-env.log"
    # Global options before the subcommand.
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --project-directory|-f|--file|-p|--project-name|--profile|--env-file|--ansi|--progress|--parallel)
          shift 2 ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    sub="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "$sub" in
      ps)
        quiet=0 services=0 fmt="" status="running" want=()
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -q|--quiet) quiet=1 ;;
            --services) services=1 ;;
            --format) fmt="$2"; shift ;;
            --format=*) fmt="${1#*=}" ;;
            --status) status="$2"; shift ;;
            --status=*) status="${1#*=}" ;;
            -*) ;;
            *) want+=("$1") ;;
          esac
          shift
        done
        # Only running services exist in the stub.
        [[ "$status" == running ]] || exit 0
        for s in ${STUB_RUNNING:-}; do
          if [[ ${#want[@]} -gt 0 && " ${want[*]} " != *" $s "* ]]; then
            continue
          fi
          if [[ $quiet -eq 1 ]]; then
            printf 'id-%s\n' "$s"
          elif [[ $services -eq 1 ]]; then
            printf '%s\n' "$s"
          elif [[ "$fmt" == json ]]; then
            printf '{"ID":"id-%s","Name":"media-%s-1","Service":"%s","State":"running","Health":"%s","Status":"Up"}\n' \
              "$s" "$s" "$s" "$(health_of "$s")"
          else
            printf 'media-%s-1 %s running %s\n' "$s" "$s" "$(health_of "$s")"
          fi
        done
        exit 0
        ;;
      config)
        if [[ " $* " == *" --images "* ]]; then
          if [[ -n "${STUB_IMAGES:-}" ]]; then
            printf '%s\n' "$STUB_IMAGES"
          fi
        elif [[ " $* " == *" --services "* ]]; then
          printf '%s\n' "${SVCS[@]}"
        fi
        exit 0
        ;;
      exec)
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -u|--user|-e|--env|-w|--workdir|--index) shift 2 ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        svc="${1:-}"
        if ! is_running "$svc"; then
          printf 'service "%s" is not running\n' "$svc" >&2
          exit 1
        fi
        out="$(env_for STUB_EXEC_OUT "$svc")"
        [[ -z "$out" ]] || printf '%s\n' "$out"
        rc="$(env_for STUB_EXEC_RC "$svc")"
        exit "${rc:-0}"
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF

write_stub curl <<'EOF'
SVCS=(sabnzbd prowlarr sonarr sonarr-anime sonarr-4k radarr radarr-4k lidarr plex seerr tautulli jellyfin)
PORTS=(8080 9696 8989 8989 8989 7878 7878 8686 32400 5055 8181 8096)
STUB_LOG="${STUB_LOG:-$_STUB_HOME/api.log}"
STUB_STATE="${STUB_STATE:-$_STUB_HOME/state}"

method="" data="" out="" wfmt="" cfg="" fail=0 url=""
headers=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X|--request) method="$2"; shift 2 ;;
    --data-binary|--data|-d|--data-raw) data="$2"; shift 2 ;;
    -o|--output) out="$2"; shift 2 ;;
    -w|--write-out) wfmt="$2"; shift 2 ;;
    -K|--config) cfg="$2"; shift 2 ;;
    -H|--header) headers+=("$2"); shift 2 ;;
    --fail-with-body|--fail) fail=1; shift ;;
    -m|--max-time|--connect-timeout|--retry|--retry-delay|--retry-max-time|-u|--user|-A|--user-agent|-e|--referer|--cacert|--resolve|-x|--proxy)
      shift 2 ;;
    --*) shift ;;
    -*)
      # Combined short flags (-sS, -fsS): -f turns on fail mode.
      [[ "$1" == *f* ]] && fail=1
      shift ;;
    *) url="$1"; shift ;;
  esac
done

# The -K config: url/header/request lines, quoted or not.
if [[ -n "$cfg" ]]; then
  src="$cfg"
  [[ "$cfg" == - ]] && src=/dev/stdin
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^[[:space:]]*-{0,2}([A-Za-z-]+)[[:space:]]*[=:]?[[:space:]]*\"(.*)\"[[:space:]]*$ ]]; then
      k="${BASH_REMATCH[1]}"
      v="${BASH_REMATCH[2]}"
      v="${v//\\\"/\"}"
      v="${v//\\\\/\\}"
    elif [[ "$line" =~ ^[[:space:]]*-{0,2}([A-Za-z-]+)[[:space:]]*[=:]?[[:space:]]*(.*)$ ]]; then
      k="${BASH_REMATCH[1]}"
      v="${BASH_REMATCH[2]}"
    else
      continue
    fi
    case "$k" in
      url) url="$v" ;;
      header|H) headers+=("$v") ;;
      request|X) method="$v" ;;
    esac
  done < "$src"
fi

if [[ -z "$method" ]]; then
  if [[ -n "$data" ]]; then method=POST; else method=GET; fi
fi

# emit <code> <body>: -o/stdout, -w, exit status like real curl.
emit() {
  local code="$1" body="$2" w
  if [[ -n "$out" ]]; then
    printf '%s' "$body" > "$out"
  else
    printf '%s' "$body"
  fi
  if [[ -n "$wfmt" ]]; then
    w="${wfmt//'%{http_code}'/$code}"
    w="${w//'\n'/$'\n'}"
    printf '%s' "$w"
  fi
  if [[ $fail -eq 1 && "$code" -ge 400 ]]; then
    exit 22
  fi
  exit 0
}
conn_fail() {
  printf 'curl: (%s) %s\n' "$1" "$2" >&2
  [[ -z "$wfmt" ]] || printf '%s' "${wfmt//'%{http_code}'/000}"
  exit "$1"
}

if [[ ! "$url" =~ ^[A-Za-z]+://([^/:?]+)(:([0-9]+))?(.*)$ ]]; then
  conn_fail 3 "URL rejected: bad or missing URL"
fi
host="${BASH_REMATCH[1]}"
port="${BASH_REMATCH[3]}"
rest="${BASH_REMATCH[4]}"
[[ "$rest" == /* ]] || rest="/$rest"

svc=""
idx=""
for i in "${!SVCS[@]}"; do
  if [[ "$host" == "172.30.0.$((10 + i))" || "$host" == "${SVCS[$i]}" ]]; then
    svc="${SVCS[$i]}"
    idx="$i"
    break
  fi
done
[[ -n "$svc" ]] || conn_fail 6 "Could not resolve host: $host"
if [[ -n "$port" && "$port" != "${PORTS[$idx]}" ]]; then
  conn_fail 7 "Failed to connect to $host port $port: Connection refused"
fi

# Key from the headers or the query; strip it from the logged path.
reqkey=""
for h in "${headers[@]}"; do
  case "${h,,}" in
    x-api-key:*|x-plex-token:*)
      reqkey="${h#*:}"
      reqkey="${reqkey# }"
      ;;
  esac
done
path="${rest%%\?*}"
if [[ "$rest" == *\?* ]]; then
  keep=()
  IFS='&' read -r -a parts <<<"${rest#*\?}"
  for p in "${parts[@]}"; do
    case "$p" in
      apikey=*|X-Plex-Token=*) reqkey="${p#*=}" ;;
      "") ;;
      *) keep+=("$p") ;;
    esac
  done
  if [[ ${#keep[@]} -gt 0 ]]; then
    path+="?$(IFS='&'; printf '%s' "${keep[*]}")"
  fi
fi

# Log what the server received (no key: it lives only in headers/query).
line="$method $svc $path"
if [[ "$method" != GET && -n "$data" ]]; then
  if [[ "$data" == @* ]]; then
    b="$(jq -c . < "${data#@}" 2>/dev/null || tr -d '\n' < "${data#@}")"
  else
    b="$data"
  fi
  line+=" body=$b"
fi
printf '%s\n' "$line" >> "$STUB_LOG"

# Fixture lookup, with per-name call sequences.
name="$(printf '%s' "${method}_${path}" | sed 's#[/?&=.]#_#g; s#__*#_#g; s#_$##')"
base="${STUB_FIXTURES:-/nonexistent}/$svc/$name.json"
mkdir -p "$STUB_STATE/$svc"
countf="$STUB_STATE/$svc/$name.count"
k=0
[[ -f "$countf" ]] && k="$(cat "$countf")"
printf '%s\n' "$((k + 1))" > "$countf"
chosen=""
for ((j = k; j >= 1; j--)); do
  if [[ -f "$base.$j" ]]; then
    chosen="$base.$j"
    break
  fi
done
[[ -n "$chosen" || ! -f "$base" ]] || chosen="$base"

code=200
httpf="${STUB_FIXTURES:-/nonexistent}/$svc/$name.http"
[[ -f "$httpf" ]] && code="$(tr -dc '0-9' < "$httpf")"
if [[ -n "${STUB_EXPECT_KEY:-}" && "$reqkey" != "$STUB_EXPECT_KEY" ]]; then
  code=401
fi
# Prowlarr's SabnzbdSettingsValidator: Category NotEmpty (a warning, which
# Create/Update reject unless forceSave=true) -> 400 with validation errors.
vbody=""
if [[ "$svc" == prowlarr && ( "$method" == POST || "$method" == PUT ) && -n "$data" \
      && "${path%%\?*}" =~ ^/api/v1/downloadclient(/[0-9]+)?$ && "&${path#*\?}&" != *"&forceSave=true&"* ]]; then
  if [[ "$data" == @* ]]; then b="$(cat "${data#@}" 2>/dev/null || true)"; else b="$data"; fi
  if jq -e '[.fields[]? | select(.name == "category")] | length > 0 and all(.[]; (.value // "") == "")' \
       >/dev/null 2>&1 <<<"$b"; then
    code=400
    vbody='[{"propertyName":"Category","errorMessage":"'"'"'Category'"'"' must not be empty.","severity":"warning","isWarning":true}]'
  fi
fi
forced="STUB_HTTP_${svc//-/_}"
[[ -z "${!forced:-}" ]] || code="${!forced}"

if [[ -n "$vbody" && "$code" == 400 ]]; then
  body="$vbody"
elif [[ -n "$chosen" ]]; then
  body="$(cat "$chosen")"
elif [[ "$code" -ge 400 ]]; then
  body="{\"message\":\"stub HTTP $code\"}"
elif [[ "$method" == GET ]]; then
  body="{}"
else
  body=""
fi
emit "$code" "$body"
EOF

write_stub ssh <<'EOF'
# STUB_SSH_RC forces a failure; otherwise the remote command (the last
# argument) runs locally, with stdin passed through.
if [[ -n "${STUB_SSH_RC:-}" ]]; then
  exit "$STUB_SSH_RC"
fi
exec bash -c "${!#}"
EOF

log_info "API stubs written to $DIR"
