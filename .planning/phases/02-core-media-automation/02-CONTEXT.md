# Phase 2: Core Media Automation -- Context

## Phase Goal
Complete the request → download → import → play loop on the LAN, with hardware transcoding.

## Requirements Covered
- **R3 Download:** SABnzbd with the categories tv, tv-4k, movies, movies-4k, music and anime, using the TRaSH single `/data` layout.
- **R4 Arr:** Prowlarr syncs to Sonarr, Sonarr-Anime, Sonarr-4K, Radarr, Radarr-4K and Lidarr.
  - Anime series go to the dedicated Sonarr-Anime instance, which is migrated from the old `animesonarr`.
  - Anime movies go to the `anime-movies` root folder in the main Radarr.
  - Imports are hardlinks or atomic moves.
- **R5 Media:**
  - Plex (Plex Pass, QSV, remote access on 32400).
  - Jellyfin as an optional evaluation behind the `jellyfin` Compose profile.
  - Seerr (Plex login; 4K requests go to the 4K instances and need admin approval; TV requests need admin approval so anime can be routed).
  - Tautulli.
  - 4K titles live only in separate Movies 4K and TV 4K libraries, shared with everyone.

`.planning/REQUIREMENTS.md` does not exist. Full detail lives in `.planning/PROJECT.md` and the spec.

**Authoritative contract:** `.planning/specs/02-core-media-automation-spec.md`. It covers the Evidence, Requirements R2.1–R2.15, the API and Type Contracts for every script, the Compose contract, Failure Modes and Acceptance Checks. Plans refer to its sections by name and do not repeat them in full. If a plan and the spec disagree, the spec wins; emit `BLOCKED`.

## What Already Exists (from prior phases)
- **Phase 1 (complete; hardware acceptance `RESULT: 10 pass, 0 fail, 0 skip` on 2026-09-28):**
  - Compose skeleton: `compose.yaml` includes 6 stacks.
  - `stacks/_common.yaml` defines the `base` template (restart, `no-new-privileges`, TZ/PUID/PGID/UMASK, log rotation).
  - `stacks/{edge,media,arr,download,transcode,ops}.yaml` are all `services: {}` with the external `proxy` network.
  - `.env.example`
  - `scripts/lib/common.sh`, which provides:
    - logging: `log_*`, `die`
    - `parse_common_args`
    - `run`, `run_sh`
    - `require_root`, `require_cmd`, `require_match`, `require_safe_path`
    - `load_env`
    - the ERR trap
  - Host scripts `scripts/host/{00,05,10,20}-*.sh`, VM scripts `scripts/vm/{00-bootstrap,verify}.sh`, and `scripts/mkdirs.sh`.
  - CI: `scripts/ci/{check-pinned-images,make-host-stubs}.sh` and `.github/workflows/lint.yml`.
  - Runbooks 01 and 02.
- **Real environment:**
  - VM `media-01` at 192.168.50.16: Debian 13, 6 vCPU, 10 GB, Docker 29.8.1.
  - `/data` is the virtiofs share of ZFS `tank/data`. Hardlinks are verified, and the TRaSH tree exists.
  - `/opt/appdata` is owned by `media` (1000:1000); the `proxy` network exists; the A380 renders on `/dev/dri/renderD128`.
- **Library** in `/data/media`: movies 89 files (4K mixed in), tv 820, anime-tv 1058, music empty. The originals are kept on the host, along with `tank@pre-migration`.
- **Old config archive:** `/tank/migration/old-docker-2026-09-27.tar.zst` on the Proxmox host only (root-only, contains secrets).
- **Twingate connector:** LXC 101 on the Proxmox host (community-scripts); the owner has confirmed it works.

## Key Design Decisions
- **Approach:** Pragmatic, chosen over Minimal and Clean in step 3.5. Script the risky parts: restore with rollback, path remap, wiring, 4K split, verification. The owner does one-time choices in the UIs: Plex libraries and prefs, Seerr servers and permissions.
- **Owner decisions (2026-09-28):**
  - 4K titles are 4K-only (HD instances unmonitor them), in separate Movies 4K and TV 4K Plex libraries shared with everyone.
  - Plex runs on the bridge network with 32400 only.
  - TV requests need approval; the owner routes anime to Sonarr Anime while the request is pending.
  - An explicit HD request for a 4K-only title may download an HD copy.
  - Jellyfin is an optional evaluation.
- **Key evidence:** usenet imports are **moves** (same inode), not hardlinks. Seerr can't auto-route anime. The masked `********` fields affect idempotency. Seerr keys are base64.
- **Waves:**
  - Wave 1 has two independent plans: 02-01 (compose + CI) and 02-02 (restore tooling).
  - 02-03 needs the service names and ports from 02-01, plus `.env`.
  - 02-04 needs `scripts/lib/arr.sh` and the API stubs from 02-03.
- **CI ownership:** only 02-01 edits `.github/workflows/lint.yml`. It adds a step that runs every `scripts/ci/test-*.sh`, so later plans add test files without touching the workflow.
- **Agents:**
  - Infrastructure and Compose: engineering-infrastructure-devops.
  - API scripts: engineering-backend-architect and testing-api-tester.
  - Runbook: product-technical-writer.
  - A testing agent sits on every code plan.
- **Hardware boundary:** agents cannot reach the VM, the host or the apps. Scripts are proven with dry-runs, synthetic fixtures and the stub `docker`/`curl`/`ssh` executables. The real run is the owner's acceptance checkpoint, recorded in `docs/runbooks/03-core-media.md` → Acceptance record.
- There is no `settings.json`, so the default `max_tasks_per_plan = 3` applies.

## Plan Structure
- **Plan 02-01 (Wave 1)**: Compose services, LAN override and CI. Covers the download/arr/media stacks, `compose.lan.yaml`, the `.env.example` keys, `config/min-versions.txt`, `check-min-versions.sh`, and the `lint.yml` steps.
- **Plan 02-02 (Wave 1)**: Restore tooling. Covers `scripts/host/30-push-appdata.sh`, `scripts/vm/10-restore-appdata.sh` and `scripts/ci/test-restore.sh`.
- **Plan 02-03 (Wave 2)**: API helper, path remap and wiring. Covers `scripts/lib/arr.sh`, `scripts/ci/make-api-stubs.sh` with fixtures, `scripts/vm/20-arr-remap.sh`, `scripts/vm/25-arr-wire.sh` and `scripts/ci/test-arr-scripts.sh`.
- **Plan 02-04 (Wave 3)**: 4K split, verification and runbook. Covers `scripts/vm/30-split-4k.sh`, `scripts/vm/verify-media.sh`, `scripts/ci/test-media-scripts.sh`, `docs/runbooks/03-core-media.md` and `docs/README.md`, plus the owner's acceptance checkpoint.
