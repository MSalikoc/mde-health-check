#Requires -Version 7.0
<#
.SYNOPSIS
    Tek komutla: veri topla → raporu üret → tarayıcıda aç.

.DESCRIPTION
    Ön koşulları kontrol eder, MDE-Collect.ps1 ve MDE-Render.ps1'i sırayla
    çalıştırır. Tüm dosyaların aynı klasörde olması yeterlidir.

.EXAMPLE
    .\Run-Assessment.ps1 -TenantId contoso.onmicrosoft.com

.EXAMPLE
    .\Run-Assessment.ps1 -TenantId <guid> -ClientName "Contoso A.S." -Logo microsoft -GraphOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [string]$ClientId,
    [string]$ClientName,
    [ValidateSet('template', 'microsoft', 'none')][string]$Logo = 'template',
    [switch]$GraphOnly,
    [int]$AlertDays = 90,
    [int]$EventDays = 30,
    [string]$Template,
    [switch]$SkipCollect,         # elde JSON varsa sadece raporu üret
    [switch]$CreateApp            # ön adım: Entra app kaydını oluştur/güncelle
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = $PSScriptRoot
$dataFile = Join-Path $root 'mde-assessment-data.json'

Write-Host ''
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host ' Microsoft Defender for Endpoint — Health Check' -ForegroundColor White
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor DarkGray

# ---------------------------------------------------------- ÖN KOŞULLAR --
Write-Host ''
Write-Host ' Ön koşullar' -ForegroundColor White

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ gerekli. Şu an: $($PSVersionTable.PSVersion). Kurulum: winget install --id Microsoft.PowerShell"
}
Write-Host "  ✓ PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green

foreach ($f in 'MDE-Collect.ps1', 'MDE-Render.ps1') {
    $p = Join-Path $root $f
    if (-not (Test-Path $p)) { throw "$f bulunamadı ($root). Tüm dosyalar aynı klasörde olmalı." }
    # İnternetten indirilen dosyalarda Mark-of-the-Web engelini kaldır
    try { Unblock-File -Path $p -ErrorAction SilentlyContinue } catch { }
}
Write-Host '  ✓ Script dosyaları yerinde (Mark-of-the-Web temizlendi)' -ForegroundColor Green

if (-not $Template) {
    $cand = @(
        (Join-Path $root 'MDE-Health-Assessment-Template.html'),
        (Join-Path (Split-Path $root -Parent) 'MDE-Health-Assessment-Template.html')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $cand) {
        throw 'Şablon bulunamadı. MDE-Health-Assessment-Template.html dosyasını bu klasöre koyun veya -Template ile yol verin.'
    }
    $Template = $cand
}
Write-Host "  ✓ Şablon: $Template" -ForegroundColor Green

$pol = Get-ExecutionPolicy
if ($pol -in 'Restricted', 'AllSigned') {
    Write-Host "  ! Execution policy: $pol — bu oturum için geçici olarak gevşetiliyor" -ForegroundColor Yellow
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}

# ------------------------------------------------------- APP KAYDI (0/2) --
$appFile = Join-Path $root '.mde-app.json'

if ($CreateApp) {
    Write-Host ''
    Write-Host ' 0/2 · Entra app kaydı' -ForegroundColor White
    & (Join-Path $root 'New-MdeApp.ps1') -TenantId $TenantId -OutFile $appFile | Out-Null
}

if (-not $ClientId -and (Test-Path $appFile)) {
    try {
        $saved = Get-Content $appFile -Raw -Encoding utf8 | ConvertFrom-Json
        if ($saved.clientId) {
            $ClientId = $saved.clientId
            Write-Host "  ✓ App kaydı bulundu (.mde-app.json): $ClientId" -ForegroundColor Green
        }
    } catch { }
}

if (-not $ClientId) {
    Write-Host '  ! -ClientId verilmedi ve .mde-app.json yok.' -ForegroundColor Yellow
    Write-Host '    Varsayılan ClientId Defender izinlerine sahip değildir; çağrılar 403 dönebilir.' -ForegroundColor Yellow
    Write-Host "    Önce şunu çalıştırın:  .\New-MdeApp.ps1 -TenantId $TenantId" -ForegroundColor Yellow
    Write-Host ''
}

# --------------------------------------------------------------- TOPLA ---
if (-not $SkipCollect) {
    Write-Host ''
    Write-Host ' 1/2 · Veri toplanıyor' -ForegroundColor White
    Write-Host '  Birazdan bir cihaz kodu görünecek — https://microsoft.com/devicelogin' -ForegroundColor DarkGray

    # NOT: $args otomatik değişken — kendi splat tablomuz farklı isimde olmalı
    $cargs = @{ TenantId = $TenantId; OutFile = $dataFile; AlertDays = $AlertDays; EventDays = $EventDays }
    if ($ClientId)  { $cargs.ClientId = $ClientId }
    if ($GraphOnly) { $cargs.GraphOnly = $true }
    $cargs.RawDumpPath = (Join-Path $root 'raw')

    & (Join-Path $root 'MDE-Collect.ps1') @cargs
    if (-not (Test-Path $dataFile)) { throw 'Toplama tamamlanamadı, JSON oluşmadı.' }
}
else {
    if (-not (Test-Path $dataFile)) { throw "-SkipCollect verildi ama $dataFile yok." }
    Write-Host ''
    Write-Host ' 1/2 · Toplama atlandı (-SkipCollect)' -ForegroundColor DarkGray
}

# --------------------------------------------------------------- ÜRET ----
Write-Host ''
Write-Host ' 2/2 · Rapor üretiliyor' -ForegroundColor White

$rargs = @{ DataFile = $dataFile; Template = $Template; Logo = $Logo }
if ($ClientName) { $rargs.ClientName = $ClientName }

& (Join-Path $root 'MDE-Render.ps1') @rargs

$report = Get-ChildItem -Path $root -Filter '*-MDE-Assessment-*.html' |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($report) {
    Write-Host ''
    Write-Host " Rapor: $($report.FullName)" -ForegroundColor Green
    Write-Host ' Tarayıcıda açılıyor — kalan alanları doldurup Ctrl+P ile PDF alın.' -ForegroundColor DarkGray
    Start-Process $report.FullName
} else {
    Write-Warning 'Rapor dosyası bulunamadı — MDE-Render.ps1 çıktısını kontrol edin.'
}
Write-Host ''
