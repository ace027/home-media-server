# Runbook 04 — Edge and secure access

This runbook puts Traefik in front of the media stack on `media-01` (VM 200,
`192.168.50.16`): a wildcard Let's Encrypt certificate by DNS-01, Cloudflare
DDNS for the public names, and one HTTPS name per admin UI under
`*.int.<domain>` that only the LAN and Twingate can reach. Seerr is the only
public app route (`requests.<domain>`). Authentik, CrowdSec, the geo-block
and the removal of the temporary LAN ports follow in sections 6 to 8, and
section 9 is the final acceptance.

Run every command **inside the VM**, as `media`, from the repo checkout
(`/opt/home-media-server`), unless a step says otherwise.

Every script is a dry-run by default and changes nothing until you add
`--apply`. The "Expected output" blocks below are real output of the same
scripts run in the CI sandbox, so paths and counts on the VM will differ.
`<repo>` stands for the checkout path.

Only ports 443 and 32400 are ever forwarded from the router. Port 80 stays
closed: certificates come from DNS-01, so no HTTP challenge is needed.

## Prerequisites

- Runbook 03 is complete and `scripts/vm/verify-media.sh` has no FAIL.
- A domain on Cloudflare DNS (the free plan is enough), and access to the
  Cloudflare dashboard and your router's admin page.
- The Twingate connector in LXC 101 works (runbook 03, section 9).
- `.env` holds your real `DOMAIN`, and the VM user is in the `docker` group.
- `dig` is installed for the DDNS check: `sudo apt install dnsutils`.

## 1. Cloudflare token and DNS records

**Token.** In the Cloudflare dashboard open My Profile, API Tokens, Create
Token, "Edit zone DNS" template. Set the permission to **Zone, DNS, Edit**
and Zone Resources to **Include, Specific zone, your domain** (this zone
only; never a global key or an all-zones token). Copy it once; Cloudflare
does not show it again. Step 2 stores it in `secrets/cf_dns_api_token`.

To rotate it, create a new token the same way, overwrite the file (step 2),
run `docker compose up -d --force-recreate traefik cloudflare-ddns`, check
`scripts/vm/verify-edge.sh`, then delete the old token in Cloudflare. Rotate
it at least yearly and whenever someone who saw it leaves.

**DNS records** (all **DNS only**, grey cloud, never proxied):

| Name | Type | Content | Kept current by |
|---|---|---|---|
| `plex` | A | your WAN IP | cloudflare-ddns |
| `requests` | A | your WAN IP | cloudflare-ddns |
| `auth` | A | your WAN IP | cloudflare-ddns |
| `*.int` | A | `192.168.50.16` (the VM's LAN IP) | you, once |

Create the first three with any placeholder IP; DDNS rewrites them within
five minutes of the first start. The `*.int` record points at a private
address on purpose: the names resolve everywhere, but only the LAN and
Twingate can reach them.

## 2. Edge secrets

Create the secret files Compose mounts. The script generates the four it
can and tells you which one you must supply:

```bash
scripts/vm/40-edge-secrets.sh
```

Expected output:

```text
DRY-RUN: create authentik_secret_key
DRY-RUN: create authentik_pg_password
DRY-RUN: create authentik_bootstrap_password
DRY-RUN: create crowdsec_bouncer_key
MISSING cf_dns_api_token: paste a Cloudflare API token (Zone:DNS:Edit, this zone only) into <repo>/secrets/cf_dns_api_token
```

Apply it, then paste the token (this keeps it out of your shell history):

```bash
scripts/vm/40-edge-secrets.sh --apply
read -rs -p 'Cloudflare token: ' t && printf '%s' "$t" > secrets/cf_dns_api_token; unset t
chmod 0400 secrets/cf_dns_api_token
ls -l secrets/
```

The files must be owned by `media` with mode `-r--------`. The script never
overwrites an existing file and never prints a value, so it is safe to
re-run. Nothing under `secrets/` is committed.

## 3. Router port forwards

On the router, forward **only**:

| WAN port | To | Why |
|---|---|---|
| TCP 443 | `192.168.50.16:443` | Traefik (Seerr, and Authentik in section 6) |
| TCP 32400 | `192.168.50.16:32400` | Plex |

Remove any forward for ports 80 and 81 (the old NPM proxy). Nothing else is
forwarded.

## 4. Traefik and certificates

Set the edge variables in `.env`:

```bash
ACME_EMAIL=you@your-domain.example
LAN_CIDR=192.168.50.0/24
ACME_CASERVER=https://acme-staging-v02.api.letsencrypt.org/directory
```

`LAN_CIDR` must contain the VM, your LAN clients **and the Twingate
connector in LXC 101**, or the `*.int` routes answer 403 to Twingate users.
Keep `ACME_CASERVER` on **staging** for the first start: staging has
generous rate limits, so a typo costs nothing.

Create the directories and start the edge:

```bash
scripts/mkdirs.sh
docker compose up -d
docker compose ps traefik socket-proxy cloudflare-ddns
scripts/vm/verify-edge.sh
```

On the first start Traefik asks for `*.<domain>` and `*.int.<domain>`. Watch
it work (staging certificates are not trusted by browsers, which is
expected):

```bash
docker compose logs -f traefik
```

`cert-wildcard` prints SKIP while the certificate is a staging one. When
the log shows the certificate was obtained, switch to production:

```bash
sed -i 's#^ACME_CASERVER=.*#ACME_CASERVER=https://acme-v02.api.letsencrypt.org/directory#' .env
docker compose stop traefik
sudo rm -f /opt/appdata/traefik/acme/acme.json
docker compose up -d traefik
```

Deleting `acme.json` is required: Traefik would otherwise keep serving the
staging certificate. After a minute `scripts/vm/verify-edge.sh` should pass
every check. The dashboard is at `https://traefik.int.<domain>/` from the
LAN or Twingate.

To preview the checks without a running stack (as CI does), run:

```bash
SKIP_NET=1 DOMAIN=example.com LAN_CIDR=192.168.1.0/24 scripts/vm/verify-edge.sh
```

Expected output:

```text
SKIP edge-healthy SKIP_NET=1
SKIP edge-ports SKIP_NET=1
SKIP no-docker-sock SKIP_NET=1
SKIP int-chains SKIP_NET=1
SKIP cert-wildcard SKIP_NET=1
SKIP ddns-records SKIP_NET=1
SKIP int-lan-only SKIP_NET=1
SKIP public-routes SKIP_NET=1
SKIP secure-headers SKIP_NET=1
SKIP authentik-healthy SKIP_NET=1
SKIP auth-public SKIP_NET=1
SKIP authentik-admin-lan SKIP_NET=1
SKIP int-forward-auth SKIP_NET=1
SKIP authentik-mfa SKIP_NET=1
SKIP crowdsec-healthy SKIP_NET=1
SKIP crowdsec-bouncer SKIP_NET=1
SKIP crowdsec-acquis SKIP_NET=1
SKIP public-chain SKIP_NET=1
SKIP no-lan-override SKIP_NET=1
SKIP crowdsec-ban run with --ban-test
RESULT: 0 pass, 0 fail, 20 skip
```

The `authentik-*`, `auth-public` and `int-forward-auth` checks belong to
section 6 and the `crowdsec-*`, `public-chain` and `no-lan-override` checks
to sections 7 and 8; until those are set up they may FAIL here.
`crowdsec-ban` runs only with `--ban-test` (section 9).

## 5. Twingate resource for *.int

In the Twingate admin console, add a Resource on the Remote Network served
by the connector in LXC 101:

- Address: `*.int.<domain>`
- Protocols: TCP, ports `443`
- Access: your admin group only

Then confirm the connector's IP is inside `LAN_CIDR`. **On the Proxmox
host:**

```bash
pct exec 101 -- ip -4 -o addr show scope global
```

If its address is outside `LAN_CIDR` (a different subnet or a NAT range),
widen `LAN_CIDR` in `.env` and run `docker compose up -d traefik`. Test from
a phone off Wi-Fi with Twingate connected: `https://sonarr.int.<domain>/`
must redirect to the Authentik login at `https://auth.<domain>/` (section 6),
then load Sonarr. From a network without Twingate it must not
connect at all.

## 6. Authentik

Authentik (server, worker and its own Postgres, image
`ghcr.io/goauthentik/server:2026.8.3`) is the second gate on every admin UI:
each `*.int.<domain>` route passes the LAN allowlist, the secure headers and
then Authentik forward-auth (`int@docker` = `lan-only,secure-headers,authentik`).
Only members of the `admins` group get through, and they must use TOTP or
WebAuthn. Three blueprints in `config/authentik/blueprints/` set this up on
every start; do not change those objects by hand in the UI, the next apply
puts them back.

| Blueprint | What it does |
|---|---|
| `10-admins-mfa.yaml` | `admins` group; the default login's MFA stage asks for TOTP or WebAuthn and makes you enrol one if you have none, but only for `admins` members and superusers (policy `admins-only-mfa`) |
| `20-forward-auth.yaml` | Proxy provider `int-forward-auth` (forward auth, domain level, cookie on `<domain>`), application `admin-uis` bound to `admins` only, embedded outpost serving it at `https://auth.<domain>` |
| `30-invitation-enrollment.yaml` | Flow `invitation-enrollment`: sign-up works only with a valid invitation |

`auth.<domain>` itself is public (login pages, rate-limited by
`public@docker`), but its admin interface, `/if/admin/`, answers only the LAN
and Twingate (`lan-admin@docker`, router priority 100). Redis is not used:
since 2025.10 Authentik keeps its cache and task queue in Postgres.

### 6.1 First start and bootstrap login

Set the bootstrap admin's email in `.env` **before the first start** (the
bootstrap only runs against an empty database):

```bash
AUTHENTIK_ADMIN_EMAIL=you@your-domain.example
```

Start it and wait until all three are up (the first start runs database
migrations and takes a few minutes):

```bash
scripts/mkdirs.sh
docker compose up -d
docker compose ps authentik-server authentik-worker authentik-db
```

`authentik-server` and `authentik-db` must show `(healthy)`. Read the
bootstrap password (it never leaves `secrets/`):

```bash
cat secrets/authentik_bootstrap_password; echo
```

From the LAN or Twingate, open `https://auth.<domain>/if/admin/` and log in
as `akadmin` with that password. `akadmin` is a superuser, so Authentik asks
you to enrol an authenticator straight away: choose TOTP (an authenticator
app) or WebAuthn (a security key or passkey) and finish it.

### 6.2 Your admin account and MFA

Use a personal account day to day and keep `akadmin` for emergencies:

1. Directory, Users, Create: your username, name and email. Then Set
   password on the new user.
2. Directory, Groups, `admins`, Users tab, Add existing user: add your
   account. Do not add anyone who should not reach every admin UI.
3. Log out, log in as your account at `https://auth.<domain>/`. Authentik
   asks you to enrol TOTP or WebAuthn (`not_configured_action: configure`);
   do it. Every later login asks for it.
4. Open `https://sonarr.int.<domain>/` from the LAN or Twingate: Authentik
   asks for your login (if the session has expired), then Sonarr loads.

Users outside `admins` (family accounts in Phase 6) are never asked for MFA
and are refused on every `*.int` route.

### 6.3 Recovery

If every admin loses their password or authenticator, recover from the VM
shell (reach it from the Proxmox console if the network is down):

```bash
docker compose exec authentik-worker ak create_recovery_key 10 akadmin
```

In 2026.8 the first argument is in **minutes**: the command prints a
`/recovery/use-token/.../` path that logs in as `akadmin` for the next 10
minutes, bypassing password and MFA. Open it as
`https://auth.<domain>/recovery/use-token/.../` and fix the account.

Run it once now to prove recovery works, then let it expire. Do not create a
long-lived key to keep on paper: it is a bearer credential that skips MFA.
What you store **offline** instead is the way back to the VM shell (the
Proxmox root password and console access) and a copy of
`secrets/authentik_bootstrap_password`; with those you can always mint a new
10-minute key.

### 6.4 Check the blueprints and the outpost

In the admin interface, Customization, Blueprints: the three `Home media - ...`
blueprints must show **successful**. Or from the VM:

```bash
docker compose exec -T authentik-worker ak shell -c 'from authentik.blueprints.models import BlueprintInstance as B; [print(b.status, b.path) for b in B.objects.filter(path__startswith="custom/").order_by("path")]' 2>/dev/null | grep -E ' custom/'
```

Expected output (from a sandbox run of the same image):

```text
successful custom/10-admins-mfa.yaml
successful custom/20-forward-auth.yaml
successful custom/30-invitation-enrollment.yaml
```

The embedded outpost picks up its new provider and `authentik_host` within
five minutes. Until then `int-forward-auth` may redirect to
`http://localhost/...`; `docker compose restart authentik-server` applies it
at once.

### 6.5 Verify

```bash
scripts/vm/verify-edge.sh
```

`authentik-healthy`, `auth-public`, `authentik-admin-lan` and
`int-forward-auth` must PASS. `authentik-mfa` needs an API token and SKIPs
without one. To run it, create a token (Directory, Tokens and App passwords,
Create: intent API, user your admin account, expiring), copy it, then:

```bash
read -rs -p 'Authentik token: ' AUTHENTIK_TOKEN && export AUTHENTIK_TOKEN
scripts/vm/verify-edge.sh
unset AUTHENTIK_TOKEN
```

Delete the token afterwards. The script never prints it and does not put it
on a command line.

### 6.6 Invitations

Enrollment is invitation-only. To invite someone (family invites are done in
Phase 6):

1. Directory, Invitations, Create.
2. Name it, set Flow to `invitation-enrollment`, set an Expires date a few
   days out and tick **Single use**.
3. Open the invitation and copy its link, which has the form
   `https://auth.<domain>/if/flow/invitation-enrollment/?itoken=...`, and
   send it privately.

Without a valid `itoken` the flow stops at its first stage. Invited users are
created as `external` under `users/invited`, with no group: they are not in
`admins` and cannot open any `*.int` route.

### 6.7 Why Seerr stays on Plex login

`requests.<domain>` (Seerr) is not behind forward-auth, by the owner's
choice: family members log in with their Plex account, and Seerr is guarded by
the `public@docker` chain (rate limit and secure headers now; CrowdSec and
geo-block in section 7). Because the forward-auth provider works at domain
level, its session cookie is set on `<domain>` and the browser also sends it
to `requests.<domain>`. This is accepted: Seerr ignores it and grants nothing
for it. The residual risk is that a compromised Seerr could read an admin's
cookie from requests; the cookie alone is still useless from outside the LAN
and Twingate, because every `*.int` route also needs the `lan-only`
allowlist. Do not put Seerr behind forward-auth without revisiting this.

## 7. CrowdSec and geo-block

Every route on the `public` chain (Seerr, and `auth.<domain>` apart from
`/if/admin`) now passes four middlewares in this order: `crowdsec`,
`geoblock`, `rate-limit`, `secure-headers`.

- **CrowdSec** (`crowdsecurity/crowdsec:v1.8.1`) reads Traefik's JSON access
  log and bans abusive clients. Traefik's bouncer plugin (v1.7.1) pulls the
  ban list from it every 15 seconds and answers 403 to banned addresses.
  The engine sits on its own `crowdsec` network, shared only with Traefik,
  and publishes no port. Clients inside `LAN_CIDR` are never checked.
- **Geo-block** (plugin v0.3.8) admits only the countries in
  `GEO_ALLOWED_COUNTRIES`. Private addresses (the LAN, Docker networks)
  always pass.

**Allowed countries.** Set the ISO 3166 codes of every country you or your
family log in from, comma-separated, in `.env`:

```bash
GEO_ALLOWED_COUNTRIES=US,CA
```

**Start CrowdSec and apply the chain.** The first start downloads three hub
collections (`crowdsecurity/traefik`, `http-cve`, `base-http-scenarios`) and
the two Traefik plugins, so the VM needs internet access:

```bash
scripts/mkdirs.sh
docker compose up -d crowdsec
docker compose ps crowdsec
docker compose up -d traefik
docker compose logs --tail 30 traefik | grep -iE 'plugin|geoblock|error'
```

`crowdsec` must show `(healthy)`. Traefik is recreated because its labels
and plugin flags changed.

**Bouncer registration.** Nothing to run by hand. `secrets/crowdsec_bouncer_key`
(created by `40-edge-secrets.sh` in section 2) is mounted into the CrowdSec
container as `/run/secrets/bouncer_key_traefik-bouncer`, and the image's start
script registers the bouncer `traefik-bouncer` with that key if it is not
registered yet. Traefik reads the same file through the plugin's
`crowdsecLapiKeyFile`, so the key never appears in the Compose file, the
environment or `docker inspect`. Confirm it:

```bash
docker compose exec crowdsec cscli bouncers list
```

`traefik-bouncer` must be listed with a recent *Last API pull*. If the bouncer
cannot reach CrowdSec it fails open (traffic keeps flowing without bans);
`crowdsec-bouncer` in `verify-edge.sh` FAILs when the last pull is older than
two minutes.

**Log rotation.** Traefik does not rotate its access log, and CrowdSec reads
it. Install the logrotate rule (weekly, four rotations, compressed,
`copytruncate` so both programs keep their open file):

```bash
sudo install -m 0644 config/logrotate/traefik-access /etc/logrotate.d/traefik-access
```

The rule targets `/opt/appdata/traefik/logs/*.log`. If your `APPDATA_ROOT` is
different, edit the path in `/etc/logrotate.d/traefik-access`. Check it with
`sudo logrotate -d /etc/logrotate.d/traefik-access`.

**Check.**

```bash
scripts/vm/verify-edge.sh
```

`crowdsec-healthy`, `crowdsec-bouncer`, `crowdsec-acquis` and `public-chain`
must PASS. `crowdsec-acquis` needs at least one request since CrowdSec
started: open `https://requests.<domain>/` first.

**Geo-block privacy and outages.** The geo-block asks an external service
(`get.geojs.io`) for the country of each *new* client IP, so that service
sees the public IPs of your visitors (results are cached in memory, 1000
entries). It fails closed: with `allowUnknownCountries=false`, an address with
no country, or a lookup that fails or times out (1 second), gets 403. A
provider outage therefore blocks public access to Seerr and the Authentik
login for addresses not yet cached. See Troubleshooting for the temporary
switch.

**You are abroad.** The geo-block also covers `auth.<domain>`, and the
Authentik login for every `*.int` route is served from there, over the
internet and not through Twingate. An admin travelling outside the allowed
countries therefore gets 403 at the login, even with Twingate on. Add the
country to `GEO_ALLOWED_COUNTRIES` before you travel, or from any shell on the
VM, and recreate Traefik:

```bash
sed -i 's/^GEO_ALLOWED_COUNTRIES=.*/GEO_ALLOWED_COUNTRIES=US,CA,PT/' .env
docker compose up -d traefik
```

## 8. Remove the temporary LAN ports

Phase 2 published the admin UIs on the VM's LAN IP through a temporary
Compose override. That override no longer exists in this repository: after you
pull this version, the admin UIs are reachable **only** as
`https://<service>.int.<domain>/` through Traefik.

**First, prove the new path works**, before you remove the old one. Over
Twingate (phone off Wi-Fi, or a laptop on the Twingate client), open each of
these and confirm it redirects to the Authentik login, accepts your MFA and
then loads the app:

`sonarr`, `sonarr-anime`, `sonarr-4k`, `radarr`, `radarr-4k`, `lidarr`,
`prowlarr`, `sabnzbd`, `tautulli`, `traefik` (the dashboard), and
`jellyfin` if you run it. `https://auth.<domain>/if/admin/` must also work.

Only then remove the old ports. In `.env`, comment out (or delete) the
`COMPOSE_FILE=` line you enabled in Phase 2 (keep `LAN_IP`; `25-arr-wire.sh`
still uses it):

```bash
sed -i 's/^COMPOSE_FILE=/# COMPOSE_FILE=/' .env
grep -n 'COMPOSE_FILE' .env
git pull
docker compose up -d --remove-orphans
```

`git pull` brings this change (the deletion of the override file).
`--remove-orphans` recreates the services that had a LAN port without it.
Then check that nothing but 443 and 32400 is published:

```bash
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -- '->'
scripts/vm/verify-edge.sh
```

The only lines with `->` must be `traefik` (`443`) and `plex` (`32400`);
`edge-ports` and `no-lan-override` must PASS.

## 9. Verify

Run the full check, including the CrowdSec ban test:

```bash
scripts/vm/verify-edge.sh --ban-test
```

`--ban-test` starts a throwaway curl container on the `proxy` network, adds a
two-minute CrowdSec ban for its address, expects `requests.<domain>` to answer
403 within 30 seconds, then deletes the ban and the container. Because the
client's address is private, it passes the geo-block, so the 403 can only come
from CrowdSec. The expected result is **0 fail** (SKIPs for `cert-wildcard`
on staging certificates and for `authentik-mfa` without a token are fine).

The checks above cannot see the internet, so the owner confirms these seven
by hand and pastes the evidence into the Acceptance record:

1. **`verify-edge.sh --ban-test`** ends with `0 fail`.
2. **DDNS recovery.** In Cloudflare, change the `plex` A record to
   `192.0.2.1`. Within five minutes `dig +short plex.<domain> @1.1.1.1` must
   show your WAN IP again (`docker compose logs cloudflare-ddns` shows the
   update).
3. **Port scan from outside.** From a phone hotspot (not your LAN), scan
   your WAN IP: `nmap -Pn -p 1-1024,5055,7878,8080,8096,8181,8686,8989,9696,32400 <WAN IP>`.
   Only `443` and `32400` may be open.
4. **`*.int` without Twingate.** From the hotspot, with Twingate off:
   `curl -sk -o /dev/null -w '%{http_code}\n' --resolve sonarr.int.<domain>:443:<WAN IP> https://sonarr.int.<domain>/`
   must print `403`.
5. **MFA over Twingate.** With Twingate on, each admin UI from section 8
   redirects to Authentik and asks for your TOTP or WebAuthn code.
6. **Geo-block.** An online HTTP checker that tests from a country that is
   not in `GEO_ALLOWED_COUNTRIES` (search "check website from multiple
   countries") gets `403` from `https://requests.<domain>/`.
7. **Plex.** In Plex, Settings, Remote Access shows **Fully accessible**.

## Acceptance record

Filled in from the owner's real run on `media-01`. Nothing here comes from CI.

| Step | Evidence |
|------|----------|
| Date | <!-- owner: paste real output --> |
| 1. `scripts/vm/verify-edge.sh --ban-test`, full output ending in `RESULT: ... 0 fail` | <!-- owner: paste real output --> |
| 2. DDNS: `plex` A record set to `192.0.2.1`, back to the WAN IP within 5 minutes (`dig` output and time) | <!-- owner: paste real output --> |
| 3. Port scan of the WAN IP from the hotspot: only 443 and 32400 open | <!-- owner: paste real output --> |
| 4. `*.int.<domain>` from off-LAN without Twingate returns 403 (`curl --resolve` output) | <!-- owner: paste real output --> |
| 5. Every admin UI over Twingate redirects to Authentik and asks for MFA (list of UIs tried) | <!-- owner: paste real output --> |
| 6. HTTP check from a non-allowed country returns 403 (checker, country, result) | <!-- owner: paste real output --> |
| 7. Plex Settings, Remote Access shows Fully accessible (date, screenshot reference) | <!-- owner: paste real output --> |
| Staging to production certificate switch done (`cert-wildcard` PASS) | <!-- owner: paste real output --> |

## Rollback

**Stop the edge.** Nothing else depends on it:

```bash
docker compose stop traefik cloudflare-ddns socket-proxy crowdsec
```

The DNS records and router forwards can stay: with Traefik stopped, nothing
answers on 443. Plex on 32400 is unaffected. Restart with
`docker compose up -d`.

**Get the temporary LAN ports back** (only if Authentik or Traefik is
unusable and you need the admin UIs now). Restore the Phase 2 override from
git, using the last commit that still had it:

```bash
git log --oneline --diff-filter=D -- compose.lan.yaml
git checkout <commit before the deletion> -- compose.lan.yaml
sed -i 's/^# COMPOSE_FILE=/COMPOSE_FILE=/' .env
docker compose up -d
```

The file is the one from the log's `<commit>^`. If `.env` has no `COMPOSE_FILE`
line, add `COMPOSE_FILE=compose.yaml:compose.lan.yaml` and set `LAN_IP` to the
VM's address. Undo it after the fix: `git rm compose.lan.yaml` and comment out
`COMPOSE_FILE` again. Section 8's `edge-ports`/`no-lan-override` checks FAIL
while it is back, by design.

**Bypass the geo-block temporarily.** Allow every country you need by adding
it to `GEO_ALLOWED_COUNTRIES` and recreating Traefik (section 7). To let
unknown or unlookupable addresses through during a provider outage, set
`traefik.http.middlewares.geoblock.plugin.geoblock.allowUnknownCountries=true`
in `stacks/edge.yaml`, run `docker compose up -d traefik`, and revert it
afterwards. Only the country test is relaxed; CrowdSec and the rate limit
stay on.

**Bypass CrowdSec temporarily.** To unban one address:
`docker compose exec crowdsec cscli decisions delete --ip <address>`. To take
CrowdSec out of the chain, change the `public` chain label in
`stacks/edge.yaml` to `geoblock,rate-limit,secure-headers`, run
`docker compose up -d traefik`, and revert it afterwards. Also add your own
network to `LAN_CIDR` if you keep banning yourself.

## Troubleshooting

**Every `*.int` route answers 500 (or 502) instead of the app.** Forward-auth
fails closed: when Traefik cannot reach `authentik-server`, it refuses the
request and never passes it to the app. Check and restart Authentik:

```bash
docker compose ps authentik-server authentik-worker authentik-db
docker compose logs --tail 50 authentik-server
docker compose up -d authentik-db authentik-server authentik-worker
```

There is no LAN-port fallback any more (section 8). Fix Authentik, or use
the recovery key below. The rollback section describes how to restore the
temporary ports.

**Locked out of Authentik** (lost password or authenticator): create a
recovery key and open the printed path on `https://auth.<domain>` within 10
minutes (section 6.3):

```bash
docker compose exec authentik-worker ak create_recovery_key 10 akadmin
```

**`*.int` redirects to `http://localhost/...`.** The embedded outpost has not
picked up `authentik_host` yet: `docker compose restart authentik-server`.

**A `*.int` route says "Permission denied" after login.** Your account is not
in `admins` (section 6.2).

**`/if/admin/` answers 403 over Twingate.** The connector's IP is outside
`LAN_CIDR` (section 5).

**Certificate not issued, or the browser says the certificate is not
trusted.** A staging certificate is not trusted by browsers; that is expected
until you switch `ACME_CASERVER` to production and delete
`/opt/appdata/traefik/acme/acme.json` (section 4). If Traefik never obtains a
certificate, `docker compose logs traefik | grep -i acme` names the error.
`Invalid token` or `403` from Cloudflare means the token lacks **Zone, DNS,
Edit** on this zone, or it was pasted with a trailing newline or quotes
(section 1 and 2). Let's Encrypt production limits failed validations (5 per
hour per name), so debug on staging.

**`*.int` answers 403 over Twingate.** Traefik sees the connector's address,
and it is outside `LAN_CIDR`. Get the address of the connector in LXC 101 with
`pct exec 101 -- ip -4 -o addr show scope global` on the Proxmox host, widen
`LAN_CIDR` in `.env` to include it, and run `docker compose up -d traefik`
(also `crowdsec`'s bouncer trusts `LAN_CIDR`, so LAN clients are never banned).

**Public routes (`requests.<domain>`, `auth.<domain>`) answer 403 to everyone,
or to you.**
Check in this order: the geo-block, then CrowdSec. The geo-block logs each
denial: `docker compose logs traefik | grep -i geoblock`. `request denied ...
due to error` means the country lookup failed (provider outage, or the VM
cannot reach `get.geojs.io`), and `allowUnknownCountries=false` blocks those
requests; use the temporary switch in the Rollback section. A denial without an
error means your country is not in `GEO_ALLOWED_COUNTRIES` (section 7). For
CrowdSec: `docker compose exec crowdsec cscli decisions list`, then
`cscli decisions delete --ip <address>`.

**Traefik does not start, or logs `plugin: failed to download`/`unable to
download plugin`.** Traefik downloads both plugins from GitHub at start and
keeps them in `/opt/appdata/traefik/plugins-storage`. Check the VM's internet
and DNS access, and that the directory is writable by `PUID`
(`scripts/mkdirs.sh`). The versions are pinned in `stacks/edge.yaml`
(`--experimental.plugins.*.version`); a typo makes the download fail. Once
downloaded, the plugins are reused, so later starts work offline.

**`crowdsec-bouncer` FAILs: never pulled, or the last pull is old.** Traefik
cannot reach `crowdsec:8080` or the key differs. `docker compose logs crowdsec
| grep -i bouncer` and `docker compose logs traefik | grep -i crowdsec`. Both
containers must be on the `crowdsec` network; recreate them with
`docker compose up -d --force-recreate crowdsec traefik`.

**A blueprint shows error.** `docker compose logs authentik-worker | grep -i
blueprint` names the failing entry. Fix the file in
`config/authentik/blueprints/`; the worker re-applies it on change.
