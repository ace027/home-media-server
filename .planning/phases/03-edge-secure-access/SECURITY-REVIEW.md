# Phase 3: Security Review

**Verdict**: PASS
**Unresolved blockers for ship**: 0

## OWASP Top 10
| # | Category | Result | Evidence |
|---|---|---|---|
| A1 | Injection | PASS | 40-edge-secrets.sh:42-44 path/PUID/PGID validation; secrets [A-Za-z0-9] only (:52); AUTHENTIK_TOKEN regex-checked verify-edge.sh:93; no user input reaches a shell |
| A2 | Broken Auth | WARN | Admin MFA enforced (10-admins-mfa.yaml:65,95); public rate limit 20 req/s too loose (edge.yaml:130-131); no Authentik CrowdSec scenario; invitee password policy length 12 only (F-3) |
| A3 | Sensitive Data | WARN | Secrets are 0400 files; bootstrap password in process env (edge.yaml:226-227, F-5); CF token readable by in-process plugins (F-4); tokens in access logs (F-9) |
| A4 | XXE | N/A | No XML parsing |
| A5 | Access Control | WARN | All *.int routers carry int@docker; /if/admin LAN-only at priority 100; /api/v3 admin endpoints public (F-1); shared proxy network (F-7) |
| A6 | Misconfiguration | WARN | api.insecure=false, Traefik read-only/cap-dropped; socket-proxy not hardened (F-6); authentik-db network not internal (F-8); LAN_CIDR unvalidated (F-10) |
| A7 | XSS | PASS | frameDeny, nosniff, referrer policy set; no CSP (apps set their own) |
| A8 | Deserialization/Integrity | WARN | Traefik plugins pinned by tag only, fetched from GitHub (F-4) |
| A9 | Known Vulns | PASS | Scan flagged none; pinned versions recent |
| A10 | Logging | WARN | JSON access log feeds CrowdSec, rotated; recovery/invite tokens in logged URLs (F-9) |

## STRIDE
| Boundary | Threat | Category | Attack Vector | Mitigation | Status |
|---|---|---|---|---|---|
| internet→Traefik 443 | Reach *.int | Elevation | Forged XFF / Host header | ipallowlist on RemoteAddr, no trustedIPs, lan-only first in chain | MITIGATED |
| internet→Traefik 443 | Reach *.int via IPv6 | Elevation | AAAA / [::]:443 userland proxy | IPv4-only allowlist denies; geoblock/CrowdSec see 172.x (F-11) | PARTIAL |
| internet→Traefik 443 | Authentik admin API | Elevation | /api/v3 with stolen token/session | Only /if/admin LAN-gated (F-1) | UNMITIGATED |
| internet→Traefik 443 | Credential stuffing on auth | Spoofing | Distributed low-rate attempts | Rate limit, geoblock, CrowdSec generic, admin MFA (F-3) | PARTIAL |
| internet→Traefik 443 | CrowdSec LAPI outage | DoS/bypass | Stream mode keeps last decisions | Documented fail-open | PARTIAL (accepted) |
| internet→Traefik 443 | Geoblock lookup outage | DoS | get.geojs.io unavailable | Fail-closed, tracked in 03-REVIEW | PARTIAL (tracked) |
| internet→Plex 32400 | Direct exposure | Info disclosure/Elevation | Plex vulns, probing | Plex auth only, owner decision | PARTIAL (accepted) |
| Twingate/LAN→*.int | Untrusted LAN host | Spoofing | IoT/guest device | Forward-auth, admins-only binding, MFA | MITIGATED |
| Twingate/LAN→*.int | Forward-auth bypass | Elevation | Authentik down | forwardauth returns 5xx (fail closed) | MITIGATED |
| Twingate/LAN→*.int | Domain-wide cookie | Info disclosure | Cookie sent to requests.<domain> (F-12) | Only replayable from LAN | PARTIAL |
| Traefik→socket-proxy | Docker API abuse | Elevation | GET /containers/*/archive,export | internal network, POST=0; ACL unverified (F-6) | PARTIAL |
| Traefik→Authentik outpost | Sniff/tamper | Tampering | Plain HTTP on shared proxy network (F-7) | none | PARTIAL |
| Traefik→CrowdSec LAPI | Key theft/spoof | Spoofing | | Dedicated network, key as Docker secret | MITIGATED |
| host secrets→containers | Bad mode/owner | Info disclosure | | 0400 PUID files; uid item tracked | MITIGATED |
| host secrets→containers | Bootstrap password in env | Info disclosure | /proc/1/environ (F-5) | Not in inspect/compose | PARTIAL |
| host secrets→containers | Plugin reads CF token | Info disclosure | Yaegi stdlib access (F-4) | Tag pin only | UNMITIGATED |
| scripts→secrets | Leak via output/xtrace/ERR trap | Info disclosure | | No xtrace, names only | MITIGATED |
| scripts→secrets | Truncated file kept | Tampering | Failed write then KEEP (F-13) | none | UNMITIGATED |

## Attack Surface
- WAN 443 → Traefik: requests.<domain> (Seerr) and auth.<domain> (Authentik: /api/v3, flows, /if/user, /recovery, enrollment, outpost paths public; /if/admin LAN-only). *.int and traefik.int answer 403 to non-LAN sources.
- WAN 32400 → Plex directly (no CrowdSec, geoblock or rate limit).
- Outbound: Traefik fetches plugins from GitHub, calls get.geojs.io, ACME and Cloudflare DNS; Authentik worker egress.
- LAN/Twingate (LXC 101) → *.int admin UIs: lan-only + Authentik forward-auth (admins + MFA).
- Shared proxy bridge: Plex, Seerr, Authentik, *arr, SABnzbd, Traefik (no east-west segmentation).
- Host: docker.sock only in socket-proxy; secrets/* 0400; acme.json under 0700 dir.

### Dependency Vulnerability Findings
_none_

### Secret Detection Findings
_none_

### Supply Chain Findings
_none_

## Findings
| ID | OWASP Cat | Severity | Finding | File(s) | Remediation | Status |
|----|-----------|----------|---------|---------|-------------|--------|
| SEC-001 | A5:Broken Access Control | MEDIUM | Authentik admin API (/api/v3 admin endpoints) is reachable from the internet; only /if/admin is LAN-restricted, and verify-edge.sh only tests /if/admin. | stacks/edge.yaml:264-271; scripts/vm/verify-edge.sh:363-376 | Add a higher-priority lan-admin@docker router for admin-only API prefixes (core/users, core/tokens, rbac, policies, propertymappings, providers, stages, outposts, flows/bindings, managed, admin) while keeping flow executor, root/config, brands/current, authenticators and core/applications public; add a verify check. | OPEN |
| SEC-002 | A3:Sensitive Data Exposure | MEDIUM | One zone-wide Cloudflare DNS:Edit token is shared by internet-facing Traefik and cloudflare-ddns; compromise allows DNS hijack and arbitrary cert issuance; runbook omits Zone:Read and IP filtering. | docs/runbooks/04-edge-access.md:31-41; stacks/edge.yaml:92,179; scripts/vm/40-edge-secrets.sh:25,82 | Client IP Address Filtering to the WAN IP, separate tokens for DDNS and ACME, CAA record with accounturi and validationmethods=dns-01, document Zone:Read. | OPEN |
| SEC-003 | A2:Broken Authentication | MEDIUM | Public login brute-force controls are weak: 20 req/s per IP rate limit, no Authentik-aware CrowdSec scenario, invitee passwords only need 12 characters with no breach/strength check. | stacks/edge.yaml:130-131,301; config/authentik/blueprints/30-invitation-enrollment.yaml | Dedicated stricter rate limit on auth (e.g. average 2, burst 10), Authentik reputation policy on identification, enable zxcvbn/HIBP checks, add an Authentik CrowdSec scenario. | OPEN |
| SEC-004 | A8:Software and Data Integrity | MEDIUM | Third-party Traefik plugins are fetched from GitHub at start, pinned by tag only, and run in-process with access to the Cloudflare token and ACME key. | stacks/edge.yaml:82-85,92 | Vendor reviewed plugin sources as localPlugins pinned to a commit and mount read-only; restrict Traefik egress where possible. | OPEN |
| SEC-005 | A3:Sensitive Data Exposure | LOW | Bootstrap password stays in the server and worker process environment after first use, and the runbook advises keeping an offline copy. | stacks/edge.yaml:224-228,280; docs/runbooks/04-edge-access.md:296 | Rotate the akadmin password after first login and overwrite the secret file with a random value; drop the wrapper from the worker. | OPEN |
| SEC-006 | A6:Security Misconfiguration | LOW | docker-socket-proxy is not hardened (root, no read_only/cap_drop) and whether CONTAINERS=1 exposes archive/export/logs is unverified. | stacks/edge.yaml:8-38 | Add read_only, cap_drop ALL and tmpfs; add a verify check that /containers/<id>/archive and /export return 403. | OPEN |
| SEC-007 | A5:Broken Access Control | LOW | All apps share the proxy network, so a compromised container reaches admin apps and Authentik directly, bypassing lan-only and forward-auth. | stacks/*.yaml (networks: proxy) | Put public-facing services on a separate network from admin apps; Traefik joins both. | OPEN |
| SEC-008 | A6:Security Misconfiguration | LOW | authentik-db sits on a non-internal network and has egress it does not need. | stacks/edge.yaml:329-333 | Give the DB its own internal: true network shared with server and worker. | OPEN |
| SEC-009 | A10:Insufficient Logging & Monitoring | LOW | Access logs retain recovery and invitation tokens in URLs for 4 weeks with loose permissions. | config/logrotate/traefik-access; scripts/mkdirs.sh | logrotate su + create 0640, shorter retention, filter /recovery/ and itoken from logs. | OPEN |
| SEC-010 | A5:Broken Access Control | LOW | LAN_CIDR is not validated; /0 or an over-broad CIDR makes lan-only and CrowdSec trust match the internet. | stacks/edge.yaml:124,145; scripts/vm/verify-edge.sh:89 | Use ${LAN_CIDR:?} in Compose and reject prefixes shorter than /8 in verify-edge.sh. | OPEN |
| SEC-011 | A5:Broken Access Control | LOW | If inbound IPv6 reaches the host, the [::]:443 userland proxy makes clients look like 172.x, bypassing geoblock and CrowdSec (lan-only still denies). | stacks/edge.yaml (traefik ports); :151 | Publish as 0.0.0.0:443:443 or confirm the router blocks inbound IPv6. | OPEN |
| SEC-012 | A7:Cross-Site Scripting | LOW | Forward-auth cookie is scoped to the whole domain and is also sent to the public Seerr host. | config/authentik/blueprints/20-forward-auth.yaml:45 | Accept as documented trade-off or use forward_single providers for high-value apps. | OPEN |
| SEC-013 | A2:Broken Authentication | LOW | A failed secret write leaves a truncated or empty file that later runs report as KEEP; -e also follows dangling symlinks. | scripts/vm/40-edge-secrets.sh:63,66 | Write to a temp file, chmod, then mv; in KEEP check size >= 48 and not a symlink. | OPEN |
| SEC-014 | A2:Broken Authentication | INFO | Runbook token step writes the Cloudflare token with the default umask before chmod, and rotation fails on a 0400 file for non-root. | docs/runbooks/04-edge-access.md:81-82 | Use (umask 077; printf ...) or install -m 0400. | OPEN |
| SEC-015 | A2:Broken Authentication | INFO | The only automated admin-MFA check SKIPs without AUTHENTIK_TOKEN; intercept_header_auth is unverified against the MFA binding. | scripts/vm/verify-edge.sh:401-402; config/authentik/blueprints/20-forward-auth.yaml:50 | Document running with AUTHENTIK_TOKEN in acceptance; test that a Basic/Bearer header cannot bypass MFA. | OPEN |
| SEC-016 | A5:Broken Access Control | INFO | A new admin without MFA enrols on first login, so whoever logs in first owns the device; wildcard cert publishes *.int in CT logs. | config/authentik/blueprints/10-admins-mfa.yaml:65; docs/runbooks/04-edge-access.md:271-274 | Keep the runbook step to enrol immediately after creating an admin. | OPEN |
