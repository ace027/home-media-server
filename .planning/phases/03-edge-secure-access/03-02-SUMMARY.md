# Plan 03-02 Summary: Authentik SSO, forward-auth and admin MFA

## Result
**Status**: Complete with Warnings
**Wave**: 2
**Agent**: engineering-security-engineer
**Completed**: 2026-10-14

## Agent Selection Rationale

| Candidate | Semantic | Heuristic | Memory | Total | Source |
|-----------|----------|-----------|--------|-------|--------|
| engineering-security-engineer | — | 16 | 0 | 16 | mandatory |
| engineering-infrastructure-devops | — | 25 | 0 | 25 | heuristic |
| engineering-backend-architect | — | 22 | 0 | 22 | heuristic |

- **Task type detected**: implementation
- **Confidence**: LOW
- **Adapter**: claude-code
- **Model tier**: sonnet

## Completed Tasks
- [x] Task 1: Authentik services and Traefik wiring (done)
- [x] Task 2: Authentik blueprints (done)
- [x] Task 3: Verify checks, CI assertions and runbook section 6 (done)

## Files Modified
- `config/authentik/blueprints/10-admins-mfa.yaml`
- `config/authentik/blueprints/20-forward-auth.yaml`
- `config/authentik/blueprints/30-invitation-enrollment.yaml`
- `scripts/vm/verify-edge.sh`

## Verification Results
18/18 verification commands passed (run by Triad after the agent finished).

## Verification Commands
| Command | Exit Code | Result |
|---------|-----------|--------|
| `cp -n .env.example .env; docker compose config -q` | 0 | PASS |
| `COMPOSE_PROFILES=jellyfin scripts/ci/check-pinned-images.sh && scripts/ci/check-min-versions.sh` | 0 | PASS |
| `shellcheck -x scripts/lib/*.sh scripts/mkdirs.sh scripts/host/*.sh scripts/vm/*.sh scripts/ci/*.sh` | 0 | PASS |
| `yamllint -s .` | 0 | PASS |
| `for t in scripts/ci/test-*.sh; do bash "$t" \|\| { echo "FAIL $t"; exit 1; }; done` | 0 | PASS |
| `SKIP_NET=1 DOMAIN=example.com LAN_CIDR=192.168.1.0/24 scripts/vm/verify-edge.sh \| tail -1 \| grep -E '^RESULT: [0-9]+ pass, 0 fail, [0-9]+ skip$'` | 0 | PASS |
| `COMPOSE_PROFILES=jellyfin scripts/ci/check-pinned-images.sh` | 0 | PASS |
| `docker compose config --format json \| jq -e '[.services[].ports[]?.published] \| unique == ["32400","443"]'` | 0 | PASS |
| `docker compose config --format json \| jq -e '.services["authentik-db"].networks \| keys == ["authentik"]'` | 0 | PASS |
| `docker compose config --format json \| jq -e '.services.traefik.labels["traefik.http.middlewares.int.chain.middlewares"] == "lan-only,secure-headers,authentik"'` | 0 | PASS |
| `yamllint -s config/authentik/blueprints` | 0 | PASS |
| `for f in config/authentik/blueprints/*.yaml; do grep -q '^version: 1' "$f" \|\| { echo "no version: $f"; exit 1; }; done` | 0 | PASS |
| `! grep -RInE '(password\|secret\|token)["]?:[[:space:]]*[A-Za-z0-9]{12,}' config/authentik/blueprints` | 0 | PASS |
| `grep -q 'forward_domain' config/authentik/blueprints/20-forward-auth.yaml && grep -q 'not_configured_action: configure' config/authentik/blueprints/10-admins-mfa.yaml` | 0 | PASS |
| `shellcheck -x scripts/vm/verify-edge.sh scripts/ci/test-edge.sh` | 0 | PASS |
| `bash scripts/ci/test-edge.sh` | 0 | PASS |
| `SKIP_NET=1 DOMAIN=example.com LAN_CIDR=192.168.1.0/24 scripts/vm/verify-edge.sh \| grep -c -E '^(PASS\|FAIL\|SKIP) ' \| grep -qx 14` | 0 | PASS |
| `grep -q 'recovery' docs/runbooks/04-edge-access.md && grep -q 'admins' docs/runbooks/04-edge-access.md` | 0 | PASS |

## Key Decisions
- No Redis: the upstream 2026.8.3 compose file ships only postgresql, server and worker, and Redis was dropped in 2025.10.

## Issues Encountered
- In this sandbox Authentik would not start until I made it listen on IPv4 only, because the kernel has no IPv6 ("address family not supported"). I applied that only in the sandbox, not in `edge.yaml`. If the VM has IPv6 disabled, add `AUTHENTIK_LISTEN__HTTP=0.0.0.0:9000` (and the other listen addresses).

## Escalations
| # | Severity | Type | Decision | Status | Resolution |
|---|----------|------|----------|--------|------------|
| 1 | warning | plan-contract-deviation (security) | Dropped the plan's `AUTHENTIK_BOOTSTRAP_PASSWORD=file:///run/secrets/authentik_bootstrap_password` env entry. An entrypoint wrapper in stacks/edge.yaml now exports the variable from the secret before running `dumb-init -- ak`. | pending | INVALID: type "plan-contract-deviation (security)" is not one of architecture, dependency, scope, schema, api, deletion, infrastructure, quality |
| 2 | info | plan-contract-deviation (runbook) | The runbook does not tell the owner to store a long-lived recovery key offline; it uses short (10-minute) keys created on demand instead. | pending | INVALID: type "plan-contract-deviation (runbook)" is not one of architecture, dependency, scope, schema, api, deletion, infrastructure, quality |

- #1 context: Authentik 2026.8.3 reads this variable with a plain getenv (authentik/core/setup/signals.py and the !Env tag in system/bootstrap.yaml), so file:// is not resolved. With the plan's interface, akadmin's password on the public auth.<domain> would have been a publicly guessable string. Confirmed in the sandbox: the real password works and the literal string does not.
- #2 context: In 2026.8 the duration argument of `ak create_recovery_key` is in minutes. A long-lived key is a bearer credential that bypasses MFA.

## Handoff Context
- **Key outputs**: config/authentik/blueprints/10-admins-mfa.yaml; config/authentik/blueprints/20-forward-auth.yaml; config/authentik/blueprints/30-invitation-enrollment.yaml; scripts/vm/verify-edge.sh
- **Decisions made**: No Redis: the upstream 2026.8.3 compose file ships only postgresql, server and worker, and Redis was dropped in 2025.10.
- **Open questions**: (none)
- **Conventions established**: 03-03 prepends crowdsec and geoblock to `public`; `auth` uses `public@docker`, so the geo-block must allow the proxy-network client or authentik-admin-lan's health check will fail.

## Requirements Covered
- R6
- R7

## Token Usage
67 requests, 6560811 input tokens (6310346 cached), 62143 output tokens, $3.7571
