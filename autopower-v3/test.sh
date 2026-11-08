#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/showcase-v3-tests.XXXXXX")"
trap 'rm -rf "$TASK_TMP"' EXIT
cd "$ROOT"
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -Wno-cast-function-type-mismatch \
  -framework Foundation -framework CoreFoundation -framework IOKit autopower-v3/test_daemon.m -o "$TASK_TMP/daemon-test"
"$TASK_TMP/daemon-test"
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -Wno-cast-function-type-mismatch \
  -framework Foundation -framework CoreFoundation -framework IOKit autopower-v3/test_daemon_integration.m -o "$TASK_TMP/daemon-integration-test"
"$TASK_TMP/daemon-integration-test"
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -Wno-cast-function-type-mismatch \
  -DSHOWCASE_APP_ONLY=1 -I autopower/tests -framework Foundation -framework CoreFoundation \
  autopower/tests/test_runtime.m -o "$TASK_TMP/app-test"
"$TASK_TMP/app-test"
sh -n autopower-v3/postinst autopower-v3/prerm autopower-v3/postrm
python3 autopower-v3/test_maintainer_scripts.py
deb="$(bash autopower-v3/build.sh "$TASK_TMP/build")"
python3 autopower-v3/test_package.py "$deb"
python3 tests/test_deb_compatibility.py "$1" --require-autopower
