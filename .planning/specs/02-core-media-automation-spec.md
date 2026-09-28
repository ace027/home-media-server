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
| Prowlarr | Indexer `protocol` is `usenet` or `torrent`. App fields: `prowlarrUrl`, `baseUrl`, `apiKey`, `syncCategories`, `animeSyncCategories`. `syncLevel` is `fullSync`. Sync command: `{"name":"ApplicationIndexerSync","forceSync":true}` | Prowlarr source |
| SABnzbd API | `get_config`; `set_config&section=categories&keyword=<n>&dir=<d>` (creates the category if missing); `del_config&section=categories&keyword=<n>`; misc settings one per call via `set_config&section=misc&keyword=<k>&value=<v>`; `mode=version` needs no key | sabnzbd source |
| Plex prefs | `autoEmptyTrash`, `LanNetworksBandwidth`, `customConnections`; linuxserver/plex has no `ADVERTISE_IP`; the lsio init adds `abc` to the `/dev/dri` group | Plex docs, lsio source |
| Seerr routing | Override rules set only profile, root folder and tags, never the server. A separate anime Sonarr is chosen manually, or by an admin editing a **pending** request. 4K servers are entries with `is4k:true`. The `REQUEST_4K*` and `AUTO_APPROVE_4K*` permissions are separate | Seerr source |
| Healthcheck tools | curl is present in every lsio image; Seerr (`node:22-alpine`) has only busybox `wget`. Unauthenticated endpoints: *arr `/ping`, Plex `/identity`, SAB `/api?mode=version`, Seerr `/api/v1/status`, Jellyfin `/health`, Tautulli `/status` | image and app source |

## Requirements
| ID | Description | Priority | Acceptance Criteria |
|----|-------------|----------|---------------------|
| R2.1 | Services defined and healthy | Must | `docker compose ps` shows sabnzbd, prowlarr, sonarr, sonarr-anime, sonarr-4k, radarr, radarr-4k, lidarr, plex, seerr, tautulli `running (healthy)`. `docker compose --profile jellyfin config -q` succeeds, and jellyfin is absent without the profile. `verify-media.sh` check `compose-healthy` PASS |
| R2.2 | Pinned, same-or-newer images | Must | `scripts/ci/check-pinned-images.sh` (with `COMPOSE_PROFILES=jellyfin`) exit 0. `scripts/ci/check-min-versions.sh` exits 0, and exits 1 on a downgraded fixture |
| R2.3 | Configs restored with rollback | Must | `30-push-appdata.sh` then `10-restore-appdata.sh --apply` place the 9 app dirs under `/opt/appdata/<svc>` owned by `PUID:PGID`. *arr DB `PRAGMA integrity_check` = `ok`. `baseline.json` is written. `--rollback <ts>` restores the previous dirs |
| R2.4 | Paths remapped, library adopted without re-downloads | Must | `verify-media.sh` checks `arr-rootfolders` and `library-adopted` PASS: no root folder or item path under `/data/{shows,movies,anime}`, and file counts ≥ baseline |
| R2.5 | SABnzbd categories (R3) | Must | `sab-categories` PASS: categories are exactly `*`, `tv`, `tv-4k`, `movies`, `movies-4k`, `music`, `anime`; `download_dir=/data/usenet/incomplete`; `complete_dir=/data/usenet/complete`; each category dir = its name |
| R2.6 | Usenet-only download clients | Must | `download-clients` PASS: each *arr has exactly one client (`Sabnzbd`, host `sabnzbd`, port 8080, correct category), with no qBittorrent/NZBGet |
| R2.7 | Prowlarr sync to all 6 (R4) | Must | `prowlarr-sync` PASS: 6 apps with `fullSync`, 0 torrent indexers, 0 indexer proxies, and each *arr has as many Prowlarr-synced indexers as Prowlarr has enabled usenet indexers (≥1) |
| R2.8 | 4K split | Must | `30-split-4k.sh` moves titles whose every file is ≥2160p into `movies-4k`/`tv-4k`, adds them to radarr-4k/sonarr-4k and unmonitors and tags them `4k-only` in HD. `4k-split` PASS: no monitored HD item has a ≥2160p file |
| R2.9 | Plex libraries | Must | `plex-sections` PASS: sections Movies (`/data/media/movies`, `/data/media/anime-movies`), TV Shows (`/data/media/tv`), Anime TV (`/data/media/anime-tv`), Music (`/data/media/music`), Movies 4K (`/data/media/movies-4k`), TV 4K (`/data/media/tv-4k`); no location outside `/data/media`; `autoEmptyTrash` = 0 |
| R2.10 | Plex hardware transcoding | Must | `plex-hw` PASS while the owner plays a forced transcode: a session with `transcodeHwRequested=1` and HW decode or encode set |
| R2.11 | Seerr routing | Must | `seerr-servers` PASS: Radarr (default, non-4K), Radarr 4K (`is4k`, default 4K), Sonarr (default, non-4K), Sonarr 4K (`is4k`, default 4K), Sonarr Anime (non-default), all using service hostnames. The owner's test requests (HD movie, 4K movie, anime TV routed at approval) land in the right instance, root and SAB category |
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
| Restore transport | Host `tar` with an allow-list and `--transform` renames, piped over `ssh $VM_HOST` into `tar -x` as `media` in `/opt/appdata/.staging/<ts>` (0700). No plaintext on `tank/data` | `/data` is visible to every container and to ZFS snapshots; the archive holds secrets. Extracting as `media` needs no sudo over ssh | Extract onto `/data` (leaks secrets); `scp` of the whole archive (3 GB and exposes everything) |
| Restore apply | A separate VM script (`sudo`) swaps staging into place, keeps `.rollback/<ts>`, chowns, removes `*.pid`, sets Plex `autoEmptyTrash="0"`, runs `integrity_check` on the *arr DBs, and writes the baseline | Rollback is a directory swap; the Plex pref is in place before first start, which protects watch state | Rely on the owner to toggle it in the UI (too late if Plex scans on start) |
| Image pins | Exactly the old tags; sonarr-anime/-4k reuse the sonarr tag and radarr-4k the radarr tag; jellyfin `12.1ubu2604-ls50`; `config/min-versions.txt` is enforced in CI | The DBs open on the schema they were written with; upgrades come later through Diun (Phase 5) with pinned bumps | Newest tags now (a schema migration during the restore adds risk) |
| App-to-app networking | All services on the external `proxy` network; they reach each other by service name (`http://sabnzbd:8080`) | Survives Phase 3 (Traefik joins `proxy`) | host networking |
| API access from scripts | `arr.sh` resolves the container IP with `docker inspect` on the `proxy` network and calls it from the VM with curl. API keys are read at runtime from `/opt/appdata` and passed via `curl -K -` (stdin), never on the command line. Scripts run as `media` (docker group), not root | Independent of published ports, so it still works after Phase 3 removes them; keys don't show in `ps` | Published ports (gone in Phase 3); `docker exec curl` (Seerr has no curl); tools container (the Clean option, more code) |
| Temporary admin access | `compose.lan.yaml` publishes `${LAN_IP}:<port>` for the admin UIs; enabled by `COMPOSE_FILE=compose.yaml:compose.lan.yaml` in `.env`; Phase 3 deletes both | Twingate's connector (LXC 101) reaches LAN IPs, not bridge IPs; a one-file removal is auditable | Ports in the stack files (harder to remove); Traefik early (Phase 3 scope) |
| Plex networking | Bridge network, `ports: 32400:32400`, `devices: /dev/dri:/dev/dri`, `/data/media` read-only; the owner sets `LanNetworksBandwidth=192.168.50.0/24` and `customConnections=http://192.168.50.16:32400` in the UI | Owner decision. linuxserver/plex has no `ADVERTISE_IP`; the lsio init handles the render group | host networking (old setup; opens extra ports) |
| 4K split | Movies whose files are all ≥2160p, and series whose **every** episode file is ≥2160p, move to `movies-4k`/`tv-4k` (`mv`, same dataset). They are added to the 4K instance with `search=false` and rescanned, then unmonitored and tagged `4k-only` in HD. Mixed-resolution series are reported and skipped. `--undo <manifest>` reverses it | Owner decision: 4K only, no HD copy | Keep HD copies (owner rejected); leave 4K mixed in (fails the criterion) |
| 4K in Plex | Separate **Movies 4K** and **TV 4K** libraries, shared with **every** family member (Phase 6); non-4K devices get a transcode with HDR tone mapping on the A380 | Owner decision (2026-09-28): everyone can watch 4K-only titles | Merge into the HD libraries; restrict 4K to 4K-capable users (owner rejected) |
| Seerr anime | Sonarr Anime is a non-default Sonarr server in Seerr. **TV requests require approval** (family keeps `AUTO_APPROVE_MOVIE` but not `AUTO_APPROVE_TV`); the owner switches an anime request to Sonarr Anime while it is pending. 4K requests require approval (no `AUTO_APPROVE_4K*`) | Owner decision: Seerr can't route anime to another server automatically | Family picks the server (unreliable); merge anime into Sonarr (loses the old instance's history) |
| Seerr/Plex config | Done by the owner in the UI (runbook step); `verify-media.sh` checks the result | One-time choices; UI is safer than a script against changing APIs | Scripted (Clean) |
| Import verification | `verify-media.sh --watch-import <instance>` polls `/data/usenet/complete/<cat>` for up to `WATCH_TIMEOUT` (default 1800 s), recording `path → inode` for each new file, then checks the imported file (history `importedPath`) has a recorded inode and is on the same device | Usenet imports are moves, so the source path disappears; an inode match proves no copy happened | Hardlink link-count check (doesn't apply to moves) |

## API and Type Contracts
**Shared CLI contract:** every new script under `scripts/host/` and `scripts/vm/` follows the Phase 1 contract: `[--apply] [--help]`, dry-run prints `DRY-RUN: <cmd>`, exit 0/1/2, `set -Eeuo pipefail`, and sources `scripts/lib/common.sh`. `load_env` runs before the defaults. Validation uses `require_match`/`require_safe_path`, and every value that ends up in `run_sh` is validated first.

**`scripts/host/30-push-appdata.sh`** (Proxmox host, root with `--apply`)
- Env:
  - `VM_HOST` (required, `^[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+$`, e.g. `media@192.168.50.16`).
  - `ARCHIVE` (default: the newest `/tank/migration/old-docker-*.tar.zst`; must exist).
  - `STAGE_TS` (default `date +%Y%m%d-%H%M%S`, `^[0-9]{8}-[0-9]{6}$`).
  - `REMOTE_APPDATA` (default `/opt/appdata`).
- Fixed allow-list, archive member → destination:
  - `docker/plex/config` → `plex`
  - `docker/plex/seerr/config` → `seerr`
  - `docker/plex/tautulli` → `tautulli`
  - `docker/servarr/sonarr` → `sonarr`
  - `docker/servarr/animesonarr` → `sonarr-anime`
  - `docker/servarr/radarr` → `radarr`
  - `docker/servarr/lidarr` → `lidarr`
  - `docker/servarr/prowlarr` → `prowlarr`
  - `docker/servarr/sabnzbd` → `sabnzbd`
- Excludes: `*/logs/*`, `*/Logs/*`, `*.pid`, `*/Plex Media Server/Cache/*`, `*/Plex Media Server/Crash Reports/*`, `*/Plex Media Server/Logs/*`, `*/Backups/*` (the *arr zip backups), `*/backups/*`.
- Steps:
  1. Precheck: `ssh -o BatchMode=yes -o ConnectTimeout=10 "$VM_HOST" true`, or die with the `ssh-copy-id` hint.
  2. Refuse if the remote staging dir already exists.
  3. Print the member list.
  4. Pipeline, in exactly two `run_sh` steps. The first step extracts the allow-listed members into `TMP=$(mktemp -d /root/.push-appdata.XXXXXX)`, which is on the host root disk, never `/tank/data`, mode 700, and removed by `trap 'rm -rf "$TMP"' EXIT`. It applies the renames while extracting:
     ```
     tar -I zstd -xf "$ARCHIVE" -C "$TMP" --wildcards <excludes as --exclude=…> \
       --transform='s#^docker/plex/config#plex#' --transform='s#^docker/plex/seerr/config#seerr#' \
       --transform='s#^docker/plex/tautulli#tautulli#' --transform='s#^docker/servarr/animesonarr#sonarr-anime#' \
       --transform='s#^docker/servarr/##' <the 9 member paths>
     ```
     The second step streams the result to the VM:
     ```
     tar -C "$TMP" -cf - plex seerr tautulli sonarr sonarr-anime radarr lidarr prowlarr sabnzbd \
       | ssh "$VM_HOST" "mkdir -p -m 700 '$REMOTE_APPDATA/.staging/$STAGE_TS' && tar -x -C '$REMOTE_APPDATA/.staging/$STAGE_TS'"
     ```
     `--transform` is applied in list order, so the `plex/seerr/config` rule precedes the generic `docker/servarr/` strip. The script checks the extracted tree has exactly the 9 top-level dirs before streaming, and exits 1 if one is missing.
  5. Print `[INFO] staged $STAGE_TS on $VM_HOST`, then the next command.
- Output, dry-run: `[INFO] members:` lines, then exactly two `DRY-RUN:` lines, one for the extract and one for the ssh pipeline. The dry-run touches neither the archive nor the VM, apart from the ssh precheck.

**`scripts/vm/10-restore-appdata.sh`** (VM, `sudo` with `--apply`)
- Modes:
  - `[--apply]` restores the newest staging dir, or `STAGE_TS=<ts>`.
  - `--rollback <ts> [--apply]` moves `.rollback/<ts>/<svc>` back over `/opt/appdata/<svc>`. The current dirs go to `.rollback/<ts>-undone`.
- Env: `APPDATA_ROOT` (from `.env`), `PUID`/`PGID`, `COMPOSE_PROJECT_DIR` (default `$REPO_ROOT`).
- Preconditions:
  - `require_cmd sqlite3 jq docker`.
  - Die if any of the 9 restored services is running (`docker compose ps --status running --services`), with the hint `docker compose stop <svcs>`.
  - Die if the staging dir is missing or contains an entry outside the allow-list, or a symlink leaving the staging dir (`find -type l`).
- Apply, in order:
  1. For each of the 9 `<svc>` in staging: if `$APPDATA_ROOT/<svc>` is non-empty, move it to `$APPDATA_ROOT/.rollback/<ts>/<svc>`. Then `mv` the staged dir into place.
  2. `chown -R $PUID:$PGID` and `chmod 700` on each restored dir; `find -name '*.pid' -delete`.
  3. Plex: in `…/Plex Media Server/Preferences.xml`, set the attribute `autoEmptyTrash="0"` (add it if missing, replace it if present) using `sed`, then check with `grep -q 'autoEmptyTrash="0"'`.
  4. Run `sqlite3 <db> 'PRAGMA integrity_check;'` for `sonarr/sonarr.db`, `sonarr-anime/sonarr.db`, `radarr/radarr.db`, `lidarr/lidarr.db` and `prowlarr/prowlarr.db`. Any value other than `ok` fails with a rollback hint.
  5. Create any missing `$APPDATA_ROOT/{sonarr-4k,radarr-4k,jellyfin}` owned by `PUID:PGID`, mode 700.
  6. Write `$APPDATA_ROOT/.migration/baseline.json` (mode 600) with `jq -n` in this shape:
     ```
     {"created":"<iso8601>","stage":"<ts>",
      "files":{"sonarr":N,"sonarr-anime":N,"radarr":N,"lidarr":N},
      "plex_watched":N}
     ```
     The counts are:
     - `select count(*) from EpisodeFiles` (Sonarr, sonarr-anime).
     - `select count(*) from MovieFiles` (Radarr).
     - `select count(*) from TrackFiles` (Lidarr, `0` if the table is missing).
     - `select count(*) from metadata_item_settings where view_count>0` on the Plex DB. `-1` if the query errors, because Plex's DB uses custom FTS and failure is tolerated with a warning.
  7. Remove the empty staging dir.
- Dry-run prints each mv/chown/sed/sqlite step as `DRY-RUN:`.

**`scripts/lib/arr.sh`** (sourced; needs `common.sh` loaded first)
- `arr_port <svc>`: sonarr* 8989, radarr* 7878, lidarr 8686, prowlarr 9696, sabnzbd 8080, plex 32400, seerr 5055, tautulli 8181, jellyfin 8096. Anything else dies.
- `arr_api_base <svc>`: `/api/v3` for sonarr* and radarr*, `/api/v1` for lidarr and prowlarr.
- `svc_ip <svc>`: `docker inspect -f '{{with index .NetworkSettings.Networks "proxy"}}{{.IPAddress}}{{end}}' "$(docker compose ps -q <svc>)"`. Dies if empty (service not running).
- `svc_key <svc>`: reads the key with `sed -n` only, never `source`:
  - *arr/prowlarr: `<ApiKey>` from `$APPDATA_ROOT/<svc>/config.xml`.
  - sabnzbd: `api_key = ` from `sabnzbd.ini`.
  - seerr: `.main.apiKey` from `settings.json` via jq.
  - plex: `PlexOnlineToken` from `Preferences.xml`.
  - The value must match `^[A-Za-z0-9_-]{16,}$`, otherwise die (without printing it).
- `api <svc> <METHOD> <path> [json-body-file]`:
  - Runs curl with `-sS --fail-with-body --max-time 30`. The URL is `http://$(svc_ip svc):$(arr_port svc)<path>`, where `<path>` includes the api base when the caller passes one.
  - Headers: `X-Api-Key` (*arr, seerr) or `X-Plex-Token` (plex), passed as a `header = "…"` line on stdin via `-K -`, plus `Accept: application/json`.
  - Body: `--data-binary @file` with `Content-Type: application/json`.
  - Prints the response body; non-2xx makes it exit 1.
  - For SAB, `sab_api <mode> [k=v…]` builds `/api?mode=…&output=json&apikey` with the key in a `-K -` `url` line. Curl `url = ` lines on stdin keep the key out of argv. Values are URL-encoded with `jq -rn --arg v "$v" '$v|@uri'`.
- Every mutating call in the scripts goes through `arr_mutate <svc> <METHOD> <path> [body]`. In dry-run it prints `DRY-RUN: <METHOD> <svc> <path>` plus a one-line compact body summary with keys redacted. With `--apply` it calls `api`.

**`scripts/vm/20-arr-remap.sh`** (VM, as `media`)
- Remap table:
  - `sonarr`: `/data/shows` → `/data/media/tv`
  - `sonarr-anime`: `/data/anime` → `/data/media/anime-tv`
  - `radarr`: `/data/movies` → `/data/media/movies`
- Preconditions:
  - `sabnzbd` and `prowlarr` are not running, or die.
  - The three *arr instances are running and healthy.
  - Each new root dir exists on disk (`test -d`).
- Per instance:
  1. `PUT {base}/config/mediamanagement` with `autoUnmonitorPreviouslyDownloaded{Episodes|Movies}=false` (GET, modify, PUT).
  2. `POST {base}/rootfolder {"path":"<new>"}`, only if missing.
  3. From `GET {base}/series|movie`, select items whose `path` starts with `<old>/`. `PUT {base}/series/editor {"seriesIds":[…],"rootFolderPath":"<new>","moveFiles":false}` (or `movie/editor` with `movieIds`).
  4. Re-GET and confirm no item path starts with `<old>/`, or die.
  5. `DELETE {base}/rootfolder/<id>` for the old root.
  6. `POST {base}/command {"name":"RescanSeries"}` or `{"name":"RescanMovie"}`.
- Also: Lidarr gets `POST /api/v1/rootfolder` with `{"name":"Music","path":"/data/media/music","defaultQualityProfileId":<first>,"defaultMetadataProfileId":<first>}`, only if missing.
- Output: `[INFO] <svc>: <n> items <old> -> <new>`.

**`scripts/vm/25-arr-wire.sh`** (VM, as `media`; runs after the remap, with sabnzbd and prowlarr running)
- **SAB:**
  - `set_config misc download_dir=/data/usenet/incomplete`, `complete_dir=/data/usenet/complete`.
  - `host_whitelist`: the existing value plus `sabnzbd,media-01,192.168.50.16`, deduplicated. The values are read from `get_config`; `LAN_IP` and `hostname` come from `.env` or the system.
  - Categories: for each of `tv tv-4k movies movies-4k music anime`, `set_config categories keyword=<c> dir=<c>`.
  - `del_config categories` for `series`, `anime-series` and `software`, if present.
- **Per-*arr desired state:**

  | svc | root folders | SAB category field | category |
  |---|---|---|---|
  | sonarr | `/data/media/tv` | `tvCategory` | `tv` |
  | sonarr-anime | `/data/media/anime-tv` | `tvCategory` | `anime` |
  | sonarr-4k | `/data/media/tv-4k` | `tvCategory` | `tv-4k` |
  | radarr | `/data/media/movies`, `/data/media/anime-movies` | `movieCategory` | `movies` |
  | radarr-4k | `/data/media/movies-4k` | `movieCategory` | `movies-4k` |
  | lidarr | `/data/media/music` | `musicCategory` | `music` |

  For each instance:
  - Add missing root folders.
  - Delete download clients whose `implementation` ≠ `Sabnzbd`.
  - Upsert one client named `SABnzbd`: `implementation: Sabnzbd`, `configContract: SabnzbdSettings`, `enable: true`, `removeCompletedDownloads: true`, `removeFailedDownloads: true`. Fields: `host=sabnzbd`, `port=8080`, `useSsl=false`, `apiKey=<SAB key>`, `<categoryField>=<cat>`. Build it from `GET {base}/downloadclient/schema` (the Sabnzbd entry) and set the named fields.
  - Delete all `remotepathmapping` entries.
- **Prowlarr:**
  - Delete indexers with `protocol=="torrent"`.
  - Delete all `indexerproxy` entries (FlareSolverr).
  - Upsert applications by name: `Sonarr`, `Sonarr Anime`, `Sonarr 4K`, `Radarr`, `Radarr 4K`, `Lidarr`. Use `implementation` Sonarr/Radarr/Lidarr and `syncLevel: fullSync`. Fields: `prowlarrUrl=http://prowlarr:9696`, `baseUrl=http://<svc>:<port>`, `apiKey=<svc key>`, `syncCategories` from the schema defaults. For Sonarr Anime set `syncCategories=[5070]` and `animeSyncCategories=[5070]`. Delete an old app named `animesonarr` or pointing to `http://animesonarr:8989`.
  - `POST /api/v1/command {"name":"ApplicationIndexerSync","forceSync":true}`.
- Idempotent: a second `--apply` makes 0 mutating calls. The dry-run then prints `[INFO] no changes`.

**`scripts/vm/30-split-4k.sh`** (VM, as `media`)
- Modes: default dry-run (writes the plan and prints a summary), `--apply`, `--undo <manifest> [--apply]`.
- Env: `QP_4K_RADARR` and `QP_4K_SONARR` (quality profile names in the 4K instances, default `Ultra-HD`). If a profile is missing the script dies, listing the available names.
- Plan file: `$APPDATA_ROOT/.migration/split-4k-<ts>.tsv`, with the columns `kind instance id title src dst action`.
  - `kind` is `movie` or `series`.
  - `action` is `move` or `skip-mixed`.
  - A movie is marked `move` if every `moviefile` has `quality.quality.resolution >= 2160`.
  - A series is marked `move` if it has ≥1 episode file and every episode file is ≥2160. It is `skip-mixed` if some are ≥2160 and some are not.
- Apply, per `move` row:
  1. Refuse if `dst` exists.
  2. `mv "$src" "$dst"`, where `dst` is `/data/media/{movies-4k|tv-4k}/<basename>`.
  3. `POST` to radarr-4k `/api/v3/movie` (or sonarr-4k `/series`) with `{tmdbId|tvdbId, title, year, qualityProfileId, rootFolderPath, path:dst, monitored:true, addOptions:{searchForMovie:false | searchForMissingEpisodes:false, monitor:"all"}}`. For sonarr, also `seasonFolder` and `languageProfileId` if the schema requires it. Take the ids from the HD record.
  4. Rescan in the 4K instance.
  5. In the HD instance, ensure the tag `4k-only` exists and `PUT` the item with `monitored:false` and the tag added.
  6. Append the row with its result to the manifest `…/split-4k-<ts>.manifest.tsv`.
- Undo: in reverse order, `mv dst src`; `DELETE` the item from the 4K instance with `deleteFiles=false`; set HD `monitored:true` and remove the tag; rescan HD.

**`scripts/vm/verify-media.sh`** (VM, as `media`; read-only except `--watch-import`, which only reads)
- Output follows the Phase 1 format: `PASS|FAIL|SKIP <id> <detail>` lines, then `RESULT: <n> pass, <n> fail, <n> skip`. Exit 1 if any FAIL.
- Check IDs, in order:
  1. **`compose-healthy`**: all 11 core services are running and healthy.
  2. **`image-versions`**: images meet `config/min-versions.txt`.
  3. **`arr-rootfolders`**: each instance's root set equals the wiring table, and no item path lies under an old root.
  4. **`library-adopted`**: for each HD instance, file count + files moved to 4K per the manifests ≥ baseline.
  5. **`sab-categories`**
  6. **`download-clients`**
  7. **`prowlarr-sync`**
  8. **`4k-split`**: SKIP if no plan file exists.
  9. **`plex-sections`**: Plex `/library/sections` plus `/:/prefs` `autoEmptyTrash`.
  10. **`plex-hw`**: `/status/sessions`; SKIP if there is no transcode session.
  11. **`seerr-servers`**: Seerr `/api/v1/settings/radarr` and `/sonarr`.
  12. **`jellyfin`**: SKIP unless running; otherwise `/health` = `Healthy` and `/dev/dri` present in the container.
- `--watch-import <svc>` runs only the import check and prints `PASS|FAIL import <detail>`:
  1. Record the start time.
  2. Poll every 5 s: `find /data/usenet/complete/<cat> -type f -newermt <start>` → `path inode`.
  3. When `GET {base}/history?eventType=downloadFolderImported&sortKey=date&sortDirection=descending&pageSize=1` shows a record newer than the start, `stat` its `importedPath`. PASS if the inode is among the recorded ones and `stat -c %d` of the imported file equals that of `/data/usenet/complete`.
  4. FAIL after `WATCH_TIMEOUT` (default 1800 s).
- Env `SKIP_APPS=1` (CI): every check that needs a live service reports SKIP. Stub-driven tests don't set it.

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

**`config/min-versions.txt`:** one `image-repo min-tag` per line (the eight old tags). **`scripts/ci/check-min-versions.sh [compose-file]`** reads `docker compose config --images` (with `COMPOSE_PROFILES=jellyfin`), compares each image in the list against the minimum using `sort -V` on the numeric version (the `-lsNNN` suffix is compared as the last field), exits 1 with `BELOW-MIN: <image> < <min>` otherwise, and prints `OK: <n> images at or above minimum`.

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
1. **Precondition (owner):** the old Ubuntu VM is stopped with onboot disabled. A second Plex with the same server identity, or old *arr instances, must not run. Host root has an ssh key on `media@192.168.50.16` (`ssh-copy-id`).
2. **VM:** `sudo apt-get install -y jq sqlite3`, then `git pull` (on `dev`), set `LAN_IP` and `COMPOSE_FILE` in `.env`, then `docker compose pull`.
3. **Host:** `VM_HOST=media@192.168.50.16 scripts/host/30-push-appdata.sh` (dry-run), then `--apply`.
4. **VM:** `sudo scripts/vm/10-restore-appdata.sh`, then `--apply`.
5. **VM:** `docker compose up -d sonarr sonarr-anime radarr lidarr` (SAB and Prowlarr stay down), then run `scripts/vm/20-arr-remap.sh` dry-run and `--apply`.
6. **VM:** `docker compose up -d` (all core services), then `scripts/vm/25-arr-wire.sh` dry-run and `--apply`.
7. **Owner UI:** in the 4K instances, check that the `Ultra-HD` profile exists or set `QP_4K_*`. Then run `scripts/vm/30-split-4k.sh` and review the TSV, then `--apply`.
8. **Owner UI, Plex:**
   - Set the network prefs.
   - For each section: add the new folder, scan, remove the old folder.
   - Create Movies 4K and TV 4K.
   - Check that HW transcoding is on.
   - Empty the trash only after the counts match.
9. **Owner UI, Seerr:**
   - Update the servers per the contract.
   - Permissions: family keeps `AUTO_APPROVE_MOVIE` and does not get `AUTO_APPROVE_TV` or `AUTO_APPROVE_4K*`; `REQUEST_4K` is granted.
   - Tautulli: point it at `http://plex:32400`.
10. **Owner:** add a Twingate resource for `192.168.50.16` (admin ports).
11. **Owner:** make test requests: an HD movie, a 4K movie (approve it), and an anime show (approve it, switching to Sonarr Anime). During each, run `verify-media.sh --watch-import <svc>`.
12. **Owner:** force a transcode in Plex, run `scripts/vm/verify-media.sh`, and paste the output into the runbook's Acceptance record.

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
| Target services running during restore | Exit 1 with `docker compose stop` hint | CI docker stub |
| *arr DB integrity not `ok` | Exit 1 after the swap, printing `--rollback <ts>` | CI with a corrupted sqlite fixture |
| Plex Preferences.xml missing | Warn and skip the pref edit; runbook step 8 sets it in the UI before the first scan | CI fixture |
| Remap with SAB/Prowlarr running | `20-arr-remap` exits 1 | CI stub |
| Items still under the old root after the editor call | Exit 1, listing the ids; the old root is not deleted | CI fixture |
| Secret value malformed or missing | Die with `missing/invalid API key for <svc>`, without printing the value | CI |
| API returns non-2xx | Exit 1 with method, svc and path (no key) | CI |
| 4K quality profile missing | `30-split` exits 1 listing the profiles | CI fixture |
| 4K destination exists | That row fails; the whole run exits 1 before any move (preflight checks every row first) | CI |
| Mixed-resolution series | Reported `skip-mixed`, not moved | CI fixture |
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
| Real run | Owner: `verify-media.sh` RESULT with 0 fail (`plex-hw` PASS required; `jellyfin` may SKIP); three `--watch-import` PASS lines | true (owner) |

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
- **Stub contract:**
  - `make-api-stubs.sh <dir>` writes stub `docker`, `curl` and `ssh` executables.
  - `docker inspect` prints `172.30.0.<n>`.
  - `docker compose ps` honors `STUB_RUNNING="svc1 svc2"`.
  - `curl` parses `-K -` stdin and the URL, logs `METHOD svc path` to `$STUB_LOG`, and returns `$STUB_FIXTURES/<svc>/<METHOD>_<path with / and ? → _>.json`, or `{}` if missing.
  - `ssh` honors `STUB_SSH_RC`.
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
  - A step that runs every `scripts/ci/test-*.sh` that exists.
  - Shellcheck glob extended to `scripts/lib/*.sh`.

### Planning doc updates
- **Path:** `.planning/PROJECT.md`, `.planning/ROADMAP.md`, `.planning/migration/old-stack-inventory.md`
- **Key Content:**
  - PROJECT.md: R5 gets separate 4K libraries shared with everyone; R12's 4K rule becomes "everyone, transcoded as needed"; add decision rows for the 4K access, anime approval and restore/remap approach.
  - ROADMAP.md: Phase 2 plan count 4; the R2.12 wording "hardlink or atomic move (same inode)"; the Phase 6 share criterion.
  - old-stack-inventory.md: the path facts.

## Open Questions
| # | Question | Impact | Default Chosen by Spec | Planning Effect |
|---|----------|--------|------------------------|-----------------|
| 1 | Does the 4K instance's built-in profile name match `Ultra-HD` on sonarr 4.0.19 / radarr 6.3.0? | Non-blocking | `Ultra-HD`, overridable via `QP_4K_*`; the script dies listing the real names | Env override + runbook step |
| 2 | Does Plex's DB open in stock `sqlite3` for the watched count? | Non-blocking | Tolerate failure (`-1` + warn); watch state is checked by the owner in the UI | Baseline field optional |
| 3 | Seerr v3.4.1 settings API paths (`/api/v1/settings/radarr`, `/sonarr`) | Non-blocking | These paths (Overseerr-lineage API, unchanged in the Seerr source); on 404 the check reports FAIL with a hint | verify check |
| 4 | Sonarr add-series payload requires `languageProfileId` on v4? | Non-blocking | Build the payload from `GET /series/lookup?term=tvdb:<id>`, then set `qualityProfileId`, `rootFolderPath`, `path`, `monitored`, `addOptions` | Script builds from lookup |
| 5 | Are there SAB jobs in the queue from the old server? | Non-blocking | The runbook clears the SAB queue/history after wiring (the old paths no longer exist) | Runbook step 4 |
| 6 | Old Prowlarr app names | Non-blocking | Upsert by `baseUrl` host match **or** name; delete any app whose host is `animesonarr`, `nzbget` or `qbittorrent` | Script logic |

## Complexity Assessment
_Filled in after the critique pass._
