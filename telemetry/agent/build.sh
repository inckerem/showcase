#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${IOS12_SDK:?Set IOS12_SDK}"
OUT="${1:?Supply external output directory}"
mkdir -p "$OUT/root/usr/libexec" "$OUT/root/Library/LaunchDaemons" "$OUT/control"
clang -target arm64-apple-ios12.0 -isysroot "$IOS12_SDK" -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
  -framework Foundation "$HERE/Agent.m" -o "$OUT/root/usr/libexec/showcase-diagnostics"
ldid -S"$HERE/entitlements.xml" "$OUT/root/usr/libexec/showcase-diagnostics"
cp "$HERE/tr.net.kcs.showcase.diagnostics.plist" "$OUT/root/Library/LaunchDaemons/"
cp "$HERE/"{control,postinst,prerm} "$OUT/control/"
chmod 0755 "$OUT/control/"{postinst,prerm} "$OUT/root/usr/libexec/showcase-diagnostics"
chmod 0644 "$OUT/control/control" "$OUT/root/Library/LaunchDaemons/"*.plist
tar_flags=(--format ustar --no-xattrs --uid 0 --gid 0 --uname root --gname wheel)
(cd "$OUT/control" && COPYFILE_DISABLE=1 tar "${tar_flags[@]}" -czf "$OUT/control.tar.gz" .)
(cd "$OUT/root" && COPYFILE_DISABLE=1 tar "${tar_flags[@]}" -czf "$OUT/data.tar.gz" .)
printf '2.0\n' > "$OUT/debian-binary"
VERSION="$(awk '/^Version:/ {print $2}' "$HERE/control")"
DEB="$OUT/tr.net.kcs.showcase.diagnostics_${VERSION}_iphoneos-arm.deb"
rm -f "$DEB"
(cd "$OUT" && ar -qS "$DEB" debian-binary control.tar.gz data.tar.gz)
printf '%s\n' "$DEB"
