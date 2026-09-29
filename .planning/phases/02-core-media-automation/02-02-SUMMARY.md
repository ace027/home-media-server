# Plan 02-02 Summary: Restore tooling

**Status:** Complete
**Agent:** engineering-infrastructure-devops (with testing-qa-verification-specialist rigor)
**Wave:** 1
**Requirements:** R3, R4, R5 (spec R2.3)

## Files
- `scripts/host/30-push-appdata.sh` (new):
  - The host only runs `zstd -dc`. That output streams over ssh into `tar -x` on the VM, which applies the allow-list, the excludes and the `--transform` renames, and writes into `/opt/appdata/.staging/<ts>` (mode 700). Nothing is written to a temp dir on the host.
  - The ssh check and the "stage exists" check run in dry-run too.
- `scripts/vm/10-restore-appdata.sh` (new), restore and `--rollback`:
  - **Preconditions:** services stopped; only the 9 names in the stage; no escaping symlink; the old roots `/data/{shows,movies,anime}` absent.
  - **Integrity check:** runs on the staged copy as `PUID`, before anything moves.
  - **Swap:** `rmdir` an empty target, then `mv -T`. Any previous dir goes into `.rollback/<ts>` (always created).
  - **App fixes:** Plex `autoEmptyTrash=0`, and a stale `TranscoderTempDirectory` is removed. SAB dirs are set offline and `admin/` is moved aside. UrlBase/Port are reported.
  - **Fresh dirs** for the new services.
  - **Baseline:** `baseline.json` plus `baseline-ids/*.txt`, all owned by `PUID`. The Plex watched count is owner-only (movies and episodes).
- `scripts/ci/test-restore.sh` (new): 14 planned cases plus CLI-error cases.
  - Stubs for ssh, docker and setpriv.
  - Every output and every ssh argv is checked for leaked dummy secrets.
  - It passes as root and as a non-root uid 1001 with sudo. Without sudo, the root-only cases print `skip`.
- `scripts/ci/fixtures/restore/README.md`: states the fixtures are synthetic. The archive and DBs are generated at test time.

## Verification
- 14/14 commands passed: 9 task lines + 5 frontmatter.
- Three commands failed on their first run and passed after one fix each: shellcheck SC2029/SC2154/SC2015, and a stub-PATH ordering bug in the test.
- Mutation check: 16 guards were broken one at a time, and each break failed the suite. The baseline chown is caught only in the non-root run.
- The coordinator re-ran shellcheck, `test-restore.sh` (`all restore tests passed`), the fixture grep and `test-compose.sh`; all exit 0.

## Decisions
- `--stage` together with `--rollback` exits 2.
- Rollback only checks that the services are stopped.
- The per-app steps act only on services present in the stage.
- A re-run refuses to overwrite an existing `.rollback/<ts>/<svc>`.
- A missing *arr DB counts 0 with a warning. `ARCHIVE` goes through `require_safe_path`.
- **Coordinator fix:** on rollback, `sabnzbd-admin` goes back into the restored sabnzbd dir. That is `<ts>-undone/sabnzbd` when an older sabnzbd dir was rolled back, so the archive's old queue never lands in the previous config. The executor had flagged this for review.

## Issues
- The scripts are longer than the spec's size estimates because of comments, validation and the extra negative cases.
