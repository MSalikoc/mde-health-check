# Hızlı başlangıç (Windows)

Ayrıntılı adım adım yönerge, parametreler, izinler ve sorun giderme için: **[README.md](README.md)**

Bu dosya yalnızca komut sırasıdır.

```powershell
# 1) PowerShell 7 (bir kez) - sonra YENI bir pwsh penceresi acin
winget install --id Microsoft.PowerShell --source winget
```

```powershell
# 2) Dosyalar
git clone https://github.com/MSalikoc/mde-health-check.git
cd mde-health-check
Get-ChildItem *.ps1 | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

```powershell
# 3) Sozdizimi kontrolu - hepsi OK olmali
.\Test-Parse.ps1
```

```powershell
# 4) Entra app kaydi (bir kez, Global Administrator ile giris)
.\New-MdeApp.ps1 -TenantId YOUR-TENANT-ID
```

```powershell
# 5) MUSTERI ORTAMI - sadece JSON uretir, rapor olusmaz
.\MDE-Collect.ps1 -TenantId YOUR-TENANT-ID
```

```powershell
# Ilk deneme icin dar kapsam (1-2 dakika)
.\MDE-Collect.ps1 -TenantId YOUR-TENANT-ID -GraphOnly -AlertDays 7 -EventDays 7
```

```powershell
# 6) KENDI ORTAMINIZ - JSON'dan raporu uretir ve tarayicida acar
.\MDE-Render.ps1 -DataFile .\mde-data-contoso-20260807.json -ClientName "Contoso A.S."
```

> Rapor müşteri ortamında **üretilmez**. Oradan çıkan tek dosya JSON'dur; taslak metinleri müşteri görmez.

## Sonra

Rapor tarayıcıda açılır. Sağ üstteki sayaç kaç **(REVIEW)** işaretli taslak kaldığını gösterir:

- Taslağı okuyun → doğruysa **(REVIEW) rozetine tıklayın** (veya `Alt+tık`), işaret gider metin kalır
- Yanlışsa metne tıklayıp düzeltin, sonra rozeti kaldırın
- Gri italik alanlar otomatik doldurulamayanlar — elle yazın
- Sayaç sıfırlanınca **Ctrl+P → PDF olarak kaydet**

JSON düz metindir — toplayıcının yanlış aldığı bir şeyi düzeltip aynı komutu tekrar çalıştırabilirsiniz.
