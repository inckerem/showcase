#!/bin/sh
# Copy app and SpringBoard crash reports without removing them from the iPad.
set -eu
if ! command -v idevice_id >/dev/null || ! command -v idevicecrashreport >/dev/null; then
  echo 'Missing libimobiledevice. Install it before collecting crash reports.' >&2
  exit 1
fi
if [ -z "$(idevice_id -l)" ]; then
  echo 'No iOS device detected. Connect and unlock the iPad and trust this Mac.' >&2
  exit 1
fi
umask 077
TASK_REPORT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/showcase-crash.XXXXXX")
mkdir -p "$TASK_REPORT_DIR/Showcase" "$TASK_REPORT_DIR/SpringBoard"
idevicecrashreport -k -f Showcase "$TASK_REPORT_DIR/Showcase"
idevicecrashreport -k -f SpringBoard "$TASK_REPORT_DIR/SpringBoard"
echo "Showcase and SpringBoard reports copied to $TASK_REPORT_DIR"
echo 'Reports can contain device and network information; review before sharing.'
