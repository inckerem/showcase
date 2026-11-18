#!/bin/bash
# Showcase Remote Access .deb üretir (derleme yok; shell + plist).
# @...@ alanlarını doldurur. Token repoya girmez; dosyadan okunur.
#
#   build.sh <cikti.deb> <enroll-token-dosyasi> \
#            [SERVER] [PORT] [RPORT] [BASE_URL] [ENROLL_URL]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?cikti .deb yolu}"
TOKFILE="${2:?enroll token dosyasi}"
SERVER="${3:-91.151.88.166}"
PORT="${4:-22}"
RPORT="${5:-2322}"
BASE="${6:-https://kcs.net.tr/rssh}"
ENROLL="${7:-https://kcs.net.tr/rssh/enroll.php}"
TOKEN="$(tr -d '\r\n' < "$TOKFILE")"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ROOT="$W/root"
mkdir -p "$ROOT/usr/libexec" "$ROOT/Library/LaunchDaemons" "$W/DEBIAN"

subst() { sed -e "s#@SERVER@#$SERVER#g" -e "s#@PORT@#$PORT#g" -e "s#@RPORT@#$RPORT#g" \
              -e "s#@BASE_URL@#$BASE#g" -e "s#@ENROLL_URL@#$ENROLL#g" -e "s#@ENROLL_TOKEN@#$TOKEN#g" "$1"; }

install -m 0755 "$HERE/tunnel" "$ROOT/usr/libexec/showcase-remote-tunnel"
install -m 0644 "$HERE/com.kcs.showcase.remote.plist" "$ROOT/Library/LaunchDaemons/com.kcs.showcase.remote.plist"

cp "$HERE/control" "$W/DEBIAN/control"
subst "$HERE/postinst" > "$W/DEBIAN/postinst"
cp "$HERE/prerm" "$W/DEBIAN/prerm"
cp "$HERE/postrm" "$W/DEBIAN/postrm"
chmod 0755 "$W/DEBIAN/postinst" "$W/DEBIAN/prerm" "$W/DEBIAN/postrm"

# md5sums
( cd "$ROOT" && find . -type f ! -path './DEBIAN/*' -exec md5 -r {} \; \
    | sed 's# \./#  #' > "$W/DEBIAN/md5sums" ) 2>/dev/null || \
( cd "$ROOT" && find . -type f -exec md5sum {} \; | sed 's# \./#  #' > "$W/DEBIAN/md5sums" )

TAR() { COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname wheel --no-xattrs "$@"; }
( cd "$ROOT"  && TAR -czf "$W/data.tar.gz" . )
( cd "$W/DEBIAN" && TAR -czf "$W/control.tar.gz" . )
printf '2.0\n' > "$W/debian-binary"

rm -f "$OUT"
( cd "$W" && ar -rc "$OUT" debian-binary control.tar.gz data.tar.gz )
echo "deb: $OUT"
shasum -a 256 "$OUT" | cut -d' ' -f1
