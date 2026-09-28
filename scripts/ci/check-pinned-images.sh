#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<EOF
Fail if any image in a compose file's resolved config is unpinned (no tag,
or the tag "latest"). A digest reference (@sha256:...) or any explicit tag
other than "latest" is accepted.

Usage: check-pinned-images.sh [compose-file] [--help]

Arguments:
  compose-file    Path to the compose file to check (default: compose.yaml
                   at the repo root).
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

FILE="${1:-$REPO_ROOT/compose.yaml}"

require_cmd docker

images=""
if docker compose -f "$FILE" config --images >/dev/null 2>&1; then
  images="$(docker compose -f "$FILE" config --images)"
else
  require_cmd python3
  json="$(docker compose -f "$FILE" config --format json)"
  images="$(python3 -c '
import json, sys
data = json.load(sys.stdin)
for svc in data.get("services", {}).values():
    image = svc.get("image")
    if image:
        print(image)
' <<<"$json")"
fi

unpinned=0
count=0

while IFS= read -r image; do
  [[ -z "$image" ]] && continue
  count=$((count + 1))

  if [[ "$image" == *"@sha256:"* ]]; then
    continue
  fi

  last_component="${image##*/}"
  if [[ "$last_component" == *:* ]]; then
    tag="${last_component##*:}"
    if [[ "$tag" != "latest" ]]; then
      continue
    fi
  fi

  printf 'UNPINNED: %s\n' "$image"
  unpinned=$((unpinned + 1))
done <<<"$images"

if [[ $unpinned -gt 0 ]]; then
  exit 1
fi

printf 'OK: %d images pinned\n' "$count"
exit 0
