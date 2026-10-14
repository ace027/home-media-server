#!/usr/bin/env bash
# shellcheck disable=SC2317
# (SC2317: the check_* functions are called indirectly, by name, from run_check.)
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# .env first, then defaults, so .env values are not masked by the defaults.
load_env
DOMAIN="${DOMAIN:-}"
LAN_CIDR="${LAN_CIDR:-}"
SKIP_NET="${SKIP_NET:-0}"
AUTHENTIK_TOKEN="${AUTHENTIK_TOKEN:-}"

# Throwaway client for int-lan-only, authentik-admin-lan, authentik-admin-api-lan and
# int-forward-auth (runs on the proxy network, outside LAN_CIDR).
CURL_IMAGE="curlimages/curl:8.22.0"
# The only ports that may be published on every interface.
OPEN_PORTS=(443 32400)
CHECKS=(edge-healthy edge-ports no-docker-sock int-chains cert-wildcard
        ddns-records int-lan-only public-routes secure-headers
        authentik-healthy auth-public authentik-admin-lan authentik-admin-api-lan
        int-forward-auth authentik-mfa crowdsec-healthy crowdsec-bouncer crowdsec-acquis public-chain no-lan-override
        crowdsec-ban)
BAN_TEST=0

usage() {
  local token_state="<unset>"
  [[ -z "$AUTHENTIK_TOKEN" ]] || token_state="<set>"
  cat <<EOF
Phase 3 acceptance gate for the edge (Traefik, socket proxy, DDNS, Authentik).
Read-only: it inspects containers and makes HTTPS and API GET requests; the only
thing it starts is a throwaway curl container on the proxy network
(int-lan-only, authentik-admin-lan, authentik-admin-api-lan, int-forward-auth),
removed on exit.

Runs ${#CHECKS[@]} checks, in order, each printing one line:
  PASS <id> <detail>
  FAIL <id> <detail>
  SKIP <id> <reason>
Check IDs: ${CHECKS[*]// /, }.
(edge-healthy: traefik healthy, socket-proxy and cloudflare-ddns running;
edge-ports: nothing but 443 and 32400 on 0.0.0.0/::, nothing on :80/:81;
cert-wildcard: a production Let's Encrypt wildcard, SKIP on staging;
authentik-healthy: authentik-server and authentik-db healthy, authentik-worker running;
auth-public: https://auth.<domain>/-/health/live/ answers 200 or 204;
authentik-admin-lan: from outside LAN_CIDR /if/admin/ is 403 and /-/health/live/ is not;
authentik-admin-api-lan: from outside LAN_CIDR the admin-only API /api/v3/policies/all/
is 403 and the public /api/v3/root/config/ is 200;
int-forward-auth: the outpost answers an unauthenticated sonarr.int request with a
302 to https://auth.<domain>/;
authentik-mfa: via /api/v3/, admins-only-mfa is bound to the MFA validation stage
binding and not_configured_action is configure; SKIP unless AUTHENTIK_TOKEN is set;
crowdsec-healthy: crowdsec running and healthy;
crowdsec-bouncer: the traefik-bouncer pulled decisions within the last 2 minutes;
crowdsec-acquis: CrowdSec has read lines from Traefik's access log;
public-chain: the public chain is crowdsec, geoblock, rate-limit, secure-headers, and only
seerr, auth and jellyfin routers use it; public-auth is crowdsec, geoblock,
auth-rate-limit, secure-headers and the auth router uses it;
no-lan-override: compose.lan.yaml is gone and no container publishes a port but 443 and 32400;
crowdsec-ban: only with --ban-test: bans a throwaway client for 2 minutes and expects a
403 from requests.<domain>, then lifts the ban; otherwise SKIP.)

Ends with: RESULT: <n> pass, <n> fail, <n> skip
Exits 1 if any check FAILs, 0 otherwise.

Usage: verify-edge.sh [--ban-test] [--help]
  --ban-test  also run crowdsec-ban (adds, then removes, a CrowdSec decision for a
              throwaway container's address; changes nothing that persists)
(--apply is accepted for CLI consistency but has no effect.)

Environment variables (normally from .env):
  DOMAIN=${DOMAIN:-<unset>}
  LAN_CIDR=${LAN_CIDR:-<unset>}
  SKIP_NET=$SKIP_NET   1: every check that needs the network or a live stack prints SKIP
  AUTHENTIK_TOKEN=$token_state   Authentik API token for authentik-mfa
    (never printed; sent from a mode 0600 temp file, not on the command line)
EOF
}

# --ban-test is this script's own flag; the rest goes to the shared parser.
rest=()
for arg in "$@"; do
  if [[ "$arg" == --ban-test ]]; then
    BAN_TEST=1
  else
    rest+=("$arg")
  fi
done
parse_common_args ${rest[@]+"${rest[@]}"}

require_match DOMAIN "$DOMAIN" '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' "a DNS domain name, set in .env"
require_match LAN_CIDR "$LAN_CIDR" '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "an IPv4 CIDR such as 192.168.1.0/24, set in .env"
require_match SKIP_NET "$SKIP_NET" '^[01]$' "0 or 1"
if [[ -n "$AUTHENTIK_TOKEN" ]]; then
  # Never echo the value; only its shape is checked (it goes into an HTTP header).
  [[ "$AUTHENTIK_TOKEN" =~ ^[A-Za-z0-9._-]+$ ]] || die "AUTHENTIK_TOKEN has characters an Authentik API token never has"
fi
if [[ "$SKIP_NET" != 1 ]]; then
  require_cmd docker curl jq openssl
fi

umask 077
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

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

# net_skip <id>: with SKIP_NET=1 prints the SKIP line and returns 0.
net_skip() {
  if [[ "$SKIP_NET" == 1 ]]; then
    skip "$1" "SKIP_NET=1"
    return 0
  fi
  return 1
}

# list <item...>: the items joined with "; " (for one-line details).
list() {
  local first="$1"
  shift
  printf '%s' "$first"
  [[ $# -eq 0 ]] || printf '; %s' "$@"
}

# The traefik container id and its proxy-network address.
traefik_id() {
  docker compose ps -q traefik | head -n 1
}

# traefik_ip: traefik's address on the proxy network (empty if none).
traefik_ip() {
  local cid
  cid="$(traefik_id)"
  [[ -n "$cid" ]] || return 0
  docker inspect "$cid" | jq -r '.[0].NetworkSettings.Networks.proxy.IPAddress // empty'
}

# proxy_curl <curl args...>: curl from a throwaway container on the proxy network.
proxy_curl() {
  docker run --rm --network proxy "$CURL_IMAGE" "$@"
}

# ak_api <path>: GET https://auth.$DOMAIN/api/v3/<path> with AUTHENTIK_TOKEN. The
# Authorization header is read from a 0600 file so the token is not in `ps`.
ak_api() {
  [[ -f "$W/ak-header" ]] || printf 'Authorization: Bearer %s\n' "$AUTHENTIK_TOKEN" >"$W/ak-header"
  curl -fsSk --max-time 15 -H "@$W/ak-header" \
    --resolve "auth.$DOMAIN:443:127.0.0.1" "https://auth.$DOMAIN/api/v3/$1"
}

# ---------------------------------------------------------------------------
check_edge_healthy() {
  local id=edge-healthy ps bad=()
  net_skip "$id" && return 0
  ps="$(docker compose ps --all --format json | jq -s 'flatten')" \
    || { fail "$id" "docker compose ps failed"; return 0; }
  jq -e 'any(.[]; .Service == "traefik" and .State == "running" and .Health == "healthy")' <<<"$ps" >/dev/null \
    || bad+=("traefik not running and healthy")
  for s in socket-proxy cloudflare-ddns; do
    jq -e --arg s "$s" 'any(.[]; .Service == $s and .State == "running")' <<<"$ps" >/dev/null \
      || bad+=("$s not running")
  done
  if [[ ${#bad[@]} -gt 0 ]]; then
    fail "$id" "$(list "${bad[@]}")"
  else
    pass "$id" "traefik healthy; socket-proxy and cloudflare-ddns running"
  fi
}

check_edge_ports() {
  local id=edge-ports name ports mapping host port bad=() lan=() allowed p listen
  net_skip "$id" && return 0
  while IFS='|' read -r name ports; do
    while read -r mapping; do
      [[ -n "$mapping" ]] || continue
      host="${mapping%:*}"
      port="${mapping##*:}"
      allowed=0
      for p in "${OPEN_PORTS[@]}"; do
        [[ "$port" == "$p" ]] && allowed=1
      done
      case "$host" in
        0.0.0.0|'[::]')
          [[ $allowed -eq 1 ]] || bad+=("$name publishes $host:$port")
          ;;
        *)
          lan+=("$name $host:$port")
          ;;
      esac
    done < <(grep -oE '(\[[0-9a-f:]+\]|[0-9]+(\.[0-9]+){3}):[0-9]+(-[0-9]+)?->' <<<"$ports" | sed 's/->$//' || true)
  done < <(docker ps --format '{{.Names}}|{{.Ports}}')
  listen="$(ss -ltn | awk 'NR > 1 && $4 ~ /:(80|81)$/ {print $4}' | paste -sd, -)"
  [[ -z "$listen" ]] || bad+=("listening on $listen")
  if [[ ${#bad[@]} -gt 0 ]]; then
    fail "$id" "$(list "${bad[@]}")"
  elif [[ ${#lan[@]} -gt 0 ]]; then
    pass "$id" "only 443 and 32400 on all interfaces; LAN-bound: $(list "${lan[@]}")"
  else
    pass "$id" "only 443 and 32400 published; nothing on :80/:81"
  fi
}

check_no_docker_sock() {
  local id=no-docker-sock cid
  net_skip "$id" && return 0
  cid="$(traefik_id)"
  [[ -n "$cid" ]] || { fail "$id" "traefik container not found"; return 0; }
  if docker inspect "$cid" | jq -e '.[0] | [(.Mounts[]?.Source), (.HostConfig.Binds[]?)] | any(.[]; test("docker\\.sock"))' >/dev/null; then
    fail "$id" "traefik mounts docker.sock"
  else
    pass "$id" "traefik has no docker.sock mount (Docker API via socket-proxy only)"
  fi
}

check_int_chains() {
  local id=int-chains ids=() n bad
  net_skip "$id" && return 0
  mapfile -t ids < <(docker ps -q)
  [[ ${#ids[@]} -gt 0 ]] || { fail "$id" "no running containers"; return 0; }
  docker inspect "${ids[@]}" >"$W/inspect.json"
  # Every router with ".int." in its rule must list int@docker in its middlewares.
  bad="$(jq -r '.[] | (.Config.Labels // {}) as $l | $l | keys[]
    | select(test("^traefik\\.http\\.routers\\.[^.]+\\.rule$") and ($l[.] | contains(".int.")))
    | sub("\\.rule$"; ".middlewares") as $mk
    | select(($l[$mk] // "" | split(",") | any(. == "int@docker")) | not)
    | sub("^traefik\\.http\\.routers\\."; "") | sub("\\.middlewares$"; "")' "$W/inspect.json" | paste -sd, -)"
  n="$(jq '[.[] | (.Config.Labels // {}) | to_entries[]
    | select((.key | test("^traefik\\.http\\.routers\\.[^.]+\\.rule$")) and (.value | contains(".int.")))] | length' "$W/inspect.json")"
  if [[ -n "$bad" ]]; then
    fail "$id" "routers without int@docker: $bad"
  elif [[ "$n" -eq 0 ]]; then
    fail "$id" "no *.int routers found"
  else
    pass "$id" "$n *.int routers use int@docker"
  fi
}

check_cert_wildcard() {
  local id=cert-wildcard out issuer san
  net_skip "$id" && return 0
  out="$(timeout 20 openssl s_client -connect 127.0.0.1:443 -servername "probe.int.$DOMAIN" </dev/null 2>/dev/null \
    | openssl x509 -noout -issuer -ext subjectAltName 2>/dev/null)" || out=""
  [[ -n "$out" ]] || { fail "$id" "no certificate from 127.0.0.1:443"; return 0; }
  issuer="$(grep -i '^issuer' <<<"$out" || true)"
  san="$(grep -i 'DNS:' <<<"$out" || true)"
  if grep -qiE 'STAGING|Fake' <<<"$issuer"; then
    skip "$id" "staging certificate; set ACME_CASERVER to production and delete acme.json to get a trusted one"
    return 0
  fi
  grep -q "Let's Encrypt" <<<"$issuer" || { fail "$id" "issuer is not Let's Encrypt: ${issuer:-none}"; return 0; }
  grep -qF "DNS:*.$DOMAIN" <<<"$san" || { fail "$id" "SAN lacks *.$DOMAIN"; return 0; }
  grep -qF "DNS:*.int.$DOMAIN" <<<"$san" || { fail "$id" "SAN lacks *.int.$DOMAIN"; return 0; }
  if ! timeout 20 openssl s_client -connect 127.0.0.1:443 -servername "probe.int.$DOMAIN" </dev/null 2>/dev/null \
      | openssl x509 -noout -checkend $((14 * 86400)) >/dev/null; then
    fail "$id" "certificate expires within 14 days"
    return 0
  fi
  pass "$id" "Let's Encrypt wildcard for *.$DOMAIN and *.int.$DOMAIN, more than 14 days left"
}

check_ddns_records() {
  local id=ddns-records wan h got bad=()
  net_skip "$id" && return 0
  command -v dig >/dev/null || { fail "$id" "dig not found (apt install dnsutils)"; return 0; }
  wan="$(curl -fsS --max-time 15 https://1.1.1.1/cdn-cgi/trace | sed -n 's/^ip=//p')" || wan=""
  [[ -n "$wan" ]] || { fail "$id" "cannot determine the WAN IP from 1.1.1.1/cdn-cgi/trace"; return 0; }
  for h in plex requests auth; do
    got="$(dig +short +time=5 +tries=1 @1.1.1.1 A "$h.$DOMAIN" | paste -sd, -)"
    [[ "$got" == "$wan" ]] || bad+=("$h.$DOMAIN is '${got:-none}', want $wan")
  done
  if [[ ${#bad[@]} -gt 0 ]]; then
    fail "$id" "$(list "${bad[@]}")"
  else
    pass "$id" "plex, requests and auth.$DOMAIN resolve to the WAN IP $wan"
  fi
}

check_int_lan_only() {
  local id=int-lan-only cid ip code
  net_skip "$id" && return 0
  cid="$(traefik_id)"
  [[ -n "$cid" ]] || { fail "$id" "traefik container not found"; return 0; }
  ip="$(docker inspect "$cid" | jq -r '.[0].NetworkSettings.Networks.proxy.IPAddress // empty')"
  [[ -n "$ip" ]] || { fail "$id" "traefik has no address on the proxy network"; return 0; }
  # The client sits on the proxy network, outside LAN_CIDR ($LAN_CIDR): 403 expected.
  # -k: only the status matters here, and staging certificates are not trusted.
  code="$(docker run --rm --network proxy "$CURL_IMAGE" -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    --resolve "sonarr.int.$DOMAIN:443:$ip" "https://sonarr.int.$DOMAIN/")" || code=""
  if [[ "$code" == 403 ]]; then
    pass "$id" "sonarr.int.$DOMAIN from outside $LAN_CIDR -> 403"
  else
    fail "$id" "sonarr.int.$DOMAIN from outside $LAN_CIDR -> ${code:-no response} (want 403; is the proxy subnet inside LAN_CIDR?)"
  fi
}

check_public_routes() {
  local id=public-routes code
  net_skip "$id" && return 0
  code="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    --resolve "requests.$DOMAIN:443:127.0.0.1" "https://requests.$DOMAIN/")" || code=""
  case "$code" in
    200|302|307) pass "$id" "https://requests.$DOMAIN/ -> $code" ;;
    *) fail "$id" "https://requests.$DOMAIN/ -> ${code:-no response} (want 200, 302 or 307)" ;;
  esac
}

check_secure_headers() {
  local id=secure-headers hdr bad=()
  net_skip "$id" && return 0
  curl -sk --max-time 15 -o /dev/null -D "$W/headers" \
    --resolve "requests.$DOMAIN:443:127.0.0.1" "https://requests.$DOMAIN/" || true
  hdr="$(tr -d '\r' <"$W/headers" 2>/dev/null || true)"
  [[ -n "$hdr" ]] || { fail "$id" "no response from https://requests.$DOMAIN/"; return 0; }
  grep -qiE '^strict-transport-security:.*max-age=31536000' <<<"$hdr" || bad+=("Strict-Transport-Security max-age=31536000")
  grep -qiE '^x-content-type-options: *nosniff' <<<"$hdr" || bad+=("X-Content-Type-Options nosniff")
  grep -qiE '^x-frame-options: *DENY' <<<"$hdr" || bad+=("X-Frame-Options DENY")
  if [[ ${#bad[@]} -gt 0 ]]; then
    fail "$id" "missing: $(list "${bad[@]}")"
  else
    pass "$id" "HSTS, nosniff and frame-deny headers present on requests.$DOMAIN"
  fi
}

check_authentik_healthy() {
  local id=authentik-healthy ps bad=() s
  net_skip "$id" && return 0
  ps="$(docker compose ps --all --format json | jq -s 'flatten')" \
    || { fail "$id" "docker compose ps failed"; return 0; }
  for s in authentik-server authentik-db; do
    jq -e --arg s "$s" 'any(.[]; .Service == $s and .State == "running" and .Health == "healthy")' <<<"$ps" >/dev/null \
      || bad+=("$s not running and healthy")
  done
  jq -e 'any(.[]; .Service == "authentik-worker" and .State == "running")' <<<"$ps" >/dev/null \
    || bad+=("authentik-worker not running")
  if [[ ${#bad[@]} -gt 0 ]]; then
    fail "$id" "$(list "${bad[@]}")"
  else
    pass "$id" "authentik-server and authentik-db healthy; authentik-worker running"
  fi
}

check_auth_public() {
  local id=auth-public code
  net_skip "$id" && return 0
  code="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    --resolve "auth.$DOMAIN:443:127.0.0.1" "https://auth.$DOMAIN/-/health/live/")" || code=""
  case "$code" in
    200|204) pass "$id" "https://auth.$DOMAIN/-/health/live/ -> $code" ;;
    *) fail "$id" "https://auth.$DOMAIN/-/health/live/ -> ${code:-no response} (want 200 or 204)" ;;
  esac
}

check_authentik_admin_lan() {
  local id=authentik-admin-lan ip admin live
  net_skip "$id" && return 0
  ip="$(traefik_ip)"
  [[ -n "$ip" ]] || { fail "$id" "traefik has no address on the proxy network"; return 0; }
  # Same vantage point as int-lan-only: on the proxy network, outside LAN_CIDR.
  admin="$(proxy_curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    --resolve "auth.$DOMAIN:443:$ip" "https://auth.$DOMAIN/if/admin/")" || admin=""
  live="$(proxy_curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    --resolve "auth.$DOMAIN:443:$ip" "https://auth.$DOMAIN/-/health/live/")" || live=""
  if [[ "$admin" == 403 && ( "$live" == 200 || "$live" == 204 ) ]]; then
    pass "$id" "from outside $LAN_CIDR: /if/admin/ -> 403, /-/health/live/ -> $live"
  else
    fail "$id" "from outside $LAN_CIDR: /if/admin/ -> ${admin:-no response} (want 403), /-/health/live/ -> ${live:-no response} (want 200 or 204)"
  fi
}

check_authentik_admin_api_lan() {
  local id=authentik-admin-api-lan ip admin pub
  net_skip "$id" && return 0
  ip="$(traefik_ip)"
  [[ -n "$ip" ]] || { fail "$id" "traefik has no address on the proxy network"; return 0; }
  # Same vantage point as authentik-admin-lan. The auth-admin-api router answers 403
  # before Authentik sees the request, so no session or token is needed.
  admin="$(proxy_curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    --resolve "auth.$DOMAIN:443:$ip" "https://auth.$DOMAIN/api/v3/policies/all/")" || admin=""
  pub="$(proxy_curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    --resolve "auth.$DOMAIN:443:$ip" "https://auth.$DOMAIN/api/v3/root/config/")" || pub=""
  if [[ "$admin" == 403 && "$pub" == 200 ]]; then
    pass "$id" "from outside $LAN_CIDR: /api/v3/policies/all/ -> 403, /api/v3/root/config/ -> 200"
  else
    fail "$id" "from outside $LAN_CIDR: /api/v3/policies/all/ -> ${admin:-no response} (want 403), /api/v3/root/config/ -> ${pub:-no response} (want 200)"
  fi
}

check_int_forward_auth() {
  local id=int-forward-auth out code loc
  net_skip "$id" && return 0
  # Asks the embedded outpost directly, as Traefik's authentik middleware does, for an
  # unauthenticated request to sonarr.int; Authentik must send it to the login.
  out="$(proxy_curl -s --max-time 15 -o /dev/null -w '%{http_code} %{redirect_url}' \
    -H "X-Forwarded-Host: sonarr.int.$DOMAIN" -H 'X-Forwarded-Proto: https' \
    -H 'X-Forwarded-Uri: /' -H 'X-Forwarded-Method: GET' \
    "http://authentik-server:9000/outpost.goauthentik.io/auth/traefik")" || out=""
  code="${out%% *}"
  loc="${out#* }"
  if [[ "$code" == 302 && "$loc" == "https://auth.$DOMAIN/"* ]]; then
    pass "$id" "unauthenticated sonarr.int.$DOMAIN -> 302 to https://auth.$DOMAIN/"
  else
    fail "$id" "unauthenticated sonarr.int.$DOMAIN -> ${code:-no response} ${loc%%\?*} (want 302 to https://auth.$DOMAIN/; is int-forward-auth in the embedded outpost?)"
  fi
}

check_authentik_mfa() {
  local id=authentik-mfa stage spk fsb pbm mode policies
  net_skip "$id" && return 0
  if [[ -z "$AUTHENTIK_TOKEN" ]]; then
    skip "$id" "AUTHENTIK_TOKEN not set (create an API token in the admin interface, runbook 04 section 6)"
    return 0
  fi
  stage="$(ak_api 'stages/authenticator/validate/?name=default-authentication-mfa-validation')" \
    || { fail "$id" "API request failed (token valid? auth.$DOMAIN up?)"; return 0; }
  spk="$(jq -r '.results[0].pk // empty' <<<"$stage")"
  [[ -n "$spk" ]] || { fail "$id" "stage default-authentication-mfa-validation not found"; return 0; }
  jq -e '.results[0].not_configured_action == "configure"' <<<"$stage" >/dev/null \
    || { fail "$id" "not_configured_action is $(jq -r '.results[0].not_configured_action' <<<"$stage"), want configure"; return 0; }
  fsb="$(ak_api "flows/bindings/?stage=$spk")" || { fail "$id" "flow binding request failed"; return 0; }
  pbm="$(jq -r '.results[0].policybindingmodel_ptr_id // empty' <<<"$fsb")"
  mode="$(jq -r '.results[0].policy_engine_mode // empty' <<<"$fsb")"
  [[ -n "$pbm" ]] || { fail "$id" "the MFA validation stage is not bound to a flow"; return 0; }
  policies="$(ak_api "policies/bindings/?target=$pbm")" || { fail "$id" "policy binding request failed"; return 0; }
  jq -e 'any(.results[]; .policy_obj.name == "admins-only-mfa" and .enabled == true)' <<<"$policies" >/dev/null \
    || { fail "$id" "admins-only-mfa is not bound (enabled) to the MFA stage binding"; return 0; }
  [[ "$mode" == all ]] || { fail "$id" "MFA stage binding policy_engine_mode is '$mode', want all"; return 0; }
  pass "$id" "admins-only-mfa bound to the MFA stage binding (mode all); not_configured_action configure"
}

# dc_exec <args...>: docker compose exec -T crowdsec <args>.
dc_exec() {
  docker compose exec -T crowdsec "$@"
}

check_crowdsec_healthy() {
  local id=crowdsec-healthy ps
  net_skip "$id" && return 0
  ps="$(docker compose ps --all --format json | jq -s 'flatten')" \
    || { fail "$id" "docker compose ps failed"; return 0; }
  if jq -e 'any(.[]; .Service == "crowdsec" and .State == "running" and .Health == "healthy")' <<<"$ps" >/dev/null; then
    pass "$id" "crowdsec running and healthy"
  else
    fail "$id" "crowdsec not running and healthy (docker compose logs crowdsec)"
  fi
}

check_crowdsec_bouncer() {
  local id=crowdsec-bouncer out age
  net_skip "$id" && return 0
  out="$(dc_exec cscli bouncers list -o json)" \
    || { fail "$id" "cscli bouncers list failed (is crowdsec running?)"; return 0; }
  jq -e 'any(.[]; .name == "traefik-bouncer")' <<<"$out" >/dev/null \
    || { fail "$id" "bouncer traefik-bouncer is not registered (secrets/crowdsec_bouncer_key, restart crowdsec)"; return 0; }
  # Fractional seconds are cut off because fromdateiso8601 does not accept them.
  age="$(jq -r '[.[] | select(.name == "traefik-bouncer" and .last_pull != null)
    | now - (.last_pull | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)] | min // empty | floor' <<<"$out")"
  if [[ -z "$age" ]]; then
    fail "$id" "traefik-bouncer has never pulled decisions (Traefik cannot reach crowdsec:8080 or the key differs)"
  elif [[ "$age" -le 120 ]]; then
    pass "$id" "traefik-bouncer pulled decisions ${age}s ago"
  else
    fail "$id" "traefik-bouncer last pulled ${age}s ago (want 120s or less; the bouncer fails open)"
  fi
}

check_crowdsec_acquis() {
  local id=crowdsec-acquis out n
  net_skip "$id" && return 0
  out="$(dc_exec cscli metrics show acquisition -o json)" \
    || { fail "$id" "cscli metrics failed (is crowdsec running?)"; return 0; }
  n="$(jq -r '[.acquisition // {} | to_entries[] | select(.key | test("traefik")) | .value.reads // 0] | add // 0' <<<"$out")"
  if [[ "$n" -gt 0 ]]; then
    pass "$id" "CrowdSec read $n lines from Traefik's access log"
  else
    fail "$id" "CrowdSec has read no lines from /var/log/traefik/access.log (send a request; check config/crowdsec/acquis.yaml)"
  fi
}

check_public_chain() {
  local id=public-chain cid labels chain bad ids=() auth_chain auth_mw
  net_skip "$id" && return 0
  cid="$(traefik_id)"
  [[ -n "$cid" ]] || { fail "$id" "traefik container not found"; return 0; }
  labels="$(docker inspect "$cid" | jq -r '.[0].Config.Labels["traefik.http.middlewares.public.chain.middlewares"] // ""')"
  chain="crowdsec,geoblock,rate-limit,secure-headers"
  [[ "$labels" == "$chain" ]] || { fail "$id" "public chain is '${labels:-unset}', want $chain"; return 0; }
  labels="$(docker inspect "$cid" | jq -r '.[0].Config.Labels["traefik.http.middlewares.public-auth.chain.middlewares"] // ""')"
  auth_chain="crowdsec,geoblock,auth-rate-limit,secure-headers"
  [[ "$labels" == "$auth_chain" ]] || { fail "$id" "public-auth chain is '${labels:-unset}', want $auth_chain"; return 0; }
  mapfile -t ids < <(docker ps -q)
  docker inspect "${ids[@]}" >"$W/inspect.json"
  auth_mw="$(jq -r '[.[] | .Config.Labels["traefik.http.routers.auth.middlewares"] // empty][0] // ""' "$W/inspect.json")"
  [[ "$auth_mw" == "public-auth@docker" ]] || { fail "$id" "auth router middlewares is '${auth_mw:-unset}', want public-auth@docker"; return 0; }
  # Routers whose middlewares include public@docker, other than the expected ones.
  bad="$(jq -r '.[] | (.Config.Labels // {}) as $l | $l | keys[]
    | select(test("^traefik\\.http\\.routers\\.[^.]+\\.middlewares$") and ($l[.] | split(",") | any(. == "public@docker")))
    | sub("^traefik\\.http\\.routers\\."; "") | sub("\\.middlewares$"; "")
    | select(. != "seerr" and . != "auth" and . != "jellyfin")' "$W/inspect.json" | paste -sd, -)"
  if [[ -n "$bad" ]]; then
    fail "$id" "unexpected routers on public@docker: $bad"
  else
    pass "$id" "public = $chain (seerr, jellyfin); public-auth = $auth_chain (auth)"
  fi
}

check_no_lan_override() {
  local id=no-lan-override name ports mapping port bad=() p allowed
  if [[ -e "$REPO_ROOT/compose.lan.yaml" ]]; then
    fail "$id" "compose.lan.yaml still exists (git rm it and remove COMPOSE_FILE from .env)"
    return 0
  fi
  net_skip "$id" && return 0
  while IFS='|' read -r name ports; do
    while read -r mapping; do
      [[ -n "$mapping" ]] || continue
      port="${mapping##*:}"
      allowed=0
      for p in "${OPEN_PORTS[@]}"; do
        [[ "$port" == "$p" ]] && allowed=1
      done
      [[ $allowed -eq 1 ]] || bad+=("$name publishes $mapping")
    done < <(grep -oE '(\[[0-9a-f:]+\]|[0-9]+(\.[0-9]+){3}):[0-9]+(-[0-9]+)?->' <<<"$ports" | sed 's/->$//' || true)
  done < <(docker ps --format '{{.Names}}|{{.Ports}}')
  if [[ ${#bad[@]} -gt 0 ]]; then
    fail "$id" "$(list "${bad[@]}")"
  else
    pass "$id" "compose.lan.yaml absent; only 443 and 32400 published"
  fi
}

# crowdsec-ban: a throwaway client on the proxy network is banned in CrowdSec and must
# get 403 from requests.$DOMAIN. Its address is private, so it passes the geo-block
# (allowLocalRequests) and the 403 can only come from CrowdSec. The ban and the
# container are removed on exit, whatever happens.
BAN_CNAME=""
BAN_IP=""
ban_cleanup() {
  [[ -z "$BAN_CNAME" ]] || docker rm -f "$BAN_CNAME" >/dev/null 2>&1 || true
  [[ -z "$BAN_IP" ]] || dc_exec cscli decisions delete --ip "$BAN_IP" >/dev/null 2>&1 || true
}

check_crowdsec_ban() {
  local id=crowdsec-ban tip code="" i
  if [[ "$BAN_TEST" -ne 1 ]]; then
    skip "$id" "run with --ban-test"
    return 0
  fi
  net_skip "$id" && return 0
  tip="$(traefik_ip)"
  [[ -n "$tip" ]] || { fail "$id" "traefik has no address on the proxy network"; return 0; }
  # This check runs in its own subshell (run_check), so this trap fires when it ends.
  trap ban_cleanup EXIT
  BAN_CNAME="verify-edge-ban-$$"
  docker run -d --name "$BAN_CNAME" --network proxy --entrypoint sleep "$CURL_IMAGE" 120 >/dev/null \
    || { fail "$id" "cannot start the throwaway client"; return 0; }
  BAN_IP="$(docker inspect "$BAN_CNAME" | jq -r '.[0].NetworkSettings.Networks.proxy.IPAddress // empty')"
  [[ -n "$BAN_IP" ]] || { fail "$id" "throwaway client has no address on the proxy network"; return 0; }
  dc_exec cscli decisions add --ip "$BAN_IP" --duration 2m --reason verify-edge >/dev/null \
    || { fail "$id" "cscli decisions add failed"; return 0; }
  # The bouncer pulls every 15 s, so allow 30 s.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    code="$(docker exec "$BAN_CNAME" curl -sk --max-time 5 -o /dev/null -w '%{http_code}' \
      --resolve "requests.$DOMAIN:443:$tip" "https://requests.$DOMAIN/")" || code=""
    [[ "$code" == 403 ]] && break
    sleep 2
  done
  if [[ "$code" == 403 ]]; then
    pass "$id" "banned $BAN_IP got 403 from requests.$DOMAIN after about $((i * 2))s; ban lifted"
  else
    fail "$id" "banned $BAN_IP still got ${code:-no response} after 30s (is the proxy subnet inside LAN_CIDR, which CrowdSec trusts? check crowdsec-bouncer)"
  fi
}

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# run_check <id>: runs check_<id> (dashes as _) in a subshell with errexit,
# so an unexpected response fails that one check instead of aborting the run.
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

for id in "${CHECKS[@]}"; do
  run_check "$id"
done

printf 'RESULT: %d pass, %d fail, %d skip\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
exit 0
