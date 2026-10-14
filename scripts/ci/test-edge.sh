#!/usr/bin/env bash
# scripts/ci/test-edge.sh
#
# Edge tests (Phase 3): the rendered Compose config (routers, middlewares,
# published ports, socket proxy), scripts/vm/40-edge-secrets.sh and
# scripts/vm/verify-edge.sh. Needs no root, no running stack and no network.
# Prints "ok <name>" per check; exits 1 on the first failure.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
REPO="$PWD"
SECRETS_SH="$REPO/scripts/vm/40-edge-secrets.sh"
VERIFY_SH="$REPO/scripts/vm/verify-edge.sh"

# Pick the file set explicitly; a caller's or .env's selection must not leak in.
unset COMPOSE_FILE COMPOSE_PROFILES

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ok() { printf 'ok %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" >&2
  exit 1
}

[[ -f .env ]] || cp .env.example .env
FULL="$(docker compose -f compose.yaml --profile jellyfin config --format json)"

# ==============================================================================
# Compose config
# ==============================================================================

# label_routers: "<router>|<middlewares>|<rule>" for every router label set.
label_routers() {
  jq -r '.services | to_entries[] | .value.labels // {} | to_entries[]
    | select(.key | test("^traefik\\.http\\.routers\\.[^.]+\\.rule$"))
    | .key as $k | .value as $rule
    | ($k | capture("^traefik\\.http\\.routers\\.(?<r>[^.]+)\\.rule$").r) as $r
    | "\($r)|\($k | sub("\\.rule$"; ".middlewares"))|\($rule)"' <<<"$FULL"
}

test_int_routes_use_int_chain() {
  local n=0 router mwkey rule mw
  while IFS='|' read -r router mwkey rule; do
    [[ "$rule" == *.int.* ]] || continue
    mw="$(jq -r --arg k "$mwkey" '[.services[].labels[$k]? | strings][0] // ""' <<<"$FULL")"
    [[ "$mw" == "int@docker" ]] || fail "router $router (.int. rule) middlewares is '$mw', want int@docker"
    n=$((n + 1))
  done < <(label_routers)
  [[ $n -ge 11 ]] || fail "expected at least 11 .int. routers (10 admin UIs + dashboard), got $n"
  ok "every .int. router uses int@docker ($n routers)"
}

test_only_seerr_is_public() {
  local others
  others="$(jq -r '[.services | to_entries[] | .value.labels // {} | to_entries[]
    | select((.key | test("^traefik\\.http\\.routers\\.[^.]+\\.middlewares$")) and .value != "int@docker")
    | "\(.key | capture("routers\\.(?<r>[^.]+)\\.").r)=\(.value)"] | sort | join(",")' <<<"$FULL")"
  [[ "$others" == "auth-admin=lan-admin@docker,auth=public@docker,seerr=public@docker" ]] \
    || fail "routers not using int@docker: '$others' (want only auth-admin=lan-admin@docker, auth and seerr=public@docker)"
  jq -e '.services.seerr.labels["traefik.http.routers.seerr.rule"] | test("^Host\\(`requests\\.[^`]+`\\)$")' <<<"$FULL" >/dev/null \
    || fail "seerr rule is not Host(\`requests.<domain>\`)"
  jq -e '.services.traefik.labels["traefik.http.routers.dashboard.rule"] | test("^Host\\(`traefik\\.int\\.[^`]+`\\)$")' <<<"$FULL" >/dev/null \
    || fail "dashboard rule is not Host(\`traefik.int.<domain>\`)"
  jq -e '.services.traefik.labels["traefik.http.routers.dashboard.service"] == "api@internal"' <<<"$FULL" >/dev/null \
    || fail "dashboard router service is not api@internal"
  ok "only seerr and auth are public@docker (plus auth-admin on lan-admin); the dashboard is on traefik.int"
}

test_chains() {
  jq -e '.services.traefik.labels
    | .["traefik.http.middlewares.int.chain.middlewares"] == "lan-only,secure-headers,authentik"
      and .["traefik.http.middlewares.lan-admin.chain.middlewares"] == "lan-only,secure-headers"
      and .["traefik.http.middlewares.public.chain.middlewares"] == "crowdsec,geoblock,rate-limit,secure-headers"
      and (.["traefik.http.middlewares.lan-only.ipallowlist.sourcerange"] | length > 0)
      and .["traefik.http.middlewares.secure-headers.headers.stsSeconds"] == "31536000"
      and .["traefik.http.middlewares.secure-headers.headers.frameDeny"] == "true"
      and .["traefik.http.middlewares.rate-limit.ratelimit.average"] == "20"
      and .["traefik.http.middlewares.rate-limit.ratelimit.burst"] == "50"' <<<"$FULL" >/dev/null \
    || fail "traefik middleware/chain labels are not as specified"
  jq -e '.services.traefik.labels
    | .["traefik.http.middlewares.authentik.forwardauth.address"] == "http://authentik-server:9000/outpost.goauthentik.io/auth/traefik"
      and .["traefik.http.middlewares.authentik.forwardauth.trustForwardHeader"] == "true"
      and .["traefik.http.middlewares.authentik.forwardauth.authResponseHeaders"]
        == "X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid"' <<<"$FULL" >/dev/null \
    || fail "authentik forwardauth middleware labels are not as specified"
  ok "int (lan-only, secure-headers, authentik), lan-admin and public chains and their middlewares"
}

test_published_ports() {
  local pub
  pub="$(jq -c '[.services[].ports[]?.published] | unique' <<<"$FULL")"
  [[ "$pub" == '["32400","443"]' ]] || fail "published ports: $pub (want [\"32400\",\"443\"])"
  ok "published ports are exactly 443 and 32400"
}

test_traefik_hardening() {
  jq -e '.services.traefik.volumes | map(.source) | all(test("docker\\.sock") | not)' <<<"$FULL" >/dev/null \
    || fail "traefik mounts docker.sock"
  jq -e '.services.traefik.command | map(test("entrypoints\\.web[.=]")) | any | not' <<<"$FULL" >/dev/null \
    || fail "traefik has an entrypoints.web flag (port 80 must stay closed)"
  jq -e '.services.traefik.command | any(. == "--providers.docker.endpoint=tcp://socket-proxy:2375")' <<<"$FULL" >/dev/null \
    || fail "traefik does not use the socket proxy"
  jq -e '.services.traefik.read_only == true and (.services.traefik.cap_drop | index("ALL"))' <<<"$FULL" >/dev/null \
    || fail "traefik is not read_only with cap_drop ALL"
  ok "traefik: no docker.sock, no :80 entrypoint, read-only, via socket-proxy"
}

test_ddns() {
  jq -e '.services["cloudflare-ddns"].environment
    | .UPDATE_CRON == "@every 5m"
      and .PROXIED == "false"
      and .CLOUDFLARE_API_TOKEN_FILE == "/run/secrets/cf_dns_api_token"
      and (has("CLOUDFLARE_API_TOKEN") | not)' <<<"$FULL" >/dev/null \
    || fail "cloudflare-ddns env is not UPDATE_CRON=@every 5m, PROXIED=false, token from the secret file"
  jq -e '.services["cloudflare-ddns"].environment.DOMAINS | split(",")
    | length == 3 and (.[0] | test("^plex\\.")) and (.[1] | test("^requests\\.")) and (.[2] | test("^auth\\."))' <<<"$FULL" >/dev/null \
    || fail "cloudflare-ddns DOMAINS is not plex, requests, auth"
  jq -e '.services["cloudflare-ddns"].secrets | any(.source == "cf_dns_api_token" and .target == "/run/secrets/cf_dns_api_token")' <<<"$FULL" >/dev/null \
    || fail "cloudflare-ddns does not mount the cf_dns_api_token secret"
  ok "cloudflare-ddns: every 5m, not proxied, plex/requests/auth, token from its secret"
}

test_acme_dns01() {
  local cmd dom ca
  cmd="$(jq -r '.services.traefik.command[]' <<<"$FULL")"
  dom="$(sed -n 's/^--entrypoints\.websecure\.http\.tls\.domains\[0\]\.main=//p' <<<"$cmd")"
  [[ -n "$dom" ]] || fail "websecure tls.domains[0].main is missing"
  grep -qx -- '--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare' <<<"$cmd" \
    || fail "acme dnschallenge.provider is not cloudflare"
  grep -qxF -- "--entrypoints.websecure.http.tls.domains[0].sans=*.$dom,*.int.$dom" <<<"$cmd" \
    || fail "websecure tls.domains[0].sans is not *.$dom,*.int.$dom"
  grep -qx -- '--entrypoints.websecure.http.tls.certResolver=cloudflare' <<<"$cmd" \
    || fail "websecure certResolver is not cloudflare"
  grep -qx -- '--certificatesresolvers.cloudflare.acme.storage=/acme/acme.json' <<<"$cmd" \
    || fail "acme storage is not /acme/acme.json"
  ca="$(grep -E '^ACME_CASERVER=' .env | tail -n 1 | cut -d= -f2-)"
  [[ -n "$ca" ]] || ca="$(sed -n 's/^ACME_CASERVER=//p' .env.example | tail -n 1)"
  grep -qxF -- "--certificatesresolvers.cloudflare.acme.caServer=$ca" <<<"$cmd" \
    || fail "acme caServer does not follow ACME_CASERVER"
  jq -e '.services.traefik.secrets | any(.source == "cf_dns_api_token")' <<<"$FULL" >/dev/null \
    || fail "traefik does not mount the cf_dns_api_token secret"
  jq -e '.services.traefik.environment | has("CF_DNS_API_TOKEN_FILE") or has("CLOUDFLARE_DNS_API_TOKEN_FILE")' <<<"$FULL" >/dev/null \
    || fail "traefik has no Cloudflare token file variable"
  local tls="$REPO/config/traefik/dynamic/tls.yml"
  [[ -f "$tls" ]] || fail "missing config/traefik/dynamic/tls.yml"
  grep -qE '^[[:space:]]*minVersion: VersionTLS1[23]$' "$tls" || fail "tls.yml minVersion is not TLS 1.2 or 1.3"
  grep -qE '^[[:space:]]*sniStrict: true$' "$tls" || fail "tls.yml lacks sniStrict: true"
  ok "acme DNS-01 via cloudflare, wildcard SANs (*.$dom, *.int.$dom), storage, caServer, tls.yml"
}

test_socket_proxy() {
  jq -e '.services["socket-proxy"].volumes
    | any(.source == "/var/run/docker.sock" and .target == "/var/run/docker.sock" and .read_only == true)' <<<"$FULL" >/dev/null \
    || fail "socket-proxy does not mount docker.sock read-only"
  jq -e '.services["socket-proxy"].environment.POST == "0"
    and .services["socket-proxy"].environment.CONTAINERS == "1"
    and .services["socket-proxy"].environment.SERVICES == "0"' <<<"$FULL" >/dev/null \
    || fail "socket-proxy environment is not POST=0, CONTAINERS=1, SERVICES=0"
  jq -e '.services["socket-proxy"].networks | keys == ["socket-proxy"]' <<<"$FULL" >/dev/null \
    || fail "socket-proxy is on a network other than socket-proxy"
  jq -e '.networks["socket-proxy"].internal == true' <<<"$FULL" >/dev/null \
    || fail "socket-proxy network is not internal"
  ok "socket-proxy: docker.sock read-only, POST=0, internal network only"
}

test_secret_paths() {
  jq -e --arg p "$REPO/secrets/cf_dns_api_token" '.secrets.cf_dns_api_token.file == $p' <<<"$FULL" >/dev/null \
    || fail "cf_dns_api_token secret does not resolve to <repo>/secrets/cf_dns_api_token"
  ok "compose secrets resolve to <repo>/secrets"
}

# ==============================================================================
# Authentik (plan 03-02)
# ==============================================================================
AK_SERVICES=(authentik-server authentik-worker authentik-db)

test_authentik_networks() {
  jq -e '.services["authentik-db"].networks | keys == ["authentik"]' <<<"$FULL" >/dev/null \
    || fail "authentik-db is on a network other than authentik"
  jq -e '.services["authentik-worker"].networks | keys == ["authentik"]' <<<"$FULL" >/dev/null \
    || fail "authentik-worker is on a network other than authentik"
  jq -e '.services["authentik-server"].networks | keys == ["authentik","proxy"]' <<<"$FULL" >/dev/null \
    || fail "authentik-server is not on exactly the authentik and proxy networks"
  local others
  others="$(jq -r '[.services | to_entries[] | select(.value.networks // {} | has("authentik"))
    | .key | select(startswith("authentik-") | not)] | join(",")' <<<"$FULL")"
  [[ -z "$others" ]] || fail "non-Authentik services on the authentik network: $others"
  jq -e '.networks.authentik.driver == "bridge" and .networks.authentik.name == "authentik"' <<<"$FULL" >/dev/null \
    || fail "network authentik is not a bridge named authentik"
  ok "authentik-db only on the authentik network; nothing else shares it"
}

test_auth_routers() {
  jq -e '.services["authentik-server"].labels
    | (.["traefik.http.routers.auth.rule"] | test("^Host\\(`auth\\.[^`]+`\\)$"))
      and .["traefik.http.routers.auth.middlewares"] == "public@docker"
      and .["traefik.http.routers.auth.service"] == "authentik"
      and .["traefik.http.services.authentik.loadbalancer.server.port"] == "9000"' <<<"$FULL" >/dev/null \
    || fail "auth router is not Host(auth.<domain>) -> public@docker -> authentik:9000"
  # authentik@docker on the auth router would send Authentik's own login through
  # forward-auth (a redirect loop); int@docker contains it, so both are banned.
  jq -e '.services["authentik-server"].labels["traefik.http.routers.auth.middlewares"]
    | split(",") | any(test("^(authentik|int)(@docker)?$")) | not' <<<"$FULL" >/dev/null \
    || fail "auth router carries the authentik middleware (forward-auth loop)"
  jq -e '.services["authentik-server"].labels
    | (.["traefik.http.routers.auth-admin.rule"] | test("^Host\\(`auth\\.[^`]+`\\) && PathPrefix\\(`/if/admin`\\)$"))
      and .["traefik.http.routers.auth-admin.middlewares"] == "lan-admin@docker"
      and .["traefik.http.routers.auth-admin.priority"] == "100"
      and .["traefik.http.routers.auth-admin.service"] == "authentik"' <<<"$FULL" >/dev/null \
    || fail "auth-admin router is not PathPrefix(/if/admin) -> lan-admin@docker with priority 100"
  ok "auth is public without forward-auth; auth-admin (/if/admin) is lan-admin with priority 100"
}

test_authentik_services() {
  local s img
  for s in "${AK_SERVICES[@]}"; do
    jq -e --arg s "$s" '.services[$s] | (.ports // []) | length == 0' <<<"$FULL" >/dev/null \
      || fail "$s publishes ports"
    jq -e --arg s "$s" '.services[$s].security_opt | index("no-new-privileges:true")' <<<"$FULL" >/dev/null \
      || fail "$s does not extend the _common.yaml base"
  done
  img="$(jq -r '.services["authentik-server"].image' <<<"$FULL")"
  [[ "$img" =~ ^ghcr\.io/goauthentik/server:[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || fail "authentik-server image '$img' is not an exact release tag"
  jq -e --arg i "$img" '.services["authentik-worker"].image == $i' <<<"$FULL" >/dev/null \
    || fail "authentik-worker does not use the same image as authentik-server"
  jq -e '.services["authentik-server"].command == ["server"] and .services["authentik-worker"].command == ["worker"]' <<<"$FULL" >/dev/null \
    || fail "authentik-server/worker commands are not server/worker"
  jq -e '.services["authentik-db"].image | test("^postgres:[0-9]+\\.[0-9]+-alpine$")' <<<"$FULL" >/dev/null \
    || fail "authentik-db image is not an exact postgres:<x.y>-alpine tag"
  jq -e '.services["authentik-db"].environment.POSTGRES_PASSWORD_FILE == "/run/secrets/authentik_pg_password"
    and (.services["authentik-db"].environment | has("POSTGRES_PASSWORD") | not)' <<<"$FULL" >/dev/null \
    || fail "authentik-db does not take its password from the authentik_pg_password secret"
  for s in authentik-server authentik-worker; do
    jq -e --arg s "$s" '.services[$s].environment
      | .AUTHENTIK_SECRET_KEY == "file:///run/secrets/authentik_secret_key"
        and .AUTHENTIK_POSTGRESQL__PASSWORD == "file:///run/secrets/authentik_pg_password"
        and .AUTHENTIK_POSTGRESQL__HOST == "authentik-db"
        and (.DOMAIN | length > 0)
        and (has("AUTHENTIK_BOOTSTRAP_PASSWORD") | not)' <<<"$FULL" >/dev/null \
      || fail "$s environment is not as specified (secrets via file://, no inline bootstrap password)"
    # The bootstrap password is read with a raw getenv, so it is loaded from the
    # secret by the entrypoint wrapper, never set as a file:// string.
    jq -e --arg s "$s" '.services[$s].entrypoint | join(" ") | contains("cat /run/secrets/authentik_bootstrap_password")' <<<"$FULL" >/dev/null \
      || fail "$s entrypoint does not load the bootstrap password from its secret"
    jq -e --arg s "$s" '.services[$s].depends_on["authentik-db"].condition == "service_healthy"' <<<"$FULL" >/dev/null \
      || fail "$s does not wait for a healthy authentik-db"
    jq -e --arg s "$s" '.services[$s].volumes | any(.target == "/blueprints/custom" and .read_only == true)' <<<"$FULL" >/dev/null \
      || fail "$s does not mount the blueprints read-only at /blueprints/custom"
    jq -e --arg s "$s" '.services[$s].volumes | map(.source) | all(test("docker\\.sock") | not)' <<<"$FULL" >/dev/null \
      || fail "$s mounts docker.sock"
  done
  ok "authentik services: pinned, no ports, secrets via files, bootstrap password from its secret"
}

test_blueprints() {
  local f bp="$REPO/config/authentik/blueprints"
  for f in 10-admins-mfa 20-forward-auth 30-invitation-enrollment; do
    [[ -f "$bp/$f.yaml" ]] || fail "missing blueprint $f.yaml"
    grep -q '^version: 1$' "$bp/$f.yaml" || fail "$f.yaml lacks 'version: 1'"
  done
  if grep -RInE '(password|secret|token)["]?:[[:space:]]*[A-Za-z0-9]{12,}' "$bp" >/dev/null; then
    fail "a blueprint has a secret-looking value" "$(grep -RInE '(password|secret|token)["]?:[[:space:]]*[A-Za-z0-9]{12,}' "$bp")"
  fi
  if grep -RIn 'example\.com' "$bp" >/dev/null; then
    fail "a blueprint hard-codes a domain (use !Env DOMAIN)"
  fi
  grep -q 'mode: forward_domain' "$bp/20-forward-auth.yaml" || fail "20-forward-auth is not forward_domain"
  grep -q 'not_configured_action: configure' "$bp/10-admins-mfa.yaml" || fail "10-admins-mfa does not configure missing MFA"
  grep -q 'continue_flow_without_invitation: false' "$bp/30-invitation-enrollment.yaml" \
    || fail "30-invitation-enrollment lets users in without an invitation"
  ok "blueprints: version 1, no secret-looking values, DOMAIN only via !Env"
}

# ==============================================================================
# CrowdSec and geo-block (plan 03-03)
# ==============================================================================
test_plugins_pinned() {
  local cmd
  cmd="$(jq -r '.services.traefik.command[]' <<<"$FULL")"
  grep -qx -- '--experimental.plugins.crowdsec.moduleName=github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin' <<<"$cmd" \
    || fail "crowdsec bouncer plugin moduleName is missing or wrong"
  grep -qx -- '--experimental.plugins.geoblock.moduleName=github.com/PascalMinder/geoblock' <<<"$cmd" \
    || fail "geoblock plugin moduleName is missing or wrong"
  grep -qE -- '^--experimental\.plugins\.crowdsec\.version=v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$cmd" \
    || fail "crowdsec plugin version is not a v-prefixed release (no latest, no pre-release)"
  grep -qE -- '^--experimental\.plugins\.geoblock\.version=v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$cmd" \
    || fail "geoblock plugin version is not a v-prefixed release (no latest, no pre-release)"
  jq -e '.services.traefik.volumes | any(.target == "/plugins-storage" and (.read_only // false) == false)' <<<"$FULL" >/dev/null \
    || fail "traefik has no writable /plugins-storage volume"
  jq -e '.services.traefik.secrets | any(.source == "crowdsec_bouncer_key")' <<<"$FULL" >/dev/null \
    || fail "traefik does not mount the crowdsec_bouncer_key secret"
  ok "plugins pinned to v-prefixed releases; writable /plugins-storage; bouncer key mounted"
}

test_plugin_middlewares() {
  jq -e '.services.traefik.labels
    | .["traefik.http.middlewares.crowdsec.plugin.crowdsec.enabled"] == "true"
      and .["traefik.http.middlewares.crowdsec.plugin.crowdsec.crowdsecMode"] == "stream"
      and .["traefik.http.middlewares.crowdsec.plugin.crowdsec.updateIntervalSeconds"] == "15"
      and .["traefik.http.middlewares.crowdsec.plugin.crowdsec.crowdsecLapiHost"] == "crowdsec:8080"
      and .["traefik.http.middlewares.crowdsec.plugin.crowdsec.crowdsecLapiKeyFile"] == "/run/secrets/crowdsec_bouncer_key"
      and (.["traefik.http.middlewares.crowdsec.plugin.crowdsec.clientTrustedIPs"] | length > 0)
      and (has("traefik.http.middlewares.crowdsec.plugin.crowdsec.crowdsecLapiKey") | not)' <<<"$FULL" >/dev/null \
    || fail "crowdsec middleware labels are not as specified (stream mode, key from the secret file)"
  jq -e '.services.traefik.labels
    | .["traefik.http.middlewares.geoblock.plugin.geoblock.allowLocalRequests"] == "true"
      and .["traefik.http.middlewares.geoblock.plugin.geoblock.allowUnknownCountries"] == "false"
      and .["traefik.http.middlewares.geoblock.plugin.geoblock.blacklist"] == "false"
      and (.["traefik.http.middlewares.geoblock.plugin.geoblock.api"] | test("^https://.*\\{ip\\}"))
      and (.["traefik.http.middlewares.geoblock.plugin.geoblock.cacheSize"] | tonumber > 1)
      and (.["traefik.http.middlewares.geoblock.plugin.geoblock.countries"] | test("^[A-Z]{2}(,[A-Z]{2})*$"))' <<<"$FULL" >/dev/null \
    || fail "geoblock middleware labels are not as specified (fail closed, comma list of ISO codes)"
  ok "crowdsec (stream, key file) and geoblock (fail closed, countries from GEO_ALLOWED_COUNTRIES) middlewares"
}

test_crowdsec_service() {
  jq -e '.services.crowdsec | (.ports // []) | length == 0' <<<"$FULL" >/dev/null || fail "crowdsec publishes ports"
  jq -e '.services.crowdsec.networks | keys == ["crowdsec"]' <<<"$FULL" >/dev/null \
    || fail "crowdsec is on a network other than crowdsec"
  jq -e '.services.traefik.networks | has("crowdsec")' <<<"$FULL" >/dev/null || fail "traefik is not on the crowdsec network"
  local others
  others="$(jq -r '[.services | to_entries[] | select(.value.networks // {} | has("crowdsec"))
    | .key | select(. != "crowdsec" and . != "traefik")] | join(",")' <<<"$FULL")"
  [[ -z "$others" ]] || fail "unexpected services on the crowdsec network: $others"
  jq -e '.networks.crowdsec.driver == "bridge" and .networks.crowdsec.name == "crowdsec"' <<<"$FULL" >/dev/null \
    || fail "network crowdsec is not a bridge named crowdsec"
  jq -e '.services.crowdsec.image | test("^crowdsecurity/crowdsec:v[0-9]+\\.[0-9]+\\.[0-9]+$")' <<<"$FULL" >/dev/null \
    || fail "crowdsec image is not an exact release tag"
  jq -e '.services.crowdsec.environment.COLLECTIONS | (contains("crowdsecurity/traefik") and contains("crowdsecurity/http-cve") and contains("crowdsecurity/base-http-scenarios"))' <<<"$FULL" >/dev/null \
    || fail "crowdsec COLLECTIONS lacks traefik, http-cve or base-http-scenarios"
  jq -e '.services.crowdsec.secrets | any(.source == "crowdsec_bouncer_key" and (.target | startswith("bouncer_key_")))' <<<"$FULL" >/dev/null \
    || fail "crowdsec_bouncer_key is not mounted as /run/secrets/bouncer_key_<name> (the image registers the bouncer from it)"
  jq -e '.services.crowdsec.volumes
    | any(.target == "/var/log/traefik" and .read_only == true)
      and any(.target == "/etc/crowdsec/acquis.yaml" and .read_only == true)
      and any(.target == "/var/lib/crowdsec/data")' <<<"$FULL" >/dev/null \
    || fail "crowdsec volumes: traefik logs and acquis.yaml must be read-only, data must persist"
  jq -e '.services.crowdsec.healthcheck.test | join(" ") | contains("cscli lapi status")' <<<"$FULL" >/dev/null \
    || fail "crowdsec healthcheck is not cscli lapi status"
  local acq="$REPO/config/crowdsec/acquis.yaml" lr="$REPO/config/logrotate/traefik-access"
  grep -q 'type: traefik' "$acq" || fail "config/crowdsec/acquis.yaml does not label the source type: traefik"
  grep -q '/var/log/traefik/access.log' "$acq" || fail "config/crowdsec/acquis.yaml does not read the Traefik access log"
  grep -qE '^[[:space:]]*weekly$' "$lr" || fail "config/logrotate/traefik-access is not weekly"
  grep -q 'rotate 4' "$lr" || fail "config/logrotate/traefik-access does not keep 4 rotations"
  grep -q 'copytruncate' "$lr" || fail "config/logrotate/traefik-access does not use copytruncate"
  ok "crowdsec: own network shared with traefik only, no ports, pinned, key registered from its secret, acquis and logrotate files"
}

test_no_lan_override() {
  [[ ! -e "$REPO/compose.lan.yaml" ]] || fail "compose.lan.yaml still exists"
  if grep -qE '^[[:space:]]*#?[[:space:]]*COMPOSE_FILE=' "$REPO/.env.example"; then
    fail ".env.example still has a COMPOSE_FILE line"
  fi
  grep -q '^LAN_IP=' "$REPO/.env.example" || fail ".env.example lost LAN_IP (25-arr-wire.sh needs it)"
  ok "compose.lan.yaml is gone; LAN_IP kept"
}

# ==============================================================================
# 40-edge-secrets.sh
# ==============================================================================
GENERATED=(authentik_secret_key authentik_pg_password authentik_bootstrap_password crowdsec_bouncer_key)

test_edge_secrets() {
  local d="$tmp/secrets" rc out name sums1 sums2 mode v
  [[ "$("$SECRETS_SH" --help | head -n 1)" != "" ]] || fail "40-edge-secrets.sh --help prints nothing"
  rc=0
  "$SECRETS_SH" --bogus >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 2 ]] || fail "40-edge-secrets.sh --bogus exited $rc, want 2"

  out="$(SECRETS_DIR="$d" "$SECRETS_SH" 2>&1)"
  [[ ! -e "$d" ]] || fail "secrets dry-run created $d"
  for name in "${GENERATED[@]}"; do
    grep -qx "DRY-RUN: create $name" <<<"$out" || fail "secrets dry-run lacks 'DRY-RUN: create $name'"
  done
  grep -q "^MISSING cf_dns_api_token: paste a Cloudflare API token (Zone:DNS:Edit, this zone only) into $d/cf_dns_api_token\$" <<<"$out" \
    || fail "secrets dry-run does not report cf_dns_api_token MISSING" "$out"
  ok "secrets dry-run creates nothing and reports MISSING cf_dns_api_token"

  out="$(SECRETS_DIR="$d" "$SECRETS_SH" --apply 2>&1)"
  for name in "${GENERATED[@]}"; do
    [[ -f "$d/$name" ]] || fail "secrets --apply did not create $name"
    mode="$(stat -c %a "$d/$name")"
    [[ "$mode" == 400 ]] || fail "$name has mode $mode, want 400"
    [[ "$(stat -c %s "$d/$name")" -eq 48 ]] || fail "$name is not 48 bytes"
    grep -qE '^[A-Za-z0-9]{48}$' "$d/$name" || fail "$name is not 48 alphanumeric characters"
  done
  [[ ! -e "$d/cf_dns_api_token" ]] || fail "secrets --apply created cf_dns_api_token"
  grep -q '^MISSING cf_dns_api_token' <<<"$out" || fail "secrets --apply does not report cf_dns_api_token MISSING"
  ok "secrets --apply creates the four generated files at mode 400"

  sums1="$(cd "$d" && sha256sum -- "${GENERATED[@]}")"
  local out2
  out2="$(SECRETS_DIR="$d" "$SECRETS_SH" --apply 2>&1)"
  sums2="$(cd "$d" && sha256sum -- "${GENERATED[@]}")"
  [[ "$sums1" == "$sums2" ]] || fail "a second --apply changed a secret"
  for name in "${GENERATED[@]}"; do
    grep -qx "KEEP $name (exists)" <<<"$out2" || fail "second --apply lacks 'KEEP $name (exists)'"
  done
  ok "a second --apply keeps the secrets byte-identical"

  for name in "${GENERATED[@]}"; do
    v="$(cat "$d/$name")"
    if grep -qF -- "$v" <<<"$out$out2"; then
      fail "the value of $name appeared in the script output"
    fi
  done
  ok "no secret value appears in the output"
}

# ==============================================================================
# verify-edge.sh
# ==============================================================================
VERIFY_IDS=(edge-healthy edge-ports no-docker-sock int-chains cert-wildcard
            ddns-records int-lan-only public-routes secure-headers
            authentik-healthy auth-public authentik-admin-lan int-forward-auth authentik-mfa
            crowdsec-healthy crowdsec-bouncer crowdsec-acquis public-chain no-lan-override
            crowdsec-ban)

test_verify_edge() {
  local out id n rc bin="$tmp/stubbin"
  out="$("$VERIFY_SH" --help)" || fail "verify-edge.sh --help exited non-zero"
  for id in "${VERIFY_IDS[@]}"; do
    grep -qF -- "$id" <<<"$out" || fail "verify-edge.sh --help does not list $id"
  done
  ok "verify-edge.sh --help exits 0 and lists all ${#VERIFY_IDS[@]} check IDs"

  # A docker that fails if called: with SKIP_NET=1 no check may need it.
  mkdir -p "$bin"
  printf '#!/bin/sh\necho "stub docker called: $*" >&2\nexit 1\n' >"$bin/docker"
  chmod +x "$bin/docker"
  out="$(PATH="$bin:$PATH" SKIP_NET=1 DOMAIN=example.com LAN_CIDR=192.168.1.0/24 "$VERIFY_SH")" \
    || fail "verify-edge.sh with SKIP_NET=1 exited non-zero" "$out"
  n="$(grep -cE '^(PASS|FAIL|SKIP) ' <<<"$out")"
  [[ "$n" -eq 20 ]] || fail "verify-edge.sh printed $n result lines, want 20" "$out"
  for id in "${VERIFY_IDS[@]}"; do
    grep -qE "^(PASS|SKIP) $id " <<<"$out" || fail "verify-edge.sh has no PASS/SKIP line for $id" "$out"
  done
  tail -n 1 <<<"$out" | grep -qE '^RESULT: [0-9]+ pass, 0 fail, [0-9]+ skip$' \
    || fail "verify-edge.sh RESULT line has failures" "$out"
  grep -qx 'SKIP crowdsec-ban SKIP_NET=1\|SKIP crowdsec-ban run with --ban-test' <<<"$out" \
    || fail "crowdsec-ban is not skipped without --ban-test" "$out"
  out="$(PATH="$bin:$PATH" SKIP_NET=1 DOMAIN=example.com LAN_CIDR=192.168.1.0/24 "$VERIFY_SH" --ban-test)" \
    || fail "verify-edge.sh --ban-test with SKIP_NET=1 exited non-zero" "$out"
  [[ "$(grep -cE '^(PASS|FAIL|SKIP) ' <<<"$out")" -eq 20 ]] || fail "verify-edge.sh --ban-test did not print 20 result lines" "$out"
  rc=0
  "$VERIFY_SH" --bogus >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 2 ]] || fail "verify-edge.sh --bogus exited $rc, want 2"
  ok "verify-edge.sh SKIP_NET=1: 20 result lines, RESULT with 0 fail; --ban-test accepted"
}

# ==============================================================================
# Test list.
# ==============================================================================
TESTS=(
  test_int_routes_use_int_chain
  test_only_seerr_is_public
  test_chains
  test_published_ports
  test_traefik_hardening
  test_socket_proxy
  test_ddns
  test_acme_dns01
  test_secret_paths
  test_edge_secrets
  test_verify_edge
  test_authentik_networks
  test_auth_routers
  test_authentik_services
  test_blueprints
  test_plugins_pinned
  test_plugin_middlewares
  test_crowdsec_service
  test_no_lan_override
)

for t in "${TESTS[@]}"; do
  "$t"
done
echo "PASS: test-edge"
