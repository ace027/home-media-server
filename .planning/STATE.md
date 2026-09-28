# Project State

## Current Position
- **Phase**: 1 of 6 (complete)
- **Status**: Phase 1 complete — review passed (3 cycle(s)); owner hardware acceptance still pending
- **Last Activity**: Phase 1 review passed (2026-09-26)

## Progress
```
[#####...............] 26% — 5/19 plans complete
```

## Recent Decisions
- Execution mode: Guided
- Planning depth: Standard
- Cost profile: Balanced
- Design source: `.planning/explorations/2026-09-23-home-media-server-design.md`
- Codebase map: skipped (greenfield, no source code)
- Phase 1 architecture: Hybrid (empty stacks, `_common.yaml` via `extends`, external `proxy` network, host/vm script split, dry-run-by-default scripts, `verify.sh` acceptance gate, CI lint)
- Phase 1 spec: `.planning/specs/01-host-repo-foundation-spec.md` (critique PASS after revisions)
- Phase 1 plan critique: REWORK, then revised (5 critical + 6 warnings fixed)
- Phase 1 review: PASSED after 3 cycles (2 blockers, 9 warnings fixed; 14 suggestions deferred) — `.planning/phases/01-host-repo-foundation/01-REVIEW.md`
- 2026-09-28: Jellyfin changed from standing backup to optional evaluation (off by default behind a Compose profile; OIDC/public route/family docs only if adopted). PROJECT.md R5/R6 and ROADMAP Phases 2, 3, 6 updated
- 2026-09-28: Host hardware recorded (Skylake, 8 threads, 16 GB, no ReBAR option). VM 200 created at 6 cores / 10 GB on local-lvm; ZFS ARC capped at 2 GB. Runbook 01 now covers VM sizing, the ARC cap, optional ReBAR, and disabling pool storages before `zpool export`
- Owner checkpoint (after build): run `scripts/vm/verify.sh` on the real VM → `RESULT: 10 pass, 0 fail, 0 skip`

## GitHub
- Phase 1 issue: #1 (https://github.com/ace027/home-media-server/issues/1)
- Branches: `main` (default, released), `dev` (integration; all work branches from and merges into `dev`)
- Phase 1 PR: #3 `dev` → `main` (https://github.com/ace027/home-media-server/pull/3; supersedes #2, which was opened from a now-retired `claude/` branch); includes review fixes 5d72178, 0a01d43

## Next Action
Run `/legion:plan 2` to plan the next phase (Core Media Automation)

Owner hardware progress (2026-09-28): pool exported, moved and imported on the new host; `tank@pre-migration` snapshot taken; `tank/data` created and the library copy into `tank/data/media` is running; IOMMU/vfio config applied (reboot pending); VM 200 created (not yet started). Remaining: verify the copy, fix ownership, reboot, post-reboot checks, then `docs/runbooks/02-vm-bootstrap.md` and record `scripts/vm/verify.sh` in the Acceptance record.
