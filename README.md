# MDE Health Check — otomatik veri toplama

Rapor şablonunu Microsoft Defender for Endpoint tenant'ından çekilen gerçek veriyle dolduran iki script.

```
MDE-Collect.ps1  →  mde-assessment-data.json  →  MDE-Render.ps1  →  doldurulmuş HTML rapor
   (salt-okunur API)        (elle düzenlenebilir)                      (şablonun kopyası)
```

Aradaki JSON kasıtlı: script'in çekemediği alanları elle JSON'a yazıp render'ı tekrar çalıştırabilirsiniz.

## Gereksinimler

- **PowerShell 7+** (`pwsh`) — Windows, macOS, Linux
- Tenant'ta okuma yetkisi olan bir hesap (Security Reader + Global Reader yeterli)
- Ek modül gerekmez; sadece `Invoke-RestMethod` kullanılır

## Kullanım

```bash
pwsh ./MDE-Collect.ps1 -TenantId contoso.onmicrosoft.com -OutFile ./mde-data.json
```

Ekranda çıkan cihaz kodunu https://microsoft.com/devicelogin adresine girip oturum açarsınız. İlk çalıştırmada tenant'ta consent istenebilir (Global Admin onayı gerekir).

```bash
pwsh ./MDE-Render.ps1 -DataFile ./mde-data.json `
                      -Template ../MDE-Health-Assessment-Template.html `
                      -ClientName "Contoso A.Ş."
```

Çıktı: `Contoso-A-Ş-MDE-Assessment-2026-08-05.html` — tarayıcıda açıp kalan alanları elle doldurun, sonra PDF'e basın.

Tenant olmadan render'ı denemek için:

```bash
pwsh ./MDE-Render.ps1 -DataFile ./sample-data.json -Template ../MDE-Health-Assessment-Template.html
```

### Faydalı parametreler

| Parametre | Açıklama |
|---|---|
| `-ClientId <guid>` | Kendi public client app kaydınız (önerilir, aşağıya bakın) |
| `-GraphOnly` | `api.securitycenter.microsoft.com` çağrılarını atla (token alınamıyorsa) |
| `-AlertDays 90` / `-EventDays 30` | Telemetri pencereleri |
| `-RawDumpPath ./raw` | Ham API/KQL çıktılarını diske yaz (sorun giderme) |
| `-HideDataTables` | Raporda grafik veri tablolarını gizli başlat |
| `-Logo microsoft` | Kapak logosunu Microsoft dört-kare logosuyla değiştir (`template` = şablondaki kalsın, `none` = kaldır) |

> **Önemli:** `-Template` olarak **boş şablonu** verin (`MDE-Health-Assessment-Template.html`).
> `…-SAMPLE.html` zaten dolu olduğu için render sadece grafikleri günceller; KPI ve tablo
> alanları "boş alan" arandığı için atlanır.

## İzinler

Delegated (kullanıcı adına) — hepsi **read-only**:

**Microsoft Graph:** `ThreatHunting.Read.All`, `SecurityEvents.Read.All`, `SecurityAlert.Read.All`, `SecurityIncident.Read.All`, `CustomDetection.Read.All`, `DeviceManagementConfiguration.Read.All`, `Directory.Read.All`, `Policy.Read.All`, `RoleManagement.Read.Directory`, `Organization.Read.All`

**WindowsDefenderATP** (opsiyonel, TVM için): `Vulnerability.Read`, `SecurityRecommendation.Read`, `Ti.Read`, `Score.Read`

### ClientId — çoğu tenant'ta app kaydı ZORUNLU

Varsayılan ClientId (Azure CLI, `04b07795-…`) yalnızca dizin okuma için yetkilidir; **Defender ve güvenlik izinlerine sahip değildir.** Onunla çalıştırırsanız tenant adı ve lisanslar gelir, geri kalan her çağrı `403 Forbidden` döner. Script bunu baştan tespit edip eksik izinleri listeler.

Kalıcı çözüm — **kendi public client app kaydınız**:

1. Entra ID → App registrations → New registration
2. Supported account types: Single tenant
3. Authentication → **Allow public client flows: Yes** (redirect URI gerekmez)
4. API permissions → yukarıdaki **delegated** izinler → Grant admin consent
5. `-ClientId <yeni app id>` ile çalıştırın

## Neyi otomatik dolduruyor

| Rapor alanı | Kaynak |
|---|---|
| Cihaz envanteri, onboarding oranı, platform kırılımı | AH `DeviceInfo` |
| Sensör sağlığı (active/inactive/impaired) | AH `DeviceInfo.SensorHealthState` |
| AV/ASR/baseline yapılandırma uyumu | AH `DeviceTvmSecureConfigurationAssessment` (+KB) |
| ASR audit/block olay sayıları, kural modları | AH `DeviceEvents` `ActionType startswith "Asr"` |
| Zafiyet dağılımı, top yazılım, yazılım envanteri | AH `DeviceTvmSoftwareVulnerabilities`, `…SoftwareInventory` |
| Exposure score, güvenlik önerileri, indicator'lar | MDE API `/exposureScore`, `/recommendations`, `/indicators` |
| Secure Score + kategori kırılımı + öneri listesi | Graph `security/secureScores` |
| Uyarı/olay hacmi, severity, taktik, MTTD/MTTR | Graph `security/alerts_v2`, `security/incidents` |
| Özel tespit kuralları | Graph `security/rules/detectionRules` |
| Lisans envanteri | Graph `subscribedSkus` |
| Intune politikaları + AV exclusion'ları | Graph `deviceManagement/configurationPolicies` |
| Ayrıcalıklı roller, PIM, Conditional Access | Graph `directoryRoles`, `roleManagement`, `conditionalAccess/policies` |

## Neyi dolduramaz (elle)

Anlatım metinleri, risk yorumları, bulgu severity kararları, effort/owner/tarih, olgunluk puanları, yol haritası, Threat Analytics kullanımı (API yok), proxy/TLS bypass doğrulaması (client analyzer), SOC operasyon modeli ve tatbikat olgunluğu, exclusion gerekçeleri.

Render sonunda rapora **"Automated Collection Notes"** sayfası eklenir: neyin otomatik dolduğu, hangi çağrıların başarısız olduğu ve elle tamamlanacaklar listesi. Teslimden önce o sayfayı silin.

## Bilinen sınırlar

- **ASR kural modları** telemetriden türetilir; hiç olay üretmeyen bir kural "yapılandırılmamış" gibi görünür. Kesin mod bilgisi için Intune politika export'unu (`configurationPolicies`) çapraz kontrol edin.
- **Exclusion listesi** yalnızca Intune ile yönetilen politikalardan çıkarılır; GPO/yerel exclusion'lar görünmez (bunlar için live response veya registry sorgusu gerekir).
- **Advanced Hunting** 30 günlük veri tutar; daha uzun trendler için Sentinel'den çekilmelidir.
- Graph `security/alerts_v2` sayfalama ile 1000'er çekilir; çok büyük tenant'larda `-AlertDays` değerini düşürün.
- Script hiçbir yazma işlemi yapmaz; hata alan her çağrı atlanır ve raporun uyarı sayfasına yazılır.

## Test durumu

Script'ler bu makinede **çalıştırılarak test edilmedi** (PowerShell kurulu değil). Şablon eşleştirme mantığı `sample-data.json` ile denenmek üzere hazır — ilk gerçek çalıştırmada `-RawDumpPath` ile başlamanız önerilir.
