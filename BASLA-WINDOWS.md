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
# 5) Toplama + rapor (Security Reader + Global Reader ile giris)
.\Run-Assessment.ps1 -TenantId YOUR-TENANT-ID
```

```powershell
# Ilk deneme icin dar kapsam (1-2 dakika)
.\Run-Assessment.ps1 -TenantId YOUR-TENANT-ID -GraphOnly -AlertDays 7 -EventDays 7
```

> `YOUR-TENANT-ID` yerine kendi tenant GUID'inizi veya `contoso.onmicrosoft.com` alan adınızı yazın. Çevresine `< >` koymayın — kabukta bunlar yönlendirme operatörüdür ve komut çalışmadan hata verir.

## Sonra

Rapor tarayıcıda açılır. Sağ üstteki sayaç kaç **(REVIEW)** işaretli taslak kaldığını gösterir:

- Taslağı okuyun → doğruysa **(REVIEW) rozetine tıklayın** (veya `Alt+tık`), işaret gider metin kalır
- Yanlışsa metne tıklayıp düzeltin, sonra rozeti kaldırın
- Gri italik alanlar otomatik doldurulamayanlar — elle yazın
- Sayaç sıfırlanınca **Ctrl+P → PDF olarak kaydet**

JSON'u elle düzeltip raporu yeniden üretmek:

```powershell
.\Run-Assessment.ps1 -TenantId YOUR-TENANT-ID -SkipCollect
```
