#!/bin/bash
# KCS sunucusunda (Ubuntu/Plesk) BİR KEZ çalıştırılır. Kilitli tünel kullanıcısını,
# kayıt dizinini ve kcs.net.tr/rssh/ altındaki açık dosyaları kurar.
# Çalıştırma:  sudo bash setup.sh <enroll-token> <mac-pubkey-dosyasi>
set -euo pipefail

TOKEN="${1:?enroll token}"
MACPUB_FILE="${2:?mac .pub dosyasi}"
VHOST=/var/www/vhosts/keremincesu.com
DOCROOT="$VHOST/kcs.net.tr"
RSSH="$DOCROOT/rssh"
PRIV="$VHOST/private/showcase-remote"
OWNER=keremincesu.com:psacln

# 1) Kilitli tünel kullanıcısı: kabuk yok, yalnız anahtarla, yalnız ters port.
if ! id scssh >/dev/null 2>&1; then
    useradd -r -m -d /home/scssh -s /usr/sbin/nologin scssh
fi
install -d -m 700 -o scssh -g scssh /home/scssh/.ssh
touch /home/scssh/.ssh/authorized_keys
chown scssh:scssh /home/scssh/.ssh/authorized_keys
chmod 600 /home/scssh/.ssh/authorized_keys

# 2) Kayıt dizini (web kökü DIŞINDA) ve token.
install -d -m 700 -o "${OWNER%%:*}" -g psacln "$PRIV"
printf '%s' "$TOKEN" > "$PRIV/.enroll-token"
chown "${OWNER%%:*}:psacln" "$PRIV/.enroll-token"
chmod 600 "$PRIV/.enroll-token"

# 3) Açık uç nokta + sabitlenecek dosyalar.
install -d -m 755 -o "${OWNER%%:*}" -g psacln "$RSSH"
install -m 644 -o "${OWNER%%:*}" -g psacln "$(dirname "$0")/enroll.php" "$RSSH/enroll.php"

# Sunucunun kendi sshd host anahtarı (iPad bunu sabitleyecek).
awk '{print $1, $2}' /etc/ssh/ssh_host_ed25519_key.pub > "$RSSH/server.hostkey"
# Operatör Mac açık anahtarı.
awk '{print $1, $2}' "$MACPUB_FILE" > "$RSSH/mac.pub"
chown "${OWNER%%:*}:psacln" "$RSSH/server.hostkey" "$RSSH/mac.pub"
chmod 644 "$RSSH/server.hostkey" "$RSSH/mac.pub"

cat > "$RSSH/.htaccess" <<'EOF'
Options -Indexes
Header always set X-Robots-Tag "noindex, nofollow"
<FilesMatch "\.(token|json)$">
  Require all denied
</FilesMatch>
EOF
chown "${OWNER%%:*}:psacln" "$RSSH/.htaccess"

echo "Kuruldu. enroll: https://kcs.net.tr/rssh/enroll.php  pending: $PRIV"
