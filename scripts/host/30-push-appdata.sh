#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# .env first, then defaults, so .env values are not masked by the defaults.
# ARCHIVE's default (the newest archive) is resolved after argument parsing,
# so --help works on a machine without /tank/migration.
load_env
VM_HOST="${VM_HOST:-}"
ARCHIVE="${ARCHIVE:-}"
REMOTE_APPDATA="${REMOTE_APPDATA:-/opt/appdata}"

# Fixed allow-list: archive member -> staged name on the VM. Nothing else in
# the archive (bazarr, nzbget, fileflows, the _*.txt/_*.json dumps) is ever
# extracted.
MEMBERS=(
  docker/plex/config
  docker/plex/seerr/config
  docker/plex/tautulli
  docker/servarr/sonarr
  docker/servarr/animesonarr
  docker/servarr/radarr
  docker/servarr/lidarr
  docker/servarr/prowlarr
  docker/servarr/sabnzbd
)
NAMES=(plex seerr tautulli sonarr sonarr-anime radarr lidarr prowlarr sabnzbd)

# Matched against the original member names (before --transform).
EXCLUDES=(
  'docker/*/*/logs'
  'docker/*/*/Logs'
  '*.pid'
  'docker/plex/config/Library/Application Support/Plex Media Server/Cache'
  'docker/plex/config/Library/Application Support/Plex Media Server/Crash Reports'
  'docker/plex/config/Library/Application Support/Plex Media Server/Logs'
  'docker/servarr/*/Backups'
  'docker/servarr/*/backups'
)

# GNU tar applies these in order, each to the previous result. The
# docker/plex/* rules come before the generic docker/servarr/ strip, and no
# rule matches another rule's output.
TRANSFORMS=(
  's#^docker/plex/seerr/config#seerr#'
  's#^docker/plex/config#plex#'
  's#^docker/plex/tautulli#tautulli#'
  's#^docker/servarr/animesonarr#sonarr-anime#'
  's#^docker/servarr/##'
)

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

usage() {
  cat <<EOF
Stream the allow-listed old app configs from the migration archive on this
Proxmox host into a staging dir on the media VM, over ssh.

The host only decompresses (zstd -dc) and pipes the stream to
'ssh \$VM_HOST tar -x', which runs as the VM user. Filtering and renaming
happen on the VM, into \$REMOTE_APPDATA/.staging/<ts> (mode 700). No temp
dir is used on the host and nothing is written to /tank/data or /data.
Only these 9 members are extracted:
  docker/plex/config -> plex          docker/servarr/radarr   -> radarr
  docker/plex/seerr/config -> seerr   docker/servarr/lidarr   -> lidarr
  docker/plex/tautulli -> tautulli    docker/servarr/prowlarr -> prowlarr
  docker/servarr/sonarr -> sonarr     docker/servarr/sabnzbd  -> sabnzbd
  docker/servarr/animesonarr -> sonarr-anime

Dry-run by default: runs the read-only ssh prechecks, then prints the
commands it would run. Pass --apply to actually run them; --apply requires
root.

Usage: 30-push-appdata.sh [--stage <ts>] [--apply] [--help]

Options:
  --stage <ts>   Staging name, YYYYMMDD-HHMMSS (default: now). Must not
                 already exist on the VM.

Environment variables (defaults):
  VM_HOST=<required>          ssh target, user@host (e.g. media@192.168.50.16).
  ARCHIVE=<newest /tank/migration/old-docker-*.tar.zst>
  REMOTE_APPDATA=$REMOTE_APPDATA  appdata root on the VM.

Example:
  VM_HOST=media@192.168.50.16 scripts/host/30-push-appdata.sh --apply

Next step (printed at the end): on the VM,
  sudo scripts/vm/10-restore-appdata.sh --stage <ts>
EOF
}

# --- arguments: --stage is parsed locally, the rest by parse_common_args ----
TS=""
rest=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      TS="$2"
      shift 2
      ;;
    *)
      rest+=("$1")
      shift
      ;;
  esac
done
parse_common_args "${rest[@]}"
TS="${TS:-$(date +%Y%m%d-%H%M%S)}"

# --- validation (every value that reaches run_sh is checked here) -----------
if [[ -z "$VM_HOST" ]]; then
  usage >&2
  die "VM_HOST is required (e.g. VM_HOST=media@192.168.50.16)"
fi
require_match VM_HOST "$VM_HOST" '^[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+$' "user@host, e.g. media@192.168.50.16"
require_match "--stage" "$TS" '^[0-9]{8}-[0-9]{6}$' "YYYYMMDD-HHMMSS"
require_safe_path REMOTE_APPDATA "$REMOTE_APPDATA"
if [[ -z "$ARCHIVE" ]]; then
  # find, not ls (SC2012); newest by mtime.
  ARCHIVE="$(find /tank/migration -maxdepth 1 -name 'old-docker-*.tar.zst' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2- || true)"
  [[ -n "$ARCHIVE" ]] || die "no /tank/migration/old-docker-*.tar.zst found; set ARCHIVE"
fi
require_safe_path ARCHIVE "$ARCHIVE"
[[ -f "$ARCHIVE" ]] || die "ARCHIVE=$ARCHIVE is not a regular file"
require_root
require_cmd zstd ssh tar

DEST="$REMOTE_APPDATA/.staging/$TS"

# --- 1: what will be staged --------------------------------------------------
log_info "archive: $ARCHIVE"
log_info "members:"
for i in "${!MEMBERS[@]}"; do
  log_info "  ${MEMBERS[$i]} -> ${NAMES[$i]}"
done

# --- 2: ssh precheck (read-only, so it also runs in dry-run) -----------------
if ! ssh "${SSH_OPTS[@]}" "$VM_HOST" true; then
  die "cannot ssh to $VM_HOST non-interactively; install root's key first: ssh-copy-id -i /root/.ssh/id_ed25519.pub \"$VM_HOST\""
fi

# --- 3: the stage must not exist yet (read-only) -----------------------------
rc=0
# shellcheck disable=SC2029  # DEST is validated and meant to expand here
ssh "${SSH_OPTS[@]}" "$VM_HOST" "test ! -e '$DEST'" || rc=$?
if [[ $rc -eq 1 ]]; then
  die "stage already exists on $VM_HOST: $DEST; pick another --stage or remove it"
elif [[ $rc -ne 0 ]]; then
  die "ssh $VM_HOST failed (rc=$rc) while checking $DEST"
fi

# --- 4: one pipeline: decompress here, filter/rename/extract on the VM -------
# Built only from the fixed literals above plus the validated DEST; none of
# them contains a quote, $ or backtick, so the nesting below is safe.
remote="mkdir -p -m 700 '$DEST' && tar -x -C '$DEST' --wildcards"
for e in "${EXCLUDES[@]}"; do
  remote+=" --exclude='$e'"
done
for t in "${TRANSFORMS[@]}"; do
  remote+=" --transform='$t'"
done
for m in "${MEMBERS[@]}"; do
  remote+=" '$m'"
done
run_sh "zstd -dc -- '$ARCHIVE' | ssh ${SSH_OPTS[*]} '$VM_HOST' \"$remote\""

# --- 5: the stage holds exactly the 9 names ----------------------------------
list_cmd="ssh ${SSH_OPTS[*]} '$VM_HOST' \"ls -1 '$DEST'\""
if [[ $APPLY -eq 1 ]]; then
  actual="$(run_sh "$list_cmd" | sort)"
  expected="$(printf '%s\n' "${NAMES[@]}" | sort)"
  if [[ "$actual" != "$expected" ]]; then
    die "staged entries in $DEST differ from the allow-list: got [$(tr '\n' ' ' <<<"$actual")] expected [$(tr '\n' ' ' <<<"$expected")]"
  fi
else
  run_sh "$list_cmd"
fi

# --- 6: next step ------------------------------------------------------------
if [[ $APPLY -eq 1 ]]; then
  log_info "staged $TS on $VM_HOST"
else
  log_info "dry-run: would stage $TS on $VM_HOST (re-run with --apply)"
fi
log_info "next (on the VM): sudo scripts/vm/10-restore-appdata.sh --stage $TS"
