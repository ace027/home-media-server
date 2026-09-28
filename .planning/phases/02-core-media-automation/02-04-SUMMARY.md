# Plan 02-04 Summary: 4K split, verification and runbook

**Status:** Complete (owner acceptance checkpoint PENDING)
**Agents:** testing-api-tester (scripts, fixtures, tests); product-technical-writer (runbook, README)
**Wave:** 3
**Requirements:** R3, R4, R5 (spec R2.8–R2.12, R2.14, R2.15)

## Files
- **`scripts/vm/30-split-4k.sh`** (new): the 4K split.
  - It first looks up the 4K quality profile (`QP_4K_*`) and exits 1, listing the available names, if it is missing.
  - The plan TSV marks each title `move`, `skip-mixed` or `check`.
  - A file counts as 4K by `max(quality, mediaInfo)` resolution, or a width of 3200 or more.
  - Titles tagged `4k-only` are skipped; unmonitored titles are not. Anime is only reported, as `anime-4k=<n>`.
  - Every `move` row is preflighted before anything moves.
  - `--apply`, per row: `mv`, add to the 4K instance with `monitor:"existing"`, rescan, then unmonitor and tag `4k-only` in HD (seasons too).
  - The manifest row is written right after the `mv`. If a row is only partly applied, the script prints the `--undo` command.
  - `--undo <manifest> [--apply]` reverses rows in reverse order and renames the manifest to `.undone`.
- **`scripts/vm/verify-media.sh`** (new): the read-only gate.
  - It uses `api` only (never `arr_mutate`) and writes only to a temp dir.
  - It prints the 15 spec check IDs in order, then `RESULT`, and exits 1 on any FAIL. Each check runs isolated, so a bad response becomes a FAIL instead of aborting the run.
  - `--watch-import <svc>` looks for new files with `find -newerct` and matches the imported file by inode and device.
- **`scripts/ci/test-media-scripts.sh`** (new): 21 test groups, covering the 17 planned cases plus extras.
- **`scripts/ci/fixtures/media/`**: synthetic `split/`, `split-noprofile/` and `verify/{good,migration}`. They layer over 02-03's `fixtures/api/converged`.
- **`docs/runbooks/03-core-media.md`** (new):
  - The 14 spec headings in order.
  - The secrets warning for the migration archive.
  - Example outputs are real dry-runs against the CI stubs and fixtures, labelled as such.
  - Snapshots `pre-phase2` and `pre-4k-split`, rollback per step, and troubleshooting.
  - An unfilled Acceptance record.
- **`docs/README.md`**: a link to runbook 03.

## Verification
- 15/15 commands passed. Task 2's shellcheck failed once (SC2120/SC2119) and passed after one fix.
- The test suite also passes as a non-root user.
- Mutation check: 8 guards were broken one at a time, and each break failed the suite.
- The coordinator re-ran these; all exit 0:
  - repo-wide `shellcheck`;
  - `yamllint -s .`;
  - every `scripts/ci/test-*.sh` (compose, restore, arr-scripts, media-scripts all PASS);
  - the 32-hex grep across `scripts/ci/fixtures` and `docs`;
  - the runbook heading check.

## Decisions
- The split's dry-run writes the plan and runs the preflight, but makes API calls only with `--apply`.
- If a title already exists in the 4K instance, the split reuses it instead of adding it again.
- The `4k-split` check also exempts radarr `anime-movies` titles, which are never split by design.
- Plex paging uses the `X-Plex-Container-Start`/`-Size` query parameters; the page size is set with `PLEX_PAGE_SIZE` (default 200).
- `library-adopted` covers sonarr, sonarr-anime and radarr. The spec defines no current-count source for Lidarr.
- In `--watch-import`, an inode mismatch fails at once.

## Issues
- Some fixture names contain `:` or `%`. That is fine on Linux and in CI, but the files cannot be checked out on Windows.
- These API assumptions can only be confirmed in the owner's run:
  - the Seerr settings paths;
  - the Plex `transcodeHw*` fields and `/:/prefs` shape;
  - the payload keys for the rescan commands;
  - the Lidarr history event type.
- The suite takes about 2.5 minutes.

## Owner checkpoint (PENDING)
After merge to `dev`, the owner runs runbook 03 on media-01. Acceptance needs all of these in the Acceptance record:
- `verify-media.sh` with 0 fail;
- `plex-hw`, `plex-watched` and `plex-counts` PASS;
- three `--watch-import` PASS lines.
