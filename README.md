# Microsoft Defender for Endpoint — Health Check

Bir MDE tenant'ından salt-okunur veri çeker, topladığı veriyi best-practice ile karşılaştırır ve düzenlenebilir bir değerlendirme raporu üretir. Rapor İngilizce, araçlar PowerShell 7.

Otomatik üretilen her yorum **(REVIEW)** işaretlidir; danışman tek tek okuyup onaylar. İşaret kalmadığında health check tamamlanmış olur.

| Dosya | İşlevi |
|---|---|
| `New-MdeApp.ps1` | **Ön adım.** Entra app kaydını, izinleri ve admin consent'i oluşturur |
| `MDE-Collect.ps1` | Tenant'tan veri toplar → `mde-assessment-data.json` |
| `MDE-Render.ps1` | JSON'u şablona işler → doldurulmuş rapor |
| `Run-Assessment.ps1` | Toplama + rapor üretimini tek komutta çalıştırır |
| `Test-Parse.ps1` | Sözdizimi kontrolü (sorun giderirken ilk çalıştırılacak) |
| `MDE-Health-Assessment-Template.html` | 24 bölümlük boş rapor şablonu |
| `MDE-Health-Assessment-SAMPLE.html` | Örnek veriyle dolu sürüm (kurgusal Northwind Holding) |
| `MDE-Health-Assessment-Template.docx` | Aynı raporun Word sürümü |
| `sample-data.json` | Tenant olmadan render denemek için |

---

# Adım adım (PowerShell)

## Adım 0 · Ön koşullar

**PowerShell 7+ gerekir.** Windows'ta hazır gelen "Windows PowerShell 5.1" (mavi ikon) bu script'leri çalıştıramaz.

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Kurulumdan sonra **yeni bir PowerShell 7 penceresi** (siyah ikon, `pwsh`) açın ve doğrulayın:

```powershell
$PSVersionTable.PSVersion
```

`Major` değeri 7 veya üzeri olmalı.

**Tenant'ta gereken roller:**

| Rol | Ne için |
|---|---|
| **Security Reader** | Defender verisi: uyarılar, olaylar, Secure Score, TVM, Advanced Hunting |
| **Global Reader** | Lisanslar, roller, PIM, Conditional Access, Intune politikaları |
| **Global Administrator** | Yalnızca Adım 2'deki app kaydı + consent için (bir kez) |

> Tenant'ta **Defender RBAC** açıksa, hesabın tüm cihaz gruplarına erişimi olan bir role atanmış olması gerekir. Aksi halde izinler tam olsa bile envanter ve zafiyet sayıları kısmi gelir.

## Adım 1 · Dosyaları alın

```powershell
git clone https://github.com/MSalikoc/mde-health-check.git
```

```powershell
cd mde-health-check
```

İnternetten indirilen `.ps1` dosyaları Windows tarafından bloke edilir (Mark-of-the-Web):

```powershell
Get-ChildItem *.ps1 | Unblock-File
```

Script çalıştırma politikası kapalıysa **yalnızca bu oturum için** açın (kalıcı değişiklik yapmaz):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

## Adım 2 · Sözdizimi kontrolü (30 saniye)

Bir şey çalıştırmadan önce dosyaların sağlam geldiğini doğrulayın:

```powershell
.\Test-Parse.ps1
```

Beş dosya için de `OK` görmelisiniz. `HATA` çıkarsa satır ve sütun numarasıyla birlikte gösterir — o çıktıyı paylaşın.

## Adım 3 · Entra app kaydı (bir kez)

Varsayılan ClientId (Azure CLI) yalnızca dizin okumaya yetkilidir; **Defender izinlerine sahip değildir.** Onunla çalıştırırsanız tenant adı ve lisanslar gelir, geri kalan her çağrı `403` döner.

```powershell
.\New-MdeApp.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6
```

Ekranda bir cihaz kodu çıkar → <https://microsoft.com/devicelogin> adresinde **Global Administrator** hesabıyla giriş yapın.

Script sırasıyla şunları yapar:

1. `MDE Health Check Collector` adıyla app kaydı oluşturur
2. *Allow public client flows* ayarını açar (device code için şart)
3. 10 Graph + 6 WindowsDefenderATP delegated iznini ekler (GUID'ler servicePrincipal'dan dinamik çözülür)
4. Service principal oluşturur ve **admin consent verir**
5. Client ID'yi `.mde-app.json` dosyasına yazar

İdempotenttir: tekrar çalıştırırsanız var olan kaydı bulur, eksik izinleri tamamlar.

> Consent'in yayılması 1-2 dakika sürebilir. Hemen ardından 403 alırsanız bir kez daha deneyin.

## Adım 4 · Veriyi toplayın ve raporu üretin

Tek komut — toplar, raporu üretir, tarayıcıda açar. `-ClientId` yazmanıza gerek yok, `.mde-app.json` otomatik okunur:

```powershell
.\Run-Assessment.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6 -Logo microsoft
```

Yine bir cihaz kodu çıkar; bu sefer **Security Reader + Global Reader** yetkili hesapla giriş yapın (aynı hesap da olabilir).

**İlk denemeyi dar kapsamla yapmanız önerilir** — 1-2 dakikada biter, izin sorunlarını hemen gösterir:

```powershell
.\Run-Assessment.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6 -GraphOnly -AlertDays 7 -EventDays 7
```

### Adımları ayrı çalıştırmak isterseniz

```powershell
.\MDE-Collect.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6 -RawDumpPath .\raw -Verbose
```

```powershell
.\MDE-Render.ps1 -DataFile .\mde-assessment-data.json -Template .\MDE-Health-Assessment-Template.html -ClientName "Contoso A.S." -Logo microsoft
```

## Adım 5 · Raporu tamamlayın

Klasörde şunlar oluşur:

- `mde-assessment-data.json` — çekilen ham veri (**elle düzenlenebilir**)
- `raw\` — her API/KQL çağrısının ham çıktısı (sorun giderme)
- `<Musteri>-MDE-Assessment-<tarih>.html` — rapor

Raporu tarayıcıda açın:

1. Sağ üstteki sayaç kaç **(REVIEW)** işaretli taslak kaldığını gösterir
2. Her taslağı okuyun; doğruysa **(REVIEW) rozetine tıklayın** (veya metnin herhangi bir yerine `Alt+tık`) — işaret gider, metin kalır
3. Yanlışsa metne tıklayıp düzeltin, sonra rozeti kaldırın
4. Gri italik yer tutucular otomatik doldurulamayan alanlardır — elle yazın
5. Sayaç sıfırlandığında **Ctrl+P → PDF olarak kaydet** (kenar boşluğu: yok, arka plan grafikleri: açık)

> Toplu "hepsini kaldır" butonu bilerek yok. Her taslak tek tek okunmalı.

JSON'u elle düzeltip raporu yeniden üretmek için:

```powershell
.\Run-Assessment.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6 -SkipCollect
```

---

# Parametreler

### Run-Assessment.ps1

| Parametre | Açıklama |
|---|---|
| `-TenantId` | Tenant GUID'i veya `xxx.onmicrosoft.com` (zorunlu) |
| `-ClientId` | App kaydı ID'si (boşsa `.mde-app.json` okunur) |
| `-ClientName "Contoso A.S."` | Kapaktaki müşteri adı (boşsa tenant adı) |
| `-Logo microsoft` | Kapak logosu: `template` / `microsoft` / `none` |
| `-CreateApp` | App kaydını da bu çalıştırmada oluştur (Adım 3 + 4 birlikte) |
| `-GraphOnly` | `api.securitycenter.microsoft.com` çağrılarını atla |
| `-AlertDays 90` / `-EventDays 30` | Telemetri pencereleri |
| `-SkipCollect` | Toplamayı atla, mevcut JSON'dan raporu yeniden üret |
| `-Template <yol>` | Farklı bir şablon dosyası kullan |

### MDE-Collect.ps1 (ek)

| Parametre | Açıklama |
|---|---|
| `-RawDumpPath .\raw` | Ham API/KQL çıktılarını diske yaz |
| `-OutFile` | JSON çıktı yolu |
| `-Verbose` | Ayrıntılı ilerleme |

### MDE-Render.ps1 (ek)

| Parametre | Açıklama |
|---|---|
| `-HideDataTables` | Grafik veri tablolarını gizli başlat (teslim için daha temiz) |
| `-OutFile` | Rapor dosyası adı |

---

# İzinler

Hepsi **delegated** ve **read-only**. `New-MdeApp.ps1` bunları otomatik ekler ve consent verir.

**Microsoft Graph:** `ThreatHunting.Read.All`, `SecurityEvents.Read.All`, `SecurityAlert.Read.All`, `SecurityIncident.Read.All`, `CustomDetection.Read.All`, `DeviceManagementConfiguration.Read.All`, `Directory.Read.All`, `Organization.Read.All`, `Policy.Read.All`, `RoleManagement.Read.Directory`

**WindowsDefenderATP:** `Vulnerability.Read`, `SecurityRecommendation.Read`, `Score.Read`, `Ti.Read`, `Machine.Read`, `AdvancedQuery.Read`

Script hiçbir yazma çağrısı yapmaz; hata alan her bölüm atlanır ve raporun "Automated Collection Notes" sayfasına uyarı olarak yazılır.

---

# Ne otomatik doluyor

| Rapor alanı | Kaynak |
|---|---|
| Cihaz envanteri, onboarding oranı, platform kırılımı | AH `DeviceInfo` |
| Sensör sağlığı (active / inactive / impaired) | AH `DeviceInfo.SensorHealthState` |
| AV / ASR / baseline yapılandırma uyumu | AH `DeviceTvmSecureConfigurationAssessment` |
| ASR kural modları | Intune `configurationPolicies` + AH `DeviceEvents` |
| Zafiyet dağılımı, top yazılım, yazılım envanteri | AH `DeviceTvmSoftwareVulnerabilities` |
| Exposure score, güvenlik önerileri, indicator'lar | MDE API |
| Secure Score + kategori kırılımı | Graph `security/secureScores` |
| Uyarı/olay hacmi, severity, taktik, MTTD/MTTR | Graph `security/alerts_v2`, `incidents` |
| Özel tespit kuralları | Graph `security/rules/detectionRules` |
| Lisans envanteri | Graph `subscribedSkus` |
| Intune politikaları, AV exclusion'ları | Graph `deviceManagement/configurationPolicies` |
| Ayrıcalıklı roller, PIM, Conditional Access | Graph `directoryRoles`, `conditionalAccess/policies` |
| **Taslak bulgular** | Eşik kuralları (kapsam, tamper, ASR, CVE, exposure, CA, GA sayısı) |
| **Anlatım metinleri** | Toplanan veri + best practice (39 alan) |
| **Kontrol yorumları** | Best practice kütüphanesi (178 anahtar, ~183 satır) |

# Ne elle kalır

Yönetici özetinin doğrulanması, risk ifadesinin müşteriye uyarlanması, bulgu severity kararı, effort/owner/tarih, olgunluk puanları, öncelik matrisi, revizyon geçmişi ve iletişim bilgileri.

Teknik olarak imkânsız olanlar: 6 aylık trendler (Advanced Hunting 30 gün tutar), onboarding yöntemi (`DeviceInfo`'da alan yok), AIR otomasyon oranları (API'de yok), Threat Analytics kullanımı (API yok).

---

# Sorun giderme

| Belirti | Sebep / çözüm |
|---|---|
| `#Requires -Version 7.0` veya sözdizimi hataları | Windows PowerShell 5.1'de çalıştırıyorsunuz → `pwsh` ile açın |
| `... is not digitally signed` | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` |
| `zsh/pwsh: no such file or directory: <tenant>` | Komuttaki `< >` işaretlerini silin, yer tutucuydu |
| `AADSTS65001` / `invalid_client` | App kaydı yok veya consent verilmemiş → Adım 3 |
| Çağrıların çoğu `403` | Token'da Defender izinleri yok → Adım 3. Script eksik izinleri baştan listeler |
| `403` yalnızca securitycenter çağrılarında | `-GraphOnly` ile devam edin; exposure score elle girilir |
| Advanced Hunting boş dönüyor | `ThreatHunting.Read.All` consent'i yok ya da Defender RBAC kısıtlıyor |
| Uyarı çekimi çok uzun | `-AlertDays 30` yapın |
| ASR kuralları "not configured" görünüyor | Telemetride olay yoksa Intune'dan türetilir; GPO ile yönetilen kurallar görünmez |
| Türkçe karakterler bozuk | Windows Terminal kullanın (conhost yerine) |
| Rapor eski görünüyor / değişiklikler yansımıyor | Tarayıcı kayıtlı kopyayı yüklüyor olabilir → `Ctrl+Shift+R` |

# Bilinen sınırlar

- **ASR modları** Intune politikalarından türetilir; GPO ile yönetilen kurallar görünmez.
- **Exclusion listesi** yalnızca Intune politikalarından çıkarılır; GPO/yerel exclusion'lar için live response veya registry sorgusu gerekir.
- **Advanced Hunting** 30 günlük veri tutar; daha uzun trendler Sentinel'den çekilmelidir.
- **Best practice yorumları** satır bazlı genel doğrulardır ("bu ayar neden önemli, hedef ne olmalı"); tenant değerine göre yazılan yorumlar yalnızca veri toplanan alanlarda vardır.
- Toplanan veri ve üretilen raporlar `.gitignore` ile dışarıda tutulur — müşteri verisi yanlışlıkla commit edilmez.
