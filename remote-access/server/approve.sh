#!/bin/bash
# KCS sunucusunda çalıştırılır. Bekleyen kayıtları listeler ve seçileni
# tünel kullanıcısına KISITLI olarak yetkilendirir.
#   approve.sh list                 -> bekleyenler
#   approve.sh ok <id> <rport>      -> yetkilendir, Mac known_hosts satırını yaz
#   approve.sh deny <id>            -> kaydı sil
set -euo pipefail

PRIV=/var/www/vhosts/keremincesu.com/private/showcase-remote
AK=/home/scssh/.ssh/authorized_keys
cmd="${1:-list}"

list() {
    shopt -s nullglob
    local any=0
    for f in "$PRIV"/*.json; do
        any=1
        python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
i = sys.argv[1].split('/')[-1][:-5]
print(f"{i}  {d.get('status')}  {d.get('device')}  {d.get('ip')}  {d.get('time')}")
print("   pub:", d['pubkey'][:52], "...")
PY
    done
    [ "$any" = 1 ] || echo "bekleyen yok"
}

case "$cmd" in
    list) list ;;
    ok)
        id="${2:?id}"; rport="${3:?ters-port}"
        [[ $rport =~ ^[0-9]{2,5}$ ]] || { echo "gecersiz port"; exit 1; }
        f="$PRIV/$id.json"; [ -f "$f" ] || { echo "kayit yok: $id"; exit 1; }
        pub=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pubkey"])' "$f")
        host=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hostkey"])' "$f")
        # Anahtarı tek bir loopback portuna kilitle: kabuk/komut/başka yönlendirme yok.
        line="restrict,permitlisten=\"127.0.0.1:$rport\" $pub"
        touch "$AK"
        if grep -qF "$pub" "$AK"; then
            echo "zaten yetkili"
        else
            printf '%s\n' "$line" >> "$AK"
            chown scssh:scssh "$AK"; chmod 600 "$AK"
            echo "yetkilendirildi: $id -> 127.0.0.1:$rport"
        fi
        python3 -c 'import json,sys;json.dump({**json.load(open(sys.argv[1])),"status":"approved","rport":int(sys.argv[2])},open(sys.argv[1],"w"))' "$f" "$rport"
        echo "--- Mac known_hosts satiri (iPad host anahtarini sabitlemek icin) ---"
        echo "[127.0.0.1]:$rport $host"
        ;;
    deny)
        id="${2:?id}"; rm -f "$PRIV/$id.json"; echo "silindi: $id" ;;
    *) echo "kullanim: approve.sh list | ok <id> <rport> | deny <id>"; exit 2 ;;
esac
