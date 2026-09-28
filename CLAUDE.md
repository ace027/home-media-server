# CLAUDE.md

Guidance for Claude Code sessions working in this repository.

## Branches
- `main` is the default branch and holds released work only. Never commit or push to `main` directly.
- `dev` is the integration branch. All work starts from `dev`, and PRs target `dev`.
- When a session is assigned its own `claude/...` branch, create it from `origin/dev` (not `main`) and open its PR against `dev`:
  ```bash
  git fetch origin dev
  git checkout -B <assigned-branch> origin/dev
  ```
  If the assigned branch already exists but was cut from `main`, rebase or merge it onto `origin/dev` before starting.
- Changes are tested on `dev` first (CI, then the owner's run on the real VM). Never open a PR from a `claude/...` branch into `main`; only `dev` → `main` release PRs target `main`.
- `dev` is merged into `main` through a PR when a phase (or a set of phases) is complete.
- Delete `claude/...` branches after their PR merges into `dev`.

## Project workflow
- Subagents run on the latest Sonnet: pass `model: "sonnet"` on every Agent call (Legion executors, reviewers, critics, fix agents, research helpers). `.claude/settings.json` sets `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` (forced), and the Legion `settings.json` sets `models.planning`/`execution`/`check` to `sonnet`, overriding the Claude Code adapter's opus/haiku defaults.
- Planning lives in `.planning/` (Legion): `PROJECT.md`, `ROADMAP.md`, `STATE.md`, and per-phase plans, summaries and reviews under `.planning/phases/`. Check `STATE.md` for the current phase and next action.
- `.planning/specs/01-host-repo-foundation-spec.md` is the contract for script CLIs, output formats and `verify.sh` check IDs.

## Conventions
- Host/VM scripts are dry-run by default and change nothing without `--apply`. Never run them with `--apply` in a sandbox; test with `SYSROOT` fixtures and `scripts/ci/make-host-stubs.sh`.
- Pin every image tag; never use `latest`. Never commit secrets (`.env`, `secrets/*`, old-VM dumps are gitignored).
- Runbook "Expected output" blocks must be pasted from real dry-run output.

## Checks to run before pushing
These cover the main gates of `.github/workflows/lint.yml`:
```bash
cp -n .env.example .env && docker compose config -q
COMPOSE_PROFILES=jellyfin scripts/ci/check-pinned-images.sh && scripts/ci/check-min-versions.sh
shellcheck -x scripts/lib/*.sh scripts/mkdirs.sh scripts/host/*.sh scripts/vm/*.sh scripts/ci/*.sh
yamllint -s .
( for t in scripts/ci/test-*.sh; do bash "$t" || { echo "FAIL $t"; exit 1; }; done )
d=$(mktemp -d) && DATA_ROOT=$d/data APPDATA_ROOT=$d/appdata scripts/mkdirs.sh && DATA_ROOT=$d/data SKIP_HW=1 scripts/vm/verify.sh
```
