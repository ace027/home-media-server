# shellcheck shell=bash
# scripts/lib/common.sh
#
# Shared library for host/VM scripts: logging, common CLI arg parsing,
# a dry-run command runner, and safe .env loading.
#
# This file is meant to be *sourced*, not executed:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
# It intentionally has no shebang execution path of its own.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# APPLY=0 means dry-run (default); APPLY=1 means mutating commands execute.
APPLY=0

log_info() {
  printf '[INFO] %s\n' "$*" >&2
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

# parse_common_args "$@"
#
# Recognizes:
#   --apply    sets APPLY=1
#   -h|--help  calls the caller-defined `usage` function and exits 0
#   anything else: prints the caller's `usage` to stderr and exits 2 (usage error)
#
# Any script sourcing this file must define a `usage` function before calling
# parse_common_args.
parse_common_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --apply)
        APPLY=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done
}

# run <cmd...>
#
# When APPLY=1, executes the command. Otherwise prints "DRY-RUN: <cmd>" to
# stdout (shell-quoted, so the line can be copy-pasted) and does not execute
# it. Always exits 0 in dry-run mode.
run() {
  if [[ $APPLY -eq 1 ]]; then
    "$@"
  else
    local arg out=""
    for arg in "$@"; do
      if [[ -n $arg && $arg != *[!A-Za-z0-9_./:=,@%+-]* ]]; then
        out+="$arg "
      else
        out+="'${arg//\'/\'\\\'\'}' "
      fi
    done
    printf 'DRY-RUN: %s\n' "${out% }"
  fi
}

# run_sh <string>
#
# For commands that need shell features (redirection, pipes, globs) that
# `run` (which uses "$@" directly) cannot express. When APPLY=1, executes
# the string with `bash -c`. Otherwise prints "DRY-RUN: <string>".
run_sh() {
  local cmd_string="$1"
  if [[ $APPLY -eq 1 ]]; then
    bash -c "$cmd_string"
  else
    printf 'DRY-RUN: %s\n' "$cmd_string"
  fi
}

# require_root
#
# Dies when APPLY=1 and the effective user is not root. Root is not required
# for a dry run, so callers can preview output as any user.
require_root() {
  if [[ $APPLY -eq 1 && $EUID -ne 0 ]]; then
    die "must run as root with --apply"
  fi
}

# require_cmd <names...>
#
# Dies if any of the named commands are not found on PATH.
require_cmd() {
  local name
  for name in "$@"; do
    if ! command -v "$name" >/dev/null 2>&1; then
      die "missing required command: $name"
    fi
  done
}

# load_env
#
# If $REPO_ROOT/.env exists, reads KEY=VALUE lines (skipping blank lines and
# lines starting with #) and exports each KEY that is not already set in the
# environment. Never sources the file directly, so it cannot execute
# arbitrary shell content.
load_env() {
  local env_file="$REPO_ROOT/.env"
  [[ -f "$env_file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines and comments.
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Only accept simple KEY=VALUE lines.
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # Strip a single layer of matching surrounding quotes, if present.
    if [[ "$value" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    if [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done < "$env_file"
}
