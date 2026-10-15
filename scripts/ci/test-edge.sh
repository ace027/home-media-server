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
  [[ "$others" == "auth-admin-api=lan-admin@docker,auth-admin=lan-admin@docker,auth-public-api=public-auth@docker,auth=public-auth@docker,seerr=public@docker" ]] \
    || fail "routers not using int@docker: '$others' (want only auth-admin and auth-admin-api=lan-admin@docker, auth and auth-public-api=public-auth@docker, seerr=public@docker)"
  jq -e '.services.seerr.labels["traefik.http.routers.seerr.rule"] | test("^Host\\(`requests\\.[^`]+`\\)$")' <<<"$FULL" >/dev/null \
    || fail "seerr rule is not Host(\`requests.<domain>\`)"
  jq -e '.services.traefik.labels["traefik.http.routers.dashboard.rule"] | test("^Host\\(`traefik\\.int\\.[^`]+`\\)$")' <<<"$FULL" >/dev/null \
    || fail "dashboard rule is not Host(\`traefik.int.<domain>\`)"
  jq -e '.services.traefik.labels["traefik.http.routers.dashboard.service"] == "api@internal"' <<<"$FULL" >/dev/null \
    || fail "dashboard router service is not api@internal"
  ok "only seerr (public), auth and auth-public-api (public-auth) are internet-facing (auth-admin, auth-admin-api on lan-admin); the dashboard is on traefik.int"
}

test_chains() {
  jq -e '.services.traefik.labels
    | .["traefik.http.middlewares.int.chain.middlewares"] == "lan-only,secure-headers,authentik"
      and .["traefik.http.middlewares.lan-admin.chain.middlewares"] == "lan-only,secure-headers"
      and .["traefik.http.middlewares.public.chain.middlewares"] == "crowdsec,geoblock,rate-limit,secure-headers"
      and .["traefik.http.middlewares.public-auth.chain.middlewares"] == "crowdsec,geoblock,auth-rate-limit,secure-headers"
      and .["traefik.http.middlewares.auth-rate-limit.ratelimit.average"] == "5"
      and .["traefik.http.middlewares.auth-rate-limit.ratelimit.burst"] == "20"
      and ([keys[] | select(test("^traefik\\.http\\.middlewares\\.auth-rate-limit\\.ratelimit\\.sourcecriterion"))] | length == 0)
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
  ok "int (lan-only, secure-headers, authentik), lan-admin, public and public-auth (auth-rate-limit 5/20 per client IP) chains"
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
      and .CLOUDFLARE_API_TOKEN_FILE == "/run/secrets/cf_ddns_api_token"
      and (has("CLOUDFLARE_API_TOKEN") | not)' <<<"$FULL" >/dev/null \
    || fail "cloudflare-ddns env is not UPDATE_CRON=@every 5m, PROXIED=false, token from the cf_ddns_api_token file"
  jq -e '.services["cloudflare-ddns"].environment.DOMAINS | split(",")
    | length == 3 and (.[0] | test("^plex\\.")) and (.[1] | test("^requests\\.")) and (.[2] | test("^auth\\."))' <<<"$FULL" >/dev/null \
    || fail "cloudflare-ddns DOMAINS is not plex, requests, auth"
  jq -e '.services["cloudflare-ddns"].secrets | map(.source) == ["cf_ddns_api_token"]' <<<"$FULL" >/dev/null \
    || fail "cloudflare-ddns must mount only the cf_ddns_api_token secret (not Traefik's cf_dns_api_token)"
  jq -e '.services.traefik.secrets | map(.source) | index("cf_ddns_api_token") | not' <<<"$FULL" >/dev/null \
    || fail "traefik mounts cf_ddns_api_token (it must use only cf_dns_api_token)"
  ok "cloudflare-ddns: every 5m, not proxied, plex/requests/auth, its own cf_ddns_api_token"
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
  # ACME_CASERVER as Compose resolved it (from .env or the environment; Compose strips
  # quotes); quotes are stripped again in case a value kept them.
  ca="$(docker compose -f compose.yaml config --environment 2>/dev/null | sed -n 's/^ACME_CASERVER=//p' | tail -n 1)" || ca=""
  ca="${ca#[\"\']}"
  ca="${ca%[\"\']}"
  [[ -n "$ca" ]] || fail "ACME_CASERVER is not set (add it to .env from .env.example)"
  [[ "$ca" =~ ^https://acme(-staging)?-v02\.api\.letsencrypt\.org/directory$ ]] \
    || fail "ACME_CASERVER '$ca' is not a Let's Encrypt staging or production directory"
  grep -qxF -- "--certificatesresolvers.cloudflare.acme.caServer=$ca" <<<"$cmd" \
    || fail "acme caServer does not follow ACME_CASERVER ($ca)" "$(grep caServer <<<"$cmd")"
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

test_acme_staging_default() {
  local active
  active="$(sed -n 's/^ACME_CASERVER=//p' .env.example)"
  [[ "$active" == "https://acme-staging-v02.api.letsencrypt.org/directory" ]] \
    || fail ".env.example's active ACME_CASERVER is '$active', want the Let's Encrypt staging URL"
  [[ "$(grep -c '^ACME_CASERVER=' .env.example)" -eq 1 ]] || fail ".env.example has more than one active ACME_CASERVER"
  grep -qE '^#.*acme\.json' .env.example || fail ".env.example does not say to delete acme.json when switching to production"
  grep -qE '^# ACME_CASERVER=https://acme-v02\.api\.letsencrypt\.org/directory$' .env.example \
    || fail ".env.example lacks the commented production ACME_CASERVER"
  ok ".env.example starts on Let's Encrypt staging, production commented with the acme.json note"
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
  local n
  for n in cf_dns_api_token cf_ddns_api_token; do
    jq -e --arg p "$REPO/secrets/$n" --arg n "$n" '.secrets[$n].file == $p' <<<"$FULL" >/dev/null \
      || fail "$n secret does not resolve to <repo>/secrets/$n"
  done
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
      and .["traefik.http.routers.auth.middlewares"] == "public-auth@docker"
      and .["traefik.http.routers.auth.service"] == "authentik"
      and .["traefik.http.services.authentik.loadbalancer.server.port"] == "9000"' <<<"$FULL" >/dev/null \
    || fail "auth router is not Host(auth.<domain>) -> public-auth@docker -> authentik:9000"
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
  ok "auth is public-auth without forward-auth; auth-admin (/if/admin) is lan-admin with priority 100"
}

# Authentik API exposure (fail closed). "<method> <path>" probes: AK_API_PUBLIC must be
# matched by the auth-public-api allowlist (flows and the user interface need them);
# AK_API_LAN must not be (they fall to auth-admin-api, LAN only). Derived from the
# 2026.8.3 web bundle, see the comment on the routers in stacks/edge.yaml.
AK_API_PUBLIC=("GET /api/v3/root/config/" "GET /api/v3/admin/version/" "GET /api/v3/core/brands/current/"
  "GET /api/v3/core/users/me/" "GET /api/v3/core/users/impersonate_end/" "GET /api/v3/core/applications/"
  "GET /api/v3/core/tokens/" "GET /api/v3/core/user_consent/" "GET /api/v3/core/user_consent/3/used_by/"
  "DELETE /api/v3/core/user_consent/3/" "GET /api/v3/core/authenticated_sessions/"
  "DELETE /api/v3/core/authenticated_sessions/5e1b2c3d-1111-2222-3333-444455556666/"
  "GET /api/v3/authenticators/all/" "PUT /api/v3/authenticators/totp/3/" "DELETE /api/v3/authenticators/webauthn/3/"
  "DELETE /api/v3/authenticators/static/3/" "GET /api/v3/stages/all/user_settings/"
  "GET /api/v3/sources/all/user_settings/" "GET /api/v3/sources/user_connections/all/"
  "GET /api/v3/events/notifications/" "POST /api/v3/events/notifications/mark_all_seen/"
  "PATCH /api/v3/events/notifications/5e1b2c3d-1111-2222-3333-444455556666/"
  "GET /api/v3/enterprise/license/summary/" "GET /api/v3/flows/executor/default-authentication-flow/"
  "POST /api/v3/flows/executor/invitation-enrollment/" "POST /api/v3/flows/executor/default-recovery-flow/")
AK_API_LAN=("GET /api/v3/policies/all/" "GET /api/v3/flows/instances/" "POST /api/v3/flows/instances/import_flow/"
  "GET /api/v3/flows/instances/x/export/" "GET /api/v3/flows/instances/x/" "POST /api/v3/core/tokens/"
  "PUT /api/v3/core/tokens/abc/" "GET /api/v3/core/tokens/abc/view_key/" "DELETE /api/v3/core/tokens/abc/"
  "POST /api/v3/core/applications/" "PUT /api/v3/core/applications/x/" "GET /api/v3/core/applications/x/"
  "GET /api/v3/core/brands/" "POST /api/v3/core/brands/" "GET /api/v3/core/users/"
  "POST /api/v3/core/users/7/set_password/" "POST /api/v3/core/users/switch/"
  "POST /api/v3/core/users/account_lockdown/" "GET /api/v3/newthing/" "GET /api/v3/" "GET /api/v3/schema/"
  "GET /api/v3/admin/system/" "GET /api/v3/flows/inspector/x/" "GET /api/v3/agents/agents/"
  "GET /api/v3/root/config" "DELETE /api/v3/flows/executor/x/" "PUT /api/v3/authenticators/totp/abc/"
  "GET /api/v3/authenticators/admin/all/" "GET /api/v3/stages/authenticator/totp/" "GET /api/v3/managed/blueprints/"
  "HEAD /api/v3/root/config/")

test_auth_api_routers() {
  local labels pub adm pairs probe m p n_pub=0 n_lan=0
  labels="$(jq '.services["authentik-server"].labels' <<<"$FULL")"
  jq -e '(.["traefik.http.routers.auth-public-api.priority"] | tonumber) > (.["traefik.http.routers.auth-admin-api.priority"] | tonumber)
      and (.["traefik.http.routers.auth-admin-api.priority"] | tonumber) > (.["traefik.http.routers.auth-admin.priority"] | tonumber)
      and (has("traefik.http.routers.auth.priority") | not)
      and .["traefik.http.routers.auth-public-api.middlewares"] == "public-auth@docker"
      and .["traefik.http.routers.auth-admin-api.middlewares"] == "lan-admin@docker"
      and .["traefik.http.routers.auth-public-api.service"] == "authentik"
      and .["traefik.http.routers.auth-admin-api.service"] == "authentik"' <<<"$labels" >/dev/null \
    || fail "auth API routers: want auth-public-api (public-auth) > auth-admin-api (lan-admin) > auth-admin priority, auth unset"
  # docker compose config re-escapes \$ as \$\$; the container label has a single \$.
  adm="$(jq -r '.["traefik.http.routers.auth-admin-api.rule"]' <<<"$labels")"
  adm="${adm//\$\$/\$}"
  [[ "$adm" =~ ^Host\(\`auth\.[^\`]+\`\)\ \&\&\ PathRegexp\(\`\^/api\(/\|\$\)\`\)$ ]] \
    || fail "auth-admin-api must cover all of /api/ (Host(auth.<domain>) && PathRegexp(^/api(/|\$)))" "$adm"
  pub="$(jq -r '.["traefik.http.routers.auth-public-api.rule"]' <<<"$labels")"
  pub="${pub//\$\$/\$}"
  [[ "$pub" =~ ^Host\(\`auth\.[^\`]+\`\)\ \&\&\ \( ]] || fail "auth-public-api rule does not start with Host(auth.<domain>) && (" "$pub"
  # Every alternative must be Method(...) && PathRegexp(^/api/v3/...$): nothing else, so
  # the allowlist cannot grow a method-less or unanchored branch.
  # shellcheck disable=SC2016 # backticks are literal Traefik rule syntax
  pairs="$(grep -oE 'Method\(`[A-Z]+`\) && PathRegexp\(`[^`]+`\)' <<<"$pub" | sed -E 's/^Method\(`([A-Z]+)`\) && PathRegexp\(`([^`]+)`\)$/\1 \2/')"
  [[ "$(grep -o 'PathRegexp(' <<<"$pub" | wc -l)" -eq "$(grep -c . <<<"$pairs")" ]] \
    || fail "auth-public-api has a PathRegexp without a Method()" "$pub"
  if grep -vqE '^[A-Z]+ \^/api/v3/.*\$$' <<<"$pairs"; then
    fail "auth-public-api has a regex not anchored as ^/api/v3/...\$" "$pairs"
  fi
  # matches <method> <path>: does any (method, regex) pair of the allowlist match?
  matches() {
    jq -Rn --arg m "$1" --arg p "$2" '[inputs | capture("^(?<m>[A-Z]+) (?<re>.+)$") | select(.m == $m) | .re]
      | any(. as $re | $p | test($re))' <<<"$pairs" | grep -qx true
  }
  for probe in "${AK_API_PUBLIC[@]}"; do
    read -r m p <<<"$probe"
    matches "$m" "$p" || fail "auth-public-api does not allow $m $p (flows or the user interface need it)"
    n_pub=$((n_pub + 1))
  done
  for probe in "${AK_API_LAN[@]}"; do
    read -r m p <<<"$probe"
    if matches "$m" "$p"; then
      fail "auth-public-api makes $m $p public (it must stay LAN-only)"
    fi
    jq -en --arg p "$p" '$p | test("^/api(/|$)")' >/dev/null || fail "auth-admin-api does not cover $p"
    n_lan=$((n_lan + 1))
  done
  ok "Authentik API fails closed: /api/ LAN-only, allowlist passes $n_pub flow/user calls and refuses $n_lan admin or unlisted ones"
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
test_plugins_local() {
  local cmd lock="$REPO/config/traefik/plugins.lock" want got
  [[ -f "$lock" ]] || fail "missing config/traefik/plugins.lock"
  # Every non-comment line: <name> <module> <tag vX.Y.Z> <40-hex commit>.
  if grep -vqE '^[a-z][a-z0-9-]* [A-Za-z0-9.-]+(/[A-Za-z0-9_.-]+)+ v[0-9]+\.[0-9]+\.[0-9]+ [0-9a-f]{40}$' \
      <<<"$(grep -vE '^[[:space:]]*(#|$)' "$lock" || true)"; then
    fail "plugins.lock has a malformed line (want '<name> <module> <vX.Y.Z> <40-hex sha>')"
  fi
  want="$(grep -vE '^[[:space:]]*(#|$)' "$lock" | awk '{print "--experimental.localPlugins." $1 ".moduleName=" $2}' | sort)"
  [[ -n "$want" ]] || fail "plugins.lock lists no plugins"
  cmd="$(jq -r '.services.traefik.command[]' <<<"$FULL")"
  got="$(grep -E -- '^--experimental\.localPlugins\.' <<<"$cmd" | sort)" || got=""
  [[ "$got" == "$want" ]] || fail "traefik localPlugins flags do not match plugins.lock" "want:
$want
got:
$got"
  if grep -qE -- '^--experimental\.plugins\.' <<<"$cmd"; then
    fail "traefik still has catalog (--experimental.plugins.*) flags; plugins must be local"
  fi
  jq -e '.services.traefik.volumes | any(.target == "/plugins-local" and .read_only == true)
    and all(.target != "/plugins-storage")' <<<"$FULL" >/dev/null \
    || fail "traefik must mount /plugins-local read-only and no /plugins-storage"
  jq -e '.services.traefik.secrets | any(.source == "crowdsec_bouncer_key")' <<<"$FULL" >/dev/null \
    || fail "traefik does not mount the crowdsec_bouncer_key secret"
  ok "plugins: local only, exactly the plugins.lock modules, /plugins-local read-only; bouncer key mounted"
}

test_traefik_depends_on() {
  jq -e '.services.traefik.depends_on
    | .crowdsec.condition == "service_healthy" and .["socket-proxy"].condition == "service_started"' <<<"$FULL" >/dev/null \
    || fail "traefik depends_on is not crowdsec: service_healthy, socket-proxy: service_started"
  ok "traefik waits for a healthy crowdsec and a started socket-proxy"
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
  jq -e '.services.crowdsec.environment.COLLECTIONS | split(" ")
    | index("crowdsecurity/traefik") and index("crowdsecurity/http-cve")
      and index("crowdsecurity/base-http-scenarios")' <<<"$FULL" >/dev/null \
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
  grep -qE '^[[:space:]]*rotate 2$' "$lr" || fail "config/logrotate/traefik-access does not keep 2 rotations"
  grep -q 'copytruncate' "$lr" || fail "config/logrotate/traefik-access does not use copytruncate"
  grep -qE '^[[:space:]]*su [0-9]+ [0-9]+$' "$lr" || fail "config/logrotate/traefik-access has no 'su <uid> <gid>'"
  grep -qE '^[[:space:]]*create 0640 [0-9]+ [0-9]+$' "$lr" || fail "config/logrotate/traefik-access has no 'create 0640 <uid> <gid>'"
  ok "crowdsec: own network shared with traefik only, no ports, pinned, key registered from its secret, acquis and logrotate files"
}

test_mkdirs_edge() {
  local d="$tmp/mkdirs" mode
  DATA_ROOT="$d/data" APPDATA_ROOT="$d/appdata" "$REPO/scripts/mkdirs.sh" >/dev/null 2>&1 || fail "mkdirs.sh failed"
  mode="$(stat -c %a "$d/appdata/traefik/logs")"
  [[ "$mode" =~ ^[0-7]?750$ ]] || fail "traefik/logs has mode $mode, want 0750 (no group write)"
  [[ -d "$d/appdata/traefik/plugins-local" ]] || fail "mkdirs.sh does not create traefik/plugins-local"
  [[ ! -e "$d/appdata/traefik/plugins-storage" ]] || fail "mkdirs.sh still creates traefik/plugins-storage"
  chmod 0775 "$d/appdata/traefik/logs"
  DATA_ROOT="$d/data" APPDATA_ROOT="$d/appdata" "$REPO/scripts/mkdirs.sh" >/dev/null 2>&1 || fail "mkdirs.sh re-run failed"
  mode="$(stat -c %a "$d/appdata/traefik/logs")"
  [[ "$mode" =~ ^[0-7]?750$ ]] || fail "a re-run does not reset traefik/logs to 0750 (mode $mode)"
  grep -q 'su 1000 1000' "$REPO/config/logrotate/traefik-access" \
    || fail "logrotate su line is not the documented default PUID/PGID 1000 1000"
  ok "mkdirs: traefik/logs 0750 (reset on re-run), plugins-local, no plugins-storage"
}

test_invitation_password_policy() {
  local f="$REPO/config/authentik/blueprints/30-invitation-enrollment.yaml"
  grep -qE '^[[:space:]]+length_min: 12$' "$f" || fail "invitation password policy length_min is not 12"
  grep -qE '^[[:space:]]+check_zxcvbn: true$' "$f" || fail "invitation password policy does not check zxcvbn"
  grep -qE '^[[:space:]]+zxcvbn_score_threshold: 2$' "$f" || fail "invitation password policy zxcvbn_score_threshold is not 2 (scores 3 and 4 pass)"
  grep -qE '^[[:space:]]+check_have_i_been_pwned: true$' "$f" || fail "invitation password policy does not check Have I Been Pwned"
  ok "invitation password policy: length 12, zxcvbn threshold 2 (scores 3-4 pass), Have I Been Pwned"
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
  grep -qxF "MISSING cf_dns_api_token: paste a Cloudflare API token (Zone:Zone:Read and Zone:DNS:Edit, this zone only; Traefik ACME DNS-01) into $d/cf_dns_api_token" <<<"$out" \
    || fail "secrets dry-run does not report cf_dns_api_token MISSING with Zone:Read + DNS:Edit" "$out"
  grep -qxF "MISSING cf_ddns_api_token: paste a Cloudflare API token (Zone:Zone:Read and Zone:DNS:Edit, this zone only; cloudflare-ddns) into $d/cf_ddns_api_token" <<<"$out" \
    || fail "secrets dry-run does not report cf_ddns_api_token MISSING with Zone:Read + DNS:Edit" "$out"
  out="$("$SECRETS_SH" --help)"
  if ! grep -q 'cf_ddns_api_token' <<<"$out" || ! grep -q 'Zone:Zone:Read and Zone:DNS:Edit' <<<"$out" \
      || ! grep -qi 'Client IP Address Filtering' <<<"$out"; then
    fail "40-edge-secrets.sh --help does not describe both tokens, their permissions and the IP-filter caveat"
  fi
  ok "secrets dry-run creates nothing and reports both Cloudflare tokens MISSING (Zone:Read + DNS:Edit)"

  out="$(SECRETS_DIR="$d" "$SECRETS_SH" --apply 2>&1)"
  for name in "${GENERATED[@]}"; do
    [[ -f "$d/$name" ]] || fail "secrets --apply did not create $name"
    mode="$(stat -c %a "$d/$name")"
    [[ "$mode" == 400 ]] || fail "$name has mode $mode, want 400"
    [[ "$(stat -c %s "$d/$name")" -eq 48 ]] || fail "$name is not 48 bytes"
    grep -qE '^[A-Za-z0-9]{48}$' "$d/$name" || fail "$name is not 48 alphanumeric characters"
  done
  for name in cf_dns_api_token cf_ddns_api_token; do
    [[ ! -e "$d/$name" ]] || fail "secrets --apply created $name"
    grep -q "^MISSING $name: " <<<"$out" || fail "secrets --apply does not report $name MISSING"
  done
  [[ -z "$(find "$d" -name '.*' -type f)" ]] || fail "secrets --apply left temporary files behind" "$(ls -la "$d")"
  ok "secrets --apply creates the four generated files at mode 400 (no temp files left)"

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

  # F-13: a truncated, symlinked or non-file secret is reported INVALID, never kept or
  # overwritten, and the run exits non-zero.
  local e="$tmp/secrets-invalid" rc before
  mkdir -p "$e"
  printf 'short' >"$e/authentik_secret_key"
  ln -s /dev/null "$e/authentik_pg_password"
  mkdir "$e/authentik_bootstrap_password"
  : >"$e/cf_dns_api_token"
  printf 'cf-token-placeholder' >"$e/cf_ddns_api_token"
  snap() {
    (cd "$e" && stat -c '%n %F %s %Y %a' authentik_secret_key authentik_pg_password \
      authentik_bootstrap_password cf_dns_api_token cf_ddns_api_token \
      && cat authentik_secret_key cf_ddns_api_token)
  }
  before="$(snap)"
  for mode in "" --apply; do
    rc=0
    out="$(SECRETS_DIR="$e" "$SECRETS_SH" $mode 2>&1)" || rc=$?
    [[ $rc -ne 0 ]] || fail "secrets ${mode:-dry-run} exited 0 with invalid files" "$out"
    grep -qx 'INVALID authentik_secret_key (5 bytes, want at least 48; remove it and re-run)' <<<"$out" \
      || fail "secrets ${mode:-dry-run} does not report the 5-byte secret INVALID" "$out"
    grep -q '^INVALID authentik_pg_password (a symlink;' <<<"$out" || fail "secrets ${mode:-dry-run} does not report the symlink INVALID" "$out"
    grep -q '^INVALID authentik_bootstrap_password (not a regular file;' <<<"$out" \
      || fail "secrets ${mode:-dry-run} does not report the directory INVALID" "$out"
    grep -q '^INVALID cf_dns_api_token (0 bytes' <<<"$out" || fail "secrets ${mode:-dry-run} does not report the empty token INVALID" "$out"
    grep -qx 'KEEP cf_ddns_api_token (exists)' <<<"$out" || fail "secrets ${mode:-dry-run} does not keep a non-empty token" "$out"
  done
  grep -qx 'CREATED crowdsec_bouncer_key' <<<"$out" || fail "secrets --apply did not create the one valid missing secret" "$out"
  [[ "$(snap)" == "$before" ]] || fail "secrets --apply touched an INVALID or kept file"
  [[ "$(readlink "$e/authentik_pg_password")" == /dev/null ]] || fail "secrets --apply replaced the symlink"
  ok "INVALID (short, symlink, directory, empty token) is reported, left untouched and exits non-zero"
}

# ==============================================================================
# verify-edge.sh
# ==============================================================================
VERIFY_IDS=(edge-healthy edge-ports no-docker-sock int-chains cert-wildcard
            ddns-records int-lan-only public-routes secure-headers
            authentik-healthy auth-public authentik-admin-lan authentik-admin-api-lan
            int-forward-auth authentik-mfa crowdsec-healthy crowdsec-bouncer crowdsec-acquis public-chain no-lan-override
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
  [[ "$n" -eq ${#VERIFY_IDS[@]} ]] || fail "verify-edge.sh printed $n result lines, want ${#VERIFY_IDS[@]}" "$out"
  for id in "${VERIFY_IDS[@]}"; do
    grep -qE "^(PASS|SKIP) $id " <<<"$out" || fail "verify-edge.sh has no PASS/SKIP line for $id" "$out"
  done
  grep -qE '^RESULT: [0-9]+ pass, 0 fail, [0-9]+ skip$' <<<"$(tail -n 1 <<<"$out")" \
    || fail "verify-edge.sh RESULT line has failures" "$out"
  grep -qx 'SKIP crowdsec-ban SKIP_NET=1\|SKIP crowdsec-ban run with --ban-test' <<<"$out" \
    || fail "crowdsec-ban is not skipped without --ban-test" "$out"
  out="$(PATH="$bin:$PATH" SKIP_NET=1 DOMAIN=example.com LAN_CIDR=192.168.1.0/24 "$VERIFY_SH" --ban-test)" \
    || fail "verify-edge.sh --ban-test with SKIP_NET=1 exited non-zero" "$out"
  [[ "$(grep -cE '^(PASS|FAIL|SKIP) ' <<<"$out")" -eq ${#VERIFY_IDS[@]} ]] || fail "verify-edge.sh --ban-test did not print ${#VERIFY_IDS[@]} result lines" "$out"
  rc=0
  "$VERIFY_SH" --bogus >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 2 ]] || fail "verify-edge.sh --bogus exited $rc, want 2"
  [[ ${#VERIFY_IDS[@]} -eq 21 ]] || fail "VERIFY_IDS has ${#VERIFY_IDS[@]} IDs, want 21"
  grep -qx 'SKIP authentik-admin-api-lan SKIP_NET=1' <<<"$(grep -A1 -x 'SKIP authentik-admin-lan SKIP_NET=1' <<<"$out" || true)" \
    || fail "authentik-admin-api-lan does not come right after authentik-admin-lan" "$out"
  ok "verify-edge.sh SKIP_NET=1: ${#VERIFY_IDS[@]} result lines, RESULT with 0 fail; --ban-test accepted"
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
  test_acme_staging_default
  test_secret_paths
  test_edge_secrets
  test_verify_edge
  test_authentik_networks
  test_auth_routers
  test_auth_api_routers
  test_invitation_password_policy
  test_authentik_services
  test_blueprints
  test_plugins_local
  test_traefik_depends_on
  test_plugin_middlewares
  test_crowdsec_service
  test_mkdirs_edge
  test_no_lan_override
)

for t in "${TESTS[@]}"; do
  "$t"
done
echo "PASS: test-edge"
