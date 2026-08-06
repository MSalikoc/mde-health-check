# Windows'ta çalıştırma — hızlı başlangıç

ZIP'i açtığınız klasörde şunlar olmalı:

```
MDE-Collect.ps1
MDE-Render.ps1
Run-Assessment.ps1
MDE-Health-Assessment-Template.html
sample-data.json
README.md  /  BASLA-WINDOWS.md
```

## 1 · PowerShell 7 kurun

Windows'ta hazır gelen "Windows PowerShell" 5.1'dir; bu script'ler **PowerShell 7** ister (mavi değil, siyah ikon — `pwsh`).

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Kurulumdan sonra **yeni bir PowerShell 7 penceresi** açın. Kontrol:

```powershell
$PSVersionTable.PSVersion
```

`Major` değeri 7 veya üstü olmalı.

## 2 · Klasöre gidin ve engeli kaldırın

İnternetten indirilen `.ps1` dosyaları Windows tarafından bloke edilir (Mark-of-the-Web):

```powershell
cd C:\Users\<kullanici>\Downloads\mde-assessment-tooling
```

```powershell
Get-ChildItem *.ps1 | Unblock-File
```

Script çalıştırma politikası kapalıysa, **sadece bu oturum için** açın (kalıcı değişiklik yapmaz):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

## 3 · Çalıştırın

Tek komut — toplar, raporu üretir, tarayıcıda açar:

```powershell
.\Run-Assessment.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6 -Logo microsoft
```

Ekranda bir kod belirir → <https://microsoft.com/devicelogin> adresine gidip kodu girin, tenant'taki hesabınızla oturum açın.

### İlk deneme için dar kapsam (1-2 dakika)

```powershell
.\Run-Assessment.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6 -GraphOnly -AlertDays 7 -EventDays 7
```

### Parametreler

| Parametre | Ne işe yarar |
|---|---|
| `-TenantId` | Tenant GUID'i veya `xxx.onmicrosoft.com` (zorunlu) |
| `-ClientId` | Kendi app kaydınız (varsayılan ClientId reddedilirse) |
| `-ClientName "Contoso A.Ş."` | Kapaktaki müşteri adı (boşsa tenant adı) |
| `-Logo microsoft` | Kapak logosu: `template` / `microsoft` / `none` |
| `-GraphOnly` | Defender (securitycenter) API'sini atla |
| `-AlertDays` / `-EventDays` | Telemetri pencereleri (varsayılan 90 / 30) |
| `-SkipCollect` | Toplamayı atla, mevcut JSON'dan raporu yeniden üret |

## 4 · Sonuç

- `mde-assessment-data.json` — çekilen ham veri, elle düzenlenebilir
- `raw\` — her API/KQL çağrısının ham çıktısı (sorun giderme)
- `<Musteri>-MDE-Assessment-<tarih>.html` — rapor

Raporu tarayıcıda açıp metinlere tıklayarak doldurun, sonra **Ctrl+P → Hedef: PDF olarak kaydet** (kenar boşluğu: yok, arka plan grafikleri: açık).

JSON'u elle düzeltip raporu yeniden üretmek isterseniz:

```powershell
.\Run-Assessment.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6 -SkipCollect
```

## Sık çıkan hatalar

| Hata | Çözüm |
|---|---|
| `#Requires -Version 7.0` / sözdizimi hataları | Windows PowerShell 5.1'de çalıştırıyorsunuz → `pwsh` ile açın |
| `... is not digitally signed` | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` |
| `AADSTS65001` / `invalid_client` | Varsayılan ClientId tenant'ta yetkili değil → kendi public client app kaydınızı yapıp `-ClientId` verin (README.md adım 3) |
| Advanced Hunting boş dönüyor | `ThreatHunting.Read.All` consent'i yok ya da Defender RBAC hesabı kısıtlıyor |
| `403` (securitycenter çağrıları) | `-GraphOnly` ile devam edin; exposure score/öneriler elle girilir |
| Türkçe karakterler bozuk | Windows Terminal kullanın (conhost yerine) |

Yetki listesinin tamamı ve app registration adımları için `README.md`.
