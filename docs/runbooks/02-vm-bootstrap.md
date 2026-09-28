# Runbook 02 — VM bootstrap and verification

This runbook installs Debian 13 in the VM created by
`docs/runbooks/01-proxmox-host.md`, installs Docker and the Intel VA-API
driver, mounts `/data`, builds the media directory tree, and runs the
acceptance check. Run every command **inside the VM** unless noted.

## Prerequisites

- `docs/runbooks/01-proxmox-host.md` is complete: the VM exists, the A380 is
  passed through, and the virtiofs share is attached.
- The VM is started and you have console access (Proxmox noVNC console, or
  SSH once the installer has configured networking).

## 1. Install Debian 13

Boot the VM from the netinst ISO and install with these choices:

- Software selection: **standard system utilities** and **SSH server**
  only. Do not install a desktop environment — this is a headless server.
- Create a regular user named `media` during setup (not just a root
  password). This user becomes `MEDIA_USER` in the bootstrap step below and
  should end up as uid/gid 1000 to match `.env`'s default `PUID`/`PGID`.

After the install finishes and you've logged in as `media`, confirm the
uid/gid:

```bash
id media
```

Expected output:
```
uid=1000(media) gid=1000(media) groups=1000(media)
```

If the uid or gid is **not** 1000 (e.g. if `media` wasn't the first regular
user created), don't fight the installer — instead set `PUID`/`PGID` in
`.env` (step 2 below) to match whatever `id media` actually printed, so
file ownership stays consistent with the containers' user.

## 2. Bootstrap

Clone the repo, configure `.env`, and run the bootstrap script.

```bash
sudo git clone https://github.com/<your-fork>/home-media-server.git /opt/home-media-server
cd /opt/home-media-server
cp .env.example .env
```

Edit `.env` and set at minimum `TZ` (your timezone, e.g.
`America/New_York`) and `DOMAIN` (your real domain). Leave `PUID`/`PGID` at
`1000` unless `id media` above showed something else.

Preview the bootstrap steps first:

```bash
sudo scripts/vm/00-bootstrap.sh
```

Expected output:
```
DRY-RUN: sed -i -E 's/^Components:.*/Components: main contrib non-free non-free-firmware/' "/etc/apt/sources.list.d/debian.sources"
DRY-RUN: apt-get update
DRY-RUN: apt-get install -y firmware-intel-graphics intel-media-va-driver-non-free vainfo intel-gpu-tools qemu-guest-agent ca-certificates curl git
DRY-RUN: curl -fsI --retry 2 --max-time 15 https://download.docker.com/linux/debian/dists/trixie/Release
DRY-RUN: install -m 0755 -d /etc/apt/keyrings
DRY-RUN: curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
DRY-RUN: mkdir -p "/etc/apt/sources.list.d" && cat > "/etc/apt/sources.list.d/docker.sources" <<'DOCKERSOURCES'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
DOCKERSOURCES
DRY-RUN: apt-get update
DRY-RUN: apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
DRY-RUN: usermod -aG docker,render,video media
DRY-RUN: systemctl enable --now qemu-guest-agent
DRY-RUN: mkdir -p /data
DRY-RUN: printf '%s\n' "media-data /data virtiofs defaults,nofail 0 0" >> "/etc/fstab"
DRY-RUN: mount -a
DRY-RUN: docker network create proxy
```
(Captured on a fresh Debian 13 install, with nothing configured yet.)

Review it, then apply and reboot:

```bash
sudo scripts/vm/00-bootstrap.sh --apply
sudo reboot
```

The reboot picks up the new group memberships (`docker`, `render`, `video`)
and lets the virtiofs mount and Docker come up cleanly. If your VM's
codename ever falls outside what Docker's apt repo supports yet, rerun with
`DOCKER_CODENAME=bookworm sudo scripts/vm/00-bootstrap.sh --apply`.

## 3. Data tree

After the reboot, log back in as `media` and build the `/data` tree and the
appdata directory:

```bash
sudo scripts/mkdirs.sh
```

Expected output:
```
[INFO] created /data/usenet/incomplete
[INFO] created /data/usenet/complete/tv
[INFO] created /data/usenet/complete/tv-4k
[INFO] created /data/usenet/complete/movies
[INFO] created /data/usenet/complete/movies-4k
[INFO] created /data/usenet/complete/music
[INFO] created /data/usenet/complete/anime
[INFO] created /data/media/tv
[INFO] created /data/media/tv-4k
[INFO] created /data/media/movies
[INFO] created /data/media/movies-4k
[INFO] created /data/media/anime-tv
[INFO] created /data/media/anime-movies
[INFO] created /data/media/music
[INFO] created /data/transcode
[INFO] created /opt/appdata
[INFO] created 16, existing 0
```
(Captured on the first run, before anything exists.)

Confirm the layout:

```bash
ls -la /data/media
```

Expected output:
```
drwxrwsr-x 2 media media 4096 <date> anime-movies
drwxrwsr-x 2 media media 4096 <date> anime-tv
drwxrwsr-x 2 media media 4096 <date> movies
drwxrwsr-x 2 media media 4096 <date> movies-4k
drwxrwsr-x 2 media media 4096 <date> music
drwxrwsr-x 2 media media 4096 <date> tv
drwxrwsr-x 2 media media 4096 <date> tv-4k
```
The `s` in `drwxrwsr-x` is the setgid bit (mode `2775`), so files created
inside inherit the `media` group regardless of which container user writes
them.

## 4. Verify

`scripts/vm/verify.sh` (created by plan 01-04 of this project) is the
single acceptance check for this whole runbook. Run it:

```bash
scripts/vm/verify.sh
```

Expected output:
```
PASS gpu ...
PASS vaapi-av1 ...
PASS vaapi-hevc ...
PASS vaapi-h264 ...
PASS data-mount ...
PASS tree ...
PASS hardlink ...
PASS docker ...
PASS network ...
PASS compose ...
RESULT: 10 pass, 0 fail, 0 skip
```
(Ten checks, in this order, all `PASS`.) If any line reads `FAIL` instead
of `PASS`, see Troubleshooting below before continuing — do not proceed to
running the media stacks with a failing `verify.sh`.

## Acceptance record

Paste the owner's real hardware results here once `verify.sh` has been run
on the actual VM. Hardlinks over virtiofs can only be proven on real
hardware (they can't be exercised meaningfully in CI/sandbox), so that
check gets its own row.

| Check | Result | Date | Notes |
|-------|--------|------|-------|
| `verify.sh` RESULT line | | | |
| hardlink on virtiofs (real VM) | | | |
| `vaapi-av1` | | | |
| `gpu` (kernel version) | | | |

## Troubleshooting

**`vaapi-av1` FAILs while other checks pass.** AV1 hardware encode on the
Arc A380 needs a recent VA-API driver. Check the installed version:
```bash
dpkg -l intel-media-va-driver-non-free
```
It needs to be **23.x or newer**. If it's older, the Debian 13 repos should
already carry a current build — re-run `apt-get update && apt-get upgrade`.
Also check GuC/HuC firmware loaded correctly (required for encode on DG2):
```bash
dmesg | grep -i -e guc -e huc
```
Missing or failed GuC/HuC lines usually mean the `firmware-intel-graphics`
(or its `firmware-misc-nonfree` fallback) package didn't install correctly;
re-run `sudo scripts/vm/00-bootstrap.sh --apply`.

**`data-mount` FAILs** (virtiofs not mounted at `/data`). Check the mount
unit and fstab:
```bash
systemctl status data.mount
cat /etc/fstab
dmesg | grep virtio
```
Look for a `media-data /data virtiofs defaults,nofail 0 0` line in
`/etc/fstab` and any `virtio` errors in `dmesg`. `nofail` means the VM
still boots even if the mount fails, so check this explicitly rather than
assuming boot success means the mount succeeded.

**`hardlink` FAILs.** This usually means `/data/usenet` and `/data/media`
ended up on different filesystems or ZFS datasets (hardlinks cannot cross
device/dataset boundaries). Confirm they're the same filesystem:
```bash
df /data/usenet /data/media
```
If they differ, the Proxmox host's `tank/data` may have gained a child
dataset (see runbook 01, step 2's warning) — fix that on the host side. If
they're already the same filesystem and it still fails, virtiofs itself may
not preserve hardlink semantics reliably on your PVE version; from the
**host**, try disabling the virtiofs cache:
```bash
qm set 200 --virtiofs0 media-data,cache=never
```
and retest. If it still fails, switch to the NFS fallback in runbook 01.

**Docker group membership doesn't seem to apply** (permission denied
running `docker ps` as `media`). `usermod -aG` only takes effect on the
*next* login/session, not the current shell. Log out and back in (or
reboot, which the bootstrap step already does) rather than assuming the
bootstrap script failed.

**Docker repo codename override.** If `00-bootstrap.sh` dies with
`cannot reach Docker repo for trixie`, Docker's apt repo may not have
published a `trixie` suite yet. Re-run with the Debian 12 codename, which
Docker's repo has always supported:
```bash
sudo DOCKER_CODENAME=bookworm scripts/vm/00-bootstrap.sh --apply
```
