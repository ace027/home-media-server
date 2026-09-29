# Phase 2: Core Media Automation — Review Summary

## Result: PASSED (after escalation)

- **Cycles used**: 3 of 3 (maximum)
- **Reviewers** (dynamic panel):
  - testing-qa-verification-specialist (Production Readiness)
  - testing-api-tester (API Contract Compliance)
  - engineering-infrastructure-devops (Operational Readiness)
  - engineering-security-engineer (Secrets & Trust Boundaries)
- **Date**: 2026-09-28
- **Remaining**: 0 blockers, 0 warnings (the 3 escalated warnings were fixed and passed a targeted re-review on 2026-09-29)
- **Scope of what remains**: every open finding is on the 4K split `--undo` recovery path. The first split, the first undo, restore, remap, wiring and verify are clean.

## Findings Summary
| Cycle | Blockers found | Warnings found | Suggestions | Fixed in cycle |
|-------|----------------|----------------|-------------|----------------|
| 1 | 2 | 10 | 8 | all 20 (commits da5386c, ddd727a, b7d696a, 24e2548, ef8e7e9) |
| 2 | 1 | 3 | 6 | all 10 (commits c5ae7d0, 67c4599, 93892a3, d1a56f4, 1ee0e39) |
| 3 | 0 | 3 | 1 | — (loop limit reached) |

## Resolved Findings (highlights)
| Sev | File | Issue | Fix | Cycle |
|-----|------|-------|-----|-------|
| BLOCKER | runbook 03 | Host checkout never updated before `30-push-appdata.sh` | Prerequisite `git pull` on the host; step 2 starts with `cd` | 1 |
| BLOCKER | 25-arr-wire.sh | Prowlarr SAB client category `prowlarr` (not a SAB category) | → `""` in cycle 1, which Prowlarr's validator also rejects → `*` in cycle 2; stub now models the validator | 1–2 |
| WARNING | arr.sh / 10-restore | Relative `COMPOSE_FILE` breaks scripts run outside the repo | `arr_dc` makes it absolute; restore uses it; tests | 1–2 |
| WARNING | 20-arr-remap.sh | No folder check before editor+rescan (re-download risk) | Precheck, dry-run included | 1 |
| WARNING | 10-restore | `--rollback` after a first restore undid nothing | `installed` list; everything to `-undone`; SAB queue kept with it | 1 |
| WARNING | 10-restore | Failure after swap: no guidance | EXIT trap with recovery commands | 1 |
| WARNING | 30-split-4k.sh | No HD rescan; undo lost monitored state; seasonFolder lost | HD rescan; `prior` column; seasonFolder/seriesType copied | 1 |
| WARNING | arr.sh | SAB `status:false` inside HTTP 200 treated as success | Detected in `api()` | 1 |
| WARNING | runbook, CLAUDE.md | zfs rollback with VM up; pre-push checks ≠ lint.yml | Fixed | 1 |
| WARNING | 30-split-4k.sh | Undo not resumable; empty recreated src blocks undo; episode-level state lost | Resumable undo; `rmdir` empty src; `prior.e` + `episode/monitor` | 2 |
| SUGG | various | symlink-safe baseline writes, `.rollback` checks, LAN_IP 0.0.0.0, api tmp in `$W`, wait_cmd states, atomic manifest, `.env.example` overrides, restore COMPOSE_FILE test, fail-fast test loop | Applied | 1–2 |

## Unresolved Findings
| # | Sev | Conf | File | Issue | Reason unresolved |
|---|-----|------|------|-------|-------------------|
| 1 | WARNING | HIGH 90% | scripts/vm/30-split-4k.sh `delete_4k` (~226-238) | Sonarr v4.0.19 returns **HTTP 500** (not 404) for `DELETE /api/v3/series/{id}` on a missing id (`BasicRepository.Get(IEnumerable)` → `ApplicationException`). A resumed undo of a series row whose 4K DELETE already succeeded fails every re-run. Radarr returns 404 (fine). Test 5c forces an invented 404. | Found in cycle 3 (a regression from the cycle-2 resumable-undo fix); loop limit reached. Fix: on a resumed row, `GET /api/v3/<kind>/<new_id>` first (single-id Get → real 404) and skip the DELETE on 404; stub: sonarr-4k DELETE missing → 500, GET → 404. |
| 2 | WARNING | HIGH 85% | scripts/vm/30-split-4k.sh preflight (~276-277) and loop (~302-305) | The resumed-row test accepts an **empty** `src`. A 4K folder that went missing (with an empty HD folder recreated by a rescan) is silently "undone": the 4K entry is deleted and the HD item re-monitored with no file, so a missing search can re-download it. Reproduced (`repro-c3.sh`). | Found in cycle 3 (regression from cycle-2 fixes #2 and #4 interacting). Fix: treat a row as resumed only if `src` exists **and is not an empty dir**, in both places; test: dst gone + empty src fails the preflight. |
| 3 | WARNING | MEDIUM 60% | scripts/vm/30-split-4k.sh (~335-338) | `PUT /api/v3/episode/monitor` fails (500 for >1 id, 404 for 1) if an id in `prior.e` was since deleted by a TVDB refresh; the row then fails on every re-run. | Found in cycle 3. Fix: intersect `prior.e` with `GET /api/v3/episode?seriesId=` before the PUT; skip if empty. |
| 4 | SUGGESTION | HIGH 95% | docs/runbooks/03-core-media.md ~192 | Restore dry-run example lacks the new `DRY-RUN: install -d -m 700 -o 0 -g 0 …/.rollback` line (c5ae7d0). | Regenerate the block. |

## Reviewer Verdicts (final)
| Reviewer | Final verdict | Key observations |
|----------|---------------|------------------|
| engineering-security-engineer | PASS (cycle 2) | Keys never in argv/logs/repo; archive extraction safe; root paths validated; remaining TOCTOU on `.rollback` is inside the PUID-owned tree and PUID already owns the checkout root runs |
| engineering-infrastructure-devops | PASS (cycle 2) | Compose matches the contract; CI mirrors the spec; runbook operable end to end; examples match real output |
| testing-api-tester | NEEDS WORK (cycle 3) | All app contracts verified against upstream source at the pinned tags; open: Sonarr DELETE 500 on missing id, stale `prior.e` ids |
| testing-qa-verification-specialist | NEEDS WORK (cycle 3) | Recovery paths (restore rollback, remap precheck, resumable undo) verified by reproduction; open: empty-src resume |

## Recommendation
All three open warnings are small, localized to the `--undo` resume path of `30-split-4k.sh`, lose no data by themselves (finding 2 can cause a re-download), and only trigger if an undo is re-run after a failure. Fix all three plus the example block in one pass (a single agent, one file plus its test), then run a targeted re-check before merging PR #6. None of them affects the owner's first run of steps 1–4, and the split itself is guarded by the `tank/data@pre-4k-split` snapshot.

## Suggestions noted (not required)
- Keep `/opt/appdata/.rollback` outside the PUID-owned tree (or make `APPDATA_ROOT` root-owned) to close the residual TOCTOU on root's `mv` into `.rollback` (security, cycle 2).
- Restore an episode that was monitored inside a season that was unmonitored before the split (an edge case outside `prior.e`).

## Escalation Resolution (2026-09-29)
- **Owner decision:** "Fix manually and re-run /legion:review".
- **Fixes:**
  - 6b35718: resumed undo rows GET the 4K item before DELETE (Sonarr v4 returns 500 on a DELETE of a missing series); an empty `src` is not "moved back"; stale `prior.e` ids are skipped.
  - 8136dd6: the restore example was regenerated.
- **Targeted re-review** (reviewers on Sonnet): testing-api-tester **PASS**, verified against the Sonarr v4.0.19.2979 and Radarr v6.3.0.10514 source. testing-qa-verification-specialist **PASS**: both reproductions behave correctly, there are no regressions in the other undo paths, runbook wording matches, and the CLAUDE.md pre-push block is green.
- **QA suggestion applied** (the commit after this review file's first version): `moved_back` requires a regular file in `src`, so a src holding only an empty `Season 01` no longer counts. Test 5f is extended and mutation-checked.
- **Not actioned (low value):** no test for Radarr's GET 404 branch (the code path is shared with Sonarr).

## Result
**PASSED.** Totals across all cycles:
- 3 blockers fixed;
- 15 warnings fixed;
- 15 suggestions applied, 2 noted.

Owner hardware acceptance (runbook 03) is still pending and is tracked in the runbook's Acceptance record.
