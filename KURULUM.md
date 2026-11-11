# Kurulum rehberi

## 1. Hazır sürümle kurulum

1. [Sürümler](https://github.com/ayhanhakan/MiX-Key/releases) sayfasından son `MiX-Key-x.y.z.zip` dosyasını indir.
2. Zip dosyasını aç ve `MiX-Key.app` dosyasını Uygulamalar klasörüne taşı.
3. Uygulama Apple tarafından onaylanmış (notarize edilmiş) değil, bu yüzden macOS ilk açılışta "açılamıyor" der. İki yoldan biriyle aç:
   - Terminalde `xattr -dr com.apple.quarantine /Applications/MiX-Key.app` çalıştır, sonra uygulamayı normal aç.
   - Ya da uygulamayı bir kez açmayı dene, ardından Sistem Ayarları > Gizlilik ve Güvenlik sayfasının altında "Yine de Aç" düğmesine bas.
4. Menü çubuğunda klavye simgesi görünür. İzinleri vermek için aşağıdaki 3. bölüme geç.

## 2. Kaynaktan derleme

```bash
xcode-select --install          # yüklü değilse
git clone https://github.com/ayhanhakan/MiX-Key.git
cd MiX-Key
./build.sh
open MiX-Key.app
```

`build.sh` uygulamayı derler, `MiX-Key.app` paketini oluşturur, imzalar ve dahili testleri çalıştırır. Testlerden biri geçmezse betik durur.

### İmza

macOS, Ekran Kaydı iznini uygulamanın imzasına bağlar. İmzasız (ad-hoc) derlemede her yeniden derlemeden sonra izni tekrar vermen gerekir. Bunu önlemek için kendi geliştirici sertifikanın adını proje klasöründe `.imza` dosyasına yaz:

```bash
security find-identity -v -p codesigning     # sertifikaları listeler
echo "Apple Development: Ad Soyad (TAKIMKODU)" > .imza
```

`.imza` dosyası git'e girmez. Tek seferlik bir derleme için `IMZA="..." ./build.sh` da kullanabilirsin. Dosya da değişken de yoksa uygulama ad-hoc imzalanır.

## 3. İzinler

Sistem Ayarları > Gizlilik ve Güvenlik altında MiX-Key'i şu iki listede aç:

| İzin | Neden gerekli |
|---|---|
| Ekran ve Sistem Sesi Kaydı | Çalan sesi almak için. Görüntü kaydedilmez. |
| Giriş İzleme | Klavyeye bağlanmak ve yazdığını fark etmek için |

İzinleri verdikten sonra uygulamayı paneldeki "Çık" düğmesiyle kapatıp yeniden aç. Bir izin eksikse panelde uyarı görünür.

## 4. Klavyeyi bağlama

MX Keys Mini Mac'e Bluetooth ile bağlı olmalı. Klavye uykudaysa bir tuşa bas. Uygulama klavye uyanana kadar "Klavye bekleniyor" yazar ve kendisi yeniden dener.

## 5. Komut satırı

Ayar denemek ya da sorun aramak için uygulamayı komut satırından da çalıştırabilirsin:

```bash
APP=MiX-Key.app/Contents/MacOS/MiX-Key
$APP test                                  # dahili testler
$APP --pil                                 # klavyenin pil durumu
$APP --mod medium --sure 30                # 30 saniye Medium modunda çalış
$APP --mod hard --bant bas --hassasiyet 0.6 --kaynak com.spotify.client
```

Seçenekler: `--mod` (soft, medium, hard, nefes), `--sure` (saniye, öntanımlı 45), `--bant` (bas, orta, tiz, hepsi), `--hassasiyet`, `--sonus` ve `--kesim` (0 ile 1 arası), `--kaynak` (uygulamanın paket kimliği, boşsa tüm sistem sesi). Çalışma bitince kaç kez yazıldığı ve seviyelerin dağılımı yazdırılır.

## 6. Sorun giderme

### Işık müziğe tepki vermiyor

Panelde izin uyarısı var mı bak. Kaynak olarak "Tümü" seçili mi kontrol et. Sessiz çalan müzikte Hassasiyet ayarını artır.

### Panelde "Klavye yok" yazıyor

Klavye Bluetooth yerine bir alıcıyla bağlı olabilir. Sistem Ayarları > Bluetooth listesinde MX Keys Mini'nin bağlı olduğunu kontrol et.

### Işık son seviyede takılı kaldı

Uygulama çıkarken eski ayarı geri yazar. Beklenmedik bir kapanmadan sonra elle geri yüklemek için proje klasöründe şunu çalıştır:

```bash
swift isik-test.swift geri
```

Yedek dosyası `~/Library/Application Support/MiX-Key/backlight-yedek.txt` konumunda durur. Bu dosyayı silme, klavyenin ilk ayarı oradadır.

### Her derlemeden sonra izin istiyor

2. bölümdeki imza adımını uygula.

## Kaldırma

1. Uygulamadan çık ve "Açılışta başla" açıksa önce kapat.
2. `MiX-Key.app` dosyasını sil.
3. `~/Library/Application Support/MiX-Key` klasörünü ve `io.github.ayhanhakan.mixkey` ayarlarını sil:
   ```bash
   rm -rf ~/Library/Application\ Support/MiX-Key
   defaults delete io.github.ayhanhakan.mixkey
   ```
