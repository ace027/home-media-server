# Plan 02-01 Summary: Compose services, LAN override and CI

**Status:** Complete
**Agent:** engineering-infrastructure-devops (with testing-qa-verification-specialist rigor)
**Wave:** 1
**Requirements:** R3, R4, R5 (spec R2.1, R2.2, R2.13, R2.14, R2.15 CI part)

## Files
- `stacks/download.yaml`: `sabnzbd`.
- `stacks/arr.yaml`: prowlarr, sonarr, sonarr-anime, sonarr-4k, radarr, radarr-4k and lidarr.
- `stacks/media.yaml`:
  - plex: bridge network, only `32400:32400`, `/dev/dri`, `/data/media:ro`, `start_period` 300s.
  - seerr: `init`, `/app/config`, wget healthcheck.
  - tautulli.
  - jellyfin: `profiles: [jellyfin]`, `/dev/dri`, `/data/media:ro`.
- `compose.lan.yaml` (new): 11 admin ports bound to `${LAN_IP:?…}`, jellyfin with its profile.
- `.env.example`: `LAN_IP=192.168.1.10` and a commented `# COMPOSE_FILE=compose.yaml:compose.lan.yaml`.
- `config/min-versions.txt` (new): the 8 old image tags.
- `scripts/ci/check-min-versions.sh` (new): normalizes tags (`v` prefix, `-lsN`, Plex hash), compares with `sort -V`, and prints `BELOW-MIN`, `NO-IMAGES` or `OK`.
- `scripts/ci/test-compose.sh` (new): 14 checks.
  - The compose variants (default, jellyfin profile, LAN override) validate; jellyfin exists only with its profile.
  - LAN_IP is required; the 11 admin ports bind to it.
  - `/data` is mounted once; only 32400 is published without the override.
  - Fixtures hold only the dummy key.
  - Min-versions: a downgrade fails, `NO-IMAGES` fails, and the Plex-hash and newer-version cases pass.
- `.github/workflows/lint.yml`:
  - installs jq, sqlite3 and zstd;
  - runs the pinned check with `COMPOSE_PROFILES=jellyfin`;
  - adds a min-versions step;
  - widens the shellcheck glob to `scripts/lib/*.sh`;
  - adds a "Script tests" loop over `scripts/ci/test-*.sh`.
- `docs/architecture.md`: Plex 32400 is the only permanent published port; a table of the temporary admin ports.

## Verification
- 22/22 commands passed: task lines, frontmatter commands and re-runs.
- The coordinator re-ran these independently, all exit 0:
  - `docker compose config -q`
  - `check-pinned-images.sh` → `OK: 12 images pinned`
  - `check-min-versions.sh` → `OK: 11 images at or above minimum`
  - `test-compose.sh` → `PASS`
  - `yamllint -s .` and `shellcheck`
- Negative mutation tests: each of these made `test-compose.sh` fail with a precise message:
  - a second `/data` mount;
  - a missing `:ro`;
  - an extra published port;
  - an unbound LAN port;
  - a non-dummy key;
  - a downgraded tag;
  - a missing `:?` guard.

## Decisions
- The output line is `BELOW-MIN: <image> < <repo>:<min-tag>`.
- `/data` targets are matched with `^/data(/|$)`. The test requires exactly two `/data/media` mounts, so it cannot pass vacuously.
- `test-compose.sh` unsets `COMPOSE_FILE`, `COMPOSE_PROFILES` and `LAN_IP`, and uses `-f compose.yaml`, so the owner's real `.env` can't mask failures.
- A digest-only reference to a listed repo is skipped with a `[WARN]`.

## Issues
- The jellyfin `profiles` line in `compose.lan.yaml` is redundant (the base service's profile already applies), but the spec requires it and it is kept.
- The new workflow steps were validated locally, not yet on a GitHub runner.
