# home-media-server

## What This Is
This is a GitOps Docker Compose repository for a home media platform on Proxmox. It covers a complete Usenet ARR stack, with Plex as the primary server and Jellyfin as a backup. Traefik and Authentik handle public access, Twingate provides the only way into the admin tools, DDNS tracks the dynamic IP, and FileFlows converts the library to AV1 on an Intel Arc A380. Everything is reproducible from this repo except secrets.

## Core Value
Family members request a title in one place, it appears automatically at the right quality, and they can watch it anywhere without help. The owner gets private admin access, SSO, AV1 space savings, and monitoring and backups from day one, all managed through git.

## Who It's For
- **Owner/admin:** runs the Proxmox host and manages everything over Twingate.
- **Family (1-5 users):** watch on AV1-capable TVs (Google TV Streamer or equivalent), phones and browsers, at home and remotely, via Plex (primary) or Jellyfin (backup), and request titles through Seerr.

## Requirements

### Validated
(None yet — ship to validate)

### Active
- [ ] **R1 Repo foundation:** `compose.yaml` using `include:` with stacks/{edge,media,arr,download,transcode,ops}.yaml, `.env.example`, gitignored `secrets/`, pinned image tags, `scripts/mkdirs.sh`, and a docs skeleton.
- [ ] **R2 Host & VM:** ZFS datasets (`tank/data` with recordsize=1M, `tank/backups`), IOMMU/vfio, a Debian 13 VM (q35/OVMF) with appdata on SSD, Arc A380 passthrough with ReBAR (`vainfo` OK), `/data` mounted via virtiofs, Docker Engine and the Compose plugin. Delivered as a runbook plus scripts.
- [ ] **R3 Download:** SABnzbd with categories tv, tv-4k, movies, movies-4k, music, anime, following the TRaSH single `/data` layout.
- [ ] **R4 Arr:** Prowlarr syncing to Sonarr, Sonarr-4K, Radarr, Radarr-4K and Lidarr. Anime uses its own root folders and profiles in the main Sonarr and Radarr. Imports are hardlinks or atomic moves.
- [ ] **R5 Media:** Plex (Plex Pass, QSV hardware transcoding, remote access on 32400, remote quality set to Original with an overall cap of about 400 Mbps), Jellyfin (QSV, same libraries), Seerr (Plex login; 4K requests go to the 4K instances and need admin approval), Tautulli.
- [ ] **R6 Edge:** Traefik v3 with wildcard certificates via Cloudflare DNS-01, `cloudflare-ddns` for the dynamic IP (DNS-only records), Authentik (invites, admin MFA, OIDC for Jellyfin), CrowdSec bouncer, geo-block, secure headers. Only ports 443 and 32400 are forwarded.
- [ ] **R7 Private admin:** Twingate connector (preferably in a separate LXC). Admin UIs live under `*.int.<domain>` behind the `lan-only` ipAllowList plus Authentik forward-auth.
- [ ] **R8 AV1 transcode:** FileFlows server and GPU node, QSV AV1, running 01:00-07:00 with 1 runner, covering all libraries including 4K.
  - 4K is 10-bit and keeps HDR10. Dolby Vision profile 7/8 files lose the DV layer; profile 5 files are skipped.
  - A converted file is kept only if it's at least 15-20% smaller, and each replacement triggers a rescan in the *arr apps, Plex and Jellyfin.
- [ ] **R9 Quality automation:** Recyclarr (TRaSH HD, 4K and anime profiles; AV1 and DV custom-format scores set to 0; DV without HDR10 fallback blocked), Bazarr (HD), Maintainerr (dry-run first).
- [ ] **R10 Monitoring & alerts:** Homepage, Uptime Kuma, Notifiarr/Discord webhooks, Dozzle, Diun update notifications.
- [ ] **R11 Backups:** nightly vzdump to Proxmox Backup Server (PBS), Backrest/restic of appdata off-site, sanoid snapshots of `tank/data`, ZFS scrub and SMART alerts, and a documented restore drill that has actually been run.
- [ ] **R12 Family onboarding:** Authentik invite flow, Plex library sharing rules (4K only for users with 4K/HDR-capable devices), and a one-page family guide with recommended AV1-capable devices.

### Out of Scope
- Torrents or a VPN download container (Usenet only)
- Books and audiobooks (Readarr is retired)
- Public or open sign-up (invite only)
- Kubernetes or multi-node HA
- Streaming media through a Cloudflare proxy or Tunnel
- Live TV/DVR
- Preserving Dolby Vision
- Off-site backup of the media files themselves (they can be re-acquired from the *arr databases)

## Constraints
- The media `/data` pool is an **existing ZFS pool on SSDs**, migrated from the old server (exported there, imported on a fresh Proxmox install). It holds a media library that must be kept and adopted, not re-downloaded. Inventory: pool `tank`, 1.14T used, 9.56T free, media stored directly in the root dataset. The library is copied once into `tank/data` (runbook 01 §1a case d). SSD capacity is limited, so AV1 conversion matters.
- Dynamic public IP, so DDNS is required. Not behind CGNAT. 1 Gbps symmetrical fiber.
- Only ports 443 and 32400 are forwarded. No Cloudflare proxy (orange cloud) on media hostnames.
- Secrets are never committed; image tags are pinned, never `latest`.
- A single Proxmox VM holds the whole stack. One Arc A380 is shared by Plex, Jellyfin and FileFlows.
- appdata stays on the VM's SSD, never on network or ZFS media storage (the apps use SQLite).
- Physical, router, Proxmox-host and third-party account steps (Cloudflare, Twingate, Plex, Usenet providers and indexers) are carried out by the owner. The repo provides runbooks, scripts and config for them.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Design source | Exploration completed 2026-09-23 | `.planning/explorations/2026-09-23-home-media-server-design.md` |
| Codebase map | Greenfield repo with no source code | Skipped |
| Approach | Fits 1-5 users on one host and covers every requested capability | Balanced modular Compose + FileFlows |
| Host layout | Simple, snapshot-able, dedicated GPU | 1 Debian 13 VM + Arc A380 passthrough |
| Storage | Host-managed ZFS, hardlink-safe | `tank/data` via virtiofs as `/data` |
| Downloads | Simplicity; no VPN needed | Usenet only (SABnzbd) |
| Proxy/SSO | Label-driven infrastructure as code; family user management | Traefik v3 + Authentik |
| Remote access | Easy for family, admin tools stay private | Hybrid: Plex direct, Jellyfin/Seerr via Traefik, admin via Twingate |
| DNS | Dynamic IP; ToS-safe for media | Cloudflare DNS-only + cloudflare-ddns |
| Request app | Overseerr and Jellyseerr merged in 2026 | Seerr |
| Primary server | Owner's Plex Pass covers family remote streaming | Plex primary, Jellyfin backup |
| 4K/anime | Keep family on appropriate quality; stay manageable | Separate 4K instances; anime via root folders and profiles |
| AV1 | Save space; family devices support AV1 | FileFlows on all libraries including 4K; HDR10 kept, DV dropped |
| Media pool | Owner is moving SSDs with an existing pool and library into the new server | Import (optionally renamed to `tank`); consolidate into a single `<pool>/data` dataset; `05-import-pool.sh` + runbook 01 §1a |
| Execution mode | Host, router and GPU steps are high-stakes | Guided |
| Planning depth | Design already defines 6 phases | Standard |
| Cost profile | default | Balanced |

## Architecture Influences
- Compose `include:` joins the domain stack files. Only Traefik (443) and Plex (32400) publish ports. Internal routers carry the `lan-only` middleware plus Authentik forward-auth.
- TRaSH single-mount `/data/{usenet,media}` layout, PUID/PGID 1000, umask 002. Plex and Jellyfin get `/data/media` read-only.
- `/dev/dri` is shared by Plex, Jellyfin and FileFlows; FileFlows only runs off-peak.
- Recyclarr profiles must neutralize the AV1 and DV custom formats to prevent *arr upgrade loops after FileFlows replaces a file.
- Recovery stack: Proxmox snapshots, then PBS, then restic of appdata; git revert handles config.

---
*Last updated: 2026-09-23 after initialization*
