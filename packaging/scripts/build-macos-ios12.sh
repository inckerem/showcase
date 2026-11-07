#!/bin/bash
# Build a rootful package on macOS using an iOS 12 SDK and a trusted upstream
# rootful deb for the bundled BTstack runtime. Usage:
# IOS12_SDK=/path/to/iPhoneOS12.4.sdk BASE_DEB=/path/to/original.deb bash packaging/scripts/build-macos-ios12.sh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${IOS12_SDK:?Set IOS12_SDK to a compatible iPhoneOS 12 SDK directory}"
: "${BASE_DEB:?Set BASE_DEB to the trusted upstream rootful deb}"
[[ -d "$IOS12_SDK" && -f "$BASE_DEB" ]] || { echo 'SDK or base deb missing' >&2; exit 1; }
command -v ldid >/dev/null || { echo 'ldid is required' >&2; exit 1; }
TASK_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/showcase-ios12-build.XXXXXX")"
mkdir -p "$TASK_STAGE/unpack" "$TASK_STAGE/rootfs" "$TASK_STAGE/control" "$TASK_STAGE/repo/debs"
BASE_DEB="$(cd "$(dirname "$BASE_DEB")" && pwd)/$(basename "$BASE_DEB")"
python3 - "$BASE_DEB" "$TASK_STAGE/unpack" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
if not data.startswith(b'!<arch>\n'):
    raise SystemExit('base deb is not an ar archive')
offset = 8
while offset + 60 <= len(data):
    header = data[offset:offset + 60]
    offset += 60
    name = header[:16].decode('ascii').strip().rstrip('/')
    size = int(header[48:58].decode('ascii').strip())
    body = data[offset:offset + size]
    offset += size + size % 2
    if name in ('debian-binary', 'control.tar.gz', 'data.tar.gz'):
        (Path(sys.argv[2]) / name).write_bytes(body)
PY
( cd "$TASK_STAGE/unpack" && tar -xzf data.tar.gz )
for task_part in Applications usr Library; do cp -R "$TASK_STAGE/unpack/$task_part" "$TASK_STAGE/rootfs/"; done
TASK_APP="$TASK_STAGE/rootfs/Applications/Showcase.app"
TASK_LIB="$TASK_STAGE/rootfs/usr/lib/libBTstack.dylib"
. "$TASK_ROOT/packaging/scripts/version.sh"
cd "$TASK_ROOT"
clang -arch arm64 -fobjc-arc -miphoneos-version-min=12.0 -isysroot "$IOS12_SDK" \
  -DAPP_VERSION="\"$DISPLAY_VERSION\"" -DPACKAGE_VERSION="\"$PACKAGE_VERSION\"" \
  -o "$TASK_APP/Showcase" source/Showcase.m -framework UIKit -framework AVFoundation \
  -framework AudioToolbox -framework CoreMedia -framework Foundation -framework Security \
  -Wl,-undefined,dynamic_lookup
clang -arch arm64 -fobjc-arc -miphoneos-version-min=12.0 -isysroot "$IOS12_SDK" \
  -o "$TASK_APP/carplay_bt" source/carplay_bt.m "$TASK_LIB" -framework Foundation \
  -framework Security -Wl,-undefined,dynamic_lookup
clang -arch arm64 -fobjc-arc -miphoneos-version-min=12.0 -isysroot "$IOS12_SDK" \
  -o "$TASK_APP/carplay_services" source/carplay_services.m source/carplay_pair.c \
  source/vendor/monocypher/monocypher.c source/vendor/monocypher/monocypher-ed25519.c \
  source/vendor/libtommath/tommath.c -framework Foundation -framework Security \
  -Wl,-undefined,dynamic_lookup
ldid -Ssource/ent_app.xml "$TASK_APP/Showcase"
ldid -Ssource/ent_bt.xml "$TASK_APP/carplay_bt"
ldid -Ssource/ent_svc.xml "$TASK_APP/carplay_services"
fill_version source/Info.plist > "$TASK_APP/Info.plist"
cp -R source/Localizations/*.lproj "$TASK_APP/"
fill_version packaging/control/control > "$TASK_STAGE/control/control"
cp packaging/control/{postinst,prerm,postrm} source/{ent_app.xml,ent_bt.xml,ent_svc.xml} "$TASK_STAGE/control/"
chmod 0755 "$TASK_STAGE/control/postinst" "$TASK_STAGE/control/prerm" "$TASK_STAGE/control/postrm"
chmod 0644 "$TASK_STAGE/control/control" "$TASK_STAGE/control/"*.xml
( cd "$TASK_STAGE/control" && COPYFILE_DISABLE=1 tar --format ustar --no-xattrs -czf "$TASK_STAGE/control.tar.gz" . )
( cd "$TASK_STAGE/rootfs" && COPYFILE_DISABLE=1 tar --format ustar --no-xattrs -czf "$TASK_STAGE/data.tar.gz" . )
printf '2.0\n' > "$TASK_STAGE/debian-binary"
TASK_DEB="$TASK_STAGE/repo/debs/com.rostane.showcase_${PACKAGE_VERSION}_iphoneos-arm.deb"
( cd "$TASK_STAGE" && ar -qS "$TASK_DEB" debian-binary control.tar.gz data.tar.gz )
python3 tests/test_deb_compatibility.py "$TASK_DEB"
python3 packaging/scripts/generate-apt-repo.py "$TASK_STAGE/repo"
printf 'Repository ready: %s\n' "$TASK_STAGE/repo"
