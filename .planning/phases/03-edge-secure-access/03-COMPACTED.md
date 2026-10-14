---
phase: 03-edge-secure-access
compacted: 2026-10-14
original_summaries: [03-01-SUMMARY.md, 03-02-SUMMARY.md, 03-03-SUMMARY.md]
requirements_satisfied: [R6, R7]
---

# Phase 3: Edge & Secure Access — Compacted Summary

## Deliverables
- 03-01 Traefik core, DDNS and admin routes (Complete)
- 03-02 Authentik SSO, forward-auth and admin MFA (Complete with Warnings): config/authentik/blueprints/10-admins-mfa.yaml, config/authentik/blueprints/20-forward-auth.yaml, config/authentik/blueprints/30-invitation-enrollment.yaml, scripts/vm/verify-edge.sh
- 03-03 CrowdSec, geo-block and LAN-port cutover (Complete)

## Decisions
- 03-02: No Redis: the upstream 2026.8.3 compose file ships only postgresql, server and worker, and Redis was dropped in 2025.10.
- 03-03: Bouncer key registration relies on the image's own start script reading /run/secrets/bouncer_key_traefik-bouncer. Because I could not confirm this, the crowdsec
- 03-03: geoblock uses a comma list for countries via `${GEO_ALLOWED_COUNTRIES}`, and the stack renders in `docker compose config`. Whether the pinned plugin splits that

## Conventions and Open Questions
- 03-01 convention: `test-edge.sh` has a marked function list where 03-02 and 03-03 add their assertions.
- 03-01 convention: The `int@docker` and `public@docker` chains and the `secrets:` entries for authentik and crowdsec are already declared in `stacks/edge.yaml`.
- 03-01 convention: Runbook 04 sections 6-9, Acceptance record and Troubleshooting are placeholders for 03-02 and 03-03. Rollback is already written.
- 03-02 convention: 03-03 prepends crowdsec and geoblock to `public`
- 03-02 convention: `auth` uses `public@docker`, so the geo-block must allow the proxy-network client or authentik-admin-lan's health check will fail.
- 03-03 convention: none

## Files Modified
| File | Change |
|------|--------|
| `config/authentik/blueprints/10-admins-mfa.yaml` | 03-02: Authentik SSO, forward-auth and admin MFA |
| `config/authentik/blueprints/20-forward-auth.yaml` | 03-02: Authentik SSO, forward-auth and admin MFA |
| `config/authentik/blueprints/30-invitation-enrollment.yaml` | 03-02: Authentik SSO, forward-auth and admin MFA |
| `scripts/vm/verify-edge.sh` | 03-02: Authentik SSO, forward-auth and admin MFA |

## Verification
- 03-01 (R6, R7): 20/20 verification commands passed
- 03-02 (R6, R7): 18/18 verification commands passed
- 03-03 (R6, R7): 22/22 verification commands passed

## Agents
- 03-01: engineering-infrastructure-devops
- 03-02: engineering-security-engineer
- 03-03: engineering-security-engineer

## Also Covered
- stacks/media.yaml
- stacks/arr.yaml
- stacks/download.yaml
- config/traefik/dynamic/tls.yml
- .env.example
- scripts/mkdirs.sh
- scripts/vm/40-edge-secrets.sh
- scripts/vm/25-arr-wire.sh
- scripts/ci/test-edge.sh
- scripts/ci/test-compose.sh
- scripts/ci/test-arr-scripts.sh
- docs/runbooks/04-edge-access.md
- docs/README.md
- .env.example
- scripts/ci/test-edge.sh
- docs/runbooks/04-edge-access.md
- config/crowdsec/acquis.yaml
- config/logrotate/traefik-access
- .env.example
- compose.lan.yaml
- scripts/vm/40-edge-secrets.sh
- scripts/ci/test-edge.sh
- scripts/ci/test-compose.sh
- docs/architecture.md
- docs/runbooks/03-core-media.md
- docs/runbooks/04-edge-access.md
