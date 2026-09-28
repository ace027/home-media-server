#!/usr/bin/env bash
# shellcheck disable=SC2016
# (SC2016: the single-quoted stub bodies below are written verbatim into
# generated scripts on disk, where their $-expressions expand at stub
# runtime, not here.)
#
# scripts/ci/test-restore.sh
#
# Tests scripts/host/30-push-appdata.sh and scripts/vm/10-restore-appdata.sh
# against a synthetic old /docker tree and archive generated under a temp dir,
# with stub ssh/docker/setpriv on PATH. Cases that need root (--apply) run
# through passwordless sudo; without it they print "skip <case> (no sudo)".
# Prints "ok <case>" per case and exits 1 on the first failure.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUSH="$REPO/scripts/host/30-push-appdata.sh"
RESTORE="$REPO/scripts/vm/10-restore-appdata.sh"

HAVE_SUDO=0
if sudo -n true 2>/dev/null; then
  HAVE_SUDO=1
fi

T="$(mktemp -d)"
cleanup() {
  rm -rf "$T" 2>/dev/null && return 0
  if [[ $HAVE_SUDO -eq 1 ]]; then
    sudo -n rm -rf "$T" || true
  fi
}
trap cleanup EXIT

ok() { printf 'ok %s\n' "$1"; }
skip() { printf 'skip %s\n' "$1"; }
fail() {
  printf 'FAIL %s: %s\n' "$1" "$2" >&2
  if [[ -n "${OUT:-}" ]]; then
    printf -- '--- output ---\n%s\n--------------\n' "$OUT" >&2
  fi
  exit 1
}

# run_capture <cmd...>: sets OUT (stdout+stderr) and RC, never exits.
run_capture() {
  RC=0
  OUT="$("$@" 2>&1)" || RC=$?
}

# expect <case> <rc> [<grep -E pattern>]: the last run_capture exited <rc>
# and (if given) its output matches <pattern>.
expect() {
  local name="$1" rc="$2" pattern="${3:-}"
  [[ $RC -eq $rc ]] || fail "$name" "exit $RC, expected $rc"
  if [[ -n "$pattern" ]] && ! grep -qE -- "$pattern" <<<"$OUT"; then
    fail "$name" "output does not match: $pattern"
  fi
}

# names <dir>: sorted top-level entry names.
names() {
  find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
}

# Dummy secrets from the fixtures: they must never show up in any output
# or in an ssh argv.
SECRETS=(0123456789abcdef0123456789abcdef dummytoken0123456789 'ZHVtbXlrZXlkdW1teWtleQ==')
no_secrets() {
  local name="$1" text="$2" s
  for s in "${SECRETS[@]}"; do
    if grep -qF -- "$s" <<<"$text"; then
      fail "$name" "a fixture secret appeared in output/argv"
    fi
  done
}

# fix_owner: after a sudo step, hand the tree back to the test user.
fix_owner() {
  sudo -n chown -R "$(id -u):$(id -g)" "$T"
}

# tree_sig <dir>: a listing + content hash, to prove a dir is unchanged.
tree_sig() {
  (cd "$1" && find . -printf '%p %y %s\n' | sort && find . -type f -exec md5sum {} + | sort)
}

# --- stubs ---------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Stub ssh: STUB_SSH_RC forces a failure; otherwise the remote command (the
# last argument) runs locally, with stdin passed through.
printf '%s\n' "$*" >> "${STUB_LOG_DIR:?}/ssh.log"
if [[ -n "${STUB_SSH_RC:-}" ]]; then
  exit "$STUB_SSH_RC"
fi
exec bash -c "${!#}"
EOF
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Stub docker: `compose ... ps --status running --services` prints
# $STUB_RUNNING, one name per line; anything else succeeds silently.
printf '%s\n' "$*" >> "${STUB_LOG_DIR:?}/docker.log"
if [[ "$1" == compose && " $* " == *" ps --status running --services "* ]]; then
  for s in ${STUB_RUNNING:-}; do
    printf '%s\n' "$s"
  done
fi
exit 0
EOF
cat > "$T/bin/setpriv" <<'EOF'
#!/usr/bin/env bash
# Stub setpriv: records its options, drops them and execs the rest.
printf '%s\n' "$*" >> "${STUB_LOG_DIR:?}/setpriv.log"
while [[ $# -gt 0 && "$1" == --* ]]; do
  shift
done
exec "$@"
EOF
chmod +x "$T/bin/ssh" "$T/bin/docker" "$T/bin/setpriv"
mkdir -p "$T/logs"
export STUB_LOG_DIR="$T/logs"
export PATH="$T/bin:$PATH"
# sudo resets PATH (secure_path), so the stubs are passed through explicitly.
SUDO=(sudo -E env "PATH=$PATH")

# --- synthetic fixture: fake old /docker tree + archive --------------------------
S="$T/src/docker"
PMS_REL="Library/Application Support/Plex Media Server"
build_fixture() {
  local pms="$S/plex/config/$PMS_REL" d
  mkdir -p "$pms/Plug-in Support/Databases" "$pms/Cache" "$pms/Logs" "$pms/Crash Reports"
  printf '<?xml version="1.0" encoding="utf-8"?>\n<Preferences PlexOnlineToken="dummytoken0123456789" TranscoderTempDirectory="/data/transcode" autoEmptyTrash="1"/>\n' \
    > "$pms/Preferences.xml"
  sqlite3 "$pms/Plug-in Support/Databases/com.plexapp.plugins.library.db" <<'SQL'
create table metadata_items(id integer primary key, guid text, metadata_type integer);
create table metadata_item_settings(account_id integer, guid text, view_count integer);
insert into metadata_items values
  (1,'plex://movie/a',1),(2,'plex://episode/b',4),(3,'plex://show/c',2),
  (4,'plex://movie/d',1),(5,'plex://movie/e',1);
-- owner (1): watched movie + watched episode count (2); the watched show,
-- the other account's row and the unwatched row do not.
insert into metadata_item_settings values
  (1,'plex://movie/a',1),(1,'plex://episode/b',3),(1,'plex://show/c',1),
  (2,'plex://movie/d',1),(1,'plex://movie/e',0);
SQL
  echo x > "$pms/Cache/x"
  echo x > "$pms/Logs/x.log"
  echo x > "$pms/Crash Reports/x.dmp"
  echo 123 > "$pms/plexmediaserver.pid"

  mkdir -p "$S/plex/seerr/config" "$S/plex/tautulli"
  printf '{"main":{"apiKey":"ZHVtbXlrZXlkdW1teWtleQ=="}}\n' > "$S/plex/seerr/config/settings.json"
  printf '[General]\nhttp_port = 8181\n' > "$S/plex/tautulli/config.ini"

  local pair dir port
  for pair in sonarr:8989 animesonarr:8989 radarr:7878 lidarr:8686 prowlarr:9696; do
    dir="${pair%%:*}" port="${pair#*:}"
    mkdir -p "$S/servarr/$dir"
    printf '<Config><ApiKey>0123456789abcdef0123456789abcdef</ApiKey><UrlBase></UrlBase><Port>%s</Port></Config>\n' "$port" \
      > "$S/servarr/$dir/config.xml"
  done
  sqlite3 "$S/servarr/sonarr/sonarr.db" <<'SQL'
create table EpisodeFiles(Id integer primary key, SeriesId integer);
create table Episodes(Id integer primary key, EpisodeFileId integer);
insert into EpisodeFiles values (1,10),(2,10),(3,11);
insert into Episodes values (100,1),(101,2),(102,0),(103,3),(104,0);
SQL
  sqlite3 "$S/servarr/animesonarr/sonarr.db" <<'SQL'
create table EpisodeFiles(Id integer primary key, SeriesId integer);
create table Episodes(Id integer primary key, EpisodeFileId integer);
insert into EpisodeFiles values (1,20);
insert into Episodes values (200,1),(201,0);
SQL
  sqlite3 "$S/servarr/radarr/radarr.db" <<'SQL'
create table MovieFiles(Id integer primary key);
create table Movies(Id integer primary key, MovieFileId integer);
insert into MovieFiles values (1),(2);
insert into Movies values (1,1),(2,2),(3,0);
SQL
  sqlite3 "$S/servarr/lidarr/lidarr.db" <<'SQL'
create table TrackFiles(Id integer primary key);
insert into TrackFiles values (1),(2),(3),(4);
SQL
  sqlite3 "$S/servarr/prowlarr/prowlarr.db" <<'SQL'
create table Indexers(Id integer primary key, Name text);
insert into Indexers values (1,'dummy');
SQL
  # A relative symlink that stays inside the service dir (must be accepted).
  mkdir -p "$S/servarr/sonarr/MediaCover"
  ln -s ../config.xml "$S/servarr/sonarr/MediaCover/link"
  for d in sonarr/logs sonarr/Backups radarr/backups sabnzbd/logs; do
    mkdir -p "$S/servarr/$d"
    echo x > "$S/servarr/$d/x.txt"
  done
  echo x > "$S/servarr/sonarr/Backups/x.zip"

  mkdir -p "$S/servarr/sabnzbd/admin"
  printf '[misc]\ndownload_dir = /data/downloads/sabnzbd/incomplete\ncomplete_dir = /data/downloads/sabnzbd/complete\napi_key = 0123456789abcdef0123456789abcdef\n' \
    > "$S/servarr/sabnzbd/sabnzbd.ini"
  echo queue > "$S/servarr/sabnzbd/admin/queue10.sab"

  # Never restored: retired/Phase 4 apps and the root-level dumps.
  mkdir -p "$S/servarr/nzbget" "$S/servarr/bazarr"
  echo x > "$S/servarr/nzbget/x"
  echo x > "$S/servarr/bazarr/config.ini"
  echo '[]' > "$T/src/_inspect.json"

  tar -C "$T/src" -cf - docker _inspect.json | zstd -q -o "$T/old-docker-2026-09-27.tar.zst"
}

# make_stage <ts> [appdata-root]: build a stage straight from the fixture
# tree, with the push's renames and excludes, so restore cases never depend
# on the push cases.
make_stage() {
  local ts="$1" root="${2:-$T/vm}" st pair
  st="$root/.staging/$ts"
  mkdir -p "$root/.staging"
  mkdir -m 700 "$st"
  cp -a "$S/plex/config" "$st/plex"
  cp -a "$S/plex/seerr/config" "$st/seerr"
  cp -a "$S/plex/tautulli" "$st/tautulli"
  for pair in sonarr:sonarr animesonarr:sonarr-anime radarr:radarr lidarr:lidarr prowlarr:prowlarr sabnzbd:sabnzbd; do
    cp -a "$S/servarr/${pair%%:*}" "$st/${pair#*:}"
  done
  find "$st" \( -name logs -o -name Logs -o -name Backups -o -name backups -o -name Cache -o -name 'Crash Reports' \) \
    -prune -exec rm -rf {} +
  find "$st" -name '*.pid' -delete
}

build_fixture

EXPECTED_NAMES="$(printf '%s\n' plex seerr tautulli sonarr sonarr-anime radarr lidarr prowlarr sabnzbd | sort)"
export VM_HOST=media@vm
export ARCHIVE="$T/old-docker-2026-09-27.tar.zst"
export REMOTE_APPDATA="$T/vm"
export APPDATA_ROOT="$T/vm"
export DATA_ROOT="$T/data"
export PUID PGID
PUID="$(id -u)"
PGID="$(id -g)"
mkdir -p "$T/data"

TS1=20260928-120000
PREFS="$PMS_REL/Preferences.xml"

# ==============================================================================
# 30-push-appdata.sh
# ==============================================================================

# --- 1: push dry-run --------------------------------------------------------------
run_capture "$PUSH" --stage "$TS1"
[[ $RC -eq 0 ]] || fail push-dry-run "exit $RC"
[[ "$(grep -c '^DRY-RUN:' <<<"$OUT")" -eq 2 ]] || fail push-dry-run "expected exactly 2 DRY-RUN lines"
[[ ! -e "$T/vm/.staging" ]] || fail push-dry-run "dry-run created $T/vm/.staging"
grep -q "zstd -dc -- '$ARCHIVE' | ssh " <<<"$OUT" || fail push-dry-run "pipeline does not start with zstd -dc | ssh"
grep -q "\-\-transform='s#^docker/plex/seerr/config#seerr#' --transform='s#^docker/plex/config#plex#' --transform='s#^docker/plex/tautulli#tautulli#' --transform='s#^docker/servarr/animesonarr#sonarr-anime#' --transform='s#^docker/servarr/##'" <<<"$OUT" \
  || fail push-dry-run "--transform rules missing or out of order"
grep -qF "next (on the VM): sudo scripts/vm/10-restore-appdata.sh --stage $TS1" <<<"$OUT" || fail push-dry-run "next command not printed"
no_secrets push-dry-run "$OUT"
ok push-dry-run

# --- push CLI errors: missing/invalid VM_HOST, bad --stage, unknown flag ----------
run_capture env -u VM_HOST "$PUSH"
expect push-no-vm-host 1 'VM_HOST is required'
run_capture env VM_HOST='media@vm;id' "$PUSH"
[[ $RC -eq 1 ]] || fail push-bad-vm-host "exit $RC"
run_capture "$PUSH" --stage 2026-09-28
[[ $RC -eq 1 ]] || fail push-bad-stage "exit $RC"
run_capture "$PUSH" --stage
[[ $RC -eq 2 ]] || fail push-stage-no-arg "exit $RC"
run_capture "$PUSH" --bogus
[[ $RC -eq 2 ]] || fail push-unknown-flag "exit $RC"
run_capture env ARCHIVE="$T/missing.tar.zst" "$PUSH"
[[ $RC -eq 1 ]] || fail push-missing-archive "exit $RC"
ok push-cli-errors

# --- 2: push apply ------------------------------------------------------------------
if [[ $HAVE_SUDO -eq 1 ]]; then
  run_capture "${SUDO[@]}" "$PUSH" --stage "$TS1" --apply
  fix_owner
  [[ $RC -eq 0 ]] || fail push-apply "exit $RC"
  st="$T/vm/.staging/$TS1"
  [[ "$(names "$st")" == "$EXPECTED_NAMES" ]] || fail push-apply "stage does not hold exactly the 9 names"
  [[ "$(stat -c %a "$st")" == 700 ]] || fail push-apply "stage mode is not 700"
  bad="$(find "$st" \( -name Cache -o -name logs -o -name Logs -o -name Backups -o -name backups \
    -o -name 'Crash Reports' -o -name nzbget -o -name bazarr -o -name _inspect.json -o -name '*.pid' \) -print)"
  [[ -z "$bad" ]] || fail push-apply "excluded entries were extracted: $bad"
  [[ -f "$st/seerr/settings.json" && -f "$st/sonarr-anime/config.xml" && -f "$st/plex/$PREFS" ]] \
    || fail push-apply "renamed members missing"
  [[ -L "$st/sonarr/MediaCover/link" && "$(readlink "$st/sonarr/MediaCover/link")" == ../config.xml ]] \
    || fail push-apply "in-tree symlink not preserved"
  [[ ! -e "$T/vm/docker" && ! -e "$T/vm/_inspect.json" ]] || fail push-apply "archive content outside the stage"
  grep -qF "staged $TS1 on media@vm" <<<"$OUT" || fail push-apply "missing 'staged' line"
  no_secrets push-apply "$OUT"
  no_secrets push-apply-ssh-argv "$(cat "$T/logs/ssh.log")"
  ok push-apply
else
  skip "push-apply (no sudo)"
fi

# --- 3: push, ssh down --------------------------------------------------------------
run_capture env STUB_SSH_RC=255 "$PUSH" --stage 20260928-120100
[[ $RC -eq 1 ]] || fail push-ssh-down "exit $RC"
grep -q 'ssh-copy-id' <<<"$OUT" || fail push-ssh-down "no ssh-copy-id hint"
ok push-ssh-down

# --- 4: push, stage already exists --------------------------------------------------
mkdir -p "$T/vm/.staging/20260928-120200"
run_capture "$PUSH" --stage 20260928-120200
[[ $RC -eq 1 ]] || fail push-stage-exists "exit $RC"
grep -q 'already exists' <<<"$OUT" || fail push-stage-exists "no 'already exists' message"
[[ -z "$(ls -A "$T/vm/.staging/20260928-120200")" ]] || fail push-stage-exists "existing stage was written to"
rmdir "$T/vm/.staging/20260928-120200"
ok push-stage-exists

# ==============================================================================
# 10-restore-appdata.sh
# ==============================================================================

# --- 5: restore dry-run -------------------------------------------------------------
[[ -d "$T/vm/.staging/$TS1" ]] || make_stage "$TS1"
before="$(tree_sig "$T/vm/.staging/$TS1")"
: > "$T/logs/docker.log"
run_capture "$RESTORE" --stage "$TS1"
[[ $RC -eq 0 ]] || fail restore-dry-run "exit $RC"
grep -q '^DRY-RUN: mv -T ' <<<"$OUT" || fail restore-dry-run "no DRY-RUN mv -T lines"
grep -q '^DRY-RUN: write baseline ' <<<"$OUT" || fail restore-dry-run "no DRY-RUN baseline line"
grep -qF "DRY-RUN: record installed services in $T/vm/.rollback/$TS1/installed: lidarr plex prowlarr radarr sabnzbd seerr sonarr sonarr-anime tautulli" <<<"$OUT" \
  || fail restore-dry-run "no DRY-RUN line for .rollback/<ts>/installed"
[[ ! -e "$T/vm/.rollback" ]] || fail restore-dry-run "dry-run created .rollback"
grep -q 'integrity ok: radarr/radarr.db' <<<"$OUT" || fail restore-dry-run "integrity check did not run in dry-run"
grep -q 'stale TranscoderTempDirectory="/data/transcode"' <<<"$OUT" || fail restore-dry-run "stale TranscoderTempDirectory not reported"
if grep -q 'WARN\] [a-z-]* UrlBase=' <<<"$OUT"; then fail restore-dry-run "unexpected UrlBase warning"; fi
[[ ! -e "$T/vm/sonarr" ]] || fail restore-dry-run "dry-run created $T/vm/sonarr"
[[ "$(tree_sig "$T/vm/.staging/$TS1")" == "$before" ]] || fail restore-dry-run "dry-run changed the stage"
grep -q -- "compose --project-directory $REPO ps --status running --services" "$T/logs/docker.log" \
  || fail restore-dry-run "docker compose not called with --project-directory"
no_secrets restore-dry-run "$OUT"
ok restore-dry-run

# --- restore CLI errors -------------------------------------------------------------
run_capture "$RESTORE" --bogus
[[ $RC -eq 2 ]] || fail restore-unknown-flag "exit $RC"
run_capture "$RESTORE" --stage "$TS1" --rollback "$TS1"
[[ $RC -eq 2 ]] || fail restore-both-modes "exit $RC"
run_capture "$RESTORE" --rollback
[[ $RC -eq 2 ]] || fail restore-rollback-no-arg "exit $RC"
run_capture "$RESTORE" --stage 'x;id'
[[ $RC -eq 1 ]] || fail restore-bad-stage "exit $RC"
run_capture "$RESTORE" --stage 20991231-000000
expect restore-missing-stage 1 'not found'
ok restore-cli-errors

# --- 6: restore apply ---------------------------------------------------------------
if [[ $HAVE_SUDO -eq 1 ]]; then
  mkdir -p "$T/vm/plex" "$T/vm/radarr"
  echo old > "$T/vm/radarr/old.txt"
  echo 1 > "$T/vm/.staging/$TS1/sonarr/sonarr.pid"
  : > "$T/logs/setpriv.log"
  run_capture "${SUDO[@]}" "$RESTORE" --stage "$TS1" --apply
  base_uid="$(stat -c %u "$T/vm/.migration/baseline.json" 2>/dev/null || echo none)"
  fix_owner
  [[ $RC -eq 0 ]] || fail restore-apply "exit $RC"
  [[ -d "$T/vm/plex/Library" && ! -e "$T/vm/plex/plex" ]] || fail restore-apply "plex not swapped in, or nested"
  [[ -f "$T/vm/.rollback/$TS1/radarr/old.txt" ]] || fail restore-apply "old radarr not saved to .rollback"
  [[ -f "$T/vm/radarr/radarr.db" && ! -e "$T/vm/radarr/radarr" ]] || fail restore-apply "radarr not swapped in, or nested"
  [[ ! -e "$T/vm/.rollback/$TS1/plex" ]] || fail restore-apply "empty plex dir was saved instead of removed"
  [[ "$(sort "$T/vm/.rollback/$TS1/installed")" == "$EXPECTED_NAMES" ]] \
    || fail restore-apply ".rollback/$TS1/installed does not list the 9 services"
  [[ "$(stat -c %a "$T/vm/sonarr")" == 700 ]] || fail restore-apply "sonarr mode is not 700"
  [[ -z "$(find "$T/vm/sonarr" -name '*.pid')" ]] || fail restore-apply "*.pid not deleted"
  grep -q 'autoEmptyTrash="0"' "$T/vm/plex/$PREFS" || fail restore-apply "autoEmptyTrash not 0"
  if grep -q 'TranscoderTempDirectory' "$T/vm/plex/$PREFS"; then fail restore-apply "TranscoderTempDirectory not removed"; fi
  grep -q 'PlexOnlineToken="dummytoken0123456789"' "$T/vm/plex/$PREFS" || fail restore-apply "other Plex prefs were damaged"
  grep -qx 'download_dir = /data/usenet/incomplete' "$T/vm/sabnzbd/sabnzbd.ini" || fail restore-apply "SAB download_dir"
  grep -qx 'complete_dir = /data/usenet/complete' "$T/vm/sabnzbd/sabnzbd.ini" || fail restore-apply "SAB complete_dir"
  [[ -f "$T/vm/.rollback/$TS1/sabnzbd-admin/queue10.sab" && ! -e "$T/vm/sabnzbd/admin" ]] || fail restore-apply "SAB admin/ not moved aside"
  for d in sonarr-4k radarr-4k jellyfin; do
    [[ -d "$T/vm/$d" && "$(stat -c %a "$T/vm/$d")" == 700 ]] || fail restore-apply "fresh dir $d missing or not 700"
  done
  b="$T/vm/.migration/baseline.json"
  jq -e '.files.sonarr>0 and .plex_watched==2' "$b" >/dev/null || fail restore-apply "baseline sonarr/plex_watched"
  jq -e --arg ts "$TS1" '.stage==$ts and (.created|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
    and .files=={"sonarr":3,"sonarr-anime":1,"radarr":2,"lidarr":4}
    and .items_with_files=={"sonarr":2,"sonarr-anime":1,"radarr":2}
    and (.warnings|length==1) and (.warnings[0]|test("TranscoderTempDirectory"))' "$b" >/dev/null \
    || fail restore-apply "baseline.json shape/values: $(cat "$b")"
  [[ "$base_uid" == "$PUID" && "$(stat -c %a "$b")" == 600 && "$(stat -c %a "$T/vm/.migration")" == 700 ]] \
    || fail restore-apply "baseline owner/mode"
  expected_ids="$(sqlite3 "$S/servarr/sonarr/sonarr.db" 'select Id from Episodes where EpisodeFileId>0;')"
  [[ "$(cat "$T/vm/.migration/baseline-ids/sonarr.txt")" == "$expected_ids" && "$expected_ids" == $'100\n101\n103' ]] \
    || fail restore-apply "baseline-ids/sonarr.txt"
  [[ "$(cat "$T/vm/.migration/baseline-ids/radarr.txt")" == $'1\n2' ]] || fail restore-apply "baseline-ids/radarr.txt"
  grep -q -- "--reuid=$PUID --regid=$PGID --init-groups sqlite3 -readonly .*radarr/radarr.db PRAGMA integrity_check;" "$T/logs/setpriv.log" \
    || fail restore-apply "integrity check not run through setpriv as PUID"
  [[ ! -e "$T/vm/.staging/$TS1" ]] || fail restore-apply "stage not removed"
  grep -q "restored 9 services from $TS1; next: docker compose up -d sonarr sonarr-anime radarr lidarr" <<<"$OUT" \
    || fail restore-apply "final line"
  no_secrets restore-apply "$OUT"
  ok restore-apply

  # --- 7: rollback (dry-run changes nothing, then apply) -----------------------------
  before="$(tree_sig "$T/vm")"
  run_capture "$RESTORE" --rollback "$TS1"
  expect rollback-dry-run 0 '^DRY-RUN: mv -T '
  [[ "$(tree_sig "$T/vm")" == "$before" ]] || fail rollback-dry-run "dry-run changed the tree"
  run_capture "${SUDO[@]}" "$RESTORE" --rollback "$TS1" --apply
  fix_owner
  [[ $RC -eq 0 ]] || fail rollback-apply "exit $RC"
  [[ -f "$T/vm/radarr/old.txt" && ! -e "$T/vm/radarr/radarr.db" ]] || fail rollback-apply "radarr/old.txt not back"
  [[ -f "$T/vm/.rollback/$TS1-undone/radarr/radarr.db" ]] || fail rollback-apply "restored radarr not kept in -undone"
  [[ "$(names "$T/vm/.rollback/$TS1-undone")" == "$EXPECTED_NAMES" ]] || fail rollback-apply "not all 9 restored dirs in -undone"
  for d in plex seerr tautulli sonarr sonarr-anime lidarr prowlarr sabnzbd; do
    [[ ! -e "$T/vm/$d" ]] || fail rollback-apply "restored $d still live (no previous dir to put back)"
  done
  # The old queue belongs with the (now undone) restored sabnzbd config.
  [[ -f "$T/vm/.rollback/$TS1-undone/sabnzbd/admin/queue10.sab" && ! -e "$T/vm/.rollback/$TS1/sabnzbd-admin" ]] \
    || fail rollback-apply "sabnzbd-admin not moved into -undone/sabnzbd/admin"
  grep -q "rolled back $TS1" <<<"$OUT" || fail rollback-apply "no 'rolled back' line"
  ok rollback-apply
else
  skip "restore-apply (no sudo)"
  skip "rollback-apply (no sudo)"
fi

# --- 8: services running ------------------------------------------------------------
make_stage 20260928-120300
run_capture env STUB_RUNNING="traefik plex" "$RESTORE" --stage 20260928-120300
[[ $RC -eq 1 ]] || fail services-running "exit $RC"
grep -q 'docker compose stop plex' <<<"$OUT" || fail services-running "no 'docker compose stop' hint"
run_capture env STUB_RUNNING="traefik" "$RESTORE" --stage 20260928-120300
[[ $RC -eq 0 ]] || fail services-running "an unrelated running service blocked the restore"
run_capture env STUB_RUNNING="sonarr" "$RESTORE" --rollback "$TS1"
expect services-running-rollback 1 'docker compose stop sonarr'
ok services-running

# (as_apply: run the restore with --apply under sudo when possible, so the
# refusal cases prove nothing moves even in apply mode.)
as_apply() {
  if [[ $HAVE_SUDO -eq 1 ]]; then
    run_capture "${SUDO[@]}" "$RESTORE" "$@" --apply
    fix_owner
  else
    run_capture "$RESTORE" "$@"
  fi
}

# --- 9: corrupted DB: the swap never happens -----------------------------------------
TS9=20260928-120400
make_stage "$TS9"
printf 'this is not a sqlite database\n%.0s' {1..200} > "$T/vm/.staging/$TS9/radarr/radarr.db"
mkdir -p "$T/vm/radarr"
target_before="$(tree_sig "$T/vm/radarr")"
stage_before="$(tree_sig "$T/vm/.staging/$TS9")"
as_apply --stage "$TS9"
[[ $RC -eq 1 ]] || fail corrupt-db "exit $RC"
grep -q 'integrity check failed: radarr' <<<"$OUT" || fail corrupt-db "no 'integrity check failed' message"
[[ "$(tree_sig "$T/vm/radarr")" == "$target_before" ]] || fail corrupt-db "target radarr dir changed"
[[ "$(tree_sig "$T/vm/.staging/$TS9")" == "$stage_before" ]] || fail corrupt-db "stage changed"
[[ ! -e "$T/vm/.rollback/$TS9" ]] || fail corrupt-db ".rollback/$TS9 created before the integrity check"
ok corrupt-db

# --- 10: unexpected entry / escaping symlink -----------------------------------------
TS10=20260928-120500
make_stage "$TS10"
mkdir "$T/vm/.staging/$TS10/evil"
as_apply --stage "$TS10"
expect unexpected-entry 1 'unexpected entry in stage: evil'
rmdir "$T/vm/.staging/$TS10/evil"
ln -s /etc "$T/vm/.staging/$TS10/sonarr/link"
as_apply --stage "$TS10"
expect unexpected-symlink 1 'symlink leaves the stage: sonarr/link'
rm "$T/vm/.staging/$TS10/sonarr/link"
ln -s ../../../../../etc/passwd "$T/vm/.staging/$TS10/sonarr/MediaCover/rel"
as_apply --stage "$TS10"
expect unexpected-relative-symlink 1 'symlink leaves the stage: sonarr/MediaCover/rel'
[[ -d "$T/vm/.staging/$TS10/sonarr" && ! -e "$T/vm/.rollback/$TS10" ]] || fail unexpected-entry "something moved"
ok unexpected-entry

# --- 11: UrlBase / non-default port warning ------------------------------------------
TS11=20260928-120600
make_stage "$TS11"
sed -i 's#<UrlBase></UrlBase>#<UrlBase>/sonarr</UrlBase>#' "$T/vm/.staging/$TS11/sonarr/config.xml"
sed -i 's#<Port>7878</Port>#<Port>7879</Port>#' "$T/vm/.staging/$TS11/radarr/config.xml"
run_capture "$RESTORE" --stage "$TS11"
[[ $RC -eq 0 ]] || fail urlbase-warning "exit $RC"
grep -q '\[WARN\] sonarr UrlBase=/sonarr Port=8989' <<<"$OUT" || fail urlbase-warning "no sonarr UrlBase warning"
grep -q '\[WARN\] radarr UrlBase= Port=7879' <<<"$OUT" || fail urlbase-warning "no radarr Port warning"
no_secrets urlbase-warning "$OUT"
ok urlbase-warning

# --- 12: Preferences.xml missing -----------------------------------------------------
TS12=20260928-120700
make_stage "$TS12"
rm "$T/vm/.staging/$TS12/plex/$PREFS"
run_capture "$RESTORE" --stage "$TS12"
[[ $RC -eq 0 ]] || fail prefs-missing "exit $RC"
grep -q '\[WARN\] Preferences.xml missing' <<<"$OUT" || fail prefs-missing "no warning"
ok prefs-missing

# --- 13: first restore into an empty appdata root ------------------------------------
if [[ $HAVE_SUDO -eq 1 ]]; then
  TS13=20260928-120800
  mkdir -p "$T/vm2"
  make_stage "$TS13" "$T/vm2"
  # A planted symlink in the PUID-owned baseline dir must be replaced, not
  # written through.
  mkdir -p "$T/vm2/.migration/baseline-ids"
  echo outside > "$T/outside.txt"
  outside_before="$(md5sum < "$T/outside.txt")"
  ln -s "$T/outside.txt" "$T/vm2/.migration/baseline-ids/radarr.txt"
  run_capture env APPDATA_ROOT="$T/vm2" "${SUDO[@]}" "$RESTORE" --stage "$TS13" --apply
  base_uid="$(stat -c %u "$T/vm2/.migration/baseline.json" 2>/dev/null || echo none)"
  ids_uid="$(stat -c %u "$T/vm2/.migration/baseline-ids/sonarr.txt" 2>/dev/null || echo none)"
  fix_owner
  [[ $RC -eq 0 ]] || fail first-restore "exit $RC"
  [[ -f "$T/vm2/.rollback/$TS13/sabnzbd-admin/queue10.sab" ]] || fail first-restore "sabnzbd-admin not in .rollback/$TS13"
  [[ "$(names "$T/vm2/.rollback/$TS13")" == $'installed\nsabnzbd-admin' ]] || fail first-restore "unexpected entries saved to .rollback"
  [[ "$(md5sum < "$T/outside.txt")" == "$outside_before" ]] || fail first-restore "baseline write went through a symlink"
  [[ -f "$T/vm2/.migration/baseline-ids/radarr.txt" && ! -L "$T/vm2/.migration/baseline-ids/radarr.txt" \
    && "$(cat "$T/vm2/.migration/baseline-ids/radarr.txt")" == $'1\n2' ]] \
    || fail first-restore "baseline-ids/radarr.txt is not a regular file with the ids"
  [[ "$base_uid" == "$PUID" && "$ids_uid" == "$PUID" ]] || fail first-restore "baseline not owned by PUID ($base_uid)"
  [[ "$(names "$T/vm2")" == "$(printf '%s\n' .migration .rollback .staging jellyfin radarr-4k sonarr-4k "$EXPECTED_NAMES" | sort)" ]] \
    || fail first-restore "unexpected appdata layout"
  ok first-restore

  # --- 13b: rollback after a first restore: everything restored is undone ---------
  run_capture env APPDATA_ROOT="$T/vm2" "${SUDO[@]}" "$RESTORE" --rollback "$TS13" --apply
  fix_owner
  [[ $RC -eq 0 ]] || fail first-rollback "exit $RC"
  if grep -q 'installed missing' <<<"$OUT"; then fail first-rollback "fell back to the legacy rollback"; fi
  [[ "$(names "$T/vm2/.rollback/$TS13-undone")" == "$EXPECTED_NAMES" ]] || fail first-rollback "not all 9 dirs in -undone"
  for d in $EXPECTED_NAMES; do
    [[ ! -e "$T/vm2/$d" ]] || fail first-rollback "$d still live"
  done
  [[ -z "$(find "$T/vm2" -path "$T/vm2/.rollback" -prune -o -path '*/sabnzbd/admin' -print)" ]] \
    || fail first-rollback "a sabnzbd/admin dir is live"
  [[ -f "$T/vm2/.rollback/$TS13-undone/sabnzbd/admin/queue10.sab" ]] || fail first-rollback "queue not in -undone/sabnzbd/admin"
  grep -q "rolled back $TS13" <<<"$OUT" || fail first-rollback "no 'rolled back' line"
  ok first-rollback
else
  skip "first-restore (no sudo)"
  skip "first-rollback (no sudo)"
fi

# --- 13c: rollback of a restore made before .rollback/<ts>/installed existed ------
TS13C=20260928-120850
mkdir -p "$T/vm4/.rollback/$TS13C/radarr" "$T/vm4/radarr"
run_capture env APPDATA_ROOT="$T/vm4" "$RESTORE" --rollback "$TS13C"
expect legacy-rollback 0 'installed missing'
grep -qF "DRY-RUN: mv -T $T/vm4/.rollback/$TS13C/radarr $T/vm4/radarr" <<<"$OUT" || fail legacy-rollback "saved radarr not moved back"
ok legacy-rollback

# --- 14: old root present --------------------------------------------------------------
TS14=20260928-120900
make_stage "$TS14"
mkdir "$DATA_ROOT/shows"
stage_before="$(tree_sig "$T/vm/.staging/$TS14")"
as_apply --stage "$TS14"
[[ $RC -eq 1 ]] || fail old-root "exit $RC"
grep -qF "$DATA_ROOT/shows exists" <<<"$OUT" || fail old-root "old root not named"
[[ "$(tree_sig "$T/vm/.staging/$TS14")" == "$stage_before" && ! -e "$T/vm/.rollback/$TS14" ]] || fail old-root "something moved"
rmdir "$DATA_ROOT/shows"
ok old-root

# --- 15: failure after the swap: recovery is named, and --rollback cleans up ------
if [[ $HAVE_SUDO -eq 1 ]]; then
  TS15=20260928-121000
  mkdir -p "$T/vm3/radarr"
  echo old > "$T/vm3/radarr/old.txt"
  radarr_before="$(tree_sig "$T/vm3/radarr")"
  make_stage "$TS15" "$T/vm3"
  # No autoEmptyTrash attribute and no "/>" to insert it before: the
  # post-sed check in step 4 fails.
  printf '<Preferences PlexOnlineToken="dummytoken0123456789">\n</Preferences>\n' > "$T/vm3/.staging/$TS15/plex/$PREFS"
  run_capture env APPDATA_ROOT="$T/vm3" "${SUDO[@]}" "$RESTORE" --stage "$TS15" --apply
  fix_owner
  [[ $RC -ne 0 ]] || fail fail-after-swap "exit 0"
  grep -q 'could not set autoEmptyTrash' <<<"$OUT" || fail fail-after-swap "step 4 did not fail as set up"
  grep -qF "steps not completed: 4 plex prefs, 5 sabnzbd, 6 UrlBase report, 7 fresh dirs, 8 baseline, 9 remove stage" <<<"$OUT" \
    || fail fail-after-swap "incomplete steps not named"
  grep -qF "recover: sudo scripts/vm/10-restore-appdata.sh --rollback $TS15 --apply" <<<"$OUT" \
    || fail fail-after-swap "rollback command not named"
  grep -qF "qm rollback 200 pre-phase2" <<<"$OUT" || fail fail-after-swap "VM snapshot rollback not named"
  no_secrets fail-after-swap "$OUT"
  run_capture env APPDATA_ROOT="$T/vm3" "${SUDO[@]}" "$RESTORE" --rollback "$TS15" --apply
  fix_owner
  [[ $RC -eq 0 ]] || fail fail-after-swap-rollback "exit $RC"
  [[ "$(names "$T/vm3")" == $'.rollback\n.staging\nradarr' ]] || fail fail-after-swap-rollback "appdata not back to its pre-restore layout"
  [[ "$(tree_sig "$T/vm3/radarr")" == "$radarr_before" ]] || fail fail-after-swap-rollback "previous radarr not restored"
  [[ "$(names "$T/vm3/.rollback/$TS15-undone")" == "$EXPECTED_NAMES" ]] || fail fail-after-swap-rollback "restored dirs not in -undone"
  ok fail-after-swap
else
  skip "fail-after-swap (no sudo)"
fi

no_secrets ssh-argv "$(cat "$T/logs/ssh.log")"
printf 'all restore tests passed\n'
