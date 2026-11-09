# Showcase Mirror

Bu prototip iOS 27 ve üzerindeki iPhone’un ekranını aynı Wi-Fi ağındaki Showcase alıcısına yansıtır. Ekran paylaşımı iPhone’un sistem menüsünden onaylanır. Alıcıdan geri dönüldüğünde bağlantı kapanır.

1. Bu dizinde `xcodegen generate` çalıştır ve `ShowcaseMirror.xcodeproj` dosyasını Xcode’da aç.
2. Signing & Capabilities bölümünde geliştirme takımını seç. iPhone’u hedef olarak seçip **Run** düğmesine bas.
3. iPad’de Showcase Mirror test paketini kur. CarPlay ana ekranındaki **Araç** simgesine dokun. Yansıtmayı üç parmak menüsündeki **iPhone Ekranını Yansıt** düğmesiyle de açabilirsin.
4. iPhone’da Showcase Mirror’ı aç, **QR kodunu okut** düğmesine bas ve iPad’deki kodu tara. Ardından iOS’un ekran paylaşımı istemini onayla.

Yansıtma görüntüyü şifreli yerel bağlantıyla gönderir. Bu sürüm sesi veya iPhone’a dokunmatik komutları taşımaz. Ekran kaydını engelleyen içerik siyah görünebilir.

iPad paketi, iOS 12 derleme betiğine `SHOWCASE_MIRROR_BENCH=1` verilerek üretilir.
