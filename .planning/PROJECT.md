# home-media-server

## What This Is
This is a GitOps Docker Compose repository for a home media platform on Proxmox. It covers a complete Usenet ARR stack, with Plex as the media server (Jellyfin runs only as an optional side-by-side evaluation). Traefik and Authentik handle public access, Twingate provides the only way into the admin tools, DDNS tracks the dynamic IP, and FileFlows converts the library to AV1 on an Intel Arc A380. Everything is reproducible from this repo except secrets.

## Core Value
Family members request a title in one place, it appears automatically at the right quality, and they can watch it anywhere without help. The owner gets private admin access, SSO, AV1 space savings, and monitoring and backups from day one, all managed through git.

## Who It's For
- **Owner/admin:** runs the Proxmox host and manages everything over Twingate.
- **Family (1-5 users):** watch on AV1-capable TVs (Google TV Streamer or equivalent), phones and browsers, at home and remotely, via Plex, and request titles through Seerr.

## Requirements

### Validated
(None yet — ship to validate)

### Active
- [ ] **R1 Repo foundation:** `compose.yaml` using `include:` with stacks/{edge,media,arr,download,transcode,ops}.yaml, `.env.example`, gitignored `secrets/`, pinned image tags, `scripts/mkdirs.sh`, and a docs skeleton.
- [ ] **R2 Host & VM:** ZFS datasets (`tank/data` with recordsize=1M, `tank/backups`), IOMMU/vfio, a Debian 13 VM (q35/OVMF) with appdata on SSD, Arc A380 passthrough (ReBAR where the platform supports it; `vainfo` OK), `/data` mounted via virtiofs, Docker Engine and the Compose plugin. Delivered as a runbook plus scripts.
- [ ] **R3 Download:** SABnzbd with categories tv, tv-4k, movies, movies-4k, music, anime, following the TRaSH single `/data` layout.
- [ ] **R4 Arr:** Prowlarr syncing to Sonarr, **Sonarr-Anime**, Sonarr-4K, Radarr, Radarr-4K and Lidarr. Anime series use the dedicated Sonarr-Anime instance (migrated from the old `animesonarr`), and anime movies use the `anime-movies` root folder in the main Radarr. Imports are hardlinks or atomic moves.
- [ ] **R5 Media:** Plex (Plex Pass, QSV hardware transcoding, remote access on 32400, remote quality set to Original with an overall cap of about 400 Mbps), Jellyfin as an **optional evaluation** only (QSV, same libraries read-only, off by default behind a Compose profile, started on demand to test whether it could replace Plex), Seerr (Plex login; 4K requests go to the 4K instances and need admin approval; TV requests need admin approval so anime can be routed to Sonarr-Anime), Tautulli. 4K titles live only in separate **Movies 4K** and **TV 4K** Plex libraries, shared with every family member (non-4K devices get an HDR-tone-mapped transcode).
- [ ] **R6 Edge:** Traefik v3 with wildcard certificates via Cloudflare DNS-01, `cloudflare-ddns` for the dynamic IP (DNS-only records), Authentik (invites, admin MFA; OIDC and a public route for Jellyfin only if it is adopted after evaluation), CrowdSec bouncer, geo-block, secure headers. Only ports 443 and 32400 are forwarded.
- [ ] **R7 Private admin:** Twingate connector in a **separate LXC**, reusing the existing Twingate network. (In place: LXC 101 on the Proxmox host, deployed with the community-scripts twingate-connector script, confirmed working 2026-09-28.) Admin UIs live under `*.int.<domain>` behind the `lan-only` ipAllowList plus Authentik forward-auth.
- [ ] **R8 AV1 transcode:** FileFlows server and GPU node, QSV AV1, running 01:00-07:00 with 1 runner, covering all libraries including 4K.
  - 4K is 10-bit and keeps HDR10. Dolby Vision profile 7/8 files lose the DV layer; profile 5 files are skipped.
  - A converted file is kept only if it's at least 15-20% smaller, and each replacement triggers a rescan in the *arr apps and Plex (and Jellyfin when it is running).
- [ ] **R9 Quality automation:** Recyclarr (TRaSH HD, 4K and anime profiles; AV1 and DV custom-format scores set to 0; DV without HDR10 fallback blocked), Bazarr (HD), Maintainerr (dry-run first).
- [ ] **R10 Monitoring & alerts:** Homepage, Uptime Kuma, Notifiarr/Discord webhooks, Dozzle, Diun update notifications.
- [ ] **R11 Backups:** nightly vzdump to Proxmox Backup Server (PBS), Backrest/restic of appdata off-site, sanoid snapshots of `tank/data`, ZFS scrub and SMART alerts, and a documented restore drill that has actually been run.
- [ ] **R12 Family onboarding:** Authentik invite flow, Plex library sharing (every family member gets all libraries, including Movies 4K and TV 4K; non-4K devices transcode), and a one-page family guide with recommended AV1-capable devices.

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
- The media `/data` pool is an **existing ZFS pool on SSDs**, migrated from the old server (exported there, imported on a fresh Proxmox install). It holds a media library that must be kept and adopted, not re-downloaded. Inventory: pool `tank`, 1.14T used, 9.56T free, media stored directly in the root dataset. The library is copied once into `tank/data` (runbook 01 §1a case d): movies→media/movies, shows→media/tv, anime (series only)→media/anime-tv, music→media/music, with 4K mixed in and split in Phase 2. The live *arr/Plex/SAB configs were on the old Ubuntu VM's own disk (`/docker`, ext4), not the pool. They are archived to `/tank/migration/old-docker-<date>.tar.zst` before the export (runbook 01 §1a step 0) and restored in Phase 2. `/tank/docker` is not the live config. `/tank/template` is registered as ISO storage. Books are out of scope. SSD capacity is limited, so AV1 conversion matters.
- Dynamic public IP, so DDNS is required. Not behind CGNAT. 1 Gbps symmetrical fiber.
- Only ports 443 and 32400 are forwarded. No Cloudflare proxy (orange cloud) on media hostnames.
- Secrets are never committed; image tags are pinned, never `latest`.
- A single Proxmox VM holds the whole stack. One Arc A380 is shared by Plex, FileFlows and (when running) Jellyfin.
- Host hardware (confirmed 2026-09-28): Dell desktop, Intel Skylake CPU (8 threads) with HD 530 iGPU as the host console, 16 GB DDR4 (2×8 GB, 2 slots free, board max 64 GB), Proxmox VE 9.2 on ext4/LVM with GRUB (`local-lvm` for VM disks). No Resizable BAR or Above 4G Decoding option in the BIOS, so the A380 runs with a 256 MB BAR (fine for QSV/AV1 media work). VM 200 is sized 6 cores / 10 GB and the ZFS ARC is capped at 2 GB; a RAM upgrade to 32 GB is optional.
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
| Remote access | Easy for family, admin tools stay private | Hybrid: Plex direct, Seerr via Traefik, admin via Twingate (Jellyfin via Traefik only if adopted) |
| DNS | Dynamic IP; ToS-safe for media | Cloudflare DNS-only + cloudflare-ddns |
| Request app | Overseerr and Jellyseerr merged in 2026 | Seerr |
| Primary server | Owner's Plex Pass covers family remote streaming | Plex |
| Jellyfin | Owner wants to evaluate it as a possible Plex replacement, not run it as a standing backup (decided 2026-09-28) | Optional evaluation: off by default (Compose profile `jellyfin`), same read-only libraries + QSV; Authentik OIDC, public route and family docs only if adopted |
| 4K/anime | Keep family on appropriate quality; keep the existing anime instance's history | Separate 4K instances; a dedicated Sonarr-Anime instance (migrated); anime movies via a root folder in Radarr |
| 4K titles (2026-09-28) | Limited SSD space; everyone should still be able to watch | 4K-only (no HD copies; HD instances unmonitor them); separate Plex Movies 4K / TV 4K libraries shared with everyone. An explicit HD request for a 4K-only title is allowed to download an HD copy |
| Anime routing (2026-09-28) | Seerr can't auto-route anime to a separate Sonarr (override rules only set profile/root/tags) | TV requests need admin approval; the owner switches anime requests to Sonarr-Anime while pending. Movies stay auto-approved; 4K always needs approval |
| Phase 2 approach (2026-09-28) | Restore live state safely, once | Pragmatic: restore old configs (not rebuild), remap paths via each app's API, scripted wiring/4K split/verification, owner UI for Plex/Seerr. Spec: `.planning/specs/02-core-media-automation-spec.md` |
| Old stack migration | Old server ran qBittorrent+gluetun+flaresolverr, NZBGet, a separate animesonarr, and a Twingate connector | Usenet only (retire torrents and NZBGet); keep a separate anime Sonarr; Twingate connector moves to a separate LXC. See `.planning/migration/old-stack-inventory.md` |
| AV1 | Save space; family devices support AV1 | FileFlows on all libraries including 4K; HDR10 kept, DV dropped |
| Media pool | Owner is moving SSDs with an existing pool and library into the new server | Import (optionally renamed to `tank`); consolidate into a single `<pool>/data` dataset; `05-import-pool.sh` + runbook 01 §1a |
| Execution mode | Host, router and GPU steps are high-stakes | Guided |
| Planning depth | Design already defines 6 phases | Standard |
| Cost profile | default | Balanced |

## Architecture Influences
- Compose `include:` joins the domain stack files. Only Traefik (443) and Plex (32400) publish ports. Internal routers carry the `lan-only` middleware plus Authentik forward-auth.
- TRaSH single-mount `/data/{usenet,media}` layout, PUID/PGID 1000, umask 002. Plex and Jellyfin get `/data/media` read-only.
- `/dev/dri` is shared by Plex, FileFlows and (when running) Jellyfin; FileFlows only runs off-peak.
- Recyclarr profiles must neutralize the AV1 and DV custom formats to prevent *arr upgrade loops after FileFlows replaces a file.
- Recovery stack: Proxmox snapshots, then PBS, then restic of appdata; git revert handles config.

---
*Last updated: 2026-09-28 (Jellyfin optional evaluation; host hardware; Phase 2 decisions: 4K access, anime routing, approach)*
