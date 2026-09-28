<#
.SYNOPSIS
    Toolbar'i silinmis bir calisma kopyasini yeniden duzenlenebilir/kaydedilebilir yapar.

.DESCRIPTION
    Eski surumlerde "Save as HTML" toolbar'i ve icindekiler panelini de siliyordu.
    Sonuc: dosya duzenlenebilir kaliyor ama kaydetme dugmesi, onay sayaci ve
    icindekiler yok - yani uzerine calisip kaydetmek mumkun degil.

    Bu script o paneli sablondan alip dosyaya geri koyar. Iceriginize DOKUNMAZ:
    yalnizca <div id="doc"> blogundan ONCEKI kisim degisir.

    Sablonun kendisi duzeltildi; bu script yalnizca daha once kaydedilmis
    dosyalari kurtarmak icindir.

.EXAMPLE
    .\Repair-WorkingCopy.ps1 -Path .\MDE-Assessment-2026-09-27.html
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Template,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not (Test-Path $Path)) { throw "Dosya bulunamadi: $Path" }
if (-not $Template) {
    $Template = @(
        (Join-Path $PSScriptRoot 'MDE-Health-Assessment-Template.html'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'MDE-Health-Assessment-Template.html')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Template -or -not (Test-Path $Template)) { throw 'Sablon bulunamadi. -Template ile verin.' }
if (-not $OutFile) {
    $OutFile = [IO.Path]::Combine(
        [IO.Path]::GetDirectoryName((Resolve-Path $Path)),
        [IO.Path]::GetFileNameWithoutExtension($Path) + '-EDITABLE.html')
}

$doc = Get-Content $Path -Raw -Encoding utf8
$tpl = Get-Content $Template -Raw -Encoding utf8

if ($doc -match '<div id="bar"') {
    Write-Host ''
    Write-Host '  Bu dosyada toolbar zaten var - onarmaya gerek yok.' -ForegroundColor Yellow
    Write-Host ''
    return
}

$anchor = '<div id="doc"'
$di = $doc.IndexOf($anchor)
if ($di -lt 0) { throw 'Dosyada <div id="doc"> bulunamadi - bu bir rapor kopyasi degil.' }

# Sablonda toolbar + icindekiler: <div id="bar"> ile <div id="doc"> arasi
$ti = $tpl.IndexOf('<div id="bar"')
$tj = $tpl.IndexOf($anchor)
if ($ti -lt 0 -or $tj -lt 0 -or $tj -le $ti) { throw 'Sablonda toolbar blogu bulunamadi.' }
$chrome = $tpl.Substring($ti, $tj - $ti)

$out = $doc.Substring(0, $di) + $chrome + $doc.Substring($di)

# saveHtml() rowtools sinifini da siliyordu; satir araclari geri gelsin
$out = [regex]::Replace($out, '<body class="([^"]*)"', {
    param($m)
    $cls = $m.Groups[1].Value
    if ($cls -notmatch '\browtools\b') { $cls = ($cls + ' rowtools').Trim() }
    "<body class=`"$cls`""
}, 1)
if ($out -notmatch '<body[^>]*class=') { $out = $out -replace '<body>', '<body class="guides rowtools">' }

$out | Set-Content -Path $OutFile -Encoding utf8

$edits = ([regex]::Matches($doc, 'contenteditable')).Count
Write-Host ''
Write-Host "  Duzenlenebilir kopya: $OutFile" -ForegroundColor Green
Write-Host "  toolbar + icindekiler geri kondu; icerige dokunulmadi" -ForegroundColor Gray
Write-Host "  duzenlenebilir alan: $edits" -ForegroundColor Gray
Write-Host ''
Write-Host '  Acip calismaya devam edin. Kaydetmek icin toolbar''daki' -ForegroundColor DarkGray
Write-Host '  "Save working copy" dugmesini kullanin.' -ForegroundColor DarkGray
Write-Host ''
