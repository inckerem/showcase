#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEB="${1:-}"
REMOTE_BASE="${REMOTE_BASE:-/tmp/showcase-deb-inspect}"

IPAD_HOST="${IPAD_HOST:-localhost}"
IPAD_PORT="${IPAD_PORT:-2222}"
IPAD_USER="${IPAD_USER:-root}"
IPAD_PASS="${IPAD_PASS:-alpine}"

if [ -z "$DEB" ]; then
  shopt -s nullglob
  candidates=("$ROOT"/build/*.deb)
  if [ "${#candidates[@]}" -ne 1 ]; then
    echo "Expected exactly one deb in $ROOT/build; specify the package path explicitly (found ${#candidates[@]})." >&2
    exit 1
  fi
  DEB="${candidates[0]}"
fi

if [ ! -f "$DEB" ]; then
  echo "Usage: $0 path/to/package.deb"
  exit 1
fi

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -p "$IPAD_PORT"
)

SCP_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -P "$IPAD_PORT"
)

# REMOTE_BASE is a pathname prefix, never a directory to remove. Restrict it
# before embedding it in a remote shell command.
if [[ ! "$REMOTE_BASE" =~ ^/([a-zA-Z0-9_-][a-zA-Z0-9._-]*/)*[a-zA-Z0-9_-][a-zA-Z0-9._-]*$ ]]; then
  echo "REMOTE_BASE must be an absolute path prefix containing only letters, digits, '.', '_' or '-'." >&2
  exit 1
fi

REMOTE_DIR="$(sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" \
  "umask 077; mktemp -d '${REMOTE_BASE}.XXXXXX'")"
REMOTE_SUFFIX="${REMOTE_DIR#"$REMOTE_BASE".}"
if [[ "$REMOTE_SUFFIX" == "$REMOTE_DIR" || ! "$REMOTE_SUFFIX" =~ ^[a-zA-Z0-9]{6}$ ]]; then
  echo "Remote mktemp returned an unexpected path; refusing to use it." >&2
  exit 1
fi

cleanup() {
  if ! sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" \
    "rm -f '$REMOTE_DIR/package.deb' && rmdir '$REMOTE_DIR'"; then
    echo "Could not remove temporary directory: $REMOTE_DIR" >&2
  fi
}
trap cleanup EXIT

sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" "$DEB" "$IPAD_USER@$IPAD_HOST:$REMOTE_DIR/package.deb"

sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" "
set -e
dpkg-deb -I '$REMOTE_DIR/package.deb'
echo
dpkg-deb -c '$REMOTE_DIR/package.deb'
"
