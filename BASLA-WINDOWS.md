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
.\New-MdeApp.ps1 -TenantId <tenant-guid>
```

```powershell
# 5) Toplama + rapor (Security Reader + Global Reader ile giris)
.\Run-Assessment.ps1 -TenantId <tenant-guid> -Logo microsoft
```

```powershell
# Ilk deneme icin dar kapsam (1-2 dakika)
.\Run-Assessment.ps1 -TenantId <tenant-guid> -GraphOnly -AlertDays 7 -EventDays 7
```

> `<tenant-guid>` yazarken **köşeli parantezleri silin**. PowerShell'de `<` `>` yönlendirme operatörüdür ve hata verir.

## Sonra

Rapor tarayıcıda açılır. Sağ üstteki sayaç kaç **(REVIEW)** işaretli taslak kaldığını gösterir:

- Taslağı okuyun → doğruysa **(REVIEW) rozetine tıklayın** (veya `Alt+tık`), işaret gider metin kalır
- Yanlışsa metne tıklayıp düzeltin, sonra rozeti kaldırın
- Gri italik alanlar otomatik doldurulamayanlar — elle yazın
- Sayaç sıfırlanınca **Ctrl+P → PDF olarak kaydet**

JSON'u elle düzeltip raporu yeniden üretmek:

```powershell
.\Run-Assessment.ps1 -TenantId <tenant-guid> -SkipCollect
```
