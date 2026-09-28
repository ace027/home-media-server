# Old Stack Inventory & Migration Decisions

Source: the old Ubuntu VM's `docker ps` (2026-09-23). Configs live in `/docker` on that VM's own disk (`/dev/sda2`, ext4), 4.2G in total. They are archived to `/tank/migration/old-docker-<date>.tar.zst` per runbook 01 §1a step 0. Every image ran `:latest`, so the exact versions come from `/docker/_versions.txt`, which the owner captures before archiving. Restores must use the **same or newer** versions.

| Old container | Image | Decision | Target (new stack) | Phase |
|---|---|---|---|---|
| plex | lscr.io/linuxserver/plex | Migrate config (watch state, metadata; excluding Cache) and remap library paths to `/data/media/*` | `plex` (media) | 2 |
| seerr | ghcr.io/seerr-team/seerr | Migrate config; re-point to the new *arr instances, and add the 4K servers | `seerr` (media) | 2 |
| tautulli | lscr.io/linuxserver/tautulli | Migrate config/history | `tautulli` (media) | 2 |
| sonarr | lscr.io/linuxserver/sonarr | Migrate DB; remap the root folder to `/data/media/tv` | `sonarr` (arr) | 2 |
| animesonarr | lscr.io/linuxserver/sonarr | **Keep as a separate instance.** Migrate DB; root folder `/data/media/anime-tv` | `sonarr-anime` (arr) | 2 |
| radarr | lscr.io/linuxserver/radarr | Migrate DB; root folder `/data/media/movies`; 4K titles split out to radarr-4k | `radarr` (arr) | 2 |
| lidarr | lscr.io/linuxserver/lidarr | Migrate DB; root folder `/data/media/music` | `lidarr` (arr) | 2 |
| prowlarr | lscr.io/linuxserver/prowlarr | Migrate; **remove torrent indexers** and re-sync apps (including the new 4K and anime instances) | `prowlarr` (arr) | 2 |
| sabnzbd | lscr.io/linuxserver/sabnzbd | Migrate config (servers); set categories tv, tv-4k, movies, movies-4k, music, anime and paths `/data/usenet/*` | `sabnzbd` (download) | 2 |
| bazarr | lscr.io/linuxserver/bazarr | Migrate config; re-point to the new Sonarr/Radarr | `bazarr` (arr) | 4 |
| servarr-fileflows-1 | revenz/fileflows | Export existing flows for reference; the new AV1 QSV flows are built fresh | `fileflows` (transcode) | 4 |
| twingate-overjoyed-wren | twingate/connector | Reuse the existing Twingate network/resources. New connector in a **separate LXC**, deployed before the old VM is retired | LXC (not compose) | 3 |
| nzbget | lscr.io/linuxserver/nzbget | **Retire** (SABnzbd only). Remove it as a download client in the *arr apps | — | 2 |
| qbittorrent | lscr.io/linuxserver/qbittorrent | **Retire** (Usenet only). Remove it as a download client in the *arr apps | — | 2 |
| gluetun | qmcgaw/gluetun | **Retire** (only served qBittorrent) | — | — |
| flaresolverr | ghcr.io/flaresolverr/flaresolverr | **Retire** (only used by torrent indexers) | — | — |
| deunhealth | qmcgaw/deunhealth | **Retire** (paired with gluetun). Health alerting comes in Phase 5 | — | 5 |

## Old `/docker` layout
There are two compose projects on the old VM:
- `/docker/plex`: plex, seerr, tautulli.
- `/docker/servarr`: every other container.

The archive also holds `_containers.txt`, `_inspect.json`, `_versions.txt`, `_layout.txt` and `_compose-resolved.yml`. The resolved compose file's `volumes:` mappings define the **old in-container paths** that the *arr databases and Plex libraries reference. Phase 2 remaps each of them to `/data/media/*` (or keeps compatible mount paths where remapping is riskier). Restore target: `/docker/<project>/<app>` → `/opt/appdata/<app>`, with `animesonarr` → `sonarr-anime`.

New instances with no old config: `sonarr-4k`, `radarr-4k`, plus Traefik, Authentik, CrowdSec, cloudflare-ddns, Recyclarr, Maintainerr, and the Phase 5 ops apps.
