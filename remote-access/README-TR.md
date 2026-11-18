# Showcase Remote Access — KCS sunucusu üzerinden güvenli SSH

iPad'e (ya da başka bir jailbreak'li cihaza) **dışarıya hiçbir port açmadan**,
KCS sunucusunu atlama noktası (jump host) yaparak SSH ile ulaşmayı sağlar.

## Nasıl çalışır

```
  iPad sshd:22
      │  (giden, ters tünel)
      ▼
  KCS sunucusu  127.0.0.1:2322  ◄── yalnız sunucuya erişen görür (loopback)
      ▲
      │  ssh -J (jump)
  Mac ── sc-ssh ──► root@iPad
```

- iPad, sunucuya **kilitli** `scssh` kullanıcısı olarak bağlanır ve
  `-R 127.0.0.1:2322:127.0.0.1:22` ile kendi sshd'sini sunucunun loopback'ine
  bağlar. Dışarıya, hatta sunucunun genel arayüzüne bile bir port açılmaz.
- `scssh` anahtarı `restrict,permitlisten="127.0.0.1:2322"` ile sınırlıdır:
  kabuk yok, komut yok, başka yönlendirme yok — sadece o tek portu bağlar.
  Anahtar sızsa bile yapabileceği tek şey o loopback portunu bağlamaktır.
- iPad, sunucunun host anahtarını **sabitler** (TOFU yok). Mac da iPad'in host
  anahtarını `approve.sh` çıktısından sabitler.
- Mac → iPad girişi parolasız: operatörün Mac açık anahtarı kurulumda iPad'in
  `root` `authorized_keys`'ine eklenir. (iPad'in parola auth'u değiştirilmez.)
- Bağlantı düşerse launchd (`KeepAlive`) tüneli yeniden kurar. Cihaz yeniden
  başlatma gerektirmez; servis kurulumda yüklenir, respring'te geri gelir.

## Bileşenler

```
ipad/        Sileo paketi (derleme yok; shell + launchd plist)
  control, postinst, prerm, postrm
  tunnel                       -> /usr/libexec/showcase-remote-tunnel (ssh döngüsü)
  com.kcs.showcase.remote.plist-> /Library/LaunchDaemons (KeepAlive)
  build.sh                     -> @...@ alanlarını doldurup .deb üretir
server/      KCS sunucusunda çalışır
  setup.sh    -> kilitli scssh kullanıcısı + kayıt dizini + kcs.net.tr/rssh/ açık dosyalar (BİR KEZ)
  enroll.php  -> kcs.net.tr/rssh/enroll.php: cihaz açık anahtarını "pending" kaydeder (token şart)
  approve.sh  -> pending kaydı KISITLI olarak yetkilendirir, Mac known_hosts satırını verir
mac/
  sc-ssh      -> ssh -J jump -p <rport> root@127.0.0.1 (bağlan / --put / --get)
```

Sırlar repoda **yoktur**: enrollment token ve anahtarlar `~/.kcs-pbx/showcase-remote/`
(Mac) ve sunucuda `…/private/showcase-remote/` içindedir. iPad'in özel anahtarı
yalnız iPad'de üretilir ve orada kalır.

## Kurulum akışı (bu iPad, ters port 2322)

1. **Sunucu (bir kez, yapıldı):**
   `sudo bash server/setup.sh <enroll-token> <mac.pub>`
   → `scssh` kullanıcısı, `kcs.net.tr/rssh/{enroll.php,server.hostkey,mac.pub}`.
2. **iPad:** Sileo → KCS deposu → **Showcase Remote Access** kur.
   Kurulumda cihaz anahtar üretir, sunucu host anahtarını sabitler, Mac
   anahtarını ekler ve açık anahtarını kaydeder. Tünel servisi yüklenir
   (anahtar yetkilenene kadar bağlanmayı dener).
3. **Sunucu:** `bash server/approve.sh list` → kaydı gör →
   `bash server/approve.sh ok <id> 2322` → çıkan `[127.0.0.1]:2322 …` satırını
   Mac'te `~/.kcs-pbx/showcase-remote/known_hosts` dosyasına ekle.
4. **Mac:** `mac/sc-ssh` → iPad'de root kabuğu.
   Dosya: `sc-ssh --put yerel uzak`, `sc-ssh --get uzak yerel`.

## Güvenlik özeti

- iPad inbound port açmaz; erişim yalnız KCS sunucusuna erişen + Mac anahtarına
  sahip olan içindir (iki katman).
- Tünel kullanıcısı kabuk alamaz, komut çalıştıramaz, yalnız tek loopback portu
  bağlar.
- Host anahtarları iki yönde de sabitlenir.
- Kaldırma: iPad'de paketi sil (tünel durur, anahtar/yapı silinir); sunucuda
  `approve.sh deny <id>` ve `scssh authorized_keys`'ten ilgili satırı çıkar.
