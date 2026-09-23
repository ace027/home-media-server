# Plan 01-04 Summary: Verification & CI

## Status: Complete

## Files Created
- `scripts/vm/verify.sh` — the single read-only acceptance gate for the VM,
  in both hardware mode and `SKIP_HW=1` sandbox/CI mode. Runs 10 checks in
  the fixed order `gpu, vaapi-av1, vaapi-hevc, vaapi-h264, data-mount, tree,
  hardlink, docker, network, compose`, each printing exactly one
  `PASS <id> <detail>` / `FAIL <id> <detail>` / `SKIP <id> <reason>` line,
  ending with `RESULT: <n> pass, <n> fail, <n> skip` and exiting 1 iff any
  check FAILed. `tree` uses the identical 15-entry list `mkdirs.sh` creates.
  `hardlink` creates and always removes (via `trap ... RETURN`) a pair of
  `.verify-hardlink-$$` files under `usenet/complete` and `media`, comparing
  `stat -c %i`/`%h`. `docker`/`network`/`compose` calls are wrapped in
  `timeout`, and are SKIP under `SKIP_HW=1` only when docker is absent or
  its daemon is unreachable — when docker works, `network` and `compose`
  still run for real, with `network` SKIP if the `proxy` network is absent
  (expected on a CI runner). `ALLOW_NFS=1` is honored for `data-mount`.
- `scripts/ci/check-pinned-images.sh` — reads
  `docker compose -f <file> config --images` (falling back to
  `config --format json` parsed with `python3` if that subcommand is
  unavailable), and fails (`UNPINNED: <image>`, exit 1) on any image with no
  tag, an explicit `:latest` tag, or a registry-port-but-no-tag reference
  (e.g. `registry:5000/app`); passes (and prints `OK: <n> images pinned`,
  including `n=0`) when every image carries a digest or a non-`latest` tag.
- `.yamllint.yaml` — `extends: default`, ignores `.planning/`, disables
  `document-start`, sets `line-length.max: 160`, `truthy.check-keys: false`
  (so the workflow's `on:` key doesn't trip `-s`), and
  `comments.min-spaces-from-content: 1`, exactly per the execution contract.
- `.github/workflows/lint.yml` — `name: lint`, triggers on push to any
  branch and on pull_request, `permissions: {contents: read}`, one
  `ubuntu-latest` job `lint` with `shell: bash` defaults, running (in
  order): checkout@v4; `cp .env.example .env`; `docker compose config -q`;
  the pinned-image checker; install + run `shellcheck -x` over
  `scripts/lib/common.sh scripts/mkdirs.sh scripts/host/*.sh
  scripts/vm/*.sh scripts/ci/*.sh`; install + run `yamllint -s .`; the
  sandbox `mkdirs.sh` + `SKIP_HW=1 verify.sh` run; the host-script dry-run
  smoke test against `scripts/ci/make-host-stubs.sh` stubs
  (`00-zfs-datasets.sh`, `20-create-vm.sh`); and the executable-bit check.

## Verification Commands Run and Passed

Plan-level `verification_commands` (all 6, exact commands from the plan
frontmatter):
```
bash -n scripts/vm/verify.sh && bash -n scripts/ci/check-pinned-images.sh
  -> exit 0

shellcheck -x scripts/lib/common.sh scripts/mkdirs.sh scripts/host/*.sh scripts/vm/*.sh scripts/ci/*.sh
  -> exit 0, zero findings

yamllint -s .
  -> exit 0

cp -n .env.example .env && docker compose config -q && scripts/ci/check-pinned-images.sh
  -> exit 0 ("OK: 0 images pinned" — stacks are still empty per 01-01/01-02/01-03)

cp -n .env.example .env && d=$(mktemp -d) && DATA_ROOT=$d/data APPDATA_ROOT=$d/appdata scripts/mkdirs.sh && DATA_ROOT=$d/data SKIP_HW=1 scripts/vm/verify.sh
  -> exit 0 (full output below)

test -z "$(find scripts -name '*.sh' ! -path 'scripts/lib/*' ! -perm -u+x)"
  -> exit 0 (all non-lib scripts executable)
```

### Full sandbox `verify.sh` output (Task 3 / plan verification_commands #5)
```
[INFO] created /tmp/tmp.HRhHQwAJww/data/usenet/incomplete
[INFO] created /tmp/tmp.HRhHQwAJww/data/usenet/complete/tv
[INFO] created /tmp/tmp.HRhHQwAJww/data/usenet/complete/tv-4k
[INFO] created /tmp/tmp.HRhHQwAJww/data/usenet/complete/movies
[INFO] created /tmp/tmp.HRhHQwAJww/data/usenet/complete/movies-4k
[INFO] created /tmp/tmp.HRhHQwAJww/data/usenet/complete/music
[INFO] created /tmp/tmp.HRhHQwAJww/data/usenet/complete/anime
[INFO] created /tmp/tmp.HRhHQwAJww/data/media/tv
[INFO] created /tmp/tmp.HRhHQwAJww/data/media/tv-4k
[INFO] created /tmp/tmp.HRhHQwAJww/data/media/movies
[INFO] created /tmp/tmp.HRhHQwAJww/data/media/movies-4k
[INFO] created /tmp/tmp.HRhHQwAJww/data/media/anime-tv
[INFO] created /tmp/tmp.HRhHQwAJww/data/media/anime-movies
[INFO] created /tmp/tmp.HRhHQwAJww/data/media/music
[INFO] created /tmp/tmp.HRhHQwAJww/data/transcode
[INFO] created /tmp/tmp.HRhHQwAJww/appdata
[INFO] created 16, existing 0
SKIP gpu SKIP_HW=1
SKIP vaapi-av1 SKIP_HW=1
SKIP vaapi-hevc SKIP_HW=1
SKIP vaapi-h264 SKIP_HW=1
SKIP data-mount SKIP_HW=1
PASS tree all 15 entries present under /tmp/tmp.HRhHQwAJww/data
PASS hardlink inode 1885143 shared, link count 2
SKIP docker docker unavailable (SKIP_HW=1)
SKIP network docker unavailable (SKIP_HW=1)
SKIP compose docker unavailable (SKIP_HW=1)
RESULT: 2 pass, 0 fail, 8 skip
```
(Docker is present on PATH in this sandbox but its daemon socket is
unreachable, so `docker`/`network`/`compose` correctly report SKIP under
`SKIP_HW=1` per the spec's "docker absent or unreachable" contract, rather
than the "docker works, network SKIP only if the proxy network is absent"
branch, which would apply on a CI runner with a live Docker daemon.)

### Task 1 task-level `<verify>` (all 3 passed)
```
bash -n scripts/vm/verify.sh && shellcheck -x scripts/vm/verify.sh
  -> exit 0

cp -n .env.example .env && d=$(mktemp -d) && DATA_ROOT=$d/data APPDATA_ROOT=$d/appdata scripts/mkdirs.sh 2>/dev/null && out=$(DATA_ROOT=$d/data SKIP_HW=1 scripts/vm/verify.sh) && echo "$out" | grep -q '^PASS tree' && echo "$out" | grep -q '^PASS hardlink' && echo "$out" | grep -q '^SKIP gpu' && echo "$out" | grep -q '^RESULT: ' && test -z "$(find $d/data -name '.verify-hardlink-*')"
  -> exit 0 (no leftover .verify-hardlink-* files)

d=$(mktemp -d) && DATA_ROOT=$d/data APPDATA_ROOT=$d/appdata scripts/mkdirs.sh 2>/dev/null && rmdir $d/data/media/music && ! DATA_ROOT=$d/data SKIP_HW=1 scripts/vm/verify.sh > $d/out.txt; grep -q '^FAIL tree.*media/music' $d/out.txt
  -> exit 0 (negative test: verify.sh exited 1, `FAIL tree missing: media/music` printed)

cp -n .env.example .env && d=$(mktemp -d) && DATA_ROOT=$d/data APPDATA_ROOT=$d/appdata scripts/mkdirs.sh 2>/dev/null && DATA_ROOT=$d/data SKIP_HW=1 scripts/vm/verify.sh | awk '{print $2}' | head -10 | tr '\n' ' ' | grep -q '^gpu vaapi-av1 vaapi-hevc vaapi-h264 data-mount tree hardlink docker network compose $'
  -> exit 0 (exact check-ID order confirmed)
```

### Task 2 task-level `<verify>` (all 4 passed)
```
bash -n scripts/ci/check-pinned-images.sh && shellcheck -x scripts/ci/check-pinned-images.sh
  -> exit 0

Fixture negatives (nginx / nginx:latest / registry:5000/app): all 3 print
"UNPINNED: <image>" and exit 1.

Fixture positive (nginx:1.27.2 + ghcr.io/org/app@sha256:<64 hex>):
"OK: 2 images pinned", exit 0.

yamllint -s . && grep -q 'SKIP_HW=1' .github/workflows/lint.yml && grep -q 'check-pinned-images.sh' .github/workflows/lint.yml && grep -q 'make-host-stubs.sh' .github/workflows/lint.yml
  -> exit 0
```

### Task 3 (full Phase 1 sandbox validation, all 6 `<verify>` commands)
All 6 commands listed in the plan's Task 3 `<verify>` block were run exactly
as written and all exited 0:
1. `cp -n .env.example .env && docker compose config -q && scripts/ci/check-pinned-images.sh` — valid config, `OK: 0 images pinned`.
2. `shellcheck -x ... && yamllint -s .` — zero findings, yamllint clean.
3. Sandbox `mkdirs.sh` + `SKIP_HW=1 verify.sh` — `RESULT: 2 pass, 0 fail, 8 skip` (shown in full above).
4. Host-script dry-run smoke test (`make-host-stubs.sh` + `00-zfs-datasets.sh` + `20-create-vm.sh`) — both scripts printed their dry-run plans and exited 0.
5. Executable-bit check — no non-executable `.sh` files outside `scripts/lib/`.
6. `git check-ignore -q .env` succeeded, and `git status --porcelain --untracked-files=all` filtered against the Phase 1 file-list regex is empty — the only untracked files after this plan's work are exactly this plan's own `files_modified`: `.github/workflows/lint.yml`, `.yamllint.yaml`, `scripts/ci/check-pinned-images.sh`, `scripts/vm/verify.sh`.

All plan-level and task-level verification commands passed on the first
attempt; no fix attempts, no `BLOCKED` conditions, and no defects were found
in files owned by 01-01/01-02/01-03.

## Decisions
- `verify.sh`'s `hardlink` check uses `trap '...' RETURN` (an inline
  command string) rather than a named cleanup function, because a named
  function invoked only via `trap` triggered ShellCheck SC2329 ("function is
  never invoked") — an inline trap avoids both the false positive and any
  need to suppress a rule.
- `check-pinned-images.sh`'s "last path component" tag test
  (`${image##*/}` then check for `:`) is what correctly distinguishes a
  registry port (`registry:5000/app`, unpinned) from a real tag
  (`ghcr.io/org/app:1.0`, pinned) or a digest (`@sha256:...`, pinned),
  matching all 5 required fixtures.
- `docker`/`network`/`compose` in `verify.sh` treat "docker on PATH but
  daemon unreachable" identically to "docker absent" for `SKIP_HW=1`
  purposes (both SKIP), matching the spec's explicit failure mode: "Docker
  daemon unreachable while the CLI is present: treat it like docker-absent
  for SKIP_HW purposes; on real hardware it's a FAIL." This was exercised
  for real in this sandbox, since `docker` is on PATH here but its daemon
  socket is not reachable — the CI runner (which has a live Docker daemon)
  will instead exercise the "docker works, network SKIP only if `proxy` is
  absent" branch, also implemented and unit-testable in principle but not
  directly observed in this environment.
- Kept `check-pinned-images.sh`'s `docker compose ... config --images`
  path as primary and the `python3 -c` JSON-parsing fallback as secondary,
  exactly as specified; both paths were not separately forced (the primary
  path is what Compose v5.1.1 here actually uses), but the fallback code was
  read-reviewed against the spec's JSON shape (`.services[].image`).

## Issues
None. All verification commands passed on the first attempt.

## Errors
None. No script was run with `--apply`. No file outside `files_modified` was
created or edited. No defect was found in `files_forbidden` paths (01-01,
01-02, or 01-03's deliverables), so no `BLOCKED` was needed.

## Owner Checkpoint (user_setup — hardware acceptance, cannot be run by agents)
> On the real VM after runbook 02: run `scripts/vm/verify.sh` and confirm
> `RESULT: 10 pass, 0 fail, 0 skip`, with `PASS hardlink` on the real
> virtiofs mount recorded as its own row; record it in
> `docs/runbooks/02-vm-bootstrap.md` → Acceptance record. This hardware
> acceptance cannot be executed by agents.

This is the final outstanding Phase 1 acceptance item. Everything else
Phase 1 requires that can be checked without hardware has been proven
locally in this plan, exactly as CI (`.github/workflows/lint.yml`) will run
it on every push.

## Notes for Downstream / Coordinator
- Files touched are exactly `files_modified`: `scripts/vm/verify.sh`,
  `scripts/ci/check-pinned-images.sh`, `.yamllint.yaml`,
  `.github/workflows/lint.yml`. No `files_forbidden` path was touched
  (confirmed via `git status --porcelain --untracked-files=all`).
- `check-pinned-images.sh` currently reports `OK: 0 images pinned` because
  all 6 stack files are still `services: {}` (Phase 2+ fills them in); this
  is expected per 01-01's summary and the spec, and CI will start exercising
  real pinned-tag enforcement once Phase 2 adds services with `image:`
  lines.
- `docker network inspect proxy` was not exercised as a real PASS in this
  sandbox (no live Docker daemon here); it will be exercised for real by
  `scripts/vm/00-bootstrap.sh --apply` on the owner's VM (which creates the
  `proxy` network) and, in `SKIP_HW=0` hardware mode, `verify.sh` will PASS
  `network` there.

## Coordinator Post-Verification Fix
- Auto-remediated: the `network` check in `scripts/vm/verify.sh` reported SKIP whenever the `proxy` network was missing, even without `SKIP_HW=1`. On the real VM this would have hidden a missing network behind a SKIP instead of failing. It now SKIPs only under `SKIP_HW=1` and otherwise FAILs with `run: docker network create proxy`. Verified with a stub `docker` whose daemon is reachable (the path CI takes), and in both modes. All plan-level verification commands, shellcheck and `yamllint -s` still pass.
