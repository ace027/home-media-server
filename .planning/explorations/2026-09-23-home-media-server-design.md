# Design Exploration — Ultimate Home Media Server

## Initial Ask
> Build the ultimate home media server with a complete ARR stack, Plex, Jellyfin ("jellyfish") as a backup, SABnzbd for downloads, a reverse proxy, and a way to securely share it with family.

Clarifications captured during exploration:
- Host: **Proxmox**, one Debian VM running Docker Compose, with a **dedicated Intel Arc A380** passed through for transcoding.
- Storage: **ZFS pool on the Proxmox host**, exposed to the VM as a single `/data` tree.
- Remote access: **hybrid**. Plex through its own remote access, Jellyfin and Seerr behind Traefik with Authentik, and all admin apps reachable **only through Twingate**.
- Network: **dynamic public IP**, so DDNS is required. DNS is on **Cloudflare, DNS-only (grey cloud)**.
- Plex Pass: **yes**, so family members stream remotely under the owner's pass.
- Content: **Movies, TV, Music, Anime, and a separate 4K library**.
- Downloads: **Usenet only (SABnzbd)**.
- Proxy/SSO: **Traefik v3 + Authentik**.
- Scale: **1-5 family users**.
- Deployment: **GitOps Compose repo** (this repo).
- Extras in MVP: quality automation, monitoring and alerts, backups and updates, security hardening.
- Added: **FileFlows** re-encodes the library to **AV1** on the Arc A380 to save space.

## Research Summary
- Facts:
  - Overseerr and Jellyseerr merged into **Seerr** (announced Feb 10 2026). It supports Plex, Jellyfin and Emby, migrates old configs automatically, and the old projects were sunset around May 2026. ([Seerr blog](https://docs.seerr.dev/blog/seerr-release/), [ElfHosted](https://store.elfhosted.com/blog/2026/04/28/overseerr-jellyseerr-sunset-may-2026/))
  - Plex now requires Plex Pass or a Remote Watch Pass for remote playback. Enforcement began on Roku in Nov 2025 and extended to other platforms in 2026. If the **server owner has Plex Pass, shared users stream remotely without their own subscription**. ([Plex support](https://support.plex.tv/articles/requirements-for-remote-playback-of-personal-media/), [AFTVnews](https://www.aftvnews.com/plex-begins-enforcing-subscription-requirements-to-stream-remotely/))
  - Cloudflare's terms on streaming video through Tunnel or the proxy are still ambiguous, and Jellyfin's community standards name Cloudflare Tunnel video streaming as a ToS violation. ([LumaDock](https://lumadock.com/tutorials/cloudflare-tunnel-jellyfin), [Cloudflare community](https://community.cloudflare.com/t/confusion-about-tos-in-relation-to-using-cloudflared-tunnel-for-media-streaming/839900))
  - Readarr was retired in 2025, so it is not included.
  - The Intel Arc A380 (DG2) has hardware AV1, HEVC and H.264 encode and decode. Jellyfin supports it via jellyfin-ffmpeg (QSV/VAAPI). Plex supports Arc hardware transcoding on Linux with a Plex Pass. Kernel 6.2+ is needed; Debian 13 ships 6.12.
  - Hardlinks and atomic moves between the SABnzbd output and the media library require one filesystem mount (the TRaSH Guides `/data` layout).
- Inferences:
  - Because the owner has Plex Pass, **Plex is the primary family client** and Jellyfin is the fallback. Jellyfin is also a Plex-independent option if Plex policy changes again.
  - With Usenet only there is no seeding, so FileFlows can replace files in place without breaking a torrent. The only hardlink concern is transient.
  - Re-encoding to AV1 conflicts with TRaSH/Recyclarr custom formats, which may score AV1 negatively. That can cause **upgrade loops**, where the *arr apps re-download a file FileFlows just shrank. Profiles must neutralize this (see Technical Direction).
  - Family TVs are moving to AV1-capable hardware (e.g. Google TV Streamer), so AV1 files will mostly **direct play**. The A380 then only transcodes for the occasional browser, older phone or travel device, which is well within its capacity.
  - One A380 is shared by Plex, Jellyfin and FileFlows. FileFlows should run in an off-peak window with limited concurrency.
- Assumptions:
  - **Confirmed:** not behind CGNAT, so ports 443 and 32400 can be forwarded directly.
  - **Confirmed:** 1 Gbps symmetrical fiber. Upload is not a constraint for 1-5 users, even with several 4K direct-play streams (about 40-80 Mbps each).
  - The Proxmox host supports IOMMU and Resizable BAR, which Arc performance depends on.
  - A domain is registered or will be registered on Cloudflare.

## Product Definition
- Target users: the owner (admin) and 1-5 family members on TVs, phones and browsers, inside and outside the home.
- Primary outcome: family members request a title in one place (Seerr), it appears automatically in Plex or Jellyfin at the right quality, and they can watch it anywhere without technical help.
- Value proposition: a reproducible, git-managed media platform with private admin access, SSO for family, automatic quality management, AV1 space savings, and monitoring and backups built in from day one.
- Non-goals:
  - Torrents or a VPN download container (Usenet only).
  - Books and audiobooks (Readarr is retired; could be added later with other tools).
  - Public or open sign-up. All access is by invite.
  - Kubernetes or multi-node HA.
  - Streaming through a Cloudflare proxy or Tunnel.
  - Live TV/DVR (possible later).

## Recommended Approach
**Balanced modular stack plus FileFlows AV1.** A single Debian 13 VM on Proxmox runs Docker Compose. The Compose files are split by domain (`edge`, `media`, `arr`, `download`, `transcode`, `ops`) and combined with Compose `include:`. Everything is version-controlled in this repo except secrets.

Why this approach: it fits the 1-5 user scale on a single host. The split files keep each area understandable and independently restartable. It covers every requested capability (4K libraries, anime, music, SSO, Twingate, DDNS, AV1) without the extra Ansible/Prometheus work of the ambitious option. Proxmox snapshots and Proxmox Backup Server (PBS) give quick rollback during early iteration.

## Alternatives Considered
| Approach | Strengths | Tradeoffs | Decision |
|----------|-----------|-----------|----------|
| Conservative core-first: one compose file, core apps only | Fastest to a working system | 4K, anime tuning and extras bolted on manually later; one large file | Rejected (the first selection was a misclick) |
| **Balanced modular + FileFlows** | Full feature set, clear structure, phased rollout, fits the scale | Needs discipline over scope and profiles; FileFlows adds GPU contention and profile tuning | **Chosen** |
| Ambitious full-IaC (Ansible, 6 arr instances, Tdarr, Kometa, Prometheus/Grafana) | Fully reproducible from bare metal, richest features | About twice the effort; more moving parts than 1-5 users need | Deferred; parts listed under Later |
| Tailscale-only access | Most secure, nothing exposed | Hard to onboard TVs and relatives' devices | Rejected; Twingate for admin only |
| Cloudflare Tunnel for media | No port forwarding, hides home IP | Unclear ToS for video, Jellyfin guidelines object, added latency | Rejected for media |
| Caddy + Authelia / NPM | Simpler config or a GUI | Less label-driven IaC; weaker family user management | Rejected in favor of Traefik + Authentik |

## Feature Scope
### MVP
- [ ] **Host:** ZFS datasets, IOMMU/vfio, Debian 13 VM (q35/OVMF), Arc A380 passthrough (`/dev/dri/renderD128`, `vainfo` OK), virtiofs `/data` mount, Docker Engine + Compose plugin.
- [ ] **Download:** SABnzbd with categories `tv`, `tv-4k`, `movies`, `movies-4k`, `music`, `anime`.
- [ ] **Arr:** Prowlarr (indexers synced to all apps), Sonarr, Sonarr-4K, Radarr, Radarr-4K, Lidarr. Anime uses dedicated root folders plus anime profiles in the main Sonarr and Radarr.
- [ ] **Media:** Plex (Plex Pass, HW transcode, remote access on 32400), Jellyfin (QSV, backup server over the same libraries), Seerr (Plex login; 4K requests routed to the 4K instances and restricted to admin/approved users), Tautulli.
- [ ] **Edge:** Traefik v3 (DNS-01 wildcard certs via the Cloudflare API), `favonia/cloudflare-ddns` for the dynamic IP, Authentik (invites, MFA, OIDC for Jellyfin and Seerr where supported), CrowdSec + Traefik bouncer, geo-block middleware, secure-headers middleware.
- [ ] **Private admin:** Twingate connector container. Resources are the internal hostnames of the *arr apps, SABnzbd, FileFlows, Traefik dashboard, Homepage, Uptime Kuma, Tautulli, Proxmox UI and PBS.
- [ ] **Transcode:** FileFlows server + GPU node with an AV1 (QSV) flow and an off-peak processing window. After replacing a file it triggers a Sonarr/Radarr rescan. Starts with the HD libraries only (see Open Questions for 4K).
- [ ] **Quality automation:** Recyclarr (TRaSH profiles for HD, 4K and anime, with AV1 scoring neutralized), Bazarr (subtitles for HD Sonarr/Radarr), Maintainerr (Plex-rule cleanup, dry-run first).
- [ ] **Monitoring & alerts:** Homepage dashboard, Uptime Kuma, Notifiarr or Discord webhooks from the *arr apps, SAB, Seerr, Uptime Kuma and Diun.
- [ ] **Backups & updates:** vzdump to PBS for the VM, and Backrest/restic for `appdata` plus the ZFS snapshot schedule. Diun notifies about new images; updates are applied manually with pinned tags. Includes one documented restore drill.
- [ ] **Family onboarding:** Authentik invite flow, Plex library shares (4K libraries shared only with users on 4K/HDR-capable devices; 4K requests still need admin approval), and a one-page family guide ("install Plex, sign in, request in Seerr").

### Later
- [ ] Dedicated anime Sonarr/Radarr instances if shared-instance profiles get messy.
- [ ] Bazarr-4K instance.
- [ ] Kometa (collections and overlays) for Plex.
- [ ] Prometheus + Grafana + exporters (ZFS, GPU, *arr).
- [ ] Ansible playbook for VM provisioning (drivers, mounts, Docker).
- [ ] Books/audiobooks (Audiobookshelf + a Readarr alternative).
- [ ] Live TV/DVR (HDHomeRun).
- [ ] Jellyfin-side request parity and Jellyfin family accounts via Authentik OIDC auto-provisioning.

## Experience / Workflow
**Family request-to-watch:**
1. A family member opens `requests.<domain>` (Seerr) and signs in with their Plex account.
2. They request a movie or show. Auto-approved for family (HD); 4K requests need admin approval.
3. Seerr sends it to Radarr or Sonarr (4K requests to the 4K instances; anime is detected by series type).
4. The *arr app searches indexers via Prowlarr and sends the NZB to SABnzbd in the matching category.
5. SAB downloads and unpacks to `/data/usenet/complete/<category>`. The *arr app imports it with an atomic move or hardlink into `/data/media/...`.
6. Plex and Jellyfin detect the new file (partial scan via the connect notification) and Seerr notifies the requester.
7. In the off-peak window, FileFlows re-encodes eligible HD files to AV1, replaces them, and triggers a rescan in Sonarr/Radarr, Plex and Jellyfin.
8. The family member watches in the Plex app at home (direct) or remotely (the owner's Plex Pass covers them). Jellyfin at `jellyfin.<domain>` is the backup.

**Admin workflow:**
- The owner connects the Twingate client, opens `home.int.<domain>` (Homepage) and reaches every admin UI.
- Updates: Diun alert, bump the pinned tag in git, `git pull && docker compose up -d` on the VM, and check Uptime Kuma is green.
- Incident: an Uptime Kuma or Discord alert, then Dozzle or `docker compose logs`, then roll back with a Proxmox snapshot or git revert.

## Technical Direction
**Platform**
- Proxmox VE host with the ZFS pool `tank`. Datasets: `tank/data` (recordsize=1M, compression=lz4 because the media is already compressed) and `tank/backups`.
- VM `media-01` runs Debian 13: 8+ vCPU, 16-24 GB RAM, system and `appdata` on a host SSD (never on the media pool, because the *arr apps use SQLite). A380 passthrough with ReBAR enabled. `tank/data` is mounted at `/data` via virtiofs (NFS from the host as a fallback).
- One user `media` (PUID/PGID 1000) with umask 002 across all containers.

**Filesystem layout (TRaSH single-mount, hardlink-safe)**
```
/data
├── usenet/{incomplete,complete/{tv,tv-4k,movies,movies-4k,music,anime}}
├── media/{tv,tv-4k,movies,movies-4k,anime-tv,anime-movies,music}
└── transcode/            # FileFlows temp (or SSD path for speed)
/opt/appdata/<service>    # configs on the VM SSD
```
Every *arr, SAB and FileFlows container mounts `/data:/data`. Plex and Jellyfin mount `/data/media` read-only; Jellyfin also gets read-write access to metadata if needed.

**Repo layout**
```
compose.yaml              # include: stacks/*.yaml
stacks/edge.yaml          # traefik, authentik(+postgres), crowdsec, cloudflare-ddns, twingate-connector
stacks/media.yaml         # plex, jellyfin, seerr, tautulli
stacks/arr.yaml           # prowlarr, sonarr, sonarr-4k, radarr, radarr-4k, lidarr, bazarr, recyclarr, maintainerr
stacks/download.yaml      # sabnzbd
stacks/transcode.yaml     # fileflows (server + gpu node)
stacks/ops.yaml           # homepage, uptime-kuma, notifiarr, diun, backrest, dozzle
config/traefik/           # static + dynamic (middlewares: authentik, crowdsec, geoblock, headers, lan-only)
config/recyclarr/         # recyclarr.yml (HD, 4K, anime; AV1 CF neutralized)
.env.example              # DOMAIN, TZ, PUID/PGID, paths — real .env + secrets/ gitignored
scripts/                  # host-prep.md/sh, vm-bootstrap.sh, mkdirs.sh, backup/restore helpers
docs/                     # architecture, runbooks, family guide
```
Image tags are pinned (no `latest`). Secrets go in `secrets/` using Docker secrets or `_FILE` variables and are never committed.

**Networking and exposure matrix**
| Service | Hostname | Exposure | Auth |
|---------|----------|----------|------|
| Plex | `plex.<domain>` + 32400/tcp forwarded | Public (Plex remote access, custom server URL) | Plex account |
| Jellyfin | `jellyfin.<domain>` | Public via Traefik :443 | Jellyfin users (Authentik OIDC via SSO plugin); no forward-auth, because it breaks the apps |
| Seerr | `requests.<domain>` | Public via Traefik :443 | Plex login (Authentik in front optional) |
| Authentik | `auth.<domain>` | Public via Traefik :443 | MFA enforced for admins |
| *arr, SAB, FileFlows, Bazarr, Tautulli, Homepage, Kuma, Traefik dash, Proxmox, PBS | `*.int.<domain>` | **Twingate only** | Traefik `lan-only` allowlist + Authentik forward-auth + app auth |

- Router: forward **443** and **32400** only, to the VM. Ports 80 and 81 stay closed because certificates use DNS-01.
- DDNS: `cloudflare-ddns` updates the A/AAAA records for `plex`, `jellyfin`, `requests` and `auth` (grey cloud, not proxied) every 5 minutes. Plex remote access also reconnects on its own via plex.tv.
- `*.int.<domain>` is a Cloudflare wildcard A record pointing at the VM's private LAN IP. Twingate resources match that wildcard, and the connector (in Docker on the VM, or a small LXC) routes to it.
- Traefik uses a single `websecure` entrypoint. Public routers match the public hostnames. Internal routers match `*.int.<domain>` and always carry the `lan-only` middleware (ipAllowList restricted to the LAN and Twingate connector source IPs), so a public request with a spoofed Host header is still refused.
- Security: CrowdSec reads Traefik access logs and blocks via the bouncer plugin. Geo-block allows only the family's countries. Secure headers and rate limits apply to the Authentik login. Container ports are never published except Traefik 443 and Plex 32400.

**GPU sharing (Arc A380)**
- `/dev/dri` is passed to Plex, Jellyfin and the FileFlows node. The container user belongs to the `render` group.
- Plex: HW transcode on, HEVC decode on, remote quality set to Original/maximum with direct play preferred. Set a generous safety cap on the internet upload limit (e.g. 400 Mbps total), not a per-user 1080p cap.
- Jellyfin: QSV, with low-power H.264/HEVC/AV1 encoding and tone mapping on.
- FileFlows: 1 GPU runner, schedule 01:00-07:00. Flow: skip if already AV1 or under a size threshold, then QSV AV1 encode (ICQ/global quality tuned per resolution), keep all audio and subtitles, output MKV, reject the result if it's not at least 15-20% smaller, replace the original, then trigger a rescan in Sonarr/Radarr/Plex/Jellyfin.

**Avoiding FileFlows ↔ *arr conflicts**
- Recyclarr sets the AV1 custom format score to **0** (not negative) in every profile FileFlows touches.
- Set quality cutoffs so an AV1 file of the same resolution is not considered an upgrade target. Use "Upgrades allowed" carefully.
- FileFlows watches `/data/media/*` only, never `/data/usenet`, so it cannot process in-flight downloads.
- 4K libraries are **excluded from AV1 in the MVP** until quality is validated (see Open Questions).

**Data and backups**
- Proxmox: nightly vzdump of the VM to PBS (on `tank/backups` or separate hardware). Keep 7 daily and 4 weekly.
- Backrest/restic: nightly `/opt/appdata` (Authentik DB dump, *arr DBs via their built-in backups, Plex database excluding Cache/transcode) to an off-site target (B2/another location).
- ZFS: snapshots of `tank/data` via sanoid (hourly/daily), plus scrub and SMART alerts on the host.
- Media is **not** backed up off-site; the *arr databases are enough to re-acquire it.

## Open Questions
- **AV1 on 4K content:** re-encoding 4K remuxes and HDR/Dolby Vision content risks losing quality and DV metadata. The proposal is to exclude 4K until the A380's AV1 quality is tested on samples. Decide after a test in the transcode phase.
- ~~CGNAT~~: resolved, not behind CGNAT.
- ~~Upload bandwidth~~: resolved, 1 Gbps symmetrical.
- ~~Family client AV1 support~~: resolved, family is upgrading to AV1-capable devices (Google TV Streamer or equivalent). The family guide lists recommended devices.
- **Twingate connector location:** a container on the media VM (simple) or a separate LXC (keeps admin access working when the VM is down). The recommendation is a separate small LXC. Decide in the host phase.
- **Seerr authentication:** Plex login only, or Authentik forward-auth in front? This depends on whether Seerr's OIDC support is mature in the pinned version. Decide in the edge phase.
- **Usenet providers and indexers:** the owner supplies these; they are not part of the design.

## Start Input
**Project:** home-media-server. A GitOps Docker Compose repo for a Proxmox-hosted home media platform serving the owner and 1-5 family members.

**Stack:** Debian 13 VM on Proxmox; Intel Arc A380 passthrough; ZFS `tank/data` via virtiofs at `/data` (TRaSH hardlink layout). Services: SABnzbd, Prowlarr, Sonarr, Sonarr-4K, Radarr, Radarr-4K, Lidarr (anime via root folders and profiles), Plex (Plex Pass, primary), Jellyfin (backup), Seerr, Tautulli, Traefik v3, Authentik, CrowdSec, cloudflare-ddns (dynamic IP, Cloudflare DNS-only), Twingate connector (admin-only access), FileFlows (AV1 QSV, off-peak, HD only at first), Recyclarr, Bazarr, Maintainerr, Homepage, Uptime Kuma, Notifiarr/Discord, Diun, Backrest/restic, PBS.

**Constraints:** dynamic public IP; only ports 443 and 32400 forwarded; no Cloudflare proxy or Tunnel for media; secrets never committed; pinned image tags; Usenet only.

**Proposed phases:**
1. Host and VM foundation: ZFS datasets, IOMMU, VM, A380 passthrough, virtiofs, Docker, repo skeleton, `.env.example`, mkdirs.
2. Core automation and media: SAB, Prowlarr, the 4 Sonarr/Radarr instances + Lidarr, Plex, Jellyfin, Seerr; hardlink and HW-transcode verification.
3. Edge and secure access: DDNS, Traefik, Authentik, CrowdSec/geo-block, Twingate, router forwards (443, 32400).
4. Quality automation and AV1: Recyclarr (AV1-neutral), Bazarr, Maintainerr, FileFlows flow and sample validation.
5. Ops: Homepage, Uptime Kuma, Tautulli, notifications, Diun, PBS + restic backups, restore drill.
6. Family onboarding: invites, library sharing rules, family guide with AV1-capable device recommendations.

**Success criteria:** a family member can request, receive and stream a title remotely with no admin action (HD); no admin UI is reachable without Twingate; certificates renew and DDNS updates automatically; a VM restore from backup is proven; FileFlows reduces the size of the HD library without triggering *arr re-downloads.
