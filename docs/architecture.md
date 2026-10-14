# Architecture

## Overview
home-media-server is a GitOps Docker Compose repository for a home media platform running on a single Proxmox host. A Debian 13 VM with an Intel Arc A380 passed through runs every container. Compose stack files are split by domain (edge, media, arr, download, transcode, ops) and joined at the root with `include:`. Family members request titles through Seerr, the *arr apps fetch them via SABnzbd over Usenet, and Plex serves the result (Jellyfin can be started on demand to evaluate it as a replacement). Traefik and Authentik handle public access for Seerr/Authentik, Plex uses its own remote access on port 32400, and every admin UI is reachable only through Twingate. FileFlows re-encodes the library to AV1 on the Arc A380 during an off-peak window. Everything is reproducible from this repo except secrets, which are never committed.

```
                     Proxmox host (ZFS pool "tank")
                     ┌─────────────────────────────┐
                     │ tank/data      tank/backups  │
                     │   │                           │
                     │   │ virtiofs (media-data)      │
                     │   ▼                           │
                     │ ┌───────────────────────────┐ │
                     │ │ VM: media-01 (Debian 13)   │ │
                     │ │  /data  <- virtiofs mount  │ │
                     │ │  /opt/appdata <- local SSD │ │
                     │ │                            │ │
                     │ │  Docker Engine + Compose   │ │
                     │ │  ┌──────────────────────┐  │ │
                     │ │  │ stacks: edge, media,  │  │ │
                     │ │  │ arr, download,        │  │ │
                     │ │  │ transcode, ops        │  │ │
                     │ │  │ (joined via proxy net)│  │ │
                     │ │  └──────────────────────┘  │ │
                     │ │  Arc A380 (/dev/dri)       │ │
                     │ └───────────────────────────┘ │
                     └─────────────────────────────┘
```

## Repository layout
```
compose.yaml            # root Compose file; include: of stacks/*.yaml
stacks/_common.yaml      # shared `base` service template, pulled in via extends
stacks/edge.yaml         # traefik, authentik, crowdsec, cloudflare-ddns, twingate-connector (Phase 3)
stacks/media.yaml        # plex, seerr, tautulli; jellyfin behind the optional `jellyfin` profile (Phase 2)
stacks/arr.yaml          # prowlarr, sonarr(-anime, -4k), radarr(-4k), lidarr, bazarr, recyclarr, maintainerr (Phases 2, 4)
stacks/download.yaml     # sabnzbd (Phase 2)
stacks/transcode.yaml    # fileflows (Phase 4)
stacks/ops.yaml          # homepage, uptime-kuma, notifiarr, diun, backrest, dozzle (Phase 5)
.env.example             # env contract consumed by every stack file and script
.gitignore               # ignores .env and secrets/ (except .gitkeep)
secrets/                 # gitignored; Docker secrets or *_FILE sources
scripts/lib/             # scripts/lib/common.sh — shared logging/run/require helpers sourced by every script
scripts/host/            # scripts/host/*.sh — Proxmox host steps: ZFS datasets, IOMMU/vfio, VM creation
scripts/vm/               # scripts/vm/*.sh — guest VM steps: bootstrap and verify.sh
scripts/ci/               # scripts/ci/*.sh — CI-only tooling: pinned-image check, host script stubs
docs/                     # this file, the docs index, and the runbooks
```

## Storage layout
The ZFS pool `tank` holds two datasets on the Proxmox host:
- `tank/data` (recordsize=1M, compression=lz4, atime=off, xattr=sa) — a single dataset with **no child datasets**. This is required because hardlinks cannot cross ZFS dataset boundaries, and the *arr apps import downloads into the media library with a hardlink or atomic move. Any subdirectory work happens inside this one dataset, never as a separate dataset.
- `tank/backups` (compression=zstd) — target for `vzdump`.

The media pool is not created from scratch: it is an **existing** ZFS pool
on SSDs, migrated (via `zpool export`/`zpool import`) from an old server
that is still running, and it already holds a media library that must be
kept. See runbook 01, section 1a for the import, ownership and
consolidation procedure. Whatever its origin, it must still end up as a
single `tank/data` dataset with no children — the requirement below is
unchanged by the migration.

`tank/data` is exposed to the VM through a Proxmox directory mapping (`media-data` → `/tank/data`), attached to the VM as a `virtiofs0` share, and mounted inside the VM at `/data` via fstab (`media-data /data virtiofs defaults,nofail 0 0`). An NFS export is documented as a fallback in the host runbook if virtiofs is unavailable.

`APPDATA_ROOT` (`/opt/appdata` by default) lives on the VM's local SSD, never on `/data`, because the *arr apps, Plex and other services store SQLite databases there and network/ZFS-backed storage is unsuitable for that access pattern.

The full `/data` tree (TRaSH single-mount, hardlink-safe layout), created by `scripts/mkdirs.sh`:
```
/data
├── usenet/
│   ├── incomplete/
│   └── complete/
│       ├── tv/
│       ├── tv-4k/
│       ├── movies/
│       ├── movies-4k/
│       ├── music/
│       └── anime/
├── media/
│   ├── tv/
│   ├── tv-4k/
│   ├── movies/
│   ├── movies-4k/
│   ├── anime-tv/
│   ├── anime-movies/
│   └── music/
└── transcode/            # FileFlows working directory
```
That is 14 leaf directories under `usenet/` and `media/` (7 each), plus `transcode/` which is created but not counted among the 14. `media/anime-tv` and `media/anime-movies` give anime its own root folders so Sonarr/Radarr profiles can target it without colliding with the general TV/movie libraries.

## Networking and exposure
Every stack file declares the same external Docker network:
```yaml
networks:
  proxy:
    name: proxy
    external: true
```
It is created once, outside Compose, by `scripts/vm/00-bootstrap.sh` (`docker network create proxy`). Declaring it identically in every stack file keeps each stack self-describing and lets a service in any stack join `proxy` without editing another file; Compose merges identical external network declarations across included files.

Only two ports are forwarded on the router, straight to the VM:

| Service | Hostname | Exposure | Auth |
|---------|----------|----------|------|
| Plex | `plex.<domain>` | Direct, port 32400/tcp forwarded (Plex's own remote access) | Plex account |
| Jellyfin *(only if adopted after evaluation)* | `jellyfin.<domain>` | Not exposed while under evaluation (LAN/Twingate only); public via Traefik on 443 if adopted | Jellyfin login (Authentik OIDC if adopted) |
| Seerr | `requests.<domain>` | Public via Traefik on 443 | Plex login |
| Authentik | `auth.<domain>` | Public via Traefik on 443 | MFA enforced for admins |
| All admin UIs (*arr, SABnzbd, FileFlows, Homepage, Uptime Kuma, Traefik dashboard, etc.) | `*.int.<domain>` | **Twingate only** | Traefik `lan-only` ipAllowList + Authentik forward-auth + app auth |

Ports 80 and 81 stay closed because certificates are issued via Cloudflare DNS-01, not HTTP-01. `cloudflare-ddns` keeps the public (DNS-only, not proxied) A/AAAA records for the public hostnames pointed at the current WAN IP.

Plex's `32400` is the only port the stack files publish, and the only permanent one. Every other service is reached by service name on `proxy` (e.g. `http://sabnzbd:8080`).

Admin UIs publish no ports at all: they are reached only as `<service>.int.<domain>`, through Twingate, Traefik's `lan-only` allowlist and Authentik forward-auth (see runbook 04).

Traefik applies four middleware chains, defined once as labels on the `traefik` service:

| Chain | Middlewares | Used by |
|-------|-------------|---------|
| `int` | `lan-only`, `secure-headers`, `authentik` | Every `*.int.<domain>` route and the Traefik dashboard |
| `lan-admin` | `lan-only`, `secure-headers` | Authentik's own `/if/admin` and its admin-only `/api/v3/` prefixes (no forward-auth, or it would protect itself) |
| `public` | `crowdsec`, `geoblock`, `rate-limit`, `secure-headers` | The internet-facing routes: Seerr, and Jellyfin if adopted |
| `public-auth` | `crowdsec`, `geoblock`, `auth-rate-limit`, `secure-headers` | The Authentik login (`auth.<domain>`), with a stricter per-address rate limit |

The CrowdSec engine runs on its own `crowdsec` network, shared only with Traefik's bouncer plugin, and reads Traefik's access log. Both Traefik plugins are local plugins: `scripts/vm/45-traefik-plugins.sh` installs them at the commits locked in `config/traefik/plugins.lock`, and Traefik loads them read-only without downloading anything. The geo-block admits only `GEO_ALLOWED_COUNTRIES` (private addresses always pass). Plex is not behind Traefik: `32400/tcp` is forwarded straight to Plex, which is the only exposure besides 443.

## Service template
New services extend the shared `base` template from `stacks/_common.yaml` instead of repeating `restart`, `security_opt`, `environment`, `dns` and `logging` on every service. The template sets the container DNS servers (`DNS_PRIMARY` / `DNS_SECONDARY` in `.env`, default `1.1.1.1` and `8.8.8.8`): Docker's built-in DNS forwards to the VM's `resolv.conf` list, and a slow or dead first entry made lookups time out inside containers:

```yaml
services:
  jellyfin:
    extends:
      file: _common.yaml
      service: base
    image: jellyfin/jellyfin:10.9.11   # pinned, never :latest
    networks:
      - proxy
```

Note that YAML anchors and aliases (`&name` / `*name`) do not work across `include:` file boundaries in Compose — each included file is parsed independently — so shared defaults must go through `extends:` with an explicit `file:` reference to `_common.yaml`, as verified locally with Docker Compose v5.1.1.
