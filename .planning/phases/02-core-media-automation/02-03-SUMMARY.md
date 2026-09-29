# Plan 02-03 Summary: API helper, path remap and wiring

**Status:** Complete
**Agent:** engineering-backend-architect (with testing-api-tester rigor)
**Wave:** 2
**Requirements:** R3, R4 (spec R2.4 remap part, R2.5, R2.6, R2.7)

## Files
- `scripts/lib/arr.sh` (new): the spec's API surface, plus helpers.
  - Spec functions: `arr_port`, `arr_base`, `svc_ip`, `svc_key`, `api`, `sab_api`, `wait_cmd`, `arr_mutate`, `same_state`, `count_mutations`.
  - Helpers: `sab_path`, `arr_redact`, `arr_change`, `arr_command`, `running_services`, `require_healthy`, `ensure_root_folder`.
  - Keys only ever travel on curl's stdin config (`-K -`) or jq's stdin.
- `scripts/ci/make-api-stubs.sh` (new): stub `docker`, `curl` and `ssh` per the spec's stub contract.
  - Sequence fixtures (`.1`, `.2`, …) return successive responses.
  - `<fixture>.http` sets the status code for one endpoint; `STUB_HTTP_<svc>` for a whole service.
  - `STUB_EXPECT_KEY` returns 401 on a wrong key; `STUB_IMAGES` feeds `config --images`.
  - `docker compose exec` works via `STUB_EXEC_OUT_*` and `STUB_EXEC_RC_*`.
  - curl exits 22 on codes ≥400 and 7 on a wrong port.
- `scripts/vm/20-arr-remap.sh` (new):
  - Refuses while SAB or Prowlarr is running.
  - Turns unmonitor-deleted off first, adds the new root, calls the editor with `moveFiles:false` and re-checks the item paths.
  - Deletes the old root only once it is empty. Rescans only when something changed.
  - Adds Lidarr's `/data/media/music` root.
- `scripts/vm/25-arr-wire.sh` (new):
  - SAB: dirs, whitelist, categories, purge of pre-baseline jobs; `--only sab` pauses the queue.
  - Per *arr: the SABnzbd client, torrent indexer and remote-path cleanup, root folders.
  - Prowlarr: SAB client, cleanup, and the 6 apps with a top-level `syncLevel=fullSync`.
  - `ApplicationIndexerSync` runs only after changes. The full run resumes SAB. A second `--apply` makes 0 mutations.
- `scripts/ci/test-arr-scripts.sh` (new): the 11 planned cases plus 5 extra, including `same_state` masking and Prowlarr app matching.
- `scripts/ci/fixtures/api/`: `initial/` and `converged/` sets, 116 synthetic JSON files. Secrets appear only as `********`.

## Verification
- 8/8 task verification lines and 5/5 frontmatter commands passed. Task 1's shellcheck failed once (SC2317) and passed after a fix.
- Non-root run (uid 1001) passes.
- Mutation check: 26 guards were broken one at a time, and each break failed the suite. The three that survived at first led to two new cases.
- The coordinator re-ran:
  - repo-wide `shellcheck`;
  - every `scripts/ci/test-*.sh` (compose, restore, arr-scripts all PASS);
  - the fixture grep.

  All exit 0. The only `X-Api-Key` line in `arr.sh` is inside the stdin `printf`.

## Decisions
- `api` returns 1 rather than exiting.
- `arr_mutate` must be called directly, not inside `$(...)`, so the mutation count is kept.
- `same_state` ignores a field on both sides if either side masks it, and sorts arrays before comparing.
- The remap uses `PUT /config/mediamanagement/<id>`. It exits 1 if the unmonitor field is missing, and requires `$DATA_ROOT/media/music` to exist.
- The SAB client is matched by the name `SABnzbd`, else by implementation. Extra Sabnzbd clients get a WARN and are kept.

## Issues / notes for review
- The SAB purge checks the queue and the history separately, which is narrower than the spec's "either" rule and safer.
- A full wire run needs all 11 core services healthy, including Plex, Seerr and Tautulli, as the spec says.
- There is no key source for Tautulli or Jellyfin. 02-04's `jellyfin` check must use an unauthenticated `/health` call.
- These API assumptions can only be confirmed in the owner's run:
  - SAB `time_added`/`completed` fields;
  - the `host_whitelist` type;
  - the mediamanagement PUT route.
- SAB's `get_config` response holds its key unmasked. It lives only in a 700 temp dir that is removed on exit.
