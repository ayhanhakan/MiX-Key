# MiX-Key

MiX-Key, Mac'te çalan müziğe göre Logitech MX Keys Mini klavyenin arka ışığını yakıp söndüren bir menü çubuğu uygulaması. Sesi sistemden alır, seçtiğin frekans bandının şiddetine bakar ve klavyenin ışık seviyesini Bluetooth üzerinden günceller.

Uygulama tek bir Swift dosyasından oluşuyor, bağımlılığı ve Xcode projesi yok. Çalışırken yaklaşık %3 işlemci kullanıyor. Ekran kilitliyken ya da uykudayken ses yakalamayı durdurduğu için işlemci kullanımı %0,1'e iniyor.

## Gereksinimler

- macOS 13 veya üstü
- Bluetooth ile bağlı bir MX Keys Mini. Logi Bolt ve Unifying alıcısıyla çalışmaz.
- Kaynaktan derleyeceksen Xcode Komut Satırı Araçları (`xcode-select --install`)

## Hızlı kurulum

1. [Sürümler](https://github.com/ayhanhakan/MiX-Key/releases) sayfasından `MiX-Key-0.1.0.zip` dosyasını indir, aç ve `MiX-Key.app` dosyasını Uygulamalar klasörüne taşı.
2. Uygulama App Store dışından geldiği için macOS ilk açılışta engeller. Terminalde şunu çalıştır:
   ```bash
   xattr -dr com.apple.quarantine /Applications/MiX-Key.app
   ```
3. Uygulamayı aç. Menü çubuğunda klavye simgesi belirir.
4. Sistem Ayarları > Gizlilik ve Güvenlik altında MiX-Key'e "Ekran ve Sistem Sesi Kaydı" ile "Giriş İzleme" izinlerini ver, sonra uygulamayı kapatıp yeniden aç.

Ayrıntılı adımlar, kaynaktan derleme ve sorun giderme için [KURULUM.md](KURULUM.md) dosyasına bak.

## Kullanım

Menü çubuğundaki simgeye tıklayınca panel açılır. Panelin üstüne gelince yanında canlı bir görünüm çıkar: klavye önizlemesi, ışık seviyesi, giriş sinyali, spektrum ve seçili ayarların etkisi.

| Ayar | Ne yapar |
|---|---|
| Soft, Medium, Hard | Işığın müziğe ne kadar sert tepki vereceği |
| Nefes | Müzikten bağımsız, 4 saniyede bir nefes alıp veren ışık |
| Bas, Orta, Tiz, Hepsi | Işığın takip ettiği frekans bandı |
| Hassasiyet | Sessiz müzikte de ışığın tam yanması için artır |
| Sönüş | Vuruştan sonra ışığın ne kadar yavaş söneceği |
| Darbe | Bir vuruşta ışığın tepede kalma süresi (150 ile 270 ms arası) |
| Bas sınırı | Bas bandının üst sınırı (60 ile 250 Hz arası) |
| Kaynak | Tüm sistem sesi ya da yalnız Spotify, Müzik, Safari veya Chrome |
| Yazarken sabit | Yazmaya başlayınca ışığı sabit bir seviyede tutar |
| Gece kapalı | Seçtiğin saatler arasında uygulamayı durdurur (öntanımlı 23.00 ile 07.00 arası) |
| Açılışta başla | Mac açılınca uygulamayı başlatır |

`⌃⌥M` kısayolu modlar arasında sırayla geçer: Kapalı, Soft, Medium, Hard, Nefes.

Klavyenin pili azalınca uygulama kendini durdurur. Ekran kilitlenince, ekran uyuyunca ya da gece saatleri başlayınca klavyenin eski ışık ayarı geri yüklenir. Kilit açılınca, ekran uyanınca ya da gece bitince efekt kendiliğinden devam eder.

## Nasıl çalışır

```
┌──────────────────────────────────────┐
│ Sistem sesi                          │
│ ScreenCaptureKit, 48 kHz mono        │
└───────────────────┬──────────────────┘
                    ▼
┌───────────────────┴──────────────────┐
│ Bant filtresi, RMS                   │
│ Bas, Orta, Tiz ya da Hepsi           │
└───────────────────┬──────────────────┘
                    ▼
┌───────────────────┴──────────────────┐
│ Seviye 0-7                           │
│ mod, hassasiyet, sönüş, darbe        │
└───────────────────┬──────────────────┘
                    ▼
┌───────────────────┴──────────────────┐
│ Klavyeye yazma                       │
│ HID++ Backlight2, Bluetooth          │
└───────────────────┬──────────────────┘
                    ▼
┌───────────────────┴──────────────────┐
│ Çıkış ya da askı                     │
│ yedekteki ışık ayarı geri yazılır    │
└──────────────────────────────────────┘
```

Uygulama açılınca klavyenin ışık ayarını okuyup `~/Library/Application Support/MiX-Key/backlight-yedek.txt` dosyasına yedekler. Çıkarken ya da askıya geçerken bu yedeği klavyeye geri yazar ve yazdığını okuyarak doğrular.

Klavyeyle konuşmak için Logitech'in HID++ 2.0 protokolündeki Backlight2 (0x1982) özelliği kullanılıyor. Sesi almak için ScreenCaptureKit kullanılıyor. Görüntü kaydedilmez, uygulama yalnız sesi işler.

## Bilinen sınırlar

- Işığın sönme hızı klavyenin kendi yazılımında sabit. Uygulama yalnız seviyeyi ayarlayabiliyor, geçişi hızlandıramıyor. Bu yüzden çok hızlı ritimlerde ışık vuruşları birbirine karışabilir.
- Yalnız MX Keys Mini (ürün kimliği B369) üzerinde denendi. Backlight2 özelliği olan başka Logitech klavyelerde çalışabilir ama kodda ürün kimliği sabit.
- Arayüz Türkçe.

## Işık takılı kalırsa

Uygulama beklenmedik şekilde kapanırsa klavyenin ışığı son seviyede kalabilir. Yedeği elle geri yüklemek için:

```bash
swift isik-test.swift geri
```

## Destek

Destek ekibimiz 7/24 açık. Yazın, en kısa sürede size dönüş yapalım. Hata bildirmek ya da öneri yazmak için bir [issue](https://github.com/ayhanhakan/MiX-Key/issues) açabilirsin.

## Lisans

[MIT](LICENSE)

MiX-Key bağımsız bir projedir, Logitech ile bir bağı yoktur. Logitech, MX Keys ve Logi Bolt, Logitech'in markalarıdır.
