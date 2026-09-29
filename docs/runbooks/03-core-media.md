# Runbook 03 — Core media cutover

This runbook moves the old server's media stack onto `media-01` (VM 200,
`192.168.50.16`). It restores the old app configs, points them at the new
`/data/media` layout, wires SABnzbd, the six *arr instances and Prowlarr for
Usenet only, splits the 4K titles into their own libraries, and ends with
the acceptance run. Settings, history and Plex watch state are kept, and
the library already in `/data/media` is adopted in place, with no
re-downloads.

Run every command **inside the VM**, as `media`, from the repo checkout
(`/opt/home-media-server`), unless a step says **On the Proxmox host**.

Every script is a dry-run by default: it reads, checks and prints what it
would do (`DRY-RUN: ...`), and changes nothing until you add `--apply`.
Always run the dry-run first and read it. The "Example (from the CI
fixtures)" blocks below are real output of the same scripts run against
this repo's test stubs and synthetic fixtures, so your titles, counts,
ids and timestamps will differ. `<tmp>` stands for a test temp dir; on the
VM those paths are `/opt/appdata/...` and `/data/...`.

Plan on a few hours: the Plex rescans (step 6) and the test downloads
(step 10) take the longest. You can stop between steps.

## Prerequisites

- Runbook 02 is complete: `scripts/vm/verify.sh` printed
  `RESULT: 10 pass, 0 fail, 0 skip`.
- **The old Ubuntu VM is powered off and cannot start again.** A second
  Plex with the same identity, or the old *arr apps grabbing into the old
  paths, must never run next to the new stack. **On the old Proxmox host**
  (the machine the old VM ran on; `<old-vmid>` is its VM id):
  ```bash
  qm status <old-vmid>
  qm config <old-vmid> | grep onboot
  ```
  The first command must show `status: stopped`. The second must print
  nothing or `onboot: 0`. If it shows `onboot: 1`, turn it off with
  `qm set <old-vmid> --onboot 0`. If the old machine is simply unplugged,
  that counts too; leave it unplugged.
- The migration archive exists **on the Proxmox host**:
  ```bash
  ls -l /tank/migration/old-docker-*.tar.zst
  ```

> **Warning: live secrets.** `/tank/migration/old-docker-*.tar.zst`, and
> the `_inspect.json` and `_compose-resolved.yml` dumps made with it, hold
> the old apps' API keys, the Plex token and the Usenet and indexer
> passwords. **Never copy any of them into this repo** (not even
> "temporarily"), never extract them onto `/tank/data` or `/data`, and
> never paste their contents into an issue or a chat. Step 2 streams the
> archive over ssh straight into a mode-700 staging dir on the VM; that is
> the only way it should leave the host.

- The host's root user can ssh to the VM with a key. **On the Proxmox
  host:**
  ```bash
  test -f /root/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
  ssh-copy-id -i /root/.ssh/id_ed25519.pub media@192.168.50.16
  ssh -o BatchMode=yes media@192.168.50.16 true && echo ssh-ok
  ```
  The last command must print `ssh-ok` without asking for a password.
- Update the host's repo checkout, so it has this phase's
  `scripts/host/30-push-appdata.sh`. The clone from runbook 01 predates
  this phase. **On the Proxmox host:**
  ```bash
  cd /root/home-media-server
  git fetch && git checkout dev && git pull
  test -x scripts/host/30-push-appdata.sh && echo push-script-ok
  ```
  The last command must print `push-script-ok`.
- Take the VM rollback point. **On the Proxmox host:**
  ```bash
  qm snapshot 200 pre-phase2 --vmstate 0
  qm listsnapshot 200
  ```
  `pre-phase2` must be in the list. The snapshot covers the VM disk
  (appdata, `.env`, containers), not `/data`: that is the virtiofs share
  of `tank/data`, which step 5 snapshots separately.
- Update the VM. **Inside the VM:**
  ```bash
  sudo apt-get install -y jq sqlite3
  cd /opt/home-media-server
  git checkout dev && git pull
  ```
  Edit `.env`: set `LAN_IP=192.168.50.16` and uncomment the line
  `COMPOSE_FILE=compose.yaml:compose.lan.yaml`, which publishes the admin
  UIs on the LAN until Phase 3. `LAN_IP` must be the VM's own LAN
  address, never `0.0.0.0`: the admin UIs bind only to it, and
  `25-arr-wire.sh` adds it to SABnzbd's host whitelist (it stops with
  `invalid LAN_IP '0.0.0.0': LAN_IP must be the VM's own LAN address`).
  Then check the config and pull the images (this only downloads;
  nothing starts):
  ```bash
  docker compose config -q && docker compose pull
  ```

## 1. Stop the old stack

The old server's stack stopped with its VM (Prerequisites). On
`media-01`, none of the restored services may run while their configs are
swapped in; the restore refuses otherwise. Stop anything that is running:

```bash
docker compose ps --status running --services
docker compose stop
```

The first command lists the running services; after `docker compose
stop` it must list none. If you skip this, step 2 stops you with a hint
like this one:

Example (from the CI fixtures):
```
[ERROR] stop first: docker compose stop plex sonarr
```

The restore also refuses while any old root exists on the new pool
(`/data/shows`, `/data/movies`, `/data/anime`): the restored apps still
point at those paths until step 3, and a scan of an existing old root
would drop their file records. Check it now:

```bash
test ! -e /data/shows && test ! -e /data/movies && test ! -e /data/anime && echo no-old-roots
```

This must print `no-old-roots`. If it doesn't, the pool import (runbook
01, section 1a) left an old directory behind: move its contents into the
matching `/data/media/*` folder on the host and remove it.

## 2. Restore app configs

**On the Proxmox host**, from the repo checkout there (updated in
Prerequisites), preview the push:

```bash
cd /root/home-media-server
VM_HOST=media@192.168.50.16 scripts/host/30-push-appdata.sh
```

Example (from the CI fixtures):
```
[INFO] archive: <tmp>/old-docker-2026-09-27.tar.zst
[INFO] members:
[INFO]   docker/plex/config -> plex
[INFO]   docker/plex/seerr/config -> seerr
[INFO]   docker/plex/tautulli -> tautulli
[INFO]   docker/servarr/sonarr -> sonarr
[INFO]   docker/servarr/animesonarr -> sonarr-anime
[INFO]   docker/servarr/radarr -> radarr
[INFO]   docker/servarr/lidarr -> lidarr
[INFO]   docker/servarr/prowlarr -> prowlarr
[INFO]   docker/servarr/sabnzbd -> sabnzbd
DRY-RUN: zstd -dc -- '<tmp>/old-docker-2026-09-27.tar.zst' | ssh -o BatchMode=yes -o ConnectTimeout=10 'media@192.168.50.16' "mkdir -p -m 700 '/opt/appdata/.staging/20260928-164849' && tar -x -C '/opt/appdata/.staging/20260928-164849' --wildcards --exclude='docker/*/*/logs' --exclude='docker/*/*/Logs' --exclude='*.pid' --exclude='docker/plex/config/Library/Application Support/Plex Media Server/Cache' --exclude='docker/plex/config/Library/Application Support/Plex Media Server/Crash Reports' --exclude='docker/plex/config/Library/Application Support/Plex Media Server/Logs' --exclude='docker/servarr/*/Backups' --exclude='docker/servarr/*/backups' --transform='s#^docker/plex/seerr/config#seerr#' --transform='s#^docker/plex/config#plex#' --transform='s#^docker/plex/tautulli#tautulli#' --transform='s#^docker/servarr/animesonarr#sonarr-anime#' --transform='s#^docker/servarr/##' 'docker/plex/config' 'docker/plex/seerr/config' 'docker/plex/tautulli' 'docker/servarr/sonarr' 'docker/servarr/animesonarr' 'docker/servarr/radarr' 'docker/servarr/lidarr' 'docker/servarr/prowlarr' 'docker/servarr/sabnzbd'"
DRY-RUN: ssh -o BatchMode=yes -o ConnectTimeout=10 'media@192.168.50.16' "ls -1 '/opt/appdata/.staging/20260928-164849'"
[INFO] dry-run: would stage 20260928-164849 on media@192.168.50.16 (re-run with --apply)
[INFO] next (on the VM): sudo scripts/vm/10-restore-appdata.sh --stage 20260928-164849
```

Check that:
- `archive:` is the newest `/tank/migration/old-docker-*.tar.zst` (set
  `ARCHIVE=<path>` to pick another);
- the nine members map to `plex seerr tautulli sonarr sonarr-anime radarr
  lidarr prowlarr sabnzbd`;
- the pipeline is `zstd -dc ... | ssh ... tar -x`: the host only
  decompresses, and nothing is written on the host.

The dry-run already tested ssh and that the stage dir doesn't exist. Push
it (the timestamp is picked now; the output names it):

```bash
cd /root/home-media-server
VM_HOST=media@192.168.50.16 scripts/host/30-push-appdata.sh --apply
```

It ends with `[INFO] staged <ts> on media@192.168.50.16` and the next
command. Write `<ts>` down: the rollback uses it.

**Inside the VM**, preview the restore:

```bash
sudo scripts/vm/10-restore-appdata.sh --stage <ts>
```

Example (from the CI fixtures):
```
[INFO] integrity ok: sonarr/sonarr.db
[INFO] integrity ok: sonarr-anime/sonarr.db
[INFO] integrity ok: radarr/radarr.db
[INFO] integrity ok: lidarr/lidarr.db
[INFO] integrity ok: prowlarr/prowlarr.db
DRY-RUN: install -d -m 700 -o 0 -g 0 <tmp>/appdata/.rollback
DRY-RUN: mkdir -p -m 700 <tmp>/appdata/.rollback/20260928-120000
DRY-RUN: mv -T <tmp>/appdata/.staging/20260928-120000/lidarr <tmp>/appdata/lidarr
DRY-RUN: mv -T <tmp>/appdata/.staging/20260928-120000/plex <tmp>/appdata/plex
DRY-RUN: mv -T <tmp>/appdata/.staging/20260928-120000/prowlarr <tmp>/appdata/prowlarr
DRY-RUN: mv -T <tmp>/appdata/.staging/20260928-120000/radarr <tmp>/appdata/radarr
DRY-RUN: mv -T <tmp>/appdata/.staging/20260928-120000/sabnzbd <tmp>/appdata/sabnzbd
DRY-RUN: mv -T <tmp>/appdata/.staging/20260928-120000/seerr <tmp>/appdata/seerr
DRY-RUN: mv -T <tmp>/appdata/.staging/20260928-120000/sonarr <tmp>/appdata/sonarr
DRY-RUN: mv -T <tmp>/appdata/.staging/20260928-120000/sonarr-anime <tmp>/appdata/sonarr-anime
DRY-RUN: mv -T <tmp>/appdata/.staging/20260928-120000/tautulli <tmp>/appdata/tautulli
DRY-RUN: record installed services in <tmp>/appdata/.rollback/20260928-120000/installed: lidarr plex prowlarr radarr sabnzbd seerr sonarr sonarr-anime tautulli
DRY-RUN: chown -R 1000:1000 <tmp>/appdata/lidarr
DRY-RUN: chmod 700 <tmp>/appdata/lidarr
DRY-RUN: find <tmp>/appdata/lidarr -name '*.pid' -delete
DRY-RUN: chown -R 1000:1000 <tmp>/appdata/plex
DRY-RUN: chmod 700 <tmp>/appdata/plex
DRY-RUN: find <tmp>/appdata/plex -name '*.pid' -delete
DRY-RUN: chown -R 1000:1000 <tmp>/appdata/prowlarr
DRY-RUN: chmod 700 <tmp>/appdata/prowlarr
DRY-RUN: find <tmp>/appdata/prowlarr -name '*.pid' -delete
DRY-RUN: chown -R 1000:1000 <tmp>/appdata/radarr
DRY-RUN: chmod 700 <tmp>/appdata/radarr
DRY-RUN: find <tmp>/appdata/radarr -name '*.pid' -delete
DRY-RUN: chown -R 1000:1000 <tmp>/appdata/sabnzbd
DRY-RUN: chmod 700 <tmp>/appdata/sabnzbd
DRY-RUN: find <tmp>/appdata/sabnzbd -name '*.pid' -delete
DRY-RUN: chown -R 1000:1000 <tmp>/appdata/seerr
DRY-RUN: chmod 700 <tmp>/appdata/seerr
DRY-RUN: find <tmp>/appdata/seerr -name '*.pid' -delete
DRY-RUN: chown -R 1000:1000 <tmp>/appdata/sonarr
DRY-RUN: chmod 700 <tmp>/appdata/sonarr
DRY-RUN: find <tmp>/appdata/sonarr -name '*.pid' -delete
DRY-RUN: chown -R 1000:1000 <tmp>/appdata/sonarr-anime
DRY-RUN: chmod 700 <tmp>/appdata/sonarr-anime
DRY-RUN: find <tmp>/appdata/sonarr-anime -name '*.pid' -delete
DRY-RUN: chown -R 1000:1000 <tmp>/appdata/tautulli
DRY-RUN: chmod 700 <tmp>/appdata/tautulli
DRY-RUN: find <tmp>/appdata/tautulli -name '*.pid' -delete
DRY-RUN: sed -i 's/autoEmptyTrash="[^"]*"/autoEmptyTrash="0"/' <tmp>/appdata/plex/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml
[WARN] plex: stale TranscoderTempDirectory="/data/transcode"; removing it
DRY-RUN: sed -i 's/ *TranscoderTempDirectory="[^"]*"//' <tmp>/appdata/plex/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml
DRY-RUN: sed -i -e 's#^download_dir *=.*#download_dir = /data/usenet/incomplete#' -e 's#^complete_dir *=.*#complete_dir = /data/usenet/complete#' <tmp>/appdata/sabnzbd/sabnzbd.ini
DRY-RUN: mv -T <tmp>/appdata/sabnzbd/admin <tmp>/appdata/.rollback/20260928-120000/sabnzbd-admin
[INFO] sabnzbd: old queue/history moved to .rollback/20260928-120000/sabnzbd-admin
DRY-RUN: install -d -m 700 -o 1000 -g 1000 <tmp>/appdata/sonarr-4k
DRY-RUN: install -d -m 700 -o 1000 -g 1000 <tmp>/appdata/radarr-4k
DRY-RUN: install -d -m 700 -o 1000 -g 1000 <tmp>/appdata/jellyfin
DRY-RUN: write baseline <tmp>/appdata/.migration/baseline.json (and <tmp>/appdata/.migration/baseline-ids/*.txt)
DRY-RUN: rmdir <tmp>/appdata/.staging/20260928-120000
[INFO] restored 9 services from 20260928-120000; next: docker compose up -d sonarr sonarr-anime radarr lidarr
```

Check that:
- the five `integrity ok:` lines are there (these checks run even in the
  dry-run; a failed check stops the script before anything moves);
- all nine services get a `mv -T` line, followed by
  `DRY-RUN: record installed services in .../.rollback/<ts>/installed`
  (the list `--rollback` uses to undo them);
- no `[WARN] <svc> UrlBase=... Port=...` line appears. If one does, finish
  the restore, then fix it before step 3 (Troubleshooting, "UrlBase").
  A `[WARN] plex: stale TranscoderTempDirectory` line is expected when the
  old server used a custom transcode dir; the script removes it.

Apply it:

```bash
sudo scripts/vm/10-restore-appdata.sh --stage <ts> --apply
jq '{created, files, items_with_files, plex_watched, warnings}' /opt/appdata/.migration/baseline.json
```

If the apply stops with `restore <ts> failed after the swap started`,
don't re-run it: see Troubleshooting, "Restore failed after the swap".

`baseline.json` is what step 6 and step 10 compare against. If
`plex_watched` is `-1`, the Plex database couldn't be read: `plex-watched`
will SKIP, and you spot-check watch state in the Plex UI in step 6
instead.

## 3. Remap *arr paths

Confirm the old roots are still absent, then start the four restored
*arr apps (not SABnzbd or Prowlarr: no grabs may happen while paths are
in flux):

```bash
test ! -e /data/shows && test ! -e /data/movies && test ! -e /data/anime && echo no-old-roots
docker compose up -d sonarr sonarr-anime radarr lidarr
docker compose ps sonarr sonarr-anime radarr lidarr
```

Wait until all four show `(healthy)` (up to two minutes), then preview:

```bash
scripts/vm/20-arr-remap.sh
```

Example (from the CI fixtures):
```
DRY-RUN: PUT sonarr /api/v3/config/mediamanagement/1 {"id":1,"autoUnmonitorPreviouslyDownloadedEpisodes":false,"recycleBin":"","createEmptySeriesFolders":false,"deleteEmptyFolders":false,"fileDate":"none","copyUsingHardlinks":true}
DRY-RUN: POST sonarr /api/v3/rootfolder {"path":"/data/media/tv"}
DRY-RUN: PUT sonarr /api/v3/series/editor {"seriesIds":[1,2],"rootFolderPath":"/data/media/tv","moveFiles":false}
DRY-RUN: DELETE sonarr /api/v3/rootfolder/1
DRY-RUN: POST sonarr /api/v3/command {"name":"RescanSeries"}
DRY-RUN: PUT sonarr-anime /api/v3/config/mediamanagement/1 {"id":1,"autoUnmonitorPreviouslyDownloadedEpisodes":false,"recycleBin":"","copyUsingHardlinks":true}
DRY-RUN: POST sonarr-anime /api/v3/rootfolder {"path":"/data/media/anime-tv"}
DRY-RUN: PUT sonarr-anime /api/v3/series/editor {"seriesIds":[11,12],"rootFolderPath":"/data/media/anime-tv","moveFiles":false}
DRY-RUN: DELETE sonarr-anime /api/v3/rootfolder/4
DRY-RUN: POST sonarr-anime /api/v3/command {"name":"RescanSeries"}
DRY-RUN: PUT radarr /api/v3/config/mediamanagement/1 {"id":1,"autoUnmonitorPreviouslyDownloadedMovies":false,"recycleBin":"","copyUsingHardlinks":true}
DRY-RUN: POST radarr /api/v3/rootfolder {"path":"/data/media/movies"}
DRY-RUN: PUT radarr /api/v3/movie/editor {"movieIds":[21,22],"rootFolderPath":"/data/media/movies","moveFiles":false}
DRY-RUN: DELETE radarr /api/v3/rootfolder/1
DRY-RUN: POST radarr /api/v3/command {"name":"RescanMovie"}
DRY-RUN: POST lidarr /api/v1/rootfolder {"name":"Music","path":"/data/media/music","defaultQualityProfileId":1,"defaultMetadataProfileId":1}
[INFO] sonarr: 2 items /data/shows -> /data/media/tv
[INFO] sonarr-anime: 2 items /data/anime -> /data/media/anime-tv
[INFO] radarr: 2 items /data/movies -> /data/media/movies
[INFO] 16 changes (dry-run; pass --apply to make them)
[INFO] next: docker compose up -d sabnzbd && scripts/vm/25-arr-wire.sh --only sab
```

Check that:
- each instance's first change is the `PUT .../config/mediamanagement`
  that sets `autoUnmonitorPreviouslyDownloaded...` to `false` (so no scan
  can unmonitor your library);
- every editor call has `"moveFiles":false` (only the database paths
  change; no file moves);
- the `[INFO] <svc>: <n> items` counts match your library (the number of
  series or movies in each app).

Before any change, even in the dry-run, the remap checks that every
title **that has files** already has its folder under its new root on the
pool. If one is missing, it stops with `folder missing on the new pool;
nothing changed: <paths>` (Troubleshooting, "Remap: folder missing").
Titles with no files (unreleased or never downloaded, so the *arr app has
no folder for them) are only listed in an `[INFO] <n> title(s) have no
files yet and no folder on the new pool` line; nothing needs doing.

Apply it. Each instance's rescan must finish within `WAIT_TIMEOUT`
seconds (default 600). For a large library, raise it:

```bash
WAIT_TIMEOUT=1800 scripts/vm/20-arr-remap.sh --apply
```

If a rescan still takes longer, the remap stops with `command <id> still
queued in <svc>; re-running is safe; raise WAIT_TIMEOUT (seconds) for
large libraries`. Re-run it with a larger `WAIT_TIMEOUT`; the re-run
skips what is already done.

A dry-run afterwards finds nothing left to do:

Example (from the CI fixtures, the same dry-run after the remap):
```
[INFO] sonarr: 0 items /data/shows -> /data/media/tv
[INFO] sonarr-anime: 0 items /data/anime -> /data/media/anime-tv
[INFO] radarr: 0 items /data/movies -> /data/media/movies
[INFO] no changes
[INFO] next: docker compose up -d sabnzbd && scripts/vm/25-arr-wire.sh --only sab
```

## 4. Wire SABnzbd, download clients and Prowlarr

Start SABnzbd alone and fix its dirs and categories before any *arr app or
Prowlarr can talk to it:

```bash
docker compose up -d sabnzbd
scripts/vm/25-arr-wire.sh --only sab
```

Example (from the CI fixtures):
```
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=misc&keyword=download_dir&value=%2Fdata%2Fusenet%2Fincomplete
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=misc&keyword=complete_dir&value=%2Fdata%2Fusenet%2Fcomplete
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=misc&keyword=host_whitelist&value=oldvm.lan%2Coldvm%2Csabnzbd%2Cmedia-01%2C192.168.50.16
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=tv&dir=tv
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=tv-4k&dir=tv-4k
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=movies&dir=movies
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=movies-4k&dir=movies-4k
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=music&dir=music
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=anime&dir=anime
DRY-RUN: GET sabnzbd /api?mode=del_config&output=json&section=categories&keyword=series
DRY-RUN: GET sabnzbd /api?mode=del_config&output=json&section=categories&keyword=anime-series
DRY-RUN: GET sabnzbd /api?mode=del_config&output=json&section=categories&keyword=software
DRY-RUN: GET sabnzbd /api?mode=pause&output=json
[INFO] 13 changes (dry-run; pass --apply to make them)
[INFO] next: docker compose up -d && scripts/vm/25-arr-wire.sh
```

Check the whitelist line (`sabnzbd`, the VM's host name and
`192.168.50.16` are added), the six categories whose dir is their own
name, the three old categories being deleted, and `mode=pause` at the end.
If the old queue or history still holds jobs from before the baseline,
two more lines purge them. Apply it:

```bash
scripts/vm/25-arr-wire.sh --only sab --apply
```

`--only sab --apply` **leaves the SAB queue paused**, so nothing downloads
into a category before the *arr apps are wired. The full `--apply` below
resumes it.

Now start everything and wait until all eleven core services are
`(healthy)` (Plex can take up to five minutes):

```bash
docker compose up -d
docker compose ps
scripts/vm/25-arr-wire.sh
```

Example (from the CI fixtures):
```
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=misc&keyword=download_dir&value=%2Fdata%2Fusenet%2Fincomplete
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=misc&keyword=complete_dir&value=%2Fdata%2Fusenet%2Fcomplete
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=misc&keyword=host_whitelist&value=oldvm.lan%2Coldvm%2Csabnzbd%2Cmedia-01%2C192.168.50.16
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=tv&dir=tv
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=tv-4k&dir=tv-4k
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=movies&dir=movies
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=movies-4k&dir=movies-4k
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=music&dir=music
DRY-RUN: GET sabnzbd /api?mode=set_config&output=json&section=categories&keyword=anime&dir=anime
DRY-RUN: GET sabnzbd /api?mode=del_config&output=json&section=categories&keyword=series
DRY-RUN: GET sabnzbd /api?mode=del_config&output=json&section=categories&keyword=anime-series
DRY-RUN: GET sabnzbd /api?mode=del_config&output=json&section=categories&keyword=software
DRY-RUN: POST sonarr /api/v3/rootfolder {"path":"/data/media/tv"}
DRY-RUN: DELETE sonarr /api/v3/downloadclient/1
DRY-RUN: PUT sonarr /api/v3/downloadclient/2 {"enable":true,"protocol":"usenet","priority":1,"removeCompletedDownloads":true,"removeFailedDownloads":true,"name":"SABnzbd","implementationName":"SABnzbd","implementation":"Sabnzbd","configContract":"SabnzbdSettings","tags":[],"fields":[{"order":0,"name":"host","label":"Host","value":"sabnzbd","type":"textbox","advanced":false,"privacy":"normal"},{"order":1,"name":"port","label":"Port","value":8080,"type":"textbox","advanced":false,"privacy":"normal"},{"order":2,"name":"useSsl","label":"Use SSL","value":false,"type":"checkbox","advanced":false,"privacy":"normal"},{"order":3,"name":"urlBase","label":"URL Base","type":"textbox","advanced":true,"privacy":"normal"},{"order":4,"name":"apiKey","label":"API Key","type":"textbox","advanced":false,"privacy":"apiKey","value":"***"},{"order":5,"name":"username","label":"Username","type":"textbox","advanced":false,"privacy":"userName"},{"order":6,"name":"password","label":"Password","type":"password","advanced":false,"privacy":"password"},{"order":7,"name":"tvCategory","label":"Category","value":"tv","type":"textbox","advanced":false,"privacy":"normal"},{"order":8,"name":"recentTvPriority","label":"Recent Priority","value":-100,"type":"select","advanced":false,"privacy":"normal"}],"id":2}
DRY-RUN: DELETE sonarr /api/v3/indexer/1
DRY-RUN: DELETE sonarr /api/v3/remotepathmapping/1
DRY-RUN: POST sonarr-anime /api/v3/rootfolder {"path":"/data/media/anime-tv"}
DRY-RUN: DELETE sonarr-anime /api/v3/downloadclient/1
DRY-RUN: PUT sonarr-anime /api/v3/downloadclient/2 {"enable":true,"protocol":"usenet","priority":1,"removeCompletedDownloads":true,"removeFailedDownloads":true,"name":"SABnzbd","implementationName":"SABnzbd","implementation":"Sabnzbd","configContract":"SabnzbdSettings","tags":[],"fields":[{"order":0,"name":"host","label":"Host","value":"sabnzbd","type":"textbox","advanced":false,"privacy":"normal"},{"order":1,"name":"port","label":"Port","value":8080,"type":"textbox","advanced":false,"privacy":"normal"},{"order":2,"name":"useSsl","label":"Use SSL","value":false,"type":"checkbox","advanced":false,"privacy":"normal"},{"order":3,"name":"urlBase","label":"URL Base","type":"textbox","advanced":true,"privacy":"normal"},{"order":4,"name":"apiKey","label":"API Key","type":"textbox","advanced":false,"privacy":"apiKey","value":"***"},{"order":5,"name":"username","label":"Username","type":"textbox","advanced":false,"privacy":"userName"},{"order":6,"name":"password","label":"Password","type":"password","advanced":false,"privacy":"password"},{"order":7,"name":"tvCategory","label":"Category","value":"anime","type":"textbox","advanced":false,"privacy":"normal"},{"order":8,"name":"recentTvPriority","label":"Recent Priority","value":-100,"type":"select","advanced":false,"privacy":"normal"}],"id":2}
DRY-RUN: DELETE sonarr-anime /api/v3/indexer/1
DRY-RUN: POST sonarr-4k /api/v3/rootfolder {"path":"/data/media/tv-4k"}
DRY-RUN: POST sonarr-4k /api/v3/downloadclient {"enable":true,"protocol":"usenet","priority":1,"removeCompletedDownloads":true,"removeFailedDownloads":true,"name":"SABnzbd","implementationName":"SABnzbd","implementation":"Sabnzbd","configContract":"SabnzbdSettings","tags":[],"fields":[{"order":0,"name":"host","label":"Host","value":"sabnzbd","type":"textbox","advanced":false,"privacy":"normal"},{"order":1,"name":"port","label":"Port","value":8080,"type":"textbox","advanced":false,"privacy":"normal"},{"order":2,"name":"useSsl","label":"Use SSL","value":false,"type":"checkbox","advanced":false,"privacy":"normal"},{"order":3,"name":"urlBase","label":"URL Base","type":"textbox","advanced":true,"privacy":"normal"},{"order":4,"name":"apiKey","label":"API Key","type":"textbox","advanced":false,"privacy":"apiKey","value":"***"},{"order":5,"name":"username","label":"Username","type":"textbox","advanced":false,"privacy":"userName"},{"order":6,"name":"password","label":"Password","type":"password","advanced":false,"privacy":"password"},{"order":7,"name":"tvCategory","label":"Category","value":"tv-4k","type":"textbox","advanced":false,"privacy":"normal"},{"order":8,"name":"recentTvPriority","label":"Recent Priority","value":-100,"type":"select","advanced":false,"privacy":"normal"}]}
DRY-RUN: POST radarr /api/v3/rootfolder {"path":"/data/media/movies"}
DRY-RUN: POST radarr /api/v3/rootfolder {"path":"/data/media/anime-movies"}
DRY-RUN: POST radarr-4k /api/v3/rootfolder {"path":"/data/media/movies-4k"}
DRY-RUN: POST radarr-4k /api/v3/downloadclient {"enable":true,"protocol":"usenet","priority":1,"removeCompletedDownloads":true,"removeFailedDownloads":true,"name":"SABnzbd","implementationName":"SABnzbd","implementation":"Sabnzbd","configContract":"SabnzbdSettings","tags":[],"fields":[{"order":0,"name":"host","label":"Host","value":"sabnzbd","type":"textbox","advanced":false,"privacy":"normal"},{"order":1,"name":"port","label":"Port","value":8080,"type":"textbox","advanced":false,"privacy":"normal"},{"order":2,"name":"useSsl","label":"Use SSL","value":false,"type":"checkbox","advanced":false,"privacy":"normal"},{"order":3,"name":"urlBase","label":"URL Base","type":"textbox","advanced":true,"privacy":"normal"},{"order":4,"name":"apiKey","label":"API Key","type":"textbox","advanced":false,"privacy":"apiKey","value":"***"},{"order":5,"name":"username","label":"Username","type":"textbox","advanced":false,"privacy":"userName"},{"order":6,"name":"password","label":"Password","type":"password","advanced":false,"privacy":"password"},{"order":7,"name":"movieCategory","label":"Category","value":"movies-4k","type":"textbox","advanced":false,"privacy":"normal"},{"order":8,"name":"recentMoviePriority","label":"Recent Priority","value":-100,"type":"select","advanced":false,"privacy":"normal"}]}
DRY-RUN: POST lidarr /api/v1/rootfolder {"name":"Music","path":"/data/media/music","defaultQualityProfileId":1,"defaultMetadataProfileId":1}
DRY-RUN: POST lidarr /api/v1/downloadclient {"enable":true,"protocol":"usenet","priority":1,"removeCompletedDownloads":true,"removeFailedDownloads":true,"name":"SABnzbd","implementationName":"SABnzbd","implementation":"Sabnzbd","configContract":"SabnzbdSettings","tags":[],"fields":[{"order":0,"name":"host","label":"Host","value":"sabnzbd","type":"textbox","advanced":false,"privacy":"normal"},{"order":1,"name":"port","label":"Port","value":8080,"type":"textbox","advanced":false,"privacy":"normal"},{"order":2,"name":"useSsl","label":"Use SSL","value":false,"type":"checkbox","advanced":false,"privacy":"normal"},{"order":3,"name":"urlBase","label":"URL Base","type":"textbox","advanced":true,"privacy":"normal"},{"order":4,"name":"apiKey","label":"API Key","type":"textbox","advanced":false,"privacy":"apiKey","value":"***"},{"order":5,"name":"username","label":"Username","type":"textbox","advanced":false,"privacy":"userName"},{"order":6,"name":"password","label":"Password","type":"password","advanced":false,"privacy":"password"},{"order":7,"name":"musicCategory","label":"Category","value":"music","type":"textbox","advanced":false,"privacy":"normal"},{"order":8,"name":"recentMusicPriority","label":"Recent Priority","value":-100,"type":"select","advanced":false,"privacy":"normal"}]}
DRY-RUN: DELETE prowlarr /api/v1/indexer/1
DRY-RUN: DELETE prowlarr /api/v1/indexerproxy/1
DRY-RUN: DELETE prowlarr /api/v1/downloadclient/1
DRY-RUN: POST prowlarr /api/v1/downloadclient {"enable":true,"protocol":"usenet","priority":1,"name":"SABnzbd","implementationName":"SABnzbd","implementation":"Sabnzbd","configContract":"SabnzbdSettings","tags":[],"fields":[{"order":0,"name":"host","value":"sabnzbd","privacy":"normal"},{"order":1,"name":"port","value":8080,"privacy":"normal"},{"order":2,"name":"useSsl","value":false,"privacy":"normal"},{"order":3,"name":"urlBase","privacy":"normal"},{"order":4,"name":"apiKey","privacy":"apiKey","value":"***"},{"order":5,"name":"username","privacy":"userName"},{"order":6,"name":"password","privacy":"password"},{"order":7,"name":"category","value":"*","privacy":"normal"},{"order":8,"name":"priority","value":-100,"privacy":"normal"}],"removeCompletedDownloads":true,"removeFailedDownloads":true}
DRY-RUN: PUT prowlarr /api/v1/applications/2 {"syncLevel":"fullSync","name":"Sonarr","implementationName":"Sonarr","implementation":"Sonarr","configContract":"SonarrSettings","tags":[],"fields":[{"order":0,"name":"prowlarrUrl","value":"http://prowlarr:9696","privacy":"normal"},{"order":1,"name":"baseUrl","value":"http://sonarr:8989","privacy":"normal"},{"order":2,"name":"apiKey","privacy":"apiKey","value":"***"},{"order":3,"name":"syncCategories","value":[5000,5010,5020,5030,5040,5045,5050,5090],"privacy":"normal"},{"order":4,"name":"animeSyncCategories","value":[5070],"privacy":"normal"},{"order":5,"name":"syncAnimeStandardFormatSearch","value":false,"privacy":"normal"}],"id":2}
DRY-RUN: POST prowlarr /api/v1/applications {"syncLevel":"fullSync","name":"Sonarr Anime","implementationName":"Sonarr","implementation":"Sonarr","configContract":"SonarrSettings","tags":[],"fields":[{"order":0,"name":"prowlarrUrl","value":"http://prowlarr:9696","privacy":"normal"},{"order":1,"name":"baseUrl","value":"http://sonarr-anime:8989","privacy":"normal"},{"order":2,"name":"apiKey","privacy":"apiKey","value":"***"},{"order":3,"name":"syncCategories","value":[],"privacy":"normal"},{"order":4,"name":"animeSyncCategories","value":[5070],"privacy":"normal"},{"order":5,"name":"syncAnimeStandardFormatSearch","value":false,"privacy":"normal"}]}
DRY-RUN: POST prowlarr /api/v1/applications {"syncLevel":"fullSync","name":"Sonarr 4K","implementationName":"Sonarr","implementation":"Sonarr","configContract":"SonarrSettings","tags":[],"fields":[{"order":0,"name":"prowlarrUrl","value":"http://prowlarr:9696","privacy":"normal"},{"order":1,"name":"baseUrl","value":"http://sonarr-4k:8989","privacy":"normal"},{"order":2,"name":"apiKey","privacy":"apiKey","value":"***"},{"order":3,"name":"syncCategories","value":[5000,5010,5020,5030,5040,5045,5050,5090],"privacy":"normal"},{"order":4,"name":"animeSyncCategories","value":[5070],"privacy":"normal"},{"order":5,"name":"syncAnimeStandardFormatSearch","value":false,"privacy":"normal"}]}
DRY-RUN: POST prowlarr /api/v1/applications {"syncLevel":"fullSync","name":"Radarr","implementationName":"Radarr","implementation":"Radarr","configContract":"RadarrSettings","tags":[],"fields":[{"order":0,"name":"prowlarrUrl","value":"http://prowlarr:9696","privacy":"normal"},{"order":1,"name":"baseUrl","value":"http://radarr:7878","privacy":"normal"},{"order":2,"name":"apiKey","privacy":"apiKey","value":"***"},{"order":3,"name":"syncCategories","value":[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090],"privacy":"normal"}]}
DRY-RUN: POST prowlarr /api/v1/applications {"syncLevel":"fullSync","name":"Radarr 4K","implementationName":"Radarr","implementation":"Radarr","configContract":"RadarrSettings","tags":[],"fields":[{"order":0,"name":"prowlarrUrl","value":"http://prowlarr:9696","privacy":"normal"},{"order":1,"name":"baseUrl","value":"http://radarr-4k:7878","privacy":"normal"},{"order":2,"name":"apiKey","privacy":"apiKey","value":"***"},{"order":3,"name":"syncCategories","value":[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090],"privacy":"normal"}]}
DRY-RUN: POST prowlarr /api/v1/applications {"syncLevel":"fullSync","name":"Lidarr","implementationName":"Lidarr","implementation":"Lidarr","configContract":"LidarrSettings","tags":[],"fields":[{"order":0,"name":"prowlarrUrl","value":"http://prowlarr:9696","privacy":"normal"},{"order":1,"name":"baseUrl","value":"http://lidarr:8686","privacy":"normal"},{"order":2,"name":"apiKey","privacy":"apiKey","value":"***"},{"order":3,"name":"syncCategories","value":[3000,3010,3030,3040,3050,3060],"privacy":"normal"}]}
[INFO] prowlarr: removing app animesonarr
DRY-RUN: DELETE prowlarr /api/v1/applications/1
DRY-RUN: POST prowlarr /api/v1/command {"name":"ApplicationIndexerSync","forceSync":true}
DRY-RUN: GET sabnzbd /api?mode=resume&output=json
[INFO] 42 changes (dry-run; pass --apply to make them)
```

Check that:
- every *arr gets its root folders and exactly one `SABnzbd` client with
  `host` `sabnzbd`, port `8080` and its own category (`tv`, `anime`,
  `tv-4k`, `movies`, `movies-4k`, `music`);
- Prowlarr's `SABnzbd` client has `category` `*` (`"value":"*"`), SABnzbd's
  default category. Prowlarr's default, `prowlarr`, is not a SABnzbd
  category, and an empty category is rejected, so saving would fail on
  either;
- every non-SABnzbd client (qBittorrent, NZBGet) and every torrent
  indexer is deleted;
- Prowlarr gets the six apps with `"syncLevel":"fullSync"`, and the old
  `animesonarr` app is removed;
- the run ends with `ApplicationIndexerSync` and `mode=resume`.

API keys show as `***`. Apply it, then apply again:

```bash
scripts/vm/25-arr-wire.sh --apply
scripts/vm/25-arr-wire.sh --apply
```

The second `--apply` must make no change and print `[INFO] no changes`,
like the dry-run on already-wired apps:

Example (from the CI fixtures, a dry-run on wired apps):
```
[INFO] no changes
```

## 5. Split out 4K titles

The old libraries mix 4K files into `movies` and `tv`. This step moves
every title whose files are **all** 4K into `movies-4k`/`tv-4k`, adds it to
Radarr 4K/Sonarr 4K, and unmonitors it in the HD instance with the tag
`4k-only`. That way the HD instance won't download it again, but an
explicit HD request can still add an HD copy. Series with both 4K and
non-4K episodes are never moved; you decide on each one.

1. **Confirm the 4K quality profile names.** Open Radarr 4K
   (`http://192.168.50.16:7879`) and Sonarr 4K
   (`http://192.168.50.16:8991`), Settings → Profiles. The script uses
   `Ultra-HD` in both. If you want another profile, add
   `QP_4K_RADARR=<name>` and/or `QP_4K_SONARR=<name>` to `.env`. A name
   that doesn't exist stops the script and lists the real ones:

   Example (from the CI fixtures, with `QP_4K_RADARR=Nope`):
   ```
   [ERROR] radarr-4k: quality profile 'Nope' not found; available: Any, Ultra-HD, HD-1080p (set QP_4K_RADARR)
   ```

2. **Take the dataset rollback point.** **On the Proxmox host:**
   ```bash
   zfs snapshot tank/data@pre-4k-split
   zfs list -t snapshot tank/data
   ```
   `tank/data@pre-4k-split` must be in the list.

3. **Plan and review.** Inside the VM:
   ```bash
   scripts/vm/30-split-4k.sh
   ```

   Example (from the CI fixtures):
   ```
   [INFO] plan: 3 move, 1 skip-mixed, 1 check, anime-4k=1 -> <tmp>/api-appdata/.migration/split-4k-20260928-164859.tsv
   [INFO] check: movie radarr 15 Scope Movie
   [INFO] skip-mixed: series sonarr 2 Mixed Show
   DRY-RUN: mv -T -- '<tmp>/vmdata/media/movies/Big 4K Movie (2019)' '<tmp>/vmdata/media/movies-4k/Big 4K Movie (2019)'
   [INFO] then: add movie 'Big 4K Movie' to radarr-4k (Ultra-HD, /data/media/movies-4k/Big 4K Movie (2019)), unmonitor and tag 4k-only in radarr
   DRY-RUN: mv -T -- '<tmp>/vmdata/media/movies/Unmonitored 4K Movie (2017)' '<tmp>/vmdata/media/movies-4k/Unmonitored 4K Movie (2017)'
   [INFO] then: add movie 'Unmonitored 4K Movie' to radarr-4k (Ultra-HD, /data/media/movies-4k/Unmonitored 4K Movie (2017)), unmonitor and tag 4k-only in radarr
   DRY-RUN: mv -T -- '<tmp>/vmdata/media/tv/UHD Show' '<tmp>/vmdata/media/tv-4k/UHD Show'
   [INFO] then: add series 'UHD Show' to sonarr-4k (Ultra-HD, /data/media/tv-4k/UHD Show), unmonitor and tag 4k-only in sonarr
   [INFO] 3 titles to move (dry-run; review <tmp>/api-appdata/.migration/split-4k-20260928-164859.tsv, then pass --apply)
   ```

   The dry-run writes the plan to
   `/opt/appdata/.migration/split-4k-<ts>.tsv` and already checks every
   move (the target must not exist, the source must exist under
   `/data/media/movies/` or `/data/media/tv/`). Read the whole plan (one
   title per line, tab-separated):
   ```bash
   cat /opt/appdata/.migration/split-4k-<ts>.tsv
   ```

   Example (from the CI fixtures, the plan file):
   ```
   kind	instance	id	title	src	dst	files	action
   movie	radarr	11	Big 4K Movie	/data/media/movies/Big 4K Movie (2019)	/data/media/movies-4k/Big 4K Movie (2019)	1	move
   movie	radarr	13	Unmonitored 4K Movie	/data/media/movies/Unmonitored 4K Movie (2017)	/data/media/movies-4k/Unmonitored 4K Movie (2017)	1	move
   movie	radarr	15	Scope Movie	/data/media/movies/Scope Movie (2015)	/data/media/movies-4k/Scope Movie (2015)	1	check
   series	sonarr	1	UHD Show	/data/media/tv/UHD Show	/data/media/tv-4k/UHD Show	2	move
   series	sonarr	2	Mixed Show	/data/media/tv/Mixed Show	/data/media/tv-4k/Mixed Show	2	skip-mixed
   ```

   The `action` column:
   - `move`: every file is 4K. The script moves it.
   - `skip-mixed`: a series with some 4K episode files. Never moved.
   - `check`: the file's quality and its measured resolution disagree
     (for example a 1080p-labelled file that is really 3840x1600). Listed
     only, never moved.

   `anime-4k=<n>` counts anime titles (Sonarr Anime, and Radarr's
   `anime-movies`) that have 4K files. Anime is never split.

4. **Resolve each `skip-mixed` and `check` title**, before or after the
   `--apply`, and record every choice in the Acceptance record:
   - **Move it to 4K by hand:** `mv "/data/media/tv/<Title>" "/data/media/tv-4k/<Title>"`
     (or `movies` → `movies-4k`). Then add it in Sonarr 4K/Radarr 4K with
     Library Import (Series/Movies → Library Import, root `/data/media/tv-4k`
     or `/data/media/movies-4k`, your 4K profile, no search). Finally, in
     the HD instance, edit the title: unmonitor it and add the tag
     `4k-only`.
   - **Keep it in HD:** nothing to do for a `skip-mixed` series:
     `4k-split` exempts it while the newest plan lists it (reported as
     `mixed=<n>`). A `check` title kept in HD is not exempt: if it stays
     monitored and has a file that counts as 4K, `4k-split` fails. Either
     unmonitor it in the HD instance, or move it.
   - **anime-4k:** the default is to leave anime 4K files where they are,
     in the anime libraries. Record your choice.

5. **Apply:**
   ```bash
   scripts/vm/30-split-4k.sh --apply
   ```

   For each row it moves the folder, adds the title to the 4K instance
   and rescans it there, then unmonitors and tags it in HD (the `PUT`
   line) and rescans it in HD, so HD drops the moved files right away.
   Each rescan must finish within `WAIT_TIMEOUT` seconds (default 600;
   `WAIT_TIMEOUT=1800 scripts/vm/30-split-4k.sh --apply` for a large
   series).

   Example (from the CI fixtures, `--apply` against the stub apps and a
   temp tree):
   ```
   [INFO] plan: 3 move, 1 skip-mixed, 1 check, anime-4k=1 -> <tmp>/api-appdata/.migration/split-4k-20260928-191538.tsv
   [INFO] check: movie radarr 15 Scope Movie
   [INFO] skip-mixed: series sonarr 2 Mixed Show
   [INFO] POST radarr-4k /api/v3/command {"name":"RescanMovie"}; waiting
   [INFO] PUT radarr /api/v3/movie/11
   [INFO] POST radarr /api/v3/command {"name":"RescanMovie"}; waiting
   [INFO] moved 1/3: movie 'Big 4K Movie' -> radarr-4k id 31
   [INFO] POST radarr-4k /api/v3/command {"name":"RescanMovie"}; waiting
   [INFO] PUT radarr /api/v3/movie/13
   [INFO] POST radarr /api/v3/command {"name":"RescanMovie"}; waiting
   [INFO] moved 2/3: movie 'Unmonitored 4K Movie' -> radarr-4k id 32
   [INFO] POST sonarr-4k /api/v3/command {"name":"RescanSeries"}; waiting
   [INFO] PUT sonarr /api/v3/series/1
   [INFO] POST sonarr /api/v3/command {"name":"RescanSeries"}; waiting
   [INFO] moved 3/3: series 'UHD Show' -> sonarr-4k id 41
   [INFO] split: 3 titles moved; manifest <tmp>/api-appdata/.migration/split-4k-20260928-191538.manifest.tsv (undo: scripts/vm/30-split-4k.sh --undo <tmp>/api-appdata/.migration/split-4k-20260928-191538.manifest.tsv --apply)
   ```

   Keep the manifest path from the last line: `--undo` uses it. The
   manifest is the plan's rows plus two columns: `new_id` (the title's id
   in the 4K instance) and `prior` (its monitored state in HD before the
   split, seasons included, plus any episodes you had unmonitored).
   `--undo` restores exactly that state.

   If a row fails halfway, the script stops with
   `[ERROR] row <n> partially applied; run --undo <manifest>`; see
   Rollback. If a rescan times out, the message says `re-running is
   safe; raise WAIT_TIMEOUT (seconds) for large libraries`. For the split,
   the row is then partially applied: run the `--undo` first, with the
   same larger timeout (its rescans can take as long), then the split
   again:
   `WAIT_TIMEOUT=1800 scripts/vm/30-split-4k.sh --undo <manifest> --apply`.
   If an undo stops partway (`undo stopped at row <n>; re-run the same
   --undo command to continue`), re-run the same command: rows already
   moved back are finished without moving them again. If the preflight says
   `<dst> is missing` for a row, its 4K folder is gone and the HD folder is
   missing or empty: nothing was changed. Find the title's files (or use
   the `zfs rollback` in Rollback) before running the undo again.

## 6. Plex

Open Plex at `http://192.168.50.16:32400/web` and sign in as the owner.
Do the steps in this order; the trash rule comes first because emptying
the trash is what would lose watch state.

1. **Settings → Library:** "Empty trash automatically after every scan"
   must be **off**. The restore already set it (`autoEmptyTrash="0"`); if
   the restore warned that `Preferences.xml` was missing, set it now,
   before any scan.
2. **Settings → Network** (show advanced):
   - "LAN Networks" (`LanNetworksBandwidth`): `192.168.50.0/24`
   - "Custom server access URLs" (`customConnections`):
     `http://192.168.50.16:32400`

   Save.
3. **Point each old library at the new folder.** For each row: Manage
   Library → Edit → Add folders → add the new folder → Save. Then "Scan
   Library Files" and wait until the scan finishes. Only then edit again
   and **remove the old folder**. The items under the old folder go to
   the trash and keep their watch state there until you empty it.

   | Library | Old folder | New folder(s) |
   |---|---|---|
   | Movies | `/data/movies` | `/data/media/movies` and `/data/media/anime-movies` |
   | TV Shows | `/data/shows` | `/data/media/tv` |
   | Anime TV | `/data/anime` | `/data/media/anime-tv` |
   | Music | `/data/music` | `/data/media/music` |

4. **Create the 4K libraries:** Add Library → Movies, name `Movies 4K`,
   folder `/data/media/movies-4k`; Add Library → TV Shows, name `TV 4K`,
   folder `/data/media/tv-4k`. Share both with every family member
   (Settings → Users & Sharing → each user → Libraries). Everyone may watch
   4K-only titles; a device that can't play 4K gets a transcode.
5. **Settings → Transcoder** (show advanced): turn on "Use hardware
   acceleration when available", "Use hardware-accelerated video
   encoding" and "Enable HDR tone mapping". Save.
6. **Gate before emptying the trash.** Run:
   ```bash
   scripts/vm/verify-media.sh
   ```
   `plex-sections`, `plex-watched` and `plex-counts` must PASS. At this
   point two other results are expected and don't block this gate:
   - `plex-hw` SKIPs: nothing is transcoding yet.
   - `seerr-servers` FAILs: Seerr is set up in step 7. So the `RESULT`
     line shows `1 fail` here.

   On `media-01`, `image-versions` reads
   `OK: 11 images at or above minimum` (the CI fixtures run fewer
   images).

   Example (from the CI fixtures, with no transcode session; only the
   lines this gate checks):
   ```
   PASS plex-sections 6 sections at /data/media/*; autoEmptyTrash=0
   PASS plex-watched watched movies+episodes=5 >= baseline 5
   PASS plex-counts Movies plex=2 radarr=2 (+0); TV Shows plex=3 sonarr=3 (+0); Anime TV plex=1 sonarr-anime=1 (+0); Movies 4K plex=1 radarr-4k=1 (+0); TV 4K plex=1 sonarr-4k=1 (+0)
   SKIP plex-hw no transcode session; play a title with a forced transcode (lower the quality in the player) and re-run
   ```

   If `plex-watched` or `plex-counts` FAILs, **do not empty the trash**;
   see Troubleshooting.
7. Only after both PASS: for each library, Manage Library → Empty Trash.

## 7. Seerr and Tautulli

Open Seerr at `http://192.168.50.16:5055` and sign in as the owner. Use
the service **host names** below everywhere, never IP addresses: container
IPs change on every restart.

1. **Settings → Plex:** server `plex`, port `32400`, SSL off. Save, then
   "Sync Libraries" and enable **Movies, TV Shows, Anime TV, Movies 4K and
   TV 4K** (Music stays off). Save.
2. **Settings → Services.** Take each API key from the app's own UI
   (Settings → General → API Key). Edit the restored servers to match this
   table, and add the missing ones:

   | Name | Type | Host | Port | 4K server | Default server | Root folder | Profile |
   |---|---|---|---|---|---|---|---|
   | Radarr | Radarr | `radarr` | 7878 | off | on | `/data/media/movies` | your HD profile |
   | Radarr 4K | Radarr | `radarr-4k` | 7878 | on | on | `/data/media/movies-4k` | your 4K profile |
   | Sonarr | Sonarr | `sonarr` | 8989 | off | on | `/data/media/tv` | your HD profile |
   | Sonarr 4K | Sonarr | `sonarr-4k` | 8989 | on | on | `/data/media/tv-4k` | your 4K profile |
   | Sonarr Anime | Sonarr | `sonarr-anime` | 8989 | off | **off** | `/data/media/anime-tv` | your anime profile |

   Delete any other server (for example an old `animesonarr` or one that
   uses an IP).
3. **Settings → Users → Default Permissions:** on: Request, Request 4K
   (Movies and Series), Auto-Approve Movies. Off: Auto-Approve Series and
   every Auto-Approve 4K option. Save.
4. **Users:** default permissions apply only to *new* users, so edit each
   existing family user and set the same permissions.
5. **Create the test user:** Users → Create Local User, name `e2e-test`,
   with your own e-mail (a `+e2e` alias works), **not** an admin, default
   permissions. Turn on Settings → Users → "Enable Local Sign-In" if it is
   off. Admin requests are auto-approved, which is why the tests in step 10
   use this user.

**How anime requests reach Sonarr Anime.** Seerr can't pick a server by
genre; its override rules only set the profile, root folder and tags. So
every TV request waits for your approval (Auto-Approve Series is off).
For an **anime** request: Requests → open it → edit (pencil) → Server
`Sonarr Anime`, root `/data/media/anime-tv`, your anime profile → Save →
Approve. Approve other TV requests as they are.

**Tautulli** (`http://192.168.50.16:8181`): Settings → Plex Media Server →
address `plex`, port `32400`, SSL off → Verify Server → Save.

Run `scripts/vm/verify-media.sh` again: `seerr-servers` now PASSes.

## 8. Jellyfin (optional)

Jellyfin is an evaluation only, off by default. To try it:

```bash
docker compose --profile jellyfin up -d jellyfin
```

Open `http://192.168.50.16:8096` and finish the wizard. Add libraries on
the same folders as Plex (`/data/media/movies`, `/data/media/tv`, ...).
They are mounted **read-only**, so leave "Save artwork into media folders"
and NFO saving off. Under Dashboard → Playback → Transcoding, choose Intel
QuickSync (QSV) with the device `/dev/dri/renderD128`.
`scripts/vm/verify-media.sh` then runs its `jellyfin` check (health and
`/dev/dri`), which SKIPs whenever Jellyfin isn't running. Stop it when
you're done:

```bash
docker compose --profile jellyfin stop jellyfin
```

## 9. Remote admin access

The admin UIs are published only on `192.168.50.16` (by
`compose.lan.yaml`). Reach them from outside the LAN through Twingate: in
the Twingate admin console, add a Resource on the Remote Network served by
the connector (LXC 101 on the Proxmox host):

- Address: `192.168.50.16`
- Ports: TCP `5055, 7878, 7879, 8080, 8181, 8686, 8989, 8990, 8991, 9696`
  (add `8096` if you evaluate Jellyfin)
- Access: your admin group only

| Port | App |
|---|---|
| 5055 | Seerr |
| 7878 / 7879 | Radarr / Radarr 4K |
| 8080 | SABnzbd |
| 8181 | Tautulli |
| 8686 | Lidarr |
| 8989 / 8990 / 8991 | Sonarr / Sonarr Anime / Sonarr 4K |
| 9696 | Prowlarr |
| 8096 | Jellyfin (optional) |

Test it from a phone off Wi-Fi with Twingate connected:
`http://192.168.50.16:5055`. These ports are temporary: Phase 3 removes
`compose.lan.yaml` and the `COMPOSE_FILE` line, and the UIs move behind
Traefik and Authentik. Plex's `32400` stays published.

## 10. Test requests and verify

Three requests, each made in Seerr **as `e2e-test`**, prove the whole loop:
request → the right instance, root folder and SAB category → an atomic
import → Plex. Before you make (HD) or approve (4K, anime) each request,
start the import watcher **in a second terminal** on the VM. It records
the inode of every new file in that category's
`/data/usenet/complete/<cat>`, and PASSes when the instance imports one of
them without copying it:

| Request | Watcher (second terminal) | Then |
|---|---|---|
| An HD movie not in the library | `scripts/vm/verify-media.sh --watch-import radarr` | request it as `e2e-test`; it is auto-approved |
| A 4K movie not in the library | `scripts/vm/verify-media.sh --watch-import radarr-4k` | request it in 4K as `e2e-test`, then approve it as the owner |
| An anime series (one short season is enough) | `scripts/vm/verify-media.sh --watch-import sonarr-anime` | request it as `e2e-test`, switch it to Sonarr Anime (step 7), then approve it |

Example (from the CI fixtures, an import into `tv`):
```
[INFO] watching <tmp>/vmdata/usenet/complete/tv for a sonarr import (timeout 30s); make or approve the request now
PASS import sonarr inode=1992018
```

The watcher gives up after 30 minutes
(`WATCH_TIMEOUT=3600 scripts/vm/verify-media.sh --watch-import ...` waits
longer):

Example (from the CI fixtures, with `WATCH_TIMEOUT=2`):
```
[INFO] watching <tmp>/vmdata/usenet/complete/movies for a radarr import (timeout 2s); make or approve the request now
FAIL import radarr no import within 2s
```

Copy each `PASS import ...` line into the Acceptance record. For each
request, also check in the app that it landed in the right instance and
root folder (`/data/media/movies`, `/data/media/movies-4k`,
`/data/media/anime-tv`), and in SABnzbd's history that the job used the
matching category (`movies`, `movies-4k`, `anime`).

Before the final run, **scan the libraries that received a test download**
in Plex (a library's `...` menu, then Scan Library Files; Movies 4K after
the 4K request, Anime TV after the anime one). Plex doesn't notice new
files on its own here, and `plex-counts` fails while Plex has fewer items
than the *arr app (for example `Movies 4K plex=64 radarr-4k=65 (-1)`).

Finally, **force a transcode**: in Plex Web, play any title and set
Quality to 720p (2 Mbps). While it plays, run:

```bash
scripts/vm/verify-media.sh
```

Example (from the CI fixtures):
```
PASS compose-healthy 11 services running (healthy)
PASS image-versions OK: 8 images at or above minimum
PASS arr-rootfolders 6 instances match the wiring table; 0 items under old roots
PASS library-adopted sonarr 19+6>=25; sonarr-anime 12+0>=12; radarr 2+1>=3 (current+moved vs baseline)
PASS no-regrab 0 re-grabs of baseline or split items since 2026-09-28T00:00:00Z; other=0
PASS sab-categories 7 categories, dirs = names, /data/usenet/{incomplete,complete}
PASS download-clients 6 *arr + prowlarr: one SABnzbd client each (sabnzbd:8080, own category); 0 torrent indexers
PASS prowlarr-sync 6 apps fullSync; 1 usenet indexers, 0 torrent, 0 proxies; each *arr has synced (Prowlarr) indexers
PASS 4k-split no monitored HD item has a >=2160p file; mixed=1 (split-4k-20260928-120000.tsv)
PASS plex-sections 6 sections at /data/media/*; autoEmptyTrash=0
PASS plex-watched watched movies+episodes=5 >= baseline 5
PASS plex-counts Movies plex=2 radarr=2 (+0); TV Shows plex=3 sonarr=3 (+0); Anime TV plex=1 sonarr-anime=1 (+0); Movies 4K plex=1 radarr-4k=1 (+0); TV 4K plex=1 sonarr-4k=1 (+0)
PASS plex-hw transcodeHwRequested with decode=vaapi encode=vaapi
PASS seerr-servers Radarr, Radarr 4K, Sonarr, Sonarr 4K, Sonarr Anime by hostname; plex:32400 with 5 libraries
SKIP jellyfin not running (optional: docker compose --profile jellyfin up -d jellyfin)
RESULT: 14 pass, 0 fail, 1 skip
```

On `media-01`, `image-versions` reads `OK: 11 images at or above
minimum`; the fixtures run fewer images.

The phase is accepted when the `RESULT` line shows `0 fail`, with
`plex-hw`, `plex-watched` and `plex-counts` PASS (`jellyfin` may SKIP),
and you have three `PASS import` lines. Paste them below.

## Acceptance record

Fill this in from your real run on `media-01`. Nothing here comes from CI.

| Item | Value |
|------|-------|
| Date | |
| VM snapshot | |
| ZFS snapshot | |
| Restore stage `<ts>` | |
| Split manifest | |
| `skip-mixed` / `check` decisions (title: moved to 4K / kept in HD) | |
| `anime-4k` decision | |

`scripts/vm/verify-media.sh` (the full output, ending with the `RESULT`
line):

<!-- owner: paste real output -->
```
```

`--watch-import` lines (HD movie, 4K movie, anime series):

<!-- owner: paste real output -->
```
```

## Rollback

Use the smallest rollback that covers the problem. From the smallest:

| Undo | Run | What it undoes | Prefer it when |
|---|---|---|---|
| The 4K split | `scripts/vm/30-split-4k.sh --undo /opt/appdata/.migration/split-4k-<ts>.manifest.tsv`, then again with `--apply` | In reverse order: moves each title back, deletes it from the 4K instance (`deleteFiles=false`, the files stay), restores its HD monitored state from the manifest's `prior` column (seasons and unmonitored episodes included), removes the `4k-only` tag, rescans it; renames the manifest to `.undone` | A split row failed halfway, or you want the 4K titles back in HD. Your manual moves for mixed titles are not included |
| The file tree since step 5 | **On the Proxmox host:** `qm shutdown 200 && zfs rollback tank/data@pre-4k-split && qm start 200` | Every file change on `tank/data` since the snapshot, including new downloads and imports | `--undo` can't run (for example its preflight fails because files were changed by hand). The apps' databases still describe the split afterwards, so combine it with `--undo` fixes by hand or with the VM rollback below |
| The config restore | `sudo scripts/vm/10-restore-appdata.sh --rollback <ts>`, then again with `--apply` (services stopped) | Every service dir the restore installed (listed in `.rollback/<ts>/installed`) moves to `.rollback/<ts>-undone/<svc>`; then each pre-restore dir saved in `.rollback/<ts>` moves back into `/opt/appdata`. A service with no saved dir (a first restore) is simply absent afterwards. The old SAB queue goes back into the undone config, `.rollback/<ts>-undone/sabnzbd/admin`, never into a live dir | The restored configs are wrong and you want to push them again (the host archive stays the source of truth), or a restore failed after the swap (Troubleshooting) |
| The whole phase on the VM | **On the Proxmox host:** `qm rollback 200 pre-phase2 && qm start 200`. If the split ran: `qm rollback 200 pre-phase2 && zfs rollback tank/data@pre-4k-split && qm start 200` | The VM disk: appdata (every app database change from steps 2–10), `.env` and the containers. `/data` is not on the VM disk, hence the `zfs rollback` after a split, run while the VM is still stopped | Anything else, including the remap and the wiring, which have no script undo |

After the VM rollback, check the VM is back at the end of runbook 02.
**Inside the VM:**

```bash
cd /opt/home-media-server
scripts/vm/verify.sh
```

It must print `RESULT: 10 pass, 0 fail, 0 skip`, as at the start of
this runbook.

`--undo` is a dry-run without `--apply`. An older manifest, written
before the `prior` column existed, prints a warning and re-monitors every
HD item and season instead:

Example (from the CI fixtures):
```
[INFO] undo 1/3: series sonarr 1 UHD Show
DRY-RUN: mv -T -- '<tmp>/vmdata/media/tv-4k/UHD Show' '<tmp>/vmdata/media/tv/UHD Show'
DRY-RUN: DELETE sonarr-4k /api/v3/series/41?deleteFiles=false
DRY-RUN: PUT sonarr /api/v3/series/1 {"id":1,"title":"UHD Show","tvdbId":2001,"path":"/data/media/tv/UHD Show","monitored":true,"tags":[],"qualityProfileId":1,"seasonFolder":true,"seriesType":"standard","seasons":[{"seasonNumber":0,"monitored":false},{"seasonNumber":1,"monitored":true},{"seasonNumber":2,"monitored":true}],"statistics":{"episodeFileCount":2}}
DRY-RUN: PUT sonarr /api/v3/episode/monitor {"episodeIds":[1002],"monitored":false}
DRY-RUN: POST sonarr /api/v3/command {"name":"RescanSeries","seriesId":1}
[INFO] undo 2/3: movie radarr 13 Unmonitored 4K Movie
DRY-RUN: mv -T -- '<tmp>/vmdata/media/movies-4k/Unmonitored 4K Movie (2017)' '<tmp>/vmdata/media/movies/Unmonitored 4K Movie (2017)'
DRY-RUN: DELETE radarr-4k /api/v3/movie/32?deleteFiles=false
DRY-RUN: PUT radarr /api/v3/movie/13 {"id":13,"title":"Unmonitored 4K Movie","year":2017,"tmdbId":1013,"path":"/data/media/movies/Unmonitored 4K Movie (2017)","hasFile":true,"monitored":false,"tags":[],"qualityProfileId":1}
DRY-RUN: POST radarr /api/v3/command {"name":"RescanMovie","movieId":13}
[INFO] undo 3/3: movie radarr 11 Big 4K Movie
DRY-RUN: mv -T -- '<tmp>/vmdata/media/movies-4k/Big 4K Movie (2019)' '<tmp>/vmdata/media/movies/Big 4K Movie (2019)'
DRY-RUN: DELETE radarr-4k /api/v3/movie/31?deleteFiles=false
DRY-RUN: PUT radarr /api/v3/movie/11 {"id":11,"title":"Big 4K Movie","year":2019,"tmdbId":1011,"path":"/data/media/movies/Big 4K Movie (2019)","hasFile":true,"monitored":true,"tags":[],"qualityProfileId":1}
DRY-RUN: POST radarr /api/v3/command {"name":"RescanMovie","movieId":11}
DRY-RUN: mv -T -- <tmp>/api-appdata/.migration/split-4k-20260928-191538.manifest.tsv <tmp>/api-appdata/.migration/split-4k-20260928-191538.manifest.tsv.undone
[INFO] undo of 3 rows (dry-run; pass --apply to make it)
```

`zfs rollback` only goes back to the newest snapshot; if you took a later
one, it refuses (`-r` would destroy the later snapshots, so read what it
names first). The restore's `--rollback` and `--undo` both refuse while
their preconditions fail, and change nothing then.

## Troubleshooting

**"UrlBase": `[WARN] <svc> UrlBase=... Port=...` from the restore.** The
scripts and health checks expect an empty URL base and the default port
(Sonarr 8989, Radarr 7878, Lidarr 8686, Prowlarr 9696). Start the app,
open its UI (Settings → General), clear "URL Base", set the default port,
save and `docker compose restart <svc>`. If the UI isn't reachable
because the port is wrong, edit the file with the app stopped:
`docker compose stop <svc>`, then
`sudo sed -i 's#<UrlBase>.*</UrlBase>#<UrlBase></UrlBase>#; s#<Port>.*</Port>#<Port><default></Port>#' /opt/appdata/<svc>/config.xml`,
then `docker compose up -d <svc>`.

**Missing 4K profile** (`quality profile '...' not found; available:
...`). Create the profile in Radarr 4K/Sonarr 4K, or set
`QP_4K_RADARR`/`QP_4K_SONARR` in `.env` to one of the listed names, and
run the dry-run again.

**Mixed series** (`skip-mixed`). They are never moved. Either move one by
hand into the 4K instance or keep it in HD (step 5, item 4). `4k-split`
exempts it only while the newest `split-4k-*.tsv` lists it, so don't
delete that file.

**A container can't resolve names** (radarr-4k logs `Resource temporarily
unavailable (api.radarr.video:443)`, `curl` says `Resolving timed out`, the
Sonarr/Radarr lookups return HTTP 500). Docker's built-in DNS forwards to
the VM's `/etc/resolv.conf` list, and a slow or dead first entry (for
example a LAN DNS server) times out. Every service gets explicit DNS
servers from `stacks/_common.yaml` (default `1.1.1.1`, `8.8.8.8`; set
`DNS_PRIMARY` and `DNS_SECONDARY` in `.env` to change them). After a
`git pull`, run `docker compose up -d` (it recreates the services whose
config changed) and check:
`docker compose exec radarr-4k curl -sSI -m 10 https://api.radarr.video | head -1`
must print an HTTP status line.

**`remap` refuses: `stop sabnzbd and prowlarr first`.** They must not run
while paths are remapped:

Example (from the CI fixtures):
```
[ERROR] stop sabnzbd and prowlarr first: docker compose stop sabnzbd prowlarr
```

Run `docker compose stop sabnzbd prowlarr` and the remap again.

**Remap: folder missing** (`folder missing on the new pool; nothing
changed: <paths>`). An *arr app lists a title that has files but whose
folder isn't under its new root on the pool. Its rescan would drop the
title's files while it stays monitored, so the remap stops before any
change. For each path listed:
- If the folder is there under a slightly different name, rename it on
  the pool to the name shown.
- If it is missing, restore it from the originals on the Proxmox host.

Then run the remap dry-run again; it must not list any missing folder.

**Remap or split: `command <id> still queued in <svc>; re-running is
safe; raise WAIT_TIMEOUT`.** The app's rescan took longer than
`WAIT_TIMEOUT` seconds (default 600). For the remap, re-run it with a
larger value, for example
`WAIT_TIMEOUT=1800 scripts/vm/20-arr-remap.sh --apply`. For the split,
the row is partially applied: run the `--undo` it names with the same
larger `WAIT_TIMEOUT`, then the split again (step 5, item 5). An undo that
stops partway is continued by re-running the same `--undo` command.

**Restore failed after the swap** (`restore <ts> failed after the swap
started (exit <n>); steps not completed: <steps>`). The stage is already
(partly) empty, so a re-run can't resume it. The `[ERROR]` lines that
follow name the two ways back: `recover: sudo
scripts/vm/10-restore-appdata.sh --rollback <ts> --apply`, or, on the
host, `qm rollback 200 pre-phase2`.

Prefer the `--rollback` (Rollback, "The config restore"); run its
dry-run first. Use `qm rollback 200 pre-phase2 && qm start 200` if the
`--rollback` refuses. Then push again from the host (step 2) and restore
the new stage.

**`plex-watched` or `plex-counts` FAILs.** **Do not empty the trash**: the
items that lost their match are still there, with their watch state. The
detail shows the counts per section. Usually a scan hasn't finished, or
the old folder was removed before the scan completed: re-add the old
folder to that library, scan, and follow step 6.3 again. If watched
titles are still missing, roll back the whole phase (Rollback, "The
whole phase on the VM", including the `zfs rollback` if the split ran)
and start again from step 2. A small surplus in Plex is fine
(`+n`, for example extras or files the *arr apps don't manage).

**`plex-hw` SKIP** (`no transcode session`). Nothing was transcoding when
it ran. Play a title with Quality set to 720p (2 Mbps) and re-run while it
plays. **`plex-hw` FAIL** (`none hardware`): check Settings → Transcoder →
"Use hardware acceleration when available" and that `/dev/dri` exists in
the container (`docker compose exec plex ls -l /dev/dri`); `verify.sh`'s
`gpu` check covers the VM side.

**`--watch-import` timeout** (`FAIL import <svc> no import within ...`).
Check, in order: SABnzbd's queue isn't paused (step 4 resumes it) and the
job has the right category; the instance's Activity → Queue shows no
import error; the download simply takes longer (raise `WATCH_TIMEOUT`).
**`... is not among the completed downloads (copied, not moved?)`**: the
import copied the file instead of moving it. Check that the instance has
no remote path mapping, and that `/data/usenet` and `/data/media` are on
one filesystem (`verify.sh`'s `hardlink` check).

**Seerr settings 404** (`seerr-servers ... HTTP 404 (Seerr settings API
path not found ...)`). This Seerr version serves its settings under a
different API path than the check expects. Check the five servers and the
Plex libraries by hand in the Seerr UI, and report it so the check gets
fixed: acceptance needs `0 fail`.

**`no-regrab` FAIL** (`re-grabbed: <svc> episodeId=... <release>`). An
instance grabbed an episode or movie that already had a file at the
baseline, or one the split moved into a 4K instance. A REPACK or PROPER
of such an item is an upgrade, not a re-grab (Sonarr and Radarr replace a
file with a revised release by design); those are counted as
`upgrades=<n>` and don't fail. Any other grab usually means the
item's file looked missing (a wrong path). In that instance, Activity →
Queue: remove the grab; in SABnzbd, delete the job. Then open the item,
check that its Path is under `/data/media/...` and the file exists, and
rescan it.
