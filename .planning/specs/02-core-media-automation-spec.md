# Spec: Phase 2 — Core Media Automation

## Overview
Phase 2 completes the loop on the LAN: request, then download, then import, then play. It has three parts:
- **R3:** SABnzbd, set up with the TRaSH categories.
- **R4:** Prowlarr plus six *arr instances.
- **R5:** Plex with QSV on the A380, Seerr and Tautulli. Jellyfin is an optional evaluation, behind a Compose profile.

The old configs (Plex, Seerr, Tautulli, Sonarr, animesonarr, Radarr, Lidarr, Prowlarr, SABnzbd) are **restored, not rebuilt**, so settings, history and Plex watch state survive. Their `/data/...` paths are then remapped to the new layout using each app's own API. The library already in `tank/data/media` is adopted in place, with no re-downloads.

Architecture approach: **Pragmatic** (chosen in `/legion:plan 2` step 3.5 over Minimal and Clean):
- **Scripted**, because they are risky or easy to get wrong: the restore (with rollback), the path remap, the SAB/*arr/Prowlarr wiring, the 4K split, and verification.
- **Done by the owner in the app UIs**, because they are one-time decisions: Plex libraries and network settings, Seerr servers and permissions, and the 4K quality profile choice.

All new host and VM scripts follow the Phase 1 contract in `.planning/specs/01-host-repo-foundation-spec.md` (API and Type Contracts): dry-run by default, `--apply`, `common.sh`, exit codes 0/1/2, and PASS/FAIL/SKIP output for verifiers.

## Evidence (verified 2026-09-28)
Taken from the owner's migration archive `/tank/migration/old-docker-2026-09-27.tar.zst` (non-secret fields only) and from upstream source and registries:

| Fact | Value | Source |
|---|---|---|
| Old image versions | plex `1.43.4.10903-e5521bd8c-ls324`, seerr `v3.4.1`, tautulli `v2.17.2-ls240`, sonarr and animesonarr `4.0.19.2979-ls321`, radarr `6.3.0.10514-ls313`, lidarr `3.1.0.4875-ls39`, prowlarr `2.5.2.5491-ls156`, sabnzbd `5.1.1-ls268` | `docker/_versions.txt` |
| Tags exist | All eight exact tags exist (Docker Hub v2 / GHCR) | registry API |
| Jellyfin tag | `lscr.io/linuxserver/jellyfin:12.1ubu2604-ls50` (current stable) | Docker Hub |
| Old mounts | Every app used `/data:/data` and `/config` (Seerr: `/app/config`); Plex used `network_mode: host` + `/dev/dri` | `docker/_compose-resolved.yml` |
| Old *arr roots | sonarr `/data/shows/`, animesonarr `/data/anime/`, radarr `/data/movies/`, lidarr none | `RootFolders` table |
| Old Plex sections | Movies `/data/movies`, TV Shows `/data/shows`, Music `/data/music`, Anime TV `/data/anime` | `section_locations` |
| Old SABnzbd | `download_dir=/data/downloads/sabnzbd/incomplete`, `complete_dir=/data/downloads/sabnzbd/complete`, categories `*`, `software`, `movies`, `series`, `anime-series` (no per-category dir) | `sabnzbd.ini` |
| Archive members | `docker/plex/config`, `docker/plex/seerr/config`, `docker/plex/tautulli`, `docker/servarr/{sonarr,animesonarr,radarr,lidarr,prowlarr,sabnzbd,bazarr,nzbget,fileflows}` | archive listing |
| Usenet imports | Sonarr/Radarr always **move** SABnzbd downloads (`CanMoveFiles=true`), which is a same-inode rename on one filesystem. Hardlinks only apply to Copy mode (torrents). History `downloadFolderImported` records `droppedPath` and `importedPath` | Sonarr/Radarr source |
| Path editor | `PUT /api/v3/series/editor` (`seriesIds`) and `/api/v3/movie/editor` (`movieIds`), each with `rootFolderPath` and `moveFiles:false`, update DB paths only | Sonarr/Radarr source |
| Unmonitor risk | Sonarr `autoUnmonitorPreviouslyDownloadedEpisodes` / Radarr `autoUnmonitorPreviouslyDownloadedMovies` unmonitor items whose files seem missing during a scan | Sonarr source |
| Prowlarr | Indexer `protocol` is `usenet` or `torrent`. App fields: `prowlarrUrl`, `baseUrl`, `apiKey`, `syncCategories`, `animeSyncCategories`. `syncLevel` is a **top-level** property of the application resource (not a `fields[]` entry); the schema defaults it to `disabled`, so it must be set to `fullSync` explicitly. Sync command: `{"name":"ApplicationIndexerSync","forceSync":true}` | Prowlarr source |
| SABnzbd API | `get_config`; `set_config&section=categories&keyword=<n>&dir=<d>` (creates the category if missing); `del_config&section=categories&keyword=<n>`; misc settings one per call via `set_config&section=misc&keyword=<k>&value=<v>`; `mode=version` needs no key | sabnzbd source |
| Plex prefs | `autoEmptyTrash`, `LanNetworksBandwidth`, `customConnections`; linuxserver/plex has no `ADVERTISE_IP`; the lsio init adds `abc` to the `/dev/dri` group | Plex docs, lsio source |
| Seerr routing | Override rules set only profile, root folder and tags, never the server. A separate anime Sonarr is chosen manually, or by an admin editing a **pending** request. 4K servers are entries with `is4k:true`. The `REQUEST_4K*` and `AUTO_APPROVE_4K*` permissions are separate | Seerr source |
| Seerr API key | base64 (`Buffer.toString('base64')`), so it can contain `+`, `/` and a trailing `=` | Seerr source |
| Masked fields | *arr/Prowlarr GET responses return privacy fields (`apiKey`, `password`) as `********` | *arr source |
| Prowlarr category sync | An indexer syncs to an app only if its categories intersect the app's `syncCategories`, so apps legitimately differ in indexer count | Prowlarr source |
| Healthcheck tools | curl is present in every lsio image; Seerr (`node:22-alpine`) has only busybox `wget`. Unauthenticated endpoints: *arr `/ping`, Plex `/identity`, SAB `/api?mode=version`, Seerr `/api/v1/status`, Jellyfin `/health`, Tautulli `/status` | image and app source |

## Requirements
| ID | Description | Priority | Acceptance Criteria |
|----|-------------|----------|---------------------|
| R2.1 | Services defined and healthy | Must | `docker compose ps` shows sabnzbd, prowlarr, sonarr, sonarr-anime, sonarr-4k, radarr, radarr-4k, lidarr, plex, seerr, tautulli `running (healthy)`. `docker compose --profile jellyfin config -q` succeeds, and jellyfin is absent without the profile. `verify-media.sh` check `compose-healthy` PASS |
| R2.2 | Pinned, same-or-newer images | Must | `scripts/ci/check-pinned-images.sh` (with `COMPOSE_PROFILES=jellyfin`) exit 0. `scripts/ci/check-min-versions.sh` exits 0, and exits 1 on a downgraded fixture |
| R2.3 | Configs restored with rollback | Must | `30-push-appdata.sh` then `10-restore-appdata.sh --apply` place the 9 app dirs under `/opt/appdata/<svc>` owned by `PUID:PGID`. *arr DB `PRAGMA integrity_check` = `ok`. `baseline.json` is written. `--rollback <ts>` restores the previous dirs |
| R2.4 | Paths remapped, library adopted without re-downloads | Must | `verify-media.sh` checks `arr-rootfolders` and `library-adopted` PASS: no root folder or item path under `/data/{shows,movies,anime}`; per instance, current file count (HD + files moved to 4K per manifest) ≥ baseline; and `no-regrab` PASS: no `grabbed` history event since the baseline time for an episode or movie that had a file at the baseline (HD instances), or for an item the split moved into a 4K instance. Other grabs (new episodes, test requests) are reported as info, not failures |
| R2.5 | SABnzbd categories (R3) | Must | `sab-categories` PASS: categories are exactly `*`, `tv`, `tv-4k`, `movies`, `movies-4k`, `music`, `anime`; `download_dir=/data/usenet/incomplete`; `complete_dir=/data/usenet/complete`; each category dir = its name |
| R2.6 | Usenet-only download clients and indexers | Must | `download-clients` PASS: each *arr and Prowlarr has exactly one download client (`Sabnzbd`, host `sabnzbd`, port 8080, correct category; Prowlarr's has no category requirement), no qBittorrent/NZBGet, and 0 indexers with `protocol=torrent` in each *arr |
| R2.7 | Prowlarr sync to all 6 (R4) | Must | `prowlarr-sync` PASS: 6 apps with `fullSync`, 0 torrent indexers, 0 indexer proxies, ≥1 enabled usenet indexer; each *arr has ≥1 indexer whose name ends in ` (Prowlarr)` and every such indexer's name (minus the suffix) matches an enabled usenet indexer in Prowlarr |
| R2.8 | 4K split | Must | `30-split-4k.sh` moves titles whose every file is ≥2160p into `movies-4k`/`tv-4k`, adds them to radarr-4k/sonarr-4k and unmonitors and tags them `4k-only` in HD. `4k-split` PASS: no monitored HD item has a ≥2160p file, except series listed `skip-mixed` in the newest plan TSV (reported in the detail as `mixed=<n>`). The runbook has the owner resolve each mixed series |
| R2.9 | Plex libraries | Must | `plex-sections` PASS: sections Movies (`/data/media/movies`, `/data/media/anime-movies`), TV Shows (`/data/media/tv`), Anime TV (`/data/media/anime-tv`), Music (`/data/media/music`), Movies 4K (`/data/media/movies-4k`), TV 4K (`/data/media/tv-4k`); no location outside `/data/media`; `autoEmptyTrash` = 0 |
| R2.9b | Plex watch state and library presence | Must | `plex-watched` PASS: number of watched movies and episodes (`/library/sections/<k>/all?type=1` for movie sections, `?type=4` for show sections, paged, `viewCount>0`, owner token) ≥ `baseline.plex_watched` (SKIP if the baseline is `-1`); `plex-counts` PASS: each Plex section's item count is **at least** the matching *arr item count with files minus `PLEX_COUNT_TOLERANCE` (default 0), with the difference in the detail (the risk is Plex *losing* items; extra unmanaged files are fine) (Movies = radarr movies with files outside 4K + anime-movies; TV Shows = sonarr series with files; Anime TV = sonarr-anime; Movies 4K = radarr-4k; TV 4K = sonarr-4k). Both are the gate before emptying Plex trash |
| R2.10 | Plex hardware transcoding | Must | `plex-hw` PASS while the owner plays a forced transcode: a session with `transcodeHwRequested` true (or `1`) and HW decode or encode set |
| R2.11 | Seerr routing | Must | `seerr-servers` PASS: Radarr (default, non-4K), Radarr 4K (`is4k`, default 4K), Sonarr (default, non-4K), Sonarr 4K (`is4k`, default 4K), Sonarr Anime (non-default), all using service hostnames; and `/api/v1/settings/plex` has `ip=plex`, `port=32400`, with Movies, TV Shows, Anime TV, Movies 4K and TV 4K enabled. The owner's test requests, made as a **non-admin test user** (HD movie auto-approved; 4K movie and anime TV pending, then approved, with the anime one switched to Sonarr Anime), land in the right instance, root and SAB category |
| R2.12 | Atomic imports | Must | `verify-media.sh --watch-import <instance>` PASS: the imported library file has the same inode as the completed download recorded in `/data/usenet/complete/<cat>`, and `droppedPath`/`importedPath` are on the same device |
| R2.13 | Temporary admin access | Must | `compose.lan.yaml` publishes admin UIs only on `${LAN_IP}`; `docker compose config` without it publishes only `32400` |
| R2.14 | Jellyfin evaluation | Should | With `--profile jellyfin`, jellyfin is healthy with `/dev/dri` and a read-only `/data/media`; `jellyfin` check PASS, otherwise SKIP |
| R2.15 | Runbook + CI | Must | `docs/runbooks/03-core-media.md` exists with the required headings; `lint.yml` runs every `scripts/ci/test-*.sh`, and they pass |

## Architecture
```
Proxmox host (root)                         VM media-01 (user media, docker group)
/tank/migration/old-docker-*.tar.zst
  └─ scripts/host/30-push-appdata.sh ──ssh──► /opt/appdata/.staging/<ts>/<svc>   (tar -x as media, mode 700)
                                             scripts/vm/10-restore-appdata.sh --apply  (sudo)
                                               ├─ .rollback/<ts>/<svc> ◄─ existing dirs
                                               ├─ /opt/appdata/<svc>   ◄─ staging  (chown PUID:PGID)
                                               ├─ Plex Preferences.xml autoEmptyTrash="0"
                                               ├─ integrity_check + .migration/baseline.json
                                               └─ empty dirs for fresh services
compose.yaml ─include─► stacks/{download,arr,media}.yaml   (+ compose.lan.yaml via COMPOSE_FILE)
scripts/lib/arr.sh  (docker inspect IP + curl -K -, keys read at runtime from /opt/appdata)
  ◄── scripts/vm/20-arr-remap.sh   (*arr roots/paths, unmonitor-deleted off)
  ◄── scripts/vm/25-arr-wire.sh    (SAB dirs/categories/whitelist, *arr clients+roots, Prowlarr apps+cleanup+sync)
  ◄── scripts/vm/30-split-4k.sh    (report → mv → add to 4K instance → unmonitor HD; --undo)
  ◄── scripts/vm/verify-media.sh   (PASS/FAIL/SKIP gate, --watch-import)
Owner UI: Plex libraries + network prefs · Seerr servers + permissions · 4K quality profile choice
CI: lint.yml → scripts/ci/test-*.sh (stub docker/curl/ssh + fixtures) · compose config variants · pinned + min-version checks
```

### Key Decisions
| Decision | Choice | Rationale | Alternatives Considered |
|----------|--------|-----------|-------------------------|
| Path remap | *arr: `rootfolder` POST → `series|movie/editor` PUT `moveFiles:false` → DELETE the old root → rescan. Plex: the owner adds the new folder, scans, then removes the old one | Supported, schema-independent, reversible. Evidence: editor recomputes the path as new root + folder name | Offline sqlite UPDATE (schema-fragile; Plex's custom SQLite); compatibility bind mounts `/data/shows` (break hardlinks and moves with EXDEV); symlinks (leave the old paths in place for good) |
| Unmonitor-deleted | `20-arr-remap.sh` sets `autoUnmonitorPreviouslyDownloaded{Episodes,Movies}=false` in each *arr **before** any rescan, and leaves it off | A scan with wrong paths would unmonitor the whole library. FileFlows (Phase 4) also replaces files, and must not trigger unmonitoring | Re-enable afterwards (only reintroduces the Phase 4 risk) |
| Remap safety | Remap runs with `sabnzbd` and `prowlarr` **stopped** (the script refuses otherwise) | No grabs can happen while paths are temporarily wrong | Rely only on "missing root folder skips the scan" |
| SAB first start | The restore sets `download_dir` and `complete_dir` offline and moves the old `admin/` queue and history aside; `25-arr-wire.sh --only sab` fixes the categories and purges pre-baseline jobs before any *arr or Prowlarr is started together with SAB | Old jobs point at paths that don't exist, and old categories would drop downloads outside the TRaSH tree | Start SAB with the old config (critique #3) |
| Restore transport | The host runs `zstd -dc` only and pipes it over `ssh $VM_HOST` into `tar -x` as `media`, with the allow-list, excludes and `--transform` applied on the VM into `/opt/appdata/.staging/<ts>` (0700). No temp dir on the host, and no plaintext on `tank/data` | `/data` is visible to every container and to ZFS snapshots; the archive holds secrets. Extracting as `media` needs no sudo over ssh | Extract onto `/data` (leaks secrets); a host temp dir on the Proxmox root LV (critique #17); `scp` of the whole archive |
| Restore apply | A separate VM script (`sudo`) swaps staging into place, keeps `.rollback/<ts>`, chowns, removes `*.pid`, sets Plex `autoEmptyTrash="0"`, runs `integrity_check` on the *arr DBs, and writes the baseline | Rollback is a directory swap; the Plex pref is in place before first start, which protects watch state | Rely on the owner to toggle it in the UI (too late if Plex scans on start) |
| Image pins | Exactly the old tags; sonarr-anime/-4k reuse the sonarr tag and radarr-4k the radarr tag; jellyfin `12.1ubu2604-ls50`; `config/min-versions.txt` is enforced in CI | The DBs open on the schema they were written with; upgrades come later through Diun (Phase 5) with pinned bumps | Newest tags now (a schema migration during the restore adds risk) |
| App-to-app networking | All services on the external `proxy` network; they reach each other by service name (`http://sabnzbd:8080`) | Survives Phase 3 (Traefik joins `proxy`) | host networking |
| API access from scripts | `arr.sh` resolves the container IP with `docker inspect` on the `proxy` network and calls it from the VM with curl. API keys are read at runtime from `/opt/appdata` and passed via `curl -K -` (stdin), never on the command line. Scripts run as `media` (docker group), not root | Independent of published ports, so it still works after Phase 3 removes them; keys don't show in `ps` | Published ports (gone in Phase 3); `docker exec curl` (Seerr has no curl); tools container (the Clean option, more code) |
| Temporary admin access | `compose.lan.yaml` publishes `${LAN_IP}:<port>` for the admin UIs; enabled by `COMPOSE_FILE=compose.yaml:compose.lan.yaml` in `.env`; Phase 3 deletes both | Twingate's connector (LXC 101) reaches LAN IPs, not bridge IPs; a one-file removal is auditable | Ports in the stack files (harder to remove); Traefik early (Phase 3 scope) |
| Plex networking | Bridge network, `ports: 32400:32400`, `devices: /dev/dri:/dev/dri`, `/data/media` read-only; the owner sets `LanNetworksBandwidth=192.168.50.0/24` and `customConnections=http://192.168.50.16:32400` in the UI | Owner decision. linuxserver/plex has no `ADVERTISE_IP`; the lsio init handles the render group | host networking (old setup; opens extra ports) |
| 4K split | Movies whose files are all ≥2160p, and series whose **every** episode file is ≥2160p, move to `movies-4k`/`tv-4k` (`mv`, same dataset). They are added to the 4K instance with `search=false` and rescanned, then unmonitored and tagged `4k-only` in HD. Mixed-resolution series are reported and skipped. `--undo <manifest>` reverses it | Owner decision: 4K only, no HD copy | Keep HD copies (owner rejected); leave 4K mixed in (fails the criterion) |
| 4K in Plex | Separate **Movies 4K** and **TV 4K** libraries, shared with **every** family member (Phase 6); non-4K devices get a transcode with HDR tone mapping on the A380 | Owner decision (2026-09-28): everyone can watch 4K-only titles | Merge into the HD libraries; restrict 4K to 4K-capable users (owner rejected) |
| Seerr anime | Sonarr Anime is a non-default Sonarr server in Seerr. **TV requests require approval** (family keeps `AUTO_APPROVE_MOVIE` but not `AUTO_APPROVE_TV`); the owner switches an anime request to Sonarr Anime while it is pending. 4K requests require approval (no `AUTO_APPROVE_4K*`) | Owner decision: Seerr can't route anime to another server automatically | Family picks the server (unreliable); merge anime into Sonarr (loses the old instance's history) |
| HD request for a 4K-only title | Allowed. A family member's explicit HD request re-monitors the Radarr-HD entry and downloads an HD copy of that one title (movies stay auto-approved) | Owner decision (2026-09-28); rare, since everyone can already watch the 4K version | Approve every movie request |
| Seerr permission scope | Seerr's default permissions only apply to new users, so runbook step 7 also edits each existing family user: `REQUEST`, `REQUEST_4K`, `AUTO_APPROVE_MOVIE` on; `AUTO_APPROVE_TV` and `AUTO_APPROVE_4K*` off. The test requests use a dedicated non-admin user `e2e-test`, since admin requests auto-approve and would never go pending | Makes the anime-routing and 4K-approval paths testable | Test as the owner (auto-approves and skips the approval path) |
| Rollback points | Runbook: `qm snapshot 200 pre-phase2 --vmstate 0` before step 2; `zfs snapshot tank/data@pre-4k-split` on the host before `30-split-4k.sh --apply`; the host archive stays the source of truth for re-pushing configs | The restore's `.rollback/` only covers the appdata swap; remap, wiring and 4K moves need VM and dataset snapshots | Rely on script-level undo only |
| Seerr/Plex config | Done by the owner in the UI (runbook step); `verify-media.sh` checks the result | One-time choices; UI is safer than a script against changing APIs | Scripted (Clean) |
| Import verification | `verify-media.sh --watch-import <instance>` polls `/data/usenet/complete/<cat>` for up to `WATCH_TIMEOUT` (default 1800 s), recording `path → inode` for each new file, then checks the imported file (history `importedPath`) has a recorded inode and is on the same device | Usenet imports are moves, so the source path disappears; an inode match proves no copy happened | Hardlink link-count check (doesn't apply to moves) |

## API and Type Contracts
**Shared CLI contract:** every new script under `scripts/host/` and `scripts/vm/` follows the Phase 1 contract: `[--apply] [--help]`, dry-run prints `DRY-RUN: <cmd>`, exit 0/1/2, `set -Eeuo pipefail`, and sources `scripts/lib/common.sh`. `load_env` runs before the defaults. Validation uses `require_match`/`require_safe_path`, and every value that ends up in `run_sh` is validated first.

**Extra flags** (`--stage`, `--rollback`, `--only`, `--undo`, `--watch-import`) are parsed **locally**, before calling `parse_common_args`:
- A `while` loop consumes the script's own flags together with their argument.
- The remaining args (`--apply`, `--help`) go to `parse_common_args "${rest[@]}"`.
- An unknown flag still exits 2.
- `common.sh` is not changed.

**Every `docker compose` call** in these scripts is `docker compose --project-directory "$REPO_ROOT"`, so the scripts work from any cwd and pick up the repo's `.env`.

**`scripts/host/30-push-appdata.sh`** (Proxmox host, root with `--apply`)
- Env:
  - `VM_HOST` (required, `^[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+$`, e.g. `media@192.168.50.16`).
  - `ARCHIVE` (default: the newest `/tank/migration/old-docker-*.tar.zst`; must exist).
  - `REMOTE_APPDATA` (default `/opt/appdata`).
- Flag: `--stage <ts>` (default `date +%Y%m%d-%H%M%S`, `^[0-9]{8}-[0-9]{6}$`).
- Fixed allow-list, archive member → staged name:
  - `docker/plex/config` → `plex`
  - `docker/plex/seerr/config` → `seerr`
  - `docker/plex/tautulli` → `tautulli`
  - `docker/servarr/sonarr` → `sonarr`
  - `docker/servarr/animesonarr` → `sonarr-anime`
  - `docker/servarr/radarr` → `radarr`
  - `docker/servarr/lidarr` → `lidarr`
  - `docker/servarr/prowlarr` → `prowlarr`
  - `docker/servarr/sabnzbd` → `sabnzbd`
- Excludes, via `--exclude` on original member names:
  - `docker/*/*/logs`, `docker/*/*/Logs`
  - `*.pid`
  - `docker/plex/config/Library/Application Support/Plex Media Server/Cache`
  - `docker/plex/config/Library/Application Support/Plex Media Server/Crash Reports`
  - `docker/plex/config/Library/Application Support/Plex Media Server/Logs`
  - `docker/servarr/*/Backups`, `docker/servarr/*/backups`
- Steps:
  1. Precheck: `ssh -o BatchMode=yes -o ConnectTimeout=10 "$VM_HOST" true`, else exit 1 with the `ssh-copy-id -i /root/.ssh/id_ed25519.pub "$VM_HOST"` hint.
  2. Refuse if `$REMOTE_APPDATA/.staging/<ts>` already exists (`ssh … test ! -e`).
  3. **One** `run_sh` pipeline. The host only decompresses; extraction, filtering and renaming happen on the VM as `media`, with no host temp dir:
     ```
     zstd -dc -- "$ARCHIVE" | ssh "$VM_HOST" "mkdir -p -m 700 '$REMOTE_APPDATA/.staging/$TS' && tar -x -C '$REMOTE_APPDATA/.staging/$TS' <--exclude=…> \
       --transform='s#^docker/plex/seerr/config#seerr#' --transform='s#^docker/plex/config#plex#' \
       --transform='s#^docker/plex/tautulli#tautulli#' --transform='s#^docker/servarr/animesonarr#sonarr-anime#' \
       --transform='s#^docker/servarr/##' <the 9 member paths>"
     ```
     GNU tar applies the `--transform` expressions in order, each to the result of the previous one. The `docker/plex/*` rules come before the generic `docker/servarr/` strip, and none of them matches another's output. Every value interpolated into the remote command string is validated first.
  4. `run_sh`: `ssh "$VM_HOST" "ls -1 '$REMOTE_APPDATA/.staging/$TS'"`. Compare the output to the 9 names and exit 1 if it differs.
  5. `[INFO] staged <ts> on <VM_HOST>`, and the next command: `sudo scripts/vm/10-restore-appdata.sh --stage <ts>`.
- The archive stream (secrets included) crosses only the encrypted ssh link. Nothing outside the allow-list is written on the VM, and nothing touches `/tank/data`.

**`scripts/vm/10-restore-appdata.sh`** (VM, `sudo` with `--apply`)
- Modes:
  - `[--stage <ts>] [--apply]` restores the given stage, or the newest one.
  - `--rollback <ts> [--apply]` moves `.rollback/<ts>/<svc>` back over `/opt/appdata/<svc>`; the current dirs go to `.rollback/<ts>-undone`.
- Env: `APPDATA_ROOT` and `PUID`/`PGID` come from `.env`. Flags are used instead of env vars because `sudo` resets the environment.
- Preconditions:
  - `require_cmd sqlite3 jq docker setpriv`.
  - Exit 1 if any of the 9 services is running (`docker compose ps --status running --services`); hint `docker compose stop <svcs>`.
  - Exit 1 if any of `$DATA_ROOT/shows`, `$DATA_ROOT/movies` or `$DATA_ROOT/anime` exists. The restored *arr apps still point at those old roots until the remap; a scan of an existing (even empty) old root would drop file records before unmonitor-deleted is turned off.
  - Exit 1 if the stage dir is missing, holds any top-level entry outside the 9 names, or contains a symlink that resolves outside the stage (`find -type l` + `realpath`).
- Apply, in order:
  1. **Integrity first, on the staged copy, as `PUID`:** for each of `sonarr/sonarr.db`, `sonarr-anime/sonarr.db`, `radarr/radarr.db`, `lidarr/lidarr.db`, `prowlarr/prowlarr.db`, run `setpriv --reuid=$PUID --regid=$PGID --init-groups sqlite3 -readonly <db> 'PRAGMA integrity_check;'`. Any result other than `ok` exits 1 before anything is moved. The Plex DB is opened read-only for the baseline only.
  2. **Swap in each service:** first `mkdir -p -m 700 $APPDATA_ROOT/.rollback/<ts>` unconditionally (step 5 uses it even on a first restore).
     - If `$APPDATA_ROOT/<svc>` is empty, `rmdir` it.
     - If it is non-empty, `mv` it to `$APPDATA_ROOT/.rollback/<ts>/<svc>`.
     - Then `mv -T` staging/<svc> to `$APPDATA_ROOT/<svc>`. `-T` means a leftover dir can never be nested into.
  3. **Ownership:** `chown -R $PUID:$PGID` and `chmod 700` on each restored dir (lsio `abc` runs as `PUID`, so 700 is readable by the app). Delete `*.pid`.
  4. **Plex prefs:** in `plex/Library/Application Support/Plex Media Server/Preferences.xml`, set the attribute `autoEmptyTrash="0"` (replace it if present, else insert it before `/>`), then check with `grep -q`. Also report `TranscoderTempDirectory` and **remove that attribute** if its value doesn't start with `/config` or `/transcode`, so a stale path can't break transcoding. If the file is missing: `[WARN]`, and runbook step 6 sets the trash pref in the UI before any scan.
  5. **SABnzbd, offline, so its first start can't use old paths or queues.** In `sabnzbd/sabnzbd.ini` `[misc]`, set `download_dir = /data/usenet/incomplete` and `complete_dir = /data/usenet/complete` (sed on those two keys). Move `sabnzbd/admin/` to `.rollback/<ts>/sabnzbd-admin`: this is the old queue and history, whose incomplete files don't exist on the new pool. Categories are fixed online by `25-arr-wire.sh --only sab`.
  6. **Report `UrlBase` and `Port`** from each restored `config.xml` (*arr and Prowlarr). If `UrlBase` is non-empty or `Port` isn't the default in the `arr_port` table: `[WARN] <svc> UrlBase=… Port=…; runbook Troubleshooting "UrlBase"`, and `baseline.json` records it. The healthchecks and `arr.sh` assume the defaults.
  7. **Fresh services:** create any missing `$APPDATA_ROOT/{sonarr-4k,radarr-4k,jellyfin}` owned by `PUID:PGID`, mode 700.
  8. **Baseline:** `install -d -m 700 -o $PUID -g $PGID $APPDATA_ROOT/.migration`, then write `$APPDATA_ROOT/.migration/baseline.json` (mode 600, owned by `PUID:PGID`, since the later scripts run as `media`) with `jq -n`:
     ```
     {"created":"<iso8601 UTC>","stage":"<ts>",
      "files":{"sonarr":N,"sonarr-anime":N,"radarr":N,"lidarr":N},
      "items_with_files":{"sonarr":N,"sonarr-anime":N,"radarr":N},
      "plex_watched":N,"warnings":["…"]}
     ```
     The counts, run as `PUID` in read-only mode:
     - `files`: `select count(*) from EpisodeFiles` (Sonarr, Sonarr Anime); `from MovieFiles` (Radarr); `from TrackFiles` (Lidarr, `0` if the table is missing).
     - `items_with_files`: `select count(distinct SeriesId) from EpisodeFiles`; `select count(*) from Movies where MovieFileId>0`.
     - `plex_watched`: the owner's watched movies and episodes, `select count(*) from metadata_item_settings s join metadata_items m on m.guid=s.guid where s.account_id=1 and s.view_count>0 and m.metadata_type in (1,4)` on the Plex DB (account 1 is the server owner; this excludes managed users and rows for deleted items). `-1` plus a warning on error.
     - **Ids with files**, for `no-regrab`: `$APPDATA_ROOT/.migration/baseline-ids/<svc>.txt` (one id per line, same ownership) from `select Id from Episodes where EpisodeFileId>0` (sonarr, sonarr-anime) and `select Id from Movies where MovieFileId>0` (radarr).
  9. Remove the empty staging dir.
- Dry-run prints each step as `DRY-RUN:`. The integrity checks still run in dry-run, because they are read-only.

**`scripts/lib/arr.sh`** (sourced after `common.sh`)
- `arr_port <svc>`: sonarr* 8989, radarr* 7878, lidarr 8686, prowlarr 9696, sabnzbd 8080, plex 32400, seerr 5055, tautulli 8181, jellyfin 8096. Anything else dies.
- `arr_base <svc>`: `/api/v3` for sonarr* and radarr*, `/api/v1` for lidarr and prowlarr.
- `svc_ip <svc>`: `docker inspect -f '{{with index .NetworkSettings.Networks "proxy"}}{{.IPAddress}}{{end}}' "$(dc ps -q <svc>)"`, where `dc` = `docker compose --project-directory "$REPO_ROOT"`. Dies if empty.
- `svc_key <svc>`: reads with `sed -n` or `jq`, never `source`, and validates per service:
  - *arr/Prowlarr: `<ApiKey>` from `config.xml`; `^[a-f0-9]{32}$`.
  - SABnzbd: `api_key = ` from `sabnzbd.ini`; `^[a-f0-9]{32}$`.
  - Seerr: `.main.apiKey` from `settings.json`; `^[A-Za-z0-9+/=_-]{16,}$` (base64).
  - Plex: `PlexOnlineToken` from `Preferences.xml`; `^[A-Za-z0-9_-]{16,}$`.
  - On failure it dies with `missing/invalid API key for <svc>` and never prints the value.
- `api <svc> <METHOD> <path> [body-file]`:
  - Calls curl `-sS --fail-with-body --max-time 30 -K -`. The curl config on stdin contains the `url = "http://<ip>:<port><path>"` line and the `header = "X-Api-Key: …"` line (`X-Plex-Token` for Plex), or for SABnzbd the full URL with `apikey=…`. Keys never appear in argv.
  - The body goes via `--data-binary @<body-file>` with `header = "Content-Type: application/json"` in the same stdin config. A body file and a stdin config can be combined.
  - Prints the body. Non-2xx makes it exit 1 with `<METHOD> <svc> <path> -> HTTP <code>`, without printing the key.
- `sab_api <mode> [k=v …]` builds `/api?mode=<mode>&output=json&<k=v urlencoded via jq @uri>` and calls `api`. It is for read-only modes (`get_config`, `version`, `queue`, `history` listing). Every SAB change (`set_config`, `del_config`, queue/history delete, `pause`, `resume`) goes through `arr_mutate sabnzbd GET <path>`, so it is dry-run by default and counted.
- `wait_cmd <svc> <command-json-response>`: polls `GET {base}/command/<id>` every 3 s until `status` is `completed` (return 0) or `failed`/`aborted` (exit 1), with a 600 s timeout.
- `arr_mutate <svc> <METHOD> <path> [body-file]`:
  - Dry-run: prints `DRY-RUN: <METHOD> <svc> <path> <compact body>` with `apiKey`, `password` and `*Key` fields replaced by `***`.
  - `--apply`: calls `api`.
- `same_state <desired-json> <current-json>`: jq comparison that **ignores fields with `privacy` ≠ `normal`, or whose value is `********`**. It compares only these keys: the top-level `enable`, `implementation`, `name` and `syncLevel` (when present), and field values for `host`, `port`, `useSsl`, `baseUrl`, `prowlarrUrl`, the category fields, `syncCategories` and `animeSyncCategories`. This makes a second `--apply` issue 0 mutations on real apps.

**`scripts/vm/20-arr-remap.sh`** (VM, as `media`)
- Remap table:
  - `sonarr`: `/data/shows` → `/data/media/tv`
  - `sonarr-anime`: `/data/anime` → `/data/media/anime-tv`
  - `radarr`: `/data/movies` → `/data/media/movies`
- Preconditions:
  - `sabnzbd` and `prowlarr` are **not running**.
  - `sonarr`, `sonarr-anime`, `radarr` and `lidarr` are running and healthy.
  - Each new root dir exists (`test -d`).
- Per instance:
  1. `GET {base}/config/mediamanagement`, set `autoUnmonitorPreviouslyDownloadedEpisodes` (Sonarr) or `…Movies` (Radarr) to `false`, and `PUT` it, only if it differs.
  2. `POST {base}/rootfolder {"path":"<new>"}` if missing.
  3. `GET {base}/series` or `/movie` and select items whose `path` starts with `<old>/`. `PUT {base}/series/editor {"seriesIds":[…],"rootFolderPath":"<new>","moveFiles":false}`, or `/movie/editor` with `movieIds`.
  4. Re-GET. If any item path still starts with `<old>/`, exit 1 and list the ids; the old root is not deleted.
  5. `DELETE {base}/rootfolder/<id>` for the old root.
  6. Only if step 3 changed items: `POST {base}/command {"name":"RescanSeries"}` or `{"name":"RescanMovie"}`, then `wait_cmd`.
- Lidarr: `POST /api/v1/rootfolder {"name":"Music","path":"/data/media/music","defaultQualityProfileId":<lowest id from /qualityprofile>,"defaultMetadataProfileId":<lowest id from /metadataprofile>}` if missing.
- Output: `[INFO] <svc>: <n> items <old> -> <new>`. A re-run finds 0 items and makes 0 mutations.

**`scripts/vm/25-arr-wire.sh`** (VM, as `media`)
- Flags: `--only sab` does just the SAB part. Default: everything, with SAB first.
- Preconditions:
  - `--only sab`: `sabnzbd` is running.
  - Full run: all core services are running and healthy.
- **SAB part:**
  1. `set_config misc download_dir=/data/usenet/incomplete`, `complete_dir=/data/usenet/complete` (if they differ).
  2. `host_whitelist`: add `sabnzbd,<hostname>,<LAN_IP>` to the current list, keeping it deduplicated.
  3. For each of `tv tv-4k movies movies-4k music anime`: `set_config categories keyword=<c> dir=<c>` if missing or different.
  4. `del_config categories` for `series`, `anime-series` and `software`, if present.
  5. `mode=queue&name=purge&del_files=1` and `mode=history&name=delete&value=all&del_files=1`, but only if the queue or history holds anything created before the baseline time. These are old jobs whose files are gone.
  6. `--only sab` only: `mode=pause` if the queue isn't already paused, so nothing downloads before the *arr apps and Prowlarr are wired (an RSS grab through an old indexer would land in a deleted category). The full run resumes it at the end.
- **Per-*arr desired state:**

  | svc | root folders | category field | category |
  |---|---|---|---|
  | sonarr | `/data/media/tv` | `tvCategory` | `tv` |
  | sonarr-anime | `/data/media/anime-tv` | `tvCategory` | `anime` |
  | sonarr-4k | `/data/media/tv-4k` | `tvCategory` | `tv-4k` |
  | radarr | `/data/media/movies`, `/data/media/anime-movies` | `movieCategory` | `movies` |
  | radarr-4k | `/data/media/movies-4k` | `movieCategory` | `movies-4k` |
  | lidarr | `/data/media/music` | `musicCategory` | `music` |

  For each instance:
  - Add the missing root folders.
  - Delete download clients whose `implementation` ≠ `Sabnzbd`.
  - Upsert the client named `SABnzbd`. Build it from the `Sabnzbd` entry of `GET {base}/downloadclient/schema` and set `name=SABnzbd`, `enable=true`, `removeCompletedDownloads=true`, `removeFailedDownloads=true`, and the fields `host=sabnzbd`, `port=8080`, `useSsl=false`, `apiKey=<SAB key>`, `<categoryField>=<category>`. Compare with `same_state`.
  - Delete **indexers with `protocol=="torrent"`** that the app holds directly.
  - Delete all `remotepathmapping` entries.
- **Prowlarr:**
  - Delete indexers with `protocol=="torrent"` and all `indexerproxy` entries.
  - Delete Prowlarr download clients whose `implementation` ≠ `Sabnzbd`, and upsert its SAB client the same way, without a category.
  - Upsert applications. **Match an existing app by the host in its `baseUrl`, then by name.** Delete apps whose host is `animesonarr`, `nzbget` or `qbittorrent`, or that are unmatched.

    | name | implementation | baseUrl | syncCategories |
    |---|---|---|---|
    | Sonarr | Sonarr | `http://sonarr:8989` | schema default |
    | Sonarr Anime | Sonarr | `http://sonarr-anime:8989` | `[]`, with `animeSyncCategories=[5070]` |
    | Sonarr 4K | Sonarr | `http://sonarr-4k:8989` | schema default |
    | Radarr | Radarr | `http://radarr:7878` | schema default |
    | Radarr 4K | Radarr | `http://radarr-4k:7878` | schema default |
    | Lidarr | Lidarr | `http://lidarr:8686` | schema default |

    All of them set the top-level `syncLevel="fullSync"` and the fields `prowlarrUrl=http://prowlarr:9696` and `apiKey=<app key>`.
  - Only if this run made any mutation: `POST /api/v1/command {"name":"ApplicationIndexerSync","forceSync":true}`, then `wait_cmd`.
  - **SAB resume:** if the SAB queue is paused (left paused by `--only sab`), `mode=resume` as the last step.
- A second `--apply` makes 0 mutating calls; the dry-run then prints `[INFO] no changes`.

**`scripts/vm/30-split-4k.sh`** (VM, as `media`)
- Modes: default dry-run (writes the plan and prints a summary), `--apply`, `--undo <manifest> [--apply]`.
- Env: `QP_4K_RADARR`, `QP_4K_SONARR` (quality profile names in the 4K instances, default `Ultra-HD`). If a profile is missing, exit 1 and list the available names.
- Plan: `$APPDATA_ROOT/.migration/split-4k-<ts>.tsv`, with columns `kind instance id title src dst files action`:
  - A file counts as 4K if `max(quality.quality.resolution, height from mediaInfo.resolution)` ≥ 2160, or the `mediaInfo` width is ≥ 3200 (scope releases such as 3840x1600). If the quality resolution and `mediaInfo` disagree about 4K, the title's action is `check` (listed, not moved).
  - Titles already tagged `4k-only` in HD are skipped, so a re-run plans 0 moves. Unmonitored titles are **not** skipped.
  - `movie`: every movie file is 4K → `move`.
  - `series`: ≥1 episode file and all ≥2160 → `move`; some ≥2160 → `skip-mixed`; none → the series is not listed.
  - `files` is the number of media files.
  - Anime (`sonarr-anime`, and radarr titles under `/data/media/anime-movies`) is not split. The summary reports `anime-4k=<n>` titles with 4K files, and the runbook records the owner's choice for them.
- Apply:
  1. **Preflight every `move` row:** `dst` must not exist, and `src` must exist and sit under the expected HD root. Any failure exits 1 before anything is moved.
  2. Then, per row:
     - `mv "$src" "$dst"`, where `dst` is `/data/media/{movies-4k|tv-4k}/<basename>`.
     - Build the add payload from `GET {4k}/movie/lookup/tmdb?tmdbId=<id>` or `GET {4k}/series/lookup?term=tvdb:<id>`. Set `qualityProfileId`, `rootFolderPath`, `path=dst` and `monitored=true`, plus `addOptions` `{searchForMovie:false}` or `{searchForMissingEpisodes:false,monitor:"existing"}`. `POST` it.
     - Rescan the 4K item with `wait_cmd`.
     - Ensure the HD tag `4k-only` exists, then `PUT` the HD item with `monitored=false` and the tag added. For series, also set every season `monitored=false`.
     - Append the row to `…/split-4k-<ts>.manifest.tsv`, adding the ids created in the 4K instance.
- Undo, in reverse manifest order:
  1. `mv dst src`.
  2. `DELETE` the 4K item with `deleteFiles=false`.
  3. Set the HD item back to monitored (seasons included) and remove the tag.
  4. Rescan the HD item.

**`scripts/vm/verify-media.sh`** (VM, as `media`; read-only)
- Output: `PASS|FAIL|SKIP <id> <detail>` lines, then `RESULT: <n> pass, <n> fail, <n> skip`. Exit 1 on any FAIL.
- Check IDs, in order:
  1. **`compose-healthy`**: the 11 core services are `running` with health `healthy`.
  2. **`image-versions`**: `scripts/ci/check-min-versions.sh` passes against the running config.
  3. **`arr-rootfolders`**: each instance's root set equals the wiring table, and no item path is under `/data/{shows,movies,anime}/`.
  4. **`library-adopted`**, per HD instance:
     - Current = sum of `statistics.episodeFileCount` over `/series` (Sonarr), or the number of `/movie` with `hasFile` (Radarr).
     - Moved = sum of `files` in the manifests (sonarr/radarr rows).
     - PASS if current + moved ≥ `baseline.files` for Sonarr, or ≥ `baseline.items_with_files` for Radarr.
     - SKIP if `baseline.json` is missing.
  5. **`no-regrab`**: `GET {base}/history/since?date=<baseline.created>&eventType=grabbed` on sonarr, sonarr-anime, radarr, sonarr-4k and radarr-4k. FAIL if a grab on an HD instance has an `episodeId`/`movieId` listed in `baseline-ids/<svc>.txt`, or a grab on a 4K instance has a `seriesId`/`movieId` created by a split manifest. The detail reports `other=<n>` for the remaining grabs. SKIP if `baseline.json` is missing.
  6. **`sab-categories`**: categories equal `* tv tv-4k movies movies-4k music anime`, the dirs match, and nothing in the queue or history predates the baseline.
  7. **`download-clients`**
  8. **`prowlarr-sync`**
  9. **`4k-split`**: SKIP if there is no plan TSV; exempts `skip-mixed` ids and reports `mixed=<n>`.
  10. **`plex-sections`**
  11. **`plex-watched`**
  12. **`plex-counts`**
  13. **`plex-hw`**: SKIP if there is no transcode session.
  14. **`seerr-servers`**
  15. **`jellyfin`**: SKIP unless running; otherwise `/health` is `Healthy` and `/dev/dri` exists in the container.
- **`--watch-import <svc>`** maps the service to its SAB category using the wiring table, then:
  1. Records the start time.
  2. Every 5 s runs `find /data/usenet/complete/<cat> -type f -newerct @<start>` and records `path inode` pairs (ctime, not mtime: unrar restores archived mtimes).
  3. When `GET {base}/history?eventType=3&sortKey=date&sortDirection=descending&pageSize=5` (Sonarr's `downloadFolderImported` event type) or the Radarr equivalent shows a record newer than the start: `stat` its `data.importedPath`. PASS if the inode is among those recorded and `stat -c %d` matches that of `/data/usenet/complete`. It prints `PASS import <svc> inode=<n>`.
  4. FAIL after `WATCH_TIMEOUT` seconds (default 1800).
- Tests drive every check through the API stubs; there is no `SKIP_APPS` flag.

**Compose contract** (all services `extends: {file: _common.yaml, service: base}` and join `proxy`)

| service | file | image | volumes | extra |
|---|---|---|---|---|
| sabnzbd | download | `lscr.io/linuxserver/sabnzbd:5.1.1-ls268` | `${APPDATA_ROOT}/sabnzbd:/config`, `${DATA_ROOT}:/data` | hc `curl -fsS "http://localhost:8080/api?mode=version"` |
| prowlarr | arr | `lscr.io/linuxserver/prowlarr:2.5.2.5491-ls156` | `…/prowlarr:/config` | hc `curl -fsS http://localhost:9696/ping` |
| sonarr, sonarr-anime, sonarr-4k | arr | `lscr.io/linuxserver/sonarr:4.0.19.2979-ls321` | `…/<svc>:/config`, `${DATA_ROOT}:/data` | hc `…:8989/ping` |
| radarr, radarr-4k | arr | `lscr.io/linuxserver/radarr:6.3.0.10514-ls313` | `…/<svc>:/config`, `${DATA_ROOT}:/data` | hc `…:7878/ping` |
| lidarr | arr | `lscr.io/linuxserver/lidarr:3.1.0.4875-ls39` | `…/lidarr:/config`, `${DATA_ROOT}:/data` | hc `…:8686/ping` |
| plex | media | `lscr.io/linuxserver/plex:1.43.4.10903-e5521bd8c-ls324` | `…/plex:/config`, `${DATA_ROOT}/media:/data/media:ro` | `ports: ["32400:32400"]`, `devices: ["/dev/dri:/dev/dri"]`, env `VERSION: docker`, hc `curl -fsS http://localhost:32400/identity` |
| seerr | media | `ghcr.io/seerr-team/seerr:v3.4.1` | `…/seerr:/app/config` | `init: true`, env `LOG_LEVEL: info`, hc `wget -qO- http://localhost:5055/api/v1/status` |
| tautulli | media | `lscr.io/linuxserver/tautulli:v2.17.2-ls240` | `…/tautulli:/config` | hc `curl -fsS http://localhost:8181/status` |
| jellyfin | media | `lscr.io/linuxserver/jellyfin:12.1ubu2604-ls50` | `…/jellyfin:/config`, `${DATA_ROOT}/media:/data/media:ro` | `profiles: ["jellyfin"]`, `devices: ["/dev/dri:/dev/dri"]`, hc `curl -fsS http://localhost:8096/health` |

- Healthchecks use `interval: 30s`, `timeout: 10s`, `retries: 5`, `start_period: 120s`, and `start_period: 300s` for plex.
- Each service mounts `/data` **at most once**, and no service mounts a `/data` subpath other than `/data/media` read-only (plex, jellyfin).
- `compose.lan.yaml` (root) publishes `"${LAN_IP:?set LAN_IP in .env}:<host>:<container>"` for:
  - sabnzbd 8080:8080
  - prowlarr 9696:9696
  - sonarr 8989:8989
  - sonarr-anime 8990:8989
  - sonarr-4k 8991:8989
  - radarr 7878:7878
  - radarr-4k 7879:7878
  - lidarr 8686:8686
  - seerr 5055:5055
  - tautulli 8181:8181
  - jellyfin 8096:8096 (the jellyfin entry repeats `profiles: ["jellyfin"]`)
- `.env.example` gains:
  - `LAN_IP=192.168.1.10` (placeholder, commented as "the VM's LAN IP")
  - `# COMPOSE_FILE=compose.yaml:compose.lan.yaml` (commented; the runbook says to uncomment it until Phase 3)

**`config/min-versions.txt`:** one line per image, `<repo> <min-tag>`, listing the eight old tags. Comments start with `#`.

**`scripts/ci/check-min-versions.sh [compose-file]`** reads `COMPOSE_PROFILES=jellyfin docker compose -f <file> config --images`. For each image whose repo is in the list it normalizes both tags and compares them:
1. Strip a leading `v`.
2. Split off a trailing `-ls<N>` into `ls=N` (0 if absent).
3. Drop any `-<hex>` segment of 7 or more hex characters (the Plex build hash).
4. Compare the remaining dotted version with `sort -V`, then compare `ls` numerically.

Output: `BELOW-MIN: <image> < <min>` and exit 1 on any failure, `NO-IMAGES` and exit 1 if no listed repo is found at all, otherwise `OK: <n> images at or above minimum`. Images whose repo isn't listed are ignored. A fixture test covers:
- plex (hash) at ls324 vs ls323;
- seerr v3.4.1 vs v3.4.0;
- sonarr 4.0.19.2979-ls321 vs 4.0.19.2979-ls320.

## File Placement
| Artifact | Path | Placement Rationale | Existing Pattern |
|----------|------|---------------------|------------------|
| Stacks | `stacks/{download,arr,media}.yaml` | Phase 1 placeholders owned by Phase 2 | Phase 1 compose contract |
| LAN override | `compose.lan.yaml` | Root, next to `compose.yaml`; selected via `COMPOSE_FILE` | Compose multi-file |
| Min versions | `config/min-versions.txt` | `config/` per the design repo layout | Design doc |
| Host push | `scripts/host/30-push-appdata.sh` | Runs on Proxmox | `scripts/host/` numbering |
| VM scripts | `scripts/vm/{10-restore-appdata,20-arr-remap,25-arr-wire,30-split-4k,verify-media}.sh` | Run in the VM; numbered in run order | `scripts/vm/00-bootstrap.sh` |
| API helper | `scripts/lib/arr.sh` | Shared library | `scripts/lib/common.sh` |
| CI | `scripts/ci/{check-min-versions,make-api-stubs,test-restore,test-arr-scripts,test-media-scripts}.sh`, fixtures `scripts/ci/fixtures/api/*.json` | CI-only tooling | `scripts/ci/make-host-stubs.sh` |
| Runbook | `docs/runbooks/03-core-media.md` | Next in sequence | runbooks 01/02 |

## Data and Control Flow
1. **Preconditions (owner):**
   - The old Ubuntu VM is **powered off with onboot disabled**. The owner confirms this on the old Proxmox host (`qm status <old-vmid>` shows `stopped`, `qm config` has no `onboot: 1`) or with the old machine unplugged. A second Plex with the same identity, or old *arr instances, must never run.
   - Host root has an ssh key on `media@192.168.50.16` (`ssh-copy-id`).
2. **Rollback point:** on the host, `qm snapshot 200 pre-phase2 --vmstate 0`.
3. **VM:** `sudo apt-get install -y jq sqlite3`, then `git pull` on `dev`. In `.env`, set `LAN_IP=192.168.50.16` and uncomment `COMPOSE_FILE`. Then `docker compose pull`.
4. **Host:** `VM_HOST=media@192.168.50.16 scripts/host/30-push-appdata.sh` (dry-run), then `--apply`.
5. **VM:** `sudo scripts/vm/10-restore-appdata.sh --stage <ts>` (dry-run), then `--apply`.
6. **VM:** confirm `test ! -e /data/shows && test ! -e /data/movies && test ! -e /data/anime`, then `docker compose up -d sonarr sonarr-anime radarr lidarr`, then `scripts/vm/20-arr-remap.sh` (dry-run), then `--apply`.
7. **VM:** `docker compose up -d sabnzbd`, then `scripts/vm/25-arr-wire.sh --only sab` (dry-run), then `--apply` (leaves the SAB queue paused).
8. **VM:** `docker compose up -d` (all core services), then `scripts/vm/25-arr-wire.sh` (dry-run), then `--apply`, then a second `--apply` to confirm it reports "no changes". The first full `--apply` resumes the SAB queue.
9. **Owner, 4K split:**
   1. Confirm the 4K quality profile names in radarr-4k and sonarr-4k.
   2. On the host, `zfs snapshot tank/data@pre-4k-split`.
   3. Run `scripts/vm/30-split-4k.sh` and review the TSV (including `skip-mixed` series), then `--apply`.
   4. Resolve each mixed series: move it with a manual `mv` and add it in Sonarr-4K, or keep it in HD. Record the choice in the runbook.
10. **Owner, Plex UI:**
    1. Set `LanNetworksBandwidth` and `customConnections`.
    2. Per section, add the new folder, scan, and remove the old folder.
    3. Create Movies 4K and TV 4K.
    4. Check HW transcoding is on.
    5. Run `verify-media.sh` and require `plex-watched` and `plex-counts` to PASS **before** emptying the trash.
11. **Owner, Seerr UI:**
    1. Point Seerr's Plex connection at `plex:32400`, sync libraries and enable Movies, TV Shows, Anime TV, Movies 4K and TV 4K.
    2. Set up the *arr servers per the contract.
    3. Set default permissions.
    4. Update every existing family user.
    5. Create the non-admin user `e2e-test`.
12. **Owner, Tautulli UI:** point Tautulli at `http://plex:32400`.
13. **Owner, Twingate:** add a resource for `192.168.50.16` covering the admin ports.
14. **Owner, test requests** as `e2e-test`:
    - an HD movie (auto-approved);
    - a 4K movie (approved by the owner);
    - an anime show (owner switches it to Sonarr Anime while pending, then approves).
    Start `verify-media.sh --watch-import <svc>` in a second terminal before making (HD) or approving (4K, anime) each request.
15. **Owner:** force a transcode in Plex, run `scripts/vm/verify-media.sh`, and paste the output into the runbook's Acceptance record.

## Compatibility Constraints
- **Image versions:** equal to the old ones (never older). Upgrades are separate pinned bumps.
- **Paths:** container paths stay `/data/...`, so the app configs need no per-app path settings beyond the remap.
- **Scripts:** bash ≥ 5, `shellcheck -x` clean, `jq` ≥ 1.6, `curl` ≥ 7.76 (`--fail-with-body`; Debian 13 ships 8.x). No secrets in argv, logs or the repo.
- **Phase 1 contracts unchanged:** `verify.sh` and the `common.sh` API. `arr.sh` only adds functions.
- **Phase 3:** it removes `compose.lan.yaml` and the `COMPOSE_FILE` line. Nothing in Phase 2 scripts depends on published ports.

## Failure Modes
| Failure Mode | Expected Behavior | Verification |
|--------------|-------------------|--------------|
| No ssh key from host to VM | `30-push` exits 1 with the `ssh-copy-id` hint | CI with an ssh stub returning 255 |
| Staging dir already exists | Exit 1, naming it | CI |
| Staged tree has an unexpected entry or a symlink | `10-restore` exits 1 before moving anything | CI fixture |
| Old roots `/data/{shows,movies,anime}` exist at restore | `10-restore` exits 1 naming them, before anything is moved | CI fixture |
| Target services running during restore | Exit 1 with `docker compose stop` hint | CI docker stub |
| *arr DB integrity not `ok` | Exit 1 **before** anything is moved (the check runs on the staged copy as `PUID`) | CI with a corrupted sqlite fixture |
| Empty or auto-created target dir | `rmdir`, then `mv -T`; never nests | CI fixture |
| `UrlBase` non-empty or non-default port in the restored `config.xml` | `[WARN]` and recorded in the baseline; runbook Troubleshooting "UrlBase" resets it | CI fixture |
| Stale Plex `TranscoderTempDirectory` | Attribute removed at restore (reported) | CI fixture |
| Old SAB queue or categories | Dirs set offline and `admin/` moved aside at restore; categories fixed and pre-baseline jobs purged by `--only sab` before the *arr apps meet SAB | CI fixture + stub |
| Plex Preferences.xml missing | Warn and skip the pref edit; runbook step 6 sets it in the UI before the first scan | CI fixture |
| Masked `********` fields in GET responses | Ignored by `same_state`, so a second `--apply` makes 0 mutations | CI fixture with masked fields |
| Unknown flag | Exit 2 (local parser, then `parse_common_args`) | CI |
| Remap with SAB/Prowlarr running | `20-arr-remap` exits 1 | CI stub |
| Items still under the old root after the editor call | Exit 1, listing the ids; the old root is not deleted | CI fixture |
| Secret value malformed or missing | Die with `missing/invalid API key for <svc>`, without printing the value | CI |
| API returns non-2xx | Exit 1 with method, svc and path (no key) | CI |
| 4K quality profile missing | `30-split` exits 1 listing the profiles | CI fixture |
| 4K destination exists | That row fails; the whole run exits 1 before any move (preflight checks every row first) | CI |
| Mixed-resolution series | Reported `skip-mixed`, not moved; `4k-split` exempts it and reports `mixed=<n>`; the runbook resolves it | CI fixture |
| Plex watched count drops after the remap | `plex-watched` FAIL; the runbook says not to empty the trash, then re-add the old folder or roll back via the snapshot | verify |
| Plex empties the trash mid-remap | Prevented: `autoEmptyTrash=0` is set at restore; `plex-sections` FAILs if not 0 | verify |
| No transcode session | `plex-hw` SKIP with hint | CI |
| Import never happens in time | `--watch-import` FAIL after `WATCH_TIMEOUT` | CI with fast timeout |
| Jellyfin profile off | `jellyfin` SKIP | CI |

## Acceptance Checks
| Check | Command or Evidence | Required |
|-------|---------------------|----------|
| Compose variants valid | `docker compose config -q`; `COMPOSE_FILE=compose.yaml:compose.lan.yaml LAN_IP=127.0.0.1 docker compose config -q`; `docker compose --profile jellyfin config -q` | true |
| Only 32400 published without the override | `docker compose config --format json \| jq` published ports = [32400] | true |
| Pins | `COMPOSE_PROFILES=jellyfin scripts/ci/check-pinned-images.sh`; `scripts/ci/check-min-versions.sh`, plus the negative fixture | true |
| Single /data mount | CI test on `docker compose config --format json`: no service has 2 volumes targeting `/data*`, except `/data/media:ro` | true |
| Shell lint | `shellcheck -x` on all scripts, including `scripts/lib/arr.sh` | true |
| Script tests | `for t in scripts/ci/test-*.sh; do "$t"; done` | true |
| Fixtures are synthetic | CI grep: no 32-hex string in `scripts/ci/fixtures/` other than the dummy key `0123456789abcdef0123456789abcdef` | true |
| Real run | Owner: `verify-media.sh` RESULT with 0 fail (`plex-hw`, `plex-watched` and `plex-counts` PASS required; `jellyfin` may SKIP); three `--watch-import` PASS lines | true (owner) |

## Deliverables
### Compose services and LAN override
- **Path:** `stacks/download.yaml`, `stacks/arr.yaml`, `stacks/media.yaml`, `compose.lan.yaml`, `.env.example`, `config/min-versions.txt`
- **Key Content:** as in the Compose contract. Keep the header comments; replace `services: {}`.
- **Size:** ~250 lines total.

### Restore tooling
- **Path:** `scripts/host/30-push-appdata.sh`, `scripts/vm/10-restore-appdata.sh`, `scripts/ci/test-restore.sh`
- **Size:** ~130 + ~200 + ~120 lines.

### API helper, remap and wiring
- **Path:** `scripts/lib/arr.sh`, `scripts/vm/20-arr-remap.sh`, `scripts/vm/25-arr-wire.sh`, `scripts/ci/make-api-stubs.sh`, `scripts/ci/test-arr-scripts.sh`, `scripts/ci/fixtures/api/`
- **Fixtures:** synthetic only, hand-written from the documented response shapes. They use the dummy key `0123456789abcdef0123456789abcdef` (Seerr: `ZHVtbXlrZXlkdW1teWtleQ==`), and the masked-field cases use `********`. Never paste real API output into them.
- **Stub contract:**
  - `make-api-stubs.sh <dir>` writes stub `docker`, `curl` and `ssh` executables.
  - `docker inspect` prints `172.30.0.<n>`.
  - `docker compose ps` honors `STUB_RUNNING="svc1 svc2"`.
  - `docker compose` honors `STUB_HEALTH="svc=healthy …"` for `ps --format json`.
  - `curl` reads the `url`/`header` lines from `-K -` stdin and maps the IP back to the service. It logs `METHOD svc path` (no key) to `$STUB_LOG` and returns `$STUB_FIXTURES/<svc>/<METHOD>_<path with / ? & = → _>.json`. If that file is missing it returns `{}` for GET and HTTP 200 with an empty body for mutations. `STUB_HTTP_<svc>=<code>` forces an error.
  - `ssh` honors `STUB_SSH_RC`.
  - `docker compose … config --images` prints `$STUB_IMAGES` (newline-separated).
  - Like real `curl --fail-with-body`, the curl stub exits 22 when the code is ≥400.
- **Size:** ~150 + ~150 + ~250 + ~120 + ~200 lines.

### 4K split, verification, runbook
- **Path:** `scripts/vm/30-split-4k.sh`, `scripts/vm/verify-media.sh`, `scripts/ci/test-media-scripts.sh`, `docs/runbooks/03-core-media.md`, `docs/README.md` (link)
- **Runbook headings:**
  - `## Prerequisites`
  - `## 1. Stop the old stack`
  - `## 2. Restore app configs`
  - `## 3. Remap *arr paths`
  - `## 4. Wire SABnzbd, download clients and Prowlarr`
  - `## 5. Split out 4K titles`
  - `## 6. Plex`
  - `## 7. Seerr and Tautulli`
  - `## 8. Jellyfin (optional)`
  - `## 9. Remote admin access`
  - `## 10. Test requests and verify`
  - `## Acceptance record`
  - `## Rollback`
  - `## Troubleshooting`
- **Size:** ~250 + ~300 + ~200 + ~350 lines.

### CI wiring
- **Path:** `.github/workflows/lint.yml`, owned by the wave-1 compose plan, so later plans only add `scripts/ci/test-*.sh` files.
- **Key Content:**
  - `apt-get install -y jq sqlite3`.
  - Compose config variants.
  - Pinned check with the jellyfin profile.
  - Min-versions check and its negative fixture.
  - Single-/data check.
  - Only-32400-published check (without the override).
  - Synthetic-fixture grep.
  - A step that runs every `scripts/ci/test-*.sh` that exists.
  - Shellcheck glob extended to `scripts/lib/*.sh`.

### Planning doc updates
Done during `/legion:plan 2`, not part of the build: PROJECT.md (R5, R12, decision rows), ROADMAP.md (4 plans, the atomic-move wording, the Phase 6 share rule) and `old-stack-inventory.md` (verified old paths).

## Open Questions
| # | Question | Impact | Default Chosen by Spec | Planning Effect |
|---|----------|--------|------------------------|-----------------|
| 1 | Does the 4K instance's built-in profile name match `Ultra-HD` on sonarr 4.0.19 / radarr 6.3.0? | Non-blocking | `Ultra-HD`, overridable via `QP_4K_*`; the script exits 1 listing the real names | Env override + runbook step |
| 2 | Does Plex's DB open in stock `sqlite3` (read-only) for the watched count? | Non-blocking | Tolerate failure (`-1` + warn); `plex-watched` then reports SKIP, and the runbook has the owner spot-check watch state in the UI | Baseline field optional |
| 3 | Seerr v3.4.1 settings API paths (`/api/v1/settings/radarr`, `/sonarr`) | Non-blocking | These paths (Overseerr-lineage API, still present in the Seerr source); on 404 the check reports FAIL with a hint | verify check |
| 4 | Old `UrlBase`/port in the *arr `config.xml` | Non-blocking | Assume empty and default; the restore reports otherwise and the runbook resets it in the app UI | Restore warning + runbook |
| 5 | Does `history/since` exist on sonarr 4.0.19 / radarr 6.3.0? | Non-blocking | Yes (v3 API); on 404, fall back to paged `/history` filtered by `date` ≥ baseline | verify-media implementation |

## Revision History
| # | Section | Change | Reason |
|---|---------|--------|--------|
| 1 | R2.8, verify `4k-split`, data flow 9 | Exempt `skip-mixed` series; runbook resolves them | Critique #1 (HIGH) |
| 2 | R2.9b, verify `plex-watched`/`plex-counts`, data flow 10 | Watch state and counts are checked before emptying the trash | Critique #2 (HIGH) |
| 3 | Restore step 5, wire `--only sab`, data flow 7 | SAB dirs set offline; old queue moved aside; categories fixed before the *arr apps meet SAB | Critique #3 (HIGH); former OQ5 resolved |
| 4 | `arr.sh svc_key` | Key validation per service (Seerr base64) | Critique #4 (HIGH) |
| 5 | R2.7 `prowlarr-sync` | ≥1 synced indexer per app, and each maps to an enabled usenet indexer | Critique #5 (HIGH) |
| 6 | `arr.sh same_state`, failure modes | Masked privacy fields ignored for idempotency | Critique #6 |
| 7 | `library-adopted`, split manifest `files` column, `wait_cmd` | Count sources and async commands defined | Critique #7 |
| 8 | CLI contract | Local flag parsing before `parse_common_args` | Critique #8 |
| 9 | All scripts | `docker compose --project-directory "$REPO_ROOT"` | Critique #9 |
| 10 | Restore step 2 | `rmdir` empty target, then `mv -T` | Critique #10 |
| 11 | Key decisions, data flow 11/14 | HD request for a 4K-only title allowed (owner); existing users' permissions edited; `e2e-test` non-admin user (the `no-regrab` exemption was replaced in row 23) | Critique #11 |
| 12 | Key decisions, data flow 2/9 | VM snapshot before the restore; ZFS snapshot before the split | Critique #12 |
| 13 | Wire script, R2.6 | *arr-level torrent indexers and Prowlarr download clients removed | Critique #13 |
| 14 | Restore step 1 | Integrity check on the staged copy, as `PUID`, read-only | Critique #14 |
| 15 | Restore CLI | `--stage` flag instead of `STAGE_TS` (sudo env_reset) | Critique #15 |
| 16 | Min-versions | Normalization defined (v-prefix, Plex hash, lsNNN) | Critique #16 |
| 17 | Push script | Decompress on the host, extract, filter and rename on the VM; no host temp | Critique #17 |
| 18 | Split payloads, Prowlarr upsert | Build from lookup; match by baseUrl host, then name | Critique #18 |
| 19 | Fixtures, CI grep | Synthetic fixtures enforced | Critique #19 |
| 20 | Restore steps 4 and 6 | Report `UrlBase`/port; remove stale `TranscoderTempDirectory` | Critique assumptions |
| 21 | Evidence, `same_state`, Prowlarr apps | `syncLevel` is top-level, set to `fullSync` and compared | Plan critique (blocker) |
| 22 | Baseline, R2.9b | `plex_watched` counts the owner's watched movies/episodes on both sides; `plex-counts` is a ≥ check | Plan critique (blocker/major) |
| 23 | Baseline ids, R2.4, `no-regrab`, data flow 14 | Fails only on re-grabs of baseline items or split items, on all 5 video instances; `e2e-test` tag dropped | Plan critique |
| 24 | Split | `monitor:"existing"`; resolution from quality and mediaInfo, `check` rows; skip `4k-only` tagged instead of unmonitored; `anime-4k` report | Plan critique |
| 25 | `--watch-import` | `-newerct` instead of `-newermt` | Plan critique |
| 26 | Restore | Old roots must be absent; `.rollback/<ts>` always created; `.migration` owned by `PUID` | Plan critique (blockers) |
| 27 | Wire, remap, `arr.sh` | SAB changes via `arr_mutate`; `--only sab` pauses, full run resumes; rescan/sync only after changes | Plan critique |
| 28 | R2.11, data flow 11 | Seerr's Plex connection and 4K libraries | Plan critique |
| 29 | Min-versions, stubs | `NO-IMAGES`; `STUB_IMAGES`; curl stub exit 22 | Plan critique |

## Complexity Assessment

**Rating:** Complex

| Metric | Value |
|--------|-------|
| Requirements | 3 (R3, R4, R5), expanded to 16 sub-requirements |
| Deliverables | ~24 files (new: 18, modify: 6) |
| Estimated waves | 3 |
| Estimated plans | 4 |
| Competing proposals | Recommended (already run: Pragmatic selected) |

**Rationale:** it restores live app state across two machines, with secrets involved. It also runs API-driven, partly irreversible data moves on a library that has to be kept, and it has an owner-run acceptance step. Mistakes are costly (re-downloads, lost watch state), which is why the rollback points and stub-tested scripts are there.

**Recommended next step:** 4 plans in 3 waves:
- Wave 1: compose + CI; restore tooling.
- Wave 2: API helper + remap + wiring.
- Wave 3: 4K split + verification + runbook.
