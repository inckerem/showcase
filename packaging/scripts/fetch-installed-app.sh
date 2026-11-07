#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$ROOT/payload/Applications"

IPAD_HOST="${IPAD_HOST:-localhost}"
IPAD_PORT="${IPAD_PORT:-2222}"
IPAD_USER="${IPAD_USER:-root}"
IPAD_PASS="${IPAD_PASS:-alpine}"
REMOTE_APP="${REMOTE_APP:-/Applications/Showcase.app}"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -p "$IPAD_PORT"
)

SCP_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -P "$IPAD_PORT"
  -rp
)

mkdir -p "$PAYLOAD"
STAGE="$(mktemp -d "$PAYLOAD/.showcase-fetch.XXXXXX")"
cleanup() {
  if [ -e "$STAGE/previous.app" ]; then
    echo "Previous payload preserved at $STAGE/previous.app" >&2
  else
    rm -rf "$STAGE"
  fi
}
trap cleanup EXIT

sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" \
  "test -d '$REMOTE_APP' && test -x '$REMOTE_APP/Showcase' && test -x '$REMOTE_APP/carplay_bt' && test -x '$REMOTE_APP/carplay_services'"

sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" \
  "$IPAD_USER@$IPAD_HOST:$REMOTE_APP" \
  "$STAGE/Showcase.app"

for binary in Showcase carplay_bt carplay_services; do
  if [ ! -x "$STAGE/Showcase.app/$binary" ]; then
    echo "Downloaded app is missing executable: $binary" >&2
    exit 1
  fi
done
find "$STAGE/Showcase.app" -name '.DS_Store' -delete

if [ -e "$PAYLOAD/Showcase.app" ]; then
  mv "$PAYLOAD/Showcase.app" "$STAGE/previous.app"
fi
if ! mv "$STAGE/Showcase.app" "$PAYLOAD/Showcase.app"; then
  if [ -e "$STAGE/previous.app" ]; then
    mv "$STAGE/previous.app" "$PAYLOAD/Showcase.app" || true
  fi
  exit 1
fi

echo "Fetched signed app payload into $PAYLOAD/Showcase.app"
