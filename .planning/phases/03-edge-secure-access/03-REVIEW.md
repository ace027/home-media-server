# Phase 3: Edge & Secure Access — Review Summary

## Result: PASSED

**Cycles Used**: 2
**Reviewers**: testing-qa-verification-specialist, engineering-senior-developer, engineering-infrastructure-devops
**Evaluators**: code-quality, integration, business-logic
**Completed**: 2026-10-14

## Findings Summary
- Must-fix (blocker, critical, major) found: 1; fixed: 1; unresolved: 0
- Suggestions (minor, advisory): 3
- Deferred (confidence 50-79%): 15
- Hot spots (flagged by 2+ reviewers): `stacks/edge.yaml`, `config/logrotate/traefik-access`, `scripts/ci/test-edge.sh`, `docs/README.md`

## Findings Detail
| ID | Severity | Location | Issue | Reviewers | Confidence | Status |
|----|----------|----------|-------|-----------|------------|--------|
| F-001 | major | `scripts/ci/test-edge.sh:99-109` | No CI test covers the cloudflare-ddns service or the DNS-01 certificate configuration. Nothing asserts `UPDATE_CRON=@every 5m`, `PROXIED=false`, `DOMAINS` (plex, requests, auth), or the `CLOUDFLARE_API_TOKEN_FILE` secret. Nothing asserts `certificatesresolvers.cloudflare.acme.dnschallenge.provider`, `websecure.http.tls.domains[0].sans` (`*.DOMAIN`, `*.int.DOMAIN`), the acme storage path, `ACME_CASERVER`, or `config/traefik/dynamic/tls.yml`. The only DDNS or cert assertions are runtime checks in `verify-edge.sh`, which the CI run skips with `SKIP_NET=1`. | evaluator:code-quality | 85% | fixed |
| F-002 | minor | `docs/README.md:7` | The runbook 04 entry says "Authentik, CrowdSec and LAN-port removal are added by later plans". The same commit (037e0b5) adds all three, and runbook 04 now covers sections 6 to 8. | evaluator:code-quality, evaluator:integration | 90% | deferred |
| F-003 | advisory | `scripts/vm/verify-edge.sh:288-304` | `check_int_lan_only` repeats `docker inspect` plus `jq` instead of calling `traefik_ip`, and repeats the `docker run --rm --network proxy "$CURL_IMAGE"` call instead of `proxy_curl`. `check_authentik_admin_lan` already uses both helpers. | evaluator:code-quality | 80% | deferred |
| F-004 | minor | `scripts/ci/test-edge.sh:139-140` | `ca="$(grep -E '^ACME_CASERVER=' .env / tail -n 1 / cut -d= -f2-)"` runs under `set -Eeuo pipefail`. If `.env` has no `ACME_CASERVER=` line, grep exits 1, the pipeline fails and the script exits silently. It never reaches the `.env.example` fallback on line 140 or any `FAIL` message. The same applies to line 140 if `.env.example` has no match. The value is also read raw, so a quoted value in `.env` would not match the rendered `--certificatesresolvers.cloudflare.acme.caServer=` flag. | testing-qa-verification-specialist, engineering-senior-developer, engineering-infrastructure-devops, evaluator:code-quality | 80% | deferred |

## Reviewer Verdicts
- Cycle 1, testing-qa-verification-specialist: **NEEDS WORK**
- Cycle 1, engineering-senior-developer: **PASS**
- Cycle 1, engineering-infrastructure-devops: **NEEDS WORK**
- Cycle 1, evaluator:code-quality: **NEEDS WORK**
- Cycle 1, evaluator:integration: **NEEDS WORK**
- Cycle 1, evaluator:business-logic: **NEEDS WORK**
- Cycle 2, testing-qa-verification-specialist: **PASS**
- Cycle 2, engineering-senior-developer: **PASS**
- Cycle 2, engineering-infrastructure-devops: **PASS**
- Cycle 2, evaluator:code-quality: **PASS**

## Suggestions (Not Required)
- F-002 `docs/README.md`: The runbook 04 entry says "Authentik, CrowdSec and LAN-port removal are added by later plans". The same commit (037e0b5) adds all three, and runbook 04 now covers sections 6 to 8. (fix: Reword the entry to say it covers Authentik forward-auth and MFA, CrowdSec, the geo-block, LAN-port removal and acceptance.)
- F-003 `scripts/vm/verify-edge.sh`: `check_int_lan_only` repeats `docker inspect` plus `jq` instead of calling `traefik_ip`, and repeats the `docker run --rm --network proxy "$CURL_IMAGE"` call instead of `proxy_curl`. `check_authentik_admin_lan` already uses both helpers. (fix: Replace the inline code in `check_int_lan_only` with `traefik_ip` and `proxy_curl`.)
- F-004 `scripts/ci/test-edge.sh`: `ca="$(grep -E '^ACME_CASERVER=' .env | tail -n 1 | cut -d= -f2-)"` runs under `set -Eeuo pipefail`. If `.env` has no `ACME_CASERVER=` line, grep exits 1, the pipeline fails and the script exits silently. It never reaches the `.env.example` fallback on line 140 or any `FAIL` message. The same applies to line 140 if `.env.example` has no match. The value is also read raw, so a quoted value in `.env` would not match the rendered `--certificatesresolvers.cloudflare.acme.caServer=` flag. (fix: Append `|| true` to each grep pipeline, for example `ca="$(grep -E '^ACME_CASERVER=' .env | tail -n 1 | cut -d= -f2- || true)"`. Strip surrounding quotes from the value. Better, read the expected value from the rendered config, for example with `docker compose config --format json` on the `ACME_CASERVER` default, so no `.env` parsing is needed.)

## Deferred (Medium Confidence)
- `stacks/edge.yaml` [major, 60%]: `traefik` has a plain `depends_on: [socket-proxy, crowdsec]`. That waits for the container to start, not for it to be healthy. On a cold start or after a reboot, Traefik loads the CrowdSec bouncer plugin before the LAPI is up and before `bouncer_key_traefik-bouncer` is registered. `crowdsec` has a 60 s `start_period` and downloads hub collections on first start.
- `stacks/edge.yaml` [major, 60%]: The geo-block depends on a third-party API (`get.geojs.io`) for every new public client IP. It uses `allowUnknownCountries=false` and `apiTimeoutMs=1000`. A geojs outage, rate limit, or a lookup slower than 1 s blocks the client. This covers `requests.<domain>` and the public `auth.<domain>` login and forward-auth callback. Each client's public IP is also sent to that third party.
- `stacks/edge.yaml` [minor, 50%]: The Traefik plugins (crowdsec bouncer, geoblock) are fetched from GitHub at start into `/plugins-storage`. If the cache is empty and GitHub or the proxy is unreachable, such as on a fresh VM rebuild or a restore without appdata, Traefik fails to start. That takes down all routes, including the `*.int` admin UIs needed to diagnose it.
- `scripts/vm/40-edge-secrets.sh` [minor, 50%]: When the script is run as non-root, the generated secrets are owned by the invoking user, with no check that this is `PUID`. If that user is not `PUID`, the 0400 files are unreadable by Traefik and cloudflare-ddns, which run as `${PUID}:${PGID}`, and Compose bind-mounts them with host ownership. The script reports `CREATED` regardless.
- `stacks/edge.yaml` [minor, 50%]: The `crowdsec` service bind-mounts `acquis.yaml` read-only at `/etc/crowdsec/acquis.yaml`, inside another bind mount of `${APPDATA_ROOT}/crowdsec/config` at `/etc/crowdsec`. These are nested mounts.
- `stacks/edge.yaml` [major, 70%]: cloudflare-ddns has no healthcheck, no failure notification and no monitoring hook. The comment says the image is distroless. The image still supports `HEALTHCHECKS` and `UPTIMEKUMA` ping URLs, and neither is wired in. `UPDATE_CRON` is `@every 5m`.
- `.env.example` [minor, 75%]: The comment says to keep the staging URL for the first start, but the active default is the production ACME endpoint, and the staging line is commented out.
- `config/logrotate/traefik-access` [major, 70%]: The rule has no `su <PUID> <PGID>` directive. `scripts/mkdirs.sh` creates `traefik/logs` and its parents as `PUID:PGID` with mode 2775, which is group-writable by a non-root group.
- `scripts/vm/verify-edge.sh` [minor, 65%]: `check_edge_ports` runs `ss -ltn`, but `require_cmd` lists only `docker curl jq openssl`. Without `ss` the check dies with the generic "unexpected error (rc=...)" message instead of a clear missing-tool message. Other tools are handled better: `ddns-records` checks for `dig` and reports how to install it.
- `scripts/vm/verify-edge.sh` [advisory, 55%]: The `public-chain` allowlist names a `jellyfin` router, but `stacks/media.yaml` puts jellyfin on `int@docker` with a `jellyfin.int.` host and has no public router. `test-edge.sh` (lines 61-62) also expects only `auth-admin`, `auth` and `seerr` as non-`int` routers. The allowance is unreachable until Jellyfin is adopted.
- `stacks/edge.yaml` [minor, 55%]: `ACME_EMAIL`, `ACME_CASERVER`, `LAN_CIDR`, `GEO_ALLOWED_COUNTRIES` and `AUTHENTIK_ADMIN_EMAIL` have no `${VAR:?}` guard or default. A `.env` that predates these variables renders them as empty strings, with only a Compose warning.
- `stacks/edge.yaml` [minor, 50%]: Authentik server and worker run as the image default user (uid 1000) and read secrets bind-mounted as 0400 files owned by `PUID`. Traefik sets `user: ${PUID}:${PGID}` for the same reason, but Authentik does not. The `cat /run/secrets/authentik_bootstrap_password` in the entrypoint and the `file://` secrets fail if `PUID` is not 1000.
- `docs/runbooks/04-edge-access.md` [critical, 65%]: The token instructions grant only "Zone, DNS, Edit" on the one zone. The same wording is in `scripts/vm/40-edge-secrets.sh` (lines 25 and 82) and the `MISSING` message that `test-edge.sh` asserts. Both consumers of the token, Traefik's lego Cloudflare DNS-01 provider and `favonia/cloudflare-ddns`, document that they also need Zone:Zone:Read. They use it to look up the zone ID.
- `scripts/ci/test-edge.sh` [major, 70%]: No test asserts the `cloudflare-ddns` service. It would not catch a change to `DOMAINS` (plex, requests, auth), `PROXIED: "false"`, `UPDATE_CRON`, or the token file wiring. `verify-edge.sh` also has no automated geo-block check, so a change to the geoblock settings or the `public` chain would be caught only by hand-run runbook step 6.
- `stacks/media.yaml` [advisory, 50%]: Nothing implements or documents the conditional criterion for adopting Jellyfin. Jellyfin has only an `int@docker` router. No `jellyfin.<domain>` public router exists, there is no DDNS record, no Authentik OIDC provider blueprint, and no runbook steps. `verify-edge.sh` already whitelists a `jellyfin` router on `public@docker`, and `test-edge.sh` asserts that every router except auth and seerr uses `int@docker`.

## Fixes Applied
- cycle 1: engineering-senior-developer on F-001 (done); checks 39/40 passed
- minor findings: engineering-senior-developer on F-002, F-003, F-004, F-001, F-002, F-003, F-004, F-005 (partial); left as is: F-002 [major] geo-block depends on get.geojs.io: not fixed. It needs a design decision (accept fail-closed, add a probe, or change the timeout or plugin DB). A troubleshooting entry would go in the runbook, which isn't writable. / F-003 [minor] plugins-storage: not fixed. It is a runbook Troubleshooting and backup-list change, and the runbook isn't in the writable list. / F-005 [minor] nested acquis.yaml mount: not fixed. Moving the mount to acquis.d/ is still nested inside the /etc/crowdsec bind mount. Whether it avoids the first-start seeding problem depends on the image's seeding check, which I haven't verified. The fix is a layout choice, and test-edge.sh:338 asserts the current path.; checks failed (1/40), changes undone

## Cycle Delta
- cycle 1: 2 out-of-domain finding(s) filtered (testing-qa-verification-specialist on infrastructure, owner engineering-infrastructure-devops; engineering-senior-developer on infrastructure, owner engineering-infrastructure-devops); see .planning/logs/authority-decisions-2026-10-14.log
- cycle 1: 1 must-fix, 2 suggestions, 15 deferred, 0 dropped (low confidence)
- cycle 2: 0 must-fix (resolved 1, new 0, unchanged 0), 1 suggestions, 0 deferred, 0 dropped (low confidence)

## Coverage
No coverage data found (looked for coverage/coverage-summary.json, coverage-summary.json, coverage/lcov.info, lcov.info, coverage.xml, coverage/cobertura-coverage.xml, coverage/coverage.xml, coverage.txt, coverage/coverage.txt). Advisory only: run the test suite with coverage to check review.coverage_thresholds.

## Security Review

**Verdict**: PASS — 0 unresolved CRITICAL/HIGH finding(s). Details: `SECURITY-REVIEW.md`.
