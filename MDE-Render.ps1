#Requires -Version 7.0
<#
.SYNOPSIS
    MDE-Collect.ps1 çıktısını (JSON) rapor şablonuna işler.

.DESCRIPTION
    Şablondaki grafikleri başlıklarına, KPI kutularını etiketlerine, tabloları
    satır etiketlerine göre eşleştirir. Otomatik doldurulamayan her alan boş
    (yer tutuculu) kalır — danışman elle tamamlar.

.EXAMPLE
    ./MDE-Render.ps1 -DataFile ./mde-assessment-data.json `
                     -Template ../MDE-Health-Assessment-Template.html `
                     -OutFile  ./Contoso-MDE-Assessment.html
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DataFile,
    # Bos birakilirsa script'in yanindaki (veya bir ust klasordeki) sablon kullanilir
    [string]$Template,
    [string]$OutFile,
    [string]$ClientName,          # boşsa JSON'daki tenant adı kullanılır
    [switch]$HideDataTables,      # grafik veri tablolarını gizli başlat

    # New-Survey.ps1 formundan dönen cevaplar. Yalnızca hâlâ boş olan hücreleri
    # doldurur - toplanan veri her zaman kazanır - ve "Self-reported" diye işaretler.
    [string]$SurveyFile,

    # Kapak logosu: template = şablondaki logoyu koru, microsoft = Microsoft
    # dört-kare logosu, none = logoyu kaldır
    [ValidateSet('template', 'microsoft', 'none')][string]$Logo = 'template'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not $Template) {
    $Template = @(
        (Join-Path $PSScriptRoot 'MDE-Health-Assessment-Template.html'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'MDE-Health-Assessment-Template.html')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Template) {
        throw 'Sablon bulunamadi. MDE-Health-Assessment-Template.html dosyasini bu klasore koyun veya -Template ile yol verin.'
    }
}

$d = Get-Content $DataFile -Raw -Encoding utf8 | ConvertFrom-Json
$html = Get-Content $Template -Raw -Encoding utf8
$filled = [ordered]@{ charts = 0; kpi = 0; rows = 0; fields = 0 }

if (-not $OutFile) {
    $name = if ($ClientName) { $ClientName } elseif ($d.meta.tenantName) { $d.meta.tenantName } else { 'MDE' }
    $safe = ($name -replace '[^\w\-]', '-') -replace '-+', '-'
    $OutFile = "./$safe-MDE-Assessment-$(Get-Date -Format yyyy-MM-dd).html"
}

function Esc([string]$s) { $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }

# Toplanamayan bir tablo icin ConvertFrom-Json $null dondurur; @($null) tek elemanli
# NULL dizi uretir ve ilk property erisiminde "array index evaluated to null" hatasi
# verir. Bir tablo her zaman opsiyoneldir - API bloke olabilir - bu yuzden tum tablo
# okumalari buradan gecer.
function Rows($Table) { return @($Table | Where-Object { $null -ne $_ }) }

# Alan puani (0-100) -> olgunluk seviyesi (1-5). Bantlar CONSULTANT-GUIDE.md'de tanimli;
# 95 ve 60 sinirlari checklist'in Compliant/Partial esikleriyle ayni olsun diye secildi.
# BURADAN BASKA YERDE seviye hesaplamayin - grafik, tablo ve dokuman ayrilirsa rapor kendi
# icinde celisir.
function Level([double]$Score) {
    if ($Score -ge 95) { return 5 }
    if ($Score -ge 85) { return 4 }
    if ($Score -ge 60) { return 3 }
    if ($Score -ge 30) { return 2 }
    return 1
}

# ------------------------------------------------------------- GRAFİKLER --
# <div class="chart" data-type="..."> … <div class="ct">Başlık</div> … <table class="data"> … </table> … </div>

# ============================================================================
#  TURETILMIS VERI
#  Toplayicinin uretemedigi ama toplanan veriden hesaplanabilen alanlar.
#  Grafik doldurma pasindan ONCE calisir ki $d.charts'a eklenenler de islensin.
# ============================================================================
$cfgAll = Rows $d.tables.secureConfiguration

# Bir alan puaninin nereden geldigini tek cumlede anlatir: kac kontrolun ortalamasi ve
# ortalamanin sakladigi en zayif iki kontrol. Ortalama, %100'deki kontrollerin arkasina
# %11'deki tamper protection'i saklayabiliyor - rakamin yanina kaniti koymadan seviye
# yazmak yaniltici olur.
function Sub-Evidence {
    param([string]$Subcategory)
    $rows = @($cfgAll | Where-Object { $_.subcategory -eq $Subcategory })
    if ($rows.Count -eq 0) { return '' }
    $avg = [math]::Round(($rows | Measure-Object compliance -Average).Average)
    $weak = @($rows | Sort-Object compliance | Select-Object -First 2 |
              Where-Object { [double]$_.compliance -lt 60 } |
              ForEach-Object { "$($_.name) $([math]::Round([double]$_.compliance))%" })
    $txt = "Mean $avg% across $($rows.Count) $Subcategory controls"
    if ($weak.Count) { $txt += "; the mean hides $($weak -join ' and ')" }
    return "$txt."
}

function Sub-Avg {
    param([string]$Subcategory)
    $rows = @($cfgAll | Where-Object { $_.subcategory -eq $Subcategory })
    if ($rows.Count -eq 0) { return $null }
    return [math]::Round(($rows | Measure-Object compliance -Average).Average)
}
function Scid-Pct {
    param([string]$Id)
    $r = $cfgAll | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($r) { [math]::Round([double]$r.compliance) } else { $null }
}
# ConvertFrom-Json nesnesine YENI ozellik atanamaz; varsa yaz, yoksa ekle
function Set-Chart {
    param([string]$Name, $Series)
    if ($d.charts.PSObject.Properties.Name -contains $Name) { $d.charts.$Name = $Series }
    else { $d.charts | Add-Member -NotePropertyName $Name -NotePropertyValue $Series -Force }
}

# Toplayici, sayilari calistigi makinenin yerel ayarina gore bicimlendiriyor:
# Turkce Windows'ta 33426200 -> "33.426.200". Eski kod noktalari koruyup [double]'a
# veriyordu ve render "Cannot convert value 33.426.200" ile tamamen duruyordu.
# Hem nokta hem virgul, hem binlik hem ondalik olarak gelebilir; ayirt etme kurali:
# ayractan sonra TAM 3 rakam varsa ve birden fazla grup varsa binlik ayracidir.
function ConvertTo-Num {
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = ($Text -replace '[^\d,.\-]', '')
    if (-not $t) { return $null }
    if ($t -match '^-?\d{1,3}([.,]\d{3})+$') { $t = $t -replace '[.,]', '' }
    else { $t = $t -replace ',', '.' }
    $out = 0.0
    if ([double]::TryParse($t, [Globalization.NumberStyles]::Float,
                           [Globalization.CultureInfo]::InvariantCulture, [ref]$out)) { return $out }
    return $null
}

function Kpi-Num {
    param([string]$Name)
    ConvertTo-Num "$($d.kpi.$Name)"
}

# --- toplayicinin yanlis KPI'sindan dogan bulgulari ayikla ---
if ($d.tables.findings) {
    $tamperPct = Scid-Pct 'scid-2003'
    if ($null -ne $tamperPct -and $tamperPct -ge 95) {
        $before = (Rows $d.tables.findings).Count
        $d.tables.findings = @($d.tables.findings | Where-Object { $_.finding -notmatch 'Tamper protection is enabled on only' })
        $after = (Rows $d.tables.findings).Count
        if ($after -lt $before) {
            $i = 1
            foreach ($f in $d.tables.findings) { $f.id = 'F-{0:D2}' -f $i; $i++ }
            foreach ($sev in 'Critical','High','Medium','Low') {
                $d.kpi.$sev = @($d.tables.findings | Where-Object { $_.severity -eq $sev }).Count
            }
            $d.kpi.'Critical Findings' = @($d.tables.findings | Where-Object { $_.severity -eq 'Critical' }).Count
            Set-Chart 'Findings by severity' @(
                'Critical','High','Medium','Low' | ForEach-Object {
                    $sv = $_
                    Write-Output -NoEnumerate @($sv, @($d.tables.findings | Where-Object { $_.severity -eq $sv }).Count)
                })
        }
    }
    # bulgu domain dagilimi (toplayicida bos geliyordu)
    $byDom = @($d.tables.findings | Where-Object { $_.domain } | Group-Object domain |
               Sort-Object Count -Descending | Select-Object -First 6)
    if ($byDom.Count) {
        Set-Chart 'Findings by domain' @($byDom | ForEach-Object {
            Write-Output -NoEnumerate @($_.Name, $_.Count)
        })
    }
}

# --- domain olgunluk puanlari (yalnizca savunulabilir olanlar) ---
$dom = [ordered]@{
    'Deployment & Onboarding'    = Kpi-Num 'Onboarding Rate'
    'Next-Generation Protection' = Sub-Avg 'Antivirus'
    'Attack Surface Reduction'   = Sub-Avg 'Attack Surface Reduction'
    'Vulnerability Management'   = $null
    'EDR & Automation'           = Sub-Avg 'EDR'
    'Identity & Access (RBAC)'   = $null
    'Integration & SIEM'         = $null
    'Security Operations'        = $null
}
$tot = Kpi-Num 'Total alerts (90d)'
$res = Kpi-Num 'Resolved'
if ($tot -gt 0) { $dom['Security Operations'] = [math]::Round(100 * $res / $tot) }
$ss = Kpi-Num 'Secure score for devices'
if ($ss) { $dom['Vulnerability Management'] = [math]::Round($ss) }

if (@($dom.Values | Where-Object { $null -ne $_ }).Count -gt 0) {
    $series = @($dom.Keys | ForEach-Object { Write-Output -NoEnumerate @($_, $dom[$_]) })
    # sablondaki baslik en-dash kullaniyor
    Set-Chart 'Domain maturity score (0–100)' $series
}

# --- lisanslardan MDE plan hakki ---
function Sku-Sum {
    param([string]$Pattern)
    $rows = @($d.tables.licenses | Where-Object { $_.partNumber -match $Pattern })
    if ($rows.Count -eq 0) { return $null }
    return [pscustomobject]@{
        purchased = ($rows | Measure-Object purchased -Sum).Sum
        assigned  = ($rows | Measure-Object assigned -Sum).Sum
        available = ($rows | Measure-Object available -Sum).Sum
        skus      = (($rows | ForEach-Object { $_.partNumber }) -join ', ')
    }
}
$lic = @{
    p2  = Sku-Sum 'E5|WIN_DEF_ATP|DEFENDER_ENDPOINT_P2|IDENTITY_THREAT'
    p1  = Sku-Sum '_E3|SPE_E3|DEFENDER_ENDPOINT_P1'
    bp  = Sku-Sum 'Business.?.?Premium'
    tvm = Sku-Sum 'TVM_Premium'
}

# --------------------------------------- OLGUNLUK: MEVCUT vs HEDEF (1-5) --
if ($dom) {
    $five = @{}
    foreach ($k in $dom.Keys) { if ($null -ne $dom[$k]) { $five[$k] = Level $dom[$k] } }
    if ($five.Count) {
        $labels = @('Deployment','Protection','ASR','TVM','EDR','Hunting','Integration','Governance')
        $src = @('Deployment & Onboarding','Next-Generation Protection','Attack Surface Reduction',
                 'Vulnerability Management','EDR & Automation','', '', '')
        $series = @()
        for ($i = 0; $i -lt $labels.Count; $i++) {
            $cur = if ($src[$i] -and $five.ContainsKey($src[$i])) { $five[$src[$i]] } else { '' }
            $tgt = if ($cur -ne '') { [math]::Min(5, [int]$cur + 1) } else { '' }
            $series += , @($labels[$i], $cur, $tgt)
        }
        Set-Chart 'Maturity: current vs. target (1–5)' $series
    }
}

# ------------------------------------------ WEB KORUMA KATEGORILERI -------
if ($d.tables.webProtection) {
    $lbl = @{
        'SmartScreenUrlWarning'                = 'Malicious or suspicious URL (SmartScreen)'
        'SmartScreenAppWarning'                = 'Untrusted application (SmartScreen)'
        'ExploitGuardNetworkProtectionBlocked' = 'Blocked by network protection'
        'ExploitGuardNetworkProtectionAudited' = 'Audited by network protection'
        'NetworkProtectionUserBypassEvent'     = 'User bypassed the block'
    }
    $series = @($d.tables.webProtection | Sort-Object -Property @{ Expression = { [int]$_.events }; Descending = $true } |
        ForEach-Object {
            $n = if ($lbl[$_.action]) { $lbl[$_.action] } else { $_.action }
            Write-Output -NoEnumerate @($n, [int]$_.events)
        })
    if ($series.Count) { Set-Chart 'Top blocked web categories (requests)' $series }
}



$rxChart = [regex]'(?s)<div class="chart"[^>]*>.*?</table>\s*(?:<div class="datahint">.*?</div>\s*)?</div>'
$html = $rxChart.Replace($html, {
    param($m)
    $block = $m.Value
    $t = [regex]::Match($block, '<div class="ct">([^<]+)</div>')
    if (-not $t.Success) { return $block }
    $title = [System.Net.WebUtility]::HtmlDecode($t.Groups[1].Value)

    $series = $null
    foreach ($k in $d.charts.PSObject.Properties.Name) {
        if ([System.Net.WebUtility]::HtmlDecode($k) -eq $title) { $series = $d.charts.$k; break }
    }
    if (-not $series) { return $block }

    # JSON: [["Etiket", 12], ["Etiket2", 8, 3]] → satır etiketi + değerler
    # NOT: iç scriptblock alt kapsamda çalışır; sayaçlar $script: olmalı.
    $script:chartRows = @($series)
    $script:chartIdx = 0
    $rxRow = [regex]'(?s)<tr>\s*<td contenteditable>(.*?)</td>(.*?)</tr>'
    $newBlock = $rxRow.Replace($block, {
        param($rm)
        if ($script:chartIdx -ge $script:chartRows.Count) { $script:chartIdx++; return $rm.Value }
        $row = @($script:chartRows[$script:chartIdx]); $script:chartIdx++
        $label = Esc([string]$row[0])
        $vals = $row[1..($row.Count - 1)]
        $cells = ($vals | ForEach-Object { "<td contenteditable>$_</td>" }) -join ''
        # hedef satırdaki değer hücresi sayısı kadar hücre üret
        $need = ([regex]::Matches($rm.Groups[2].Value, '<td contenteditable>')).Count
        if ($need -gt $vals.Count) {
            $cells += (1..($need - $vals.Count) | ForEach-Object { '<td contenteditable></td>' }) -join ''
        }
        "<tr><td contenteditable>$label</td>$cells</tr>"
    })

    # Veri şablondaki satır sayısını aşıyorsa kalan satırları ekle
    if ($script:chartIdx -lt $script:chartRows.Count) {
        $extra = ''
        for ($k = $script:chartIdx; $k -lt $script:chartRows.Count; $k++) {
            $row = @($script:chartRows[$k])
            $cells = ($row[1..($row.Count - 1)] | ForEach-Object { "<td contenteditable>$_</td>" }) -join ''
            $extra += "<tr><td contenteditable>$(Esc([string]$row[0]))</td>$cells</tr>"
        }
        $newBlock = $newBlock.Replace('</tbody>', $extra + '</tbody>')
    }

    $script:filled.charts++
    return $newBlock
})

# ------------------------------------------------------------------ KPI --
$rxKpi = [regex]'(<div class="v f" contenteditable data-ph="[^"]*">)</div>(<div class="k">)([^<]+)(</div>)'
$html = $rxKpi.Replace($html, {
    param($m)
    $label = [System.Net.WebUtility]::HtmlDecode($m.Groups[3].Value)
    $v = $null
    foreach ($k in $d.kpi.PSObject.Properties.Name) {
        if ([System.Net.WebUtility]::HtmlDecode($k) -eq $label) { $v = $d.kpi.$k; break }
    }
    if ($null -eq $v -or "$v" -eq '') { return $m.Value }
    $script:filled.kpi++
    "$($m.Groups[1].Value)$(Esc "$v")</div>$($m.Groups[2].Value)$($m.Groups[3].Value)$($m.Groups[4].Value)"
})

# ------------------------------------------------- CİHAZ ENVANTERİ TABLOSU
if ($d.tables.deviceInventory) {
    foreach ($r in $d.tables.deviceInventory) {
        # Şablon satır etiketi ek taşıyabilir ("… (legacy / UDS)") → önek eşleşmesi
        $plat = [regex]::Escape($r.platform)
        $rx = [regex]"(?s)<tr><td>($plat[^<]*)</td>(.*?)</tr>"
        $html = $rx.Replace($html, {
            param($m)
            $rowLabel = $m.Groups[1].Value
            $rest = $m.Groups[2].Value
            $script:invVals = @("$($r.discovered)", "$($r.onboarded)", "$($r.gap)", "$($r.coverage)")
            $script:invIdx = 0
            $new = [regex]::Replace($rest, '<td class="num f" contenteditable data-ph="[^"]*"></td>', {
                param($cm)
                if ($script:invIdx -lt $script:invVals.Count) {
                    $v = $script:invVals[$script:invIdx]; $script:invIdx++
                    "<td class=`"num f`" contenteditable data-ph=`"––`">$v</td>"
                } else { $cm.Value }
            })
            $script:filled.rows++
            "<tr><td>$rowLabel</td>$new</tr>"
        }, 1)
    }
}

# ------------------------------------------- TOP VULNERABLE SOFTWARE ------
if ($d.tables.topVulnerableSoftware) {
    $rxTbl = [regex]'(?s)(<h3>Top Vulnerable Software</h3>\s*<table class="t compact">.*?<tbody>)(.*?)(</tbody>)'
    $html = $rxTbl.Replace($html, {
        param($m)
        $script:swIdx = 0
        $body = [regex]::Replace($m.Groups[2].Value, '(?s)<tr>.*?</tr>', {
            param($rm)
            $sw = Rows $d.tables.topVulnerableSoftware
            if ($script:swIdx -ge $sw.Count) { $script:swIdx++; return $rm.Value }
            $s = $sw[$script:swIdx]; $script:swIdx++
            $script:filled.rows++
            @"
<tr><td class="f" contenteditable data-ph="––">$(Esc $s.product)</td><td class="f" contenteditable data-ph="––">$(Esc $s.vendor)</td><td class="num f" contenteditable data-ph="––">$($s.devices)</td><td class="num f" contenteditable data-ph="––">$($s.cves)</td><td class="num f" contenteditable data-ph="––"></td><td class="f" contenteditable data-ph="––"></td></tr>
"@
        })
        "$($m.Groups[1].Value)$body$($m.Groups[3].Value)"
    }, 1)
}

# ------------------------------------------- SECURE SCORE ÖNERİLERİ -------
if ($d.tables.secureScoreActions) {
    $rxTbl = [regex]'(?s)(<h3>Microsoft Secure Score — Top Recommended Actions</h3>\s*<table class="t compact">.*?<tbody>)(.*?)(</tbody>)'
    $html = $rxTbl.Replace($html, {
        param($m)
        $script:ssIdx = 0
        $body = [regex]::Replace($m.Groups[2].Value, '(?s)<tr>.*?</tr>', {
            param($rm)
            $a = Rows $d.tables.secureScoreActions
            if ($script:ssIdx -ge $a.Count) { $script:ssIdx++; return $rm.Value }
            $x = $a[$script:ssIdx]; $script:ssIdx++
            $script:filled.rows++
            @"
<tr><td class="f" contenteditable data-ph="––">$(Esc $x.action)</td><td class="num f" contenteditable data-ph="+––">$(if ($null -ne $x.impact -and [double]$x.impact -gt 0) { "+$([math]::Round([double]$x.impact, 1))" })</td><td class="f" contenteditable data-ph="––">$(Esc $x.state)</td><td class="f" contenteditable data-ph="––">$(Esc $x.category)</td><td class="f" contenteditable data-ph="––"></td></tr>
"@
        })
        "$($m.Groups[1].Value)$body$($m.Groups[3].Value)"
    }, 1)
}

# ============================================================================
#  GENEL TABLO ESLEYICI
#  Baslik altindaki tabloda satir etiketine gore hucreleri doldurur.
#  Map: 'satir etiketi regex' -> @{ v = @('deger1','deger2'); status='pass'; sev='high' }
#  v icindeki bos string o hucreye dokunmaz.
# ============================================================================
$ST_OPTS  = @(@('', 'Not assessed'), @('pass', 'Compliant'), @('partial', 'Partial'), @('fail', 'Non-compliant'), @('na', 'N/A'))
$SEV_OPTS = @(@('', 'Severity'), @('critical', 'Critical'), @('high', 'High'), @('medium', 'Medium'), @('low', 'Low'))

function New-Select {
    param([string]$Class, $Opts, [string]$Value)
    $o = ''
    foreach ($pair in $Opts) {
        $sel = if ($pair[0] -eq $Value) { ' selected' } else { '' }
        $o += "<option value=`"$($pair[0])`"$sel>$($pair[1])</option>"
    }
    return "<select class=`"$Class`" data-v=`"$Value`">$o</select>"
}

function Strip-Tags {
    param([string]$s)
    return ([regex]::Replace($s, '<[^>]+>', ' ') -replace '&amp;', '&' -replace '\s+', ' ').Trim()
}

function Fill-Rows {
    param(
        [string]$Heading,     # tabloyu bulmak icin onundeki h3 metni (bos ise ilk tablo)
        [hashtable]$Map,
        [string]$HeaderCell   # h3'u olmayan tablolar icin: tabloya ait benzersiz <th> metni
    )
    $anchor = if ($Heading) { [regex]::Escape($Heading) } else { '' }
    # h3 basliginda class olabilir (<h3 class="mt0">...)
    $rx = if ($HeaderCell) {
        # Bazi tablolarin kendi h3'u yok (ornegin Bolum 14 governance tablosu, RBAC
        # basligi altindaki ikinci tablo). Onlari kendi sutun basligindan yakala.
        $hc = [regex]::Escape($HeaderCell)
        [regex]("(?s)(<table class=`"t[^`"]*`">\s*<thead>(?:(?!</table>).)*?$hc(?:(?!</table>).)*?</thead>)(.*?)(</table>)")
    } elseif ($Heading) {
        # baslik ile tablo arasinda aciklama paragrafi olabilir; baska h3'e gecmeden ilk tabloyu al
        [regex]("(?s)(<h3[^>]*>$anchor</h3>(?:(?!<h3).)*?<table class=`"t[^`"]*`">)(.*?)(</table>)")
    } else { $null }
    if (-not $rx -or -not $rx.IsMatch($script:html)) { return 0 }

    $script:rowsFilled = 0
    $script:html = $rx.Replace($script:html, {
        param($m)
        $body = [regex]::Replace($m.Groups[2].Value, '(?s)<tr>.*?</tr>', {
            param($rm)
            $row = $rm.Value
            if ($row -match '<th') { return $row }
            $first = [regex]::Match($row, '(?s)<td[^>]*>(.*?)</td>')
            if (-not $first.Success) { return $row }
            $label = Strip-Tags $first.Groups[1].Value

            $entry = $null
            foreach ($k in $Map.Keys) {
                if ($label -match $k) { $entry = $Map[$k]; break }
            }
            if (-not $entry) { return $row }

            # secici hucreleri
            if ($entry.status) {
                $row = $row -replace '<td class="sel"></td>', ('<td class="sel">' + (New-Select 'st' $ST_OPTS $entry.status) + '</td>')
            }
            if ($entry.sev) {
                $row = $row -replace '<td class="sev"></td>', ('<td class="sev">' + (New-Select 'sev' $SEV_OPTS $entry.sev) + '</td>')
            }

            # duzenlenebilir hucreler (sirayla); entry.draft ise REVIEW isaretli
            if ($entry.v) {
                $script:cellIdx = 0
                $script:cellDraft = [bool]$entry.draft
                $script:cellVals = @($entry.v)
                $row = [regex]::Replace($row, '<td([^>]*class="[^"]*\bf\b[^"]*"[^>]*data-ph="[^"]*")></td>', {
                    param($cm)
                    if ($script:cellIdx -ge $script:cellVals.Count) { return $cm.Value }
                    $val = $script:cellVals[$script:cellIdx]
                    $script:cellIdx++
                    if ("$val" -eq '') { return $cm.Value }
                    $inner = if ($script:cellDraft) { "<span class=`"draft`">$val</span>" } else { "$val" }
                    "<td$($cm.Groups[1].Value)>$inner</td>"
                })
            }
            $script:rowsFilled++
            return $row
        })
        "$($m.Groups[1].Value)$body$($m.Groups[3].Value)"
    }, 1)

    $script:filled.rows += $script:rowsFilled
    return $script:rowsFilled
}

$script:html = $html   # yardimci fonksiyonlar script kapsamini kullanir

# ---------------------------------------------------------- BULGU KAYDI --
if ($d.tables.findings) {
    $map = @{}
    foreach ($f in $d.tables.findings) {
        $sev = if ($f.severity) { $f.severity.ToLower() } else { '' }
        $st = switch ($f.status) {
            'Open'        { 'fail' }
            'In progress' { 'partial' }
            'Accepted'    { 'na' }
            default       { 'fail' }
        }
        # Due, toplayici doldurmadiysa raporun kendi severity tanimindan turer
        # (Bolum 01: Critical hemen, High 30 gun, Medium 90 gun, Low rutin is).
        # Efor ve sahip bilerek bos birakilir - CONSULTANT-GUIDE.md'ye bakin.
        $due = $f.due
        if (-not $due) {
            $base = try { [datetime]::Parse($d.meta.generatedUtc) } catch { Get-Date }
            $due = switch ($sev) {
                'critical' { 'Immediate' }
                'high'     { $base.AddDays(30).ToString('dd.MM.yyyy') }
                'medium'   { $base.AddDays(90).ToString('dd.MM.yyyy') }
                'low'      { 'Next review' }
                default    { '' }
            }
        }
        $map["^$([regex]::Escape($f.id))$"] = @{
            v      = @($f.finding, $f.domain, $f.effort, $f.owner, $due)
            sev    = $sev
            status = $st
        }
    }
    $n = Fill-Rows -Heading '' -Map $map
    # Bulgu kaydinda h3 basligi yok; tabloyu ID sutunundan bul
    $script:findingMap = $map
    $script:html = [regex]::Replace($script:html, '(?s)(<tr><td>F-\d\d</td>.*?</tr>)', {
        param($rm)
        $row = $rm.Value
        $id = [regex]::Match($row, '<td>(F-\d\d)</td>').Groups[1].Value
        $key = "^$([regex]::Escape($id))$"
        if (-not $script:findingMap.ContainsKey($key)) { return $row }
        $e = $script:findingMap[$key]
        $row = $row -replace '<td class="sev"></td>', ('<td class="sev">' + (New-Select 'sev' $SEV_OPTS $e.sev) + '</td>')
        $row = $row -replace '<td class="sel"></td>', ('<td class="sel">' + (New-Select 'st' $ST_OPTS $e.status) + '</td>')
        $script:cellIdx = 0
        $script:cellVals = @($e.v)
        $row = [regex]::Replace($row, '<td([^>]*class="[^"]*\bf\b[^"]*"[^>]*data-ph="[^"]*")></td>', {
            param($cm)
            if ($script:cellIdx -ge $script:cellVals.Count) { return $cm.Value }
            $val = $script:cellVals[$script:cellIdx]
            $script:cellIdx++
            if ("$val" -eq '') { return $cm.Value }
            "<td$($cm.Groups[1].Value)>$val</td>"
        })
        $script:filled.rows++
        return $row
    })
}


# --------------------------------------------- TOP FINDINGS / STRENGTHS --
# NOT: bunlar tablo degil <ol>/<ul> listesi -> data-ph uzerinden doldurulur
function Fill-Ph {
    param([string]$Ph, [string]$Text)
    if (-not $Text) { return }
    $script:phText = $Text
    $rx = [regex]('(?s)(<(\w+)[^>]*class="[^"]*\bf\b[^"]*"[^>]*data-ph="' + [regex]::Escape($Ph) + '"[^>]*>)</\2>')
    if (-not $rx.IsMatch($script:html)) { return }
    $script:html = $rx.Replace($script:html, {
        param($m)
        $script:filled.rows++
        "$($m.Groups[1].Value)<span class=`"draft`">$(Esc $script:phText)</span></$($m.Groups[2].Value)>"
    }, 1)
}

if ($d.tables.findings) {
    $top = @($d.tables.findings |
        Sort-Object @{ Expression = { switch ($_.severity) { 'Critical' {0} 'High' {1} 'Medium' {2} default {3} } } } |
        Select-Object -First 5)
    for ($i = 0; $i -lt $top.Count; $i++) {
        $f = $top[$i]
        Fill-Ph "[Finding $($i + 1)]" "$($f.id) - $($f.finding) [$($f.severity)]"
    }
}

# guclu yonler: yuksek uyumlu kritik kontroller
$strong = @($cfgAll |
    Where-Object { $_.compliance -ge 98 -and $_.applicable -ge 50 -and $_.subcategory -in 'Antivirus','EDR','Firewall','Bitlocker','SmartScreen' } |
    Sort-Object -Property @{ Expression = { $_.applicable }; Descending = $true } | Select-Object -First 3)
for ($i = 0; $i -lt $strong.Count; $i++) {
    $c = $strong[$i]
    Fill-Ph "[Strength $($i + 1)]" "$($c.name) - $([math]::Round([double]$c.compliance))% of $($c.applicable) devices"
}


# ------------------------------------------------ ONBOARDING GAP ANALYSIS -
# Kapsam disi kalan platformlar cihaz envanterinden dogrudan cikarilabiliyor
if ($d.tables.deviceInventory) {
    $gaps = @($d.tables.deviceInventory | Where-Object { [int]$_.gap -gt 0 } |
              Sort-Object -Property @{ Expression = { [int]$_.gap }; Descending = $true } | Select-Object -First 4)
    $rootCause = @{
        'Windows Server 2012 R2' = 'Legacy operating system - requires the modern unified agent'
        'WindowsXp'              = 'Out-of-support operating system - cannot be onboarded'
        'Windows7'               = 'Out-of-support operating system - cannot be onboarded'
        'Windows2003'            = 'Out-of-support operating system - cannot be onboarded'
        'Linux servers'          = 'Onboarding package not deployed to the Linux estate'
        'Android'                = 'Mobile onboarding through Intune not configured'
        'iOS / iPadOS'           = 'Mobile onboarding through Intune not configured'
    }
    $i = 0
    $mapG = @{}
    foreach ($g in $gaps) {
        $i++
        $name = "$($g.platform)"
        if (-not $name) { $name = 'Unidentified platform' }
        $cause = $rootCause[$name]
        if (-not $cause) { $cause = 'Discovered by device inventory but no sensor deployed - confirm the population with the endpoint team' }
        $ph = @('[e.g. remote branch laptops]', '[e.g. legacy servers]', '[e.g. other AD domain]', '[…]')[$i - 1]
        if ($ph) {
            Fill-Ph $ph "$name ($($g.discovered) discovered, $($g.onboarded) onboarded)"
        }
        $mapG["^$([regex]::Escape($name))"] = @{ draft = $true; v = @("$($g.gap)", $cause, 'Assign an owner and a target date') }
    }
    # satir etiketleri yer tutucu oldugu icin sirayla doldur
    $script:gapRows = @($gaps)
    $script:gapIdx = 0
    $rxGap = [regex]'(?s)(<h3[^>]*>Onboarding Gap Analysis</h3>(?:(?!<h3).)*?<tbody>)(.*?)(</tbody>)'
    if ($rxGap.IsMatch($script:html)) {
        $script:html = $rxGap.Replace($script:html, {
            param($m)
            $body = [regex]::Replace($m.Groups[2].Value, '(?s)<tr>.*?</tr>', {
                param($rm)
                if ($script:gapIdx -ge $script:gapRows.Count) { return $rm.Value }
                $g = $script:gapRows[$script:gapIdx]; $script:gapIdx++
                $name = "$($g.platform)"; if (-not $name) { $name = 'Unidentified platform' }
                $cause = $rootCause[$name]
                if (-not $cause) { $cause = 'Discovered by device inventory but no sensor deployed - confirm this population with the endpoint team' }
                $script:filled.rows++
                "<tr><td class=`"f`" contenteditable data-ph=`"––`"><span class=`"draft`">$(Esc $name)</span></td>" +
                "<td class=`"num f`" contenteditable data-ph=`"––`">$($g.gap)</td>" +
                "<td class=`"f`" contenteditable data-ph=`"––`"><span class=`"draft`">$(Esc $cause)</span></td>" +
                "<td class=`"f`" contenteditable data-ph=`"––`"></td></tr>"
            })
            "$($m.Groups[1].Value)$body$($m.Groups[3].Value)"
        }, 1)
    }
}

# ----------------------------------------------- AJAN / SURUM GUNCELLIGI --
if ($d.tables.agentVersions) {
    $script:verRows = Rows $d.tables.agentVersions
    $script:verIdx = 0
    $rxVer = [regex]'(?s)(<h3[^>]*>Agent &amp; Platform Version Currency</h3>(?:(?!<h3).)*?<tbody>)(.*?)(</tbody>)'
    if ($rxVer.IsMatch($script:html)) {
        $script:html = $rxVer.Replace($script:html, {
            param($m)
            $body = [regex]::Replace($m.Groups[2].Value, '(?s)<tr>.*?</tr>', {
                param($rm)
                if ($script:verIdx -ge $script:verRows.Count) { return $rm.Value }
                $v = $script:verRows[$script:verIdx]; $script:verIdx++
                # 'Latest available' Microsoft'un son surumu demek ve API'den okunamaz -
                # toplayici oraya bir sey yazmaz. Behind = en yuksek gorulen surumde olmayan
                # cihaz sayisi; sifir olmasi "guncel" demek DEGIL, "hepsi ayni surumde"
                # demek, o yuzden en iyi ihtimalle partial.
                $st = if ([int]$v.behind -eq 0) { 'partial' } elseif ([int]$v.behind -lt 20) { 'partial' } else { 'fail' }
                $note = if ($v.observed) { $v.observed } else { '' }
                if ($note) { $note += '. Fill Latest available from the Microsoft release notes to judge currency.' }
                $noteCell = if ($note) { "<span class=`"draft`">$(Esc $note)</span>" } else { '' }
                if ($note) { $script:draftCount++ }
                $latestCell = if ($v.latest) { Esc $v.latest }
                              elseif ($v.observed) { $script:draftCount++; "<span class=`"draft`">from Microsoft release notes</span>" }
                              else { '' }
                $script:filled.rows++
                "<tr><td>$(Esc $v.component)</td>" +
                "<td class=`"f`" contenteditable data-ph=`"––`">$(Esc $v.current)</td>" +
                "<td class=`"f`" contenteditable data-ph=`"––`">$latestCell</td>" +
                "<td class=`"num f`" contenteditable data-ph=`"––`">$($v.behind)</td>" +
                "<td class=`"sel`">$(New-Select 'st' $ST_OPTS $st)</td>" +
                "<td class=`"f`" contenteditable data-ph=`"––`">$noteCell</td></tr>"
            })
            "$($m.Groups[1].Value)$body$($m.Groups[3].Value)"
        }, 1)
    }
}



# ------------------------------------------------ EK B: KULLANILAN KQL ----
if ($d.tables.queries) {
    $script:qRows = Rows $d.tables.queries
    $script:qIdx = 0
    $rxQ = [regex]'(?s)(<h3[^>]*>Advanced Hunting Queries Used</h3>(?:(?!<h3).)*?<tbody>)(.*?)(</tbody>)'
    if ($rxQ.IsMatch($script:html)) {
        $script:html = $rxQ.Replace($script:html, {
            param($m)
            $body = [regex]::Replace($m.Groups[2].Value, '(?s)<tr>.*?</tr>', {
                param($rm)
                if ($script:qIdx -ge $script:qRows.Count) { return $rm.Value }
                $q = $script:qRows[$script:qIdx]; $script:qIdx++
                $script:filled.rows++
                "<tr><td>$(Esc $q.purpose)</td><td><code style=`"font-size:8pt`">$(Esc $q.query)</code></td></tr>"
            })
            "$($m.Groups[1].Value)$body$($m.Groups[3].Value)"
        }, 1)
    }
}

# ------------------------------------------- UYUMLULUK ESLEMESI DURUMU ----
# Her kontrol alanini olctugumuz metrige bagla; olcemedigimizi bos birak.
function Comp-St { param($Pct) if ($null -eq $Pct) { $null } elseif ($Pct -ge 90) { 'pass' } elseif ($Pct -ge 60) { 'partial' } else { 'fail' } }
$avPct   = Sub-Avg 'Antivirus'
$cfgPct  = if ($cfgAll.Count) { [math]::Round(($cfgAll | Measure-Object compliance -Average).Average) } else { $null }
$onbPct  = Kpi-Num 'Onboarding Rate'
$shPct   = Kpi-Num 'Sensor health'
$blPct   = Scid-Pct 'scid-2090'
$npPct   = Scid-Pct 'scid-96'
$usbPct  = Scid-Pct 'scid-2511'
$totA    = Kpi-Num 'Total alerts (90d)'; $resA = Kpi-Num 'Resolved'
$irPct   = if ($totA -gt 0) { [math]::Round(100 * $resA / $totA) } else { $null }

$compMap = @{
    '^Malware protection'          = @{ p = $avPct;  e = "Antivirus configuration compliance $avPct%" }
    '^Endpoint hardening'          = @{ p = $cfgPct; e = "Security configuration compliance $cfgPct% across $($cfgAll.Count) controls" }
    '^Vulnerability management'    = @{ p = (Kpi-Num 'Secure score for devices'); e = "Secure Score $($d.kpi.'Secure score for devices')" }
    '^Asset inventory'             = @{ p = $onbPct; e = "$($d.kpi.'Onboarded') of $($d.kpi.'Total Endpoints') devices reporting" }
    '^Logging &'                   = @{ p = $shPct;  e = "Sensor health $shPct%" }
    '^Data protection on endpoints'= @{ p = $blPct;  e = "BitLocker encryption $blPct%" }
    '^Incident response'           = @{ p = $irPct;  e = "$resA of $totA alerts resolved" }
    '^Removable media control'     = @{ p = $usbPct; e = "USB attack surface rule $usbPct%" }
    '^Network protection / web'    = @{ p = $npPct;  e = "Network protection $npPct%" }
}
$script:compMap = $compMap
$script:html = [regex]::Replace($script:html, '(?s)<tr><td>([A-Z][^<]{4,40})</td>(?:(?!</tr>).)*</tr>', {
    param($rm)
    $row = $rm.Value
    if ($row -notmatch '<td class="sel"></td>') { return $row }
    if ($row -notmatch 'A\.\d|ID\.|PR\.|DE\.|RS ') { return $row }   # yalnizca uyumluluk tablosu
    $label = [regex]::Match($row, '<tr><td>([^<]+)</td>').Groups[1].Value
    $hit = $null
    foreach ($k in $script:compMap.Keys) { if ($label -match $k) { $hit = $script:compMap[$k]; break } }
    if (-not $hit -or $null -eq $hit.p) { return $row }
    $st = Comp-St $hit.p
    $row = $row -replace '<td class="sel"></td>', ('<td class="sel">' + (New-Select 'st' $ST_OPTS $st) + '</td>')
    $row = [regex]::Replace($row, '<td([^>]*class="[^"]*\bf\b[^"]*"[^>]*data-ph="[^"]*")></td>', {
        param($cm) "<td$($cm.Groups[1].Value)><span class=`"draft`">$(Esc $hit.e)</span></td>"
    }, 1)
    $script:filled.rows++
    return $row
})

# ------------------------------------------------- ONCELIK MATRISI --------
$pmF = Rows $d.tables.findings
if ($pmF.Count) {
    # effort alani toplayicida bos gelebilir: o durumda Critical = hemen yapilacak
    $hiLow  = @($pmF | Where-Object { $_.effort -eq 'Low' -or (-not $_.effort -and $_.severity -eq 'Critical') })
    $hiMed  = @($pmF | Where-Object { $_.severity -in 'Critical','High' -and $_.id -notin (@($pmF | Where-Object { $_.effort -eq 'Low' -or (-not $_.effort -and $_.severity -eq 'Critical') }) | ForEach-Object { $_.id }) })
    $medAll = @($pmF | Where-Object { $_.severity -eq 'Medium' })
    $ids = { param($set) if ($set.Count) { ($set | ForEach-Object { $_.id }) -join ', ' } else { '' } }
    Fill-Ph '[do first]' (& $ids $hiLow)
    Fill-Ph '[plan]'     (& $ids $hiMed)
    Fill-Ph '[project]'  (& $ids $medAll)
}

# ------------------------------------------------- LISANS HAK KONTROLU --
function Lic-Row {
    param($L, [string]$Note)
    if (-not $L) { return @{ draft = $true; v = @('0', '0', '0', '0', 'Not present in the tenant') } }
    return @{ draft = $true; v = @("$($L.purchased)", "$($L.assigned)", "$($L.assigned)", "$($L.available)", "$Note - $($L.skus)") }
}
Fill-Rows -Heading 'License Inventory' -Map @{
    'Defender for Endpoint Plan 1'   = (Lic-Row $lic.p1 'Plan 1 entitlement comes with these SKUs')
    'Defender for Endpoint Plan 2'   = (Lic-Row $lic.p2 'Plan 2 entitlement comes with these SKUs')
    'Defender for Servers'           = @{ draft = $true; v = @('', '', '', '', 'Server plans are licensed in Defender for Cloud and are not visible in subscribedSkus - confirm in the Azure portal') }
    'Defender Vulnerability Management' = (Lic-Row $lic.tvm 'Standalone add-on')
    'Microsoft 365 E5'               = (Lic-Row $lic.p2 'E5 family')
} | Out-Null

$p2n = if ($lic.p2) { $lic.p2.assigned } else { 0 }
$p1n = if ($lic.p1) { $lic.p1.assigned } else { 0 }
$yesP2 = if ($p2n -gt 0) { "Yes - $p2n Plan 2 licences" } else { 'No Plan 2 entitlement found' }
$yesAll = if (($p1n + $p2n) -gt 0) { "Yes - $($p1n + $p2n) licensed users" } else { 'No entitlement found' }

Fill-Rows -Heading 'Capability Entitlement Check' -Map @{
    'Next-generation protection'      = @{ draft = $true; v = @($yesAll) }
    'Attack surface reduction'        = @{ draft = $true; v = @($yesAll) }
    'Device control'                  = @{ draft = $true; v = @($yesAll) }
    'Manual response actions'         = @{ draft = $true; v = @($yesAll) }
    'EDR & behavioural blocking'      = @{ draft = $true; v = @($yesP2) }
    'Automated investigation'         = @{ draft = $true; v = @($yesP2) }
    'Advanced hunting'                = @{ draft = $true; v = @($yesP2) }
    'Vulnerability management'        = @{ draft = $true; v = @($yesP2) }
    'Threat analytics'                = @{ draft = $true; v = @($yesP2) }
    'Defender Experts'                = @{ draft = $true; v = @('Separate subscription - confirm with the client') }
    'Streaming API'                   = @{ draft = $true; v = @($yesP2) }
} | Out-Null

# ------------------------------------------------------ LISANS ENVANTERI -
if ($d.tables.licenses) {
    $map = @{}
    foreach ($l in $d.tables.licenses) {
        $key = [regex]::Escape($l.sku)
        $map[$key] = @{ v = @("$($l.purchased)", "$($l.assigned)", "$($l.assigned)", "$($l.available)", "$($l.partNumber)") }
    }
    Fill-Rows -Heading 'License Inventory' -Map $map | Out-Null
}

# --------------------------------------------------------- RBAC ROLLERI --
if ($d.tables.privilegedRoles) {
    $map = @{}
    foreach ($r in $d.tables.privilegedRoles) {
        $map[[regex]::Escape($r.role)] = @{
            v      = @('', "$($r.members)", '')
            status = $(if ($r.role -eq 'Global Administrator' -and $r.members -gt 5) { 'fail' } else { 'partial' })
        }
    }
    Fill-Rows -Heading 'Role-Based Access Control' -Map $map | Out-Null
}

# ------------------------------------------------- YONETISIM KONTROLLERI --
# Bolum 14'un governance tablosunun kendi h3'u yok - kendi sutun basligindan yakalanir.
$govMap = @{}
$mg = @($d.raw.machineGroups | Where-Object { $_.MachineGroup })
if ($d.raw.machineGroups) {
    $govMap['RBAC enabled'] = if ($mg.Count -gt 0) {
        @{ v = @("$($mg.Count) device groups defined"); status = 'pass'; draft = $true }
    } else {
        @{ v = @('No device groups - every device sits in the default group'); status = 'fail'; draft = $true }
    }
}
if ($null -ne $d.meta.pimEligibleAssignments) {
    $pim = [int]$d.meta.pimEligibleAssignments
    $govMap['Privileged Identity Management'] = if ($pim -gt 0) {
        @{ v = @("$pim eligible (time-bound) assignments"); status = 'pass'; draft = $true }
    } else {
        @{ v = @('No eligible assignments - all privileged access is standing'); status = 'fail'; draft = $true }
    }
}
$ca = @(Rows $d.tables.conditionalAccess)[0]
if ($ca) {
    $govMap['MFA enforced for admin roles'] = @{
        v = @("$($ca.enabledPolicies) of $($ca.totalPolicies) Conditional Access policies enabled - confirm which target directory roles")
        status = 'partial'; draft = $true
    }
}
if ($govMap.Count) { Fill-Rows -HeaderCell 'Governance control' -Map $govMap | Out-Null }

# --------------------------------------------------- ENTEGRASYON ANAHTARI --
$intMap = @{}
if ($ca) {
    $intMap['Device risk .*Conditional Access'] = @{
        v = @("$($ca.deviceComplianceCA) of $($ca.totalPolicies) policies require device compliance; device risk signals $(if ($ca.deviceRiskUsed) { 'are in use' } else { 'are not used' })")
        status = $(if ([int]$ca.deviceComplianceCA -gt 0) { 'partial' } else { 'fail' }); draft = $true
    }
}
if ($d.tables.intunePolicies) {
    $intMap['Microsoft Intune connection'] = @{
        v = @("$(@(Rows $d.tables.intunePolicies).Count) Intune configuration policies were readable, so the connection is live")
        status = 'pass'; draft = $true
    }
}
if ($intMap.Count) { Fill-Rows -Heading 'Advanced Features &amp; Integration Switches' -Map $intMap | Out-Null }

# ------------------------------------------------------------ INDICATORS --
# tables.indicators toplaniyordu ama hicbir yere yazilmiyordu.
$ind = Rows $d.tables.indicators
if ($ind.Count) {
    $byType = @{}
    foreach ($i in $ind) { $byType[$i.type] = $i }
    $sum = { param($pat) (@($ind | Where-Object { $_.type -match $pat } | Measure-Object count -Sum).Sum) }
    $hash = [int](& $sum 'FileSha|FileMd5|FileHash')
    $net  = [int](& $sum 'IpAddress|Url|DomainName')
    $cert = [int](& $sum 'Certificate')
    $noExp = [int]((@($ind | Measure-Object withoutExpiry -Sum).Sum))
    $total = [int]((@($ind | Measure-Object count -Sum).Sum))
    $indMap = @{
        'Indicators \(file hash\)'   = @{ v = @("$hash file hash indicators"); status = $(if ($hash) { 'pass' } else { 'na' }); draft = $true }
        'Indicators \(IP / URL / domain\)' = @{ v = @("$net network indicators"); status = $(if ($net) { 'pass' } else { 'na' }); draft = $true }
        'Indicators \(certificates\)' = @{ v = @("$cert certificate indicators"); status = $(if ($cert) { 'pass' } else { 'na' }); draft = $true }
        'Indicator expiry'            = @{
            v = @("$noExp of $total indicators carry no expiry date")
            status = $(if ($noExp -eq 0) { 'pass' } elseif ($noExp -lt $total) { 'partial' } else { 'fail' }); draft = $true
        }
    }
    Fill-Rows -Heading 'Threat Analytics &amp; Threat Intelligence' -Map $indMap | Out-Null
}

# ------------------------------------------------------------- SOC KPI ---
if ($d.tables.socKpi) {
    $map = @{}
    foreach ($k in $d.tables.socKpi) {
        $map[[regex]::Escape($k.metric)] = @{ v = @("$($k.observed)", '') }
    }
    Fill-Rows -Heading 'Operational KPIs' -Map $map | Out-Null
}

# ------------------------------------------------- EXCLUSION HIJYENI -----
if ($d.tables.avExclusions) {
    $all = Rows $d.tables.avExclusions
    $paths = @($all | Where-Object { $_.value -match '\\' })
    $exts  = @($all | Where-Object { $_.value -match '^\*?\.\w+$' })
    $procs = @($all | Where-Object { $_.value -match '\.exe$' })
    $risky = @($all | Where-Object { $_.value -match '^\w:\\?$|\*|AppData|Temp|Users\\' })
    Fill-Rows -Heading 'Exclusion Hygiene' -Map @{
        'Path exclusions'      = @{ v = @("$($paths.Count)", "$($risky.Count)", '') ; status = $(if ($risky.Count) { 'fail' } else { 'pass' }) }
        'Extension exclusions' = @{ v = @("$($exts.Count)", '0', '') }
        'Process exclusions'   = @{ v = @("$($procs.Count)", '0', '') }
    } | Out-Null
}

# ------------------------------------------- OZEL TESPIT KURALLARI -------
if ($d.tables.customDetections -and @($d.tables.customDetections).Count -gt 0) {
    # Tabloda 5 satir var, tenant'ta 677 kural olabiliyor. API sirasindan ilk 5'i
    # basmak envanteri 5 kuraldan ibaret gosterir. Dikkat isteyenleri one aliyoruz:
    # once devre disi olanlar (kendi basina bir yonetisim bulgusu), sonra severity.
    $sevRank = @{ 'critical' = 0; 'high' = 1; 'medium' = 2; 'low' = 3 }
    $rules = @(Rows $d.tables.customDetections | Sort-Object `
        @{ Expression = { if ($_.enabled -eq $false) { 0 } else { 1 } } },
        @{ Expression = { $r = "$($_.severity)".ToLower(); if ($sevRank.ContainsKey($r)) { $sevRank[$r] } else { 4 } } },
        @{ Expression = { "$($_.name)" } })
    $script:cdIdx = 0
    $rx = [regex]'(?s)(<h3>Custom Detection Rule Inventory</h3>\s*<table class="t compact">.*?<tbody>)(.*?)(</tbody>)'
    $script:html = $rx.Replace($script:html, {
        param($m)
        $body = [regex]::Replace($m.Groups[2].Value, '(?s)<tr>.*?</tr>', {
            param($rm)
            if ($script:cdIdx -ge $rules.Count) { return $rm.Value }
            $r = $rules[$script:cdIdx]; $script:cdIdx++
            $script:filled.rows++
            $sev = if ($r.severity) { $r.severity.ToLower() } else { '' }
            "<tr><td class=`"f`" contenteditable data-ph=`"––`">$(Esc $r.name)</td><td class=`"f`" contenteditable data-ph=`"––`">$(Esc $r.frequency)</td><td class=`"sev`">$(New-Select 'sev' $SEV_OPTS $sev)</td><td class=`"f`" contenteditable data-ph=`"––`">$(Esc $r.actions)</td><td class=`"f`" contenteditable data-ph=`"––`"></td></tr>"
        })
        "$($m.Groups[1].Value)$body$($m.Groups[3].Value)"
    }, 1)
}

$html = $script:html

# ------------------------------------------------------- KAPAK ALANLARI --
$cover = @{
    '[Client / Organization Name]' = if ($ClientName) { $ClientName } else { $d.meta.tenantName }
    '[tenant.onmicrosoft.com]'     = $d.meta.verifiedDomain
    '[dd.mm.yyyy]'                 = (Get-Date -Format 'dd.MM.yyyy')
    '[dd.mm.yyyy – dd.mm.yyyy]'    = "$((Get-Date).AddDays(-90).ToString('dd.MM.yyyy')) – $(Get-Date -Format 'dd.MM.yyyy')"
    '[all in-scope devices]'       = 'Discovered by Defender device inventory'
    '[active MDE sensors]'         = 'Sensor state = Active'
    '[discovered, not onboarded]'  = 'Onboarding status = Can be onboarded'
}
foreach ($k in $cover.Keys) {
    if (-not $cover[$k]) { continue }
    $rx = [regex]("(<[^>]*data-ph=`"" + [regex]::Escape([System.Net.WebUtility]::HtmlEncode($k)) + "`"[^>]*>)</(\w+)>")
    if (-not $rx.IsMatch($html)) {
        $rx = [regex]("(<[^>]*data-ph=`"" + [regex]::Escape($k) + "`"[^>]*>)</(\w+)>")
    }
    $html = $rx.Replace($html, {
        param($m)
        $script:filled.fields++
        "$($m.Groups[1].Value)$(Esc $cover[$k])</$($m.Groups[2].Value)>"
    }, 1)
}

# Secure Score büyük rakam
if ($d.meta.secureScore -or $d.kpi.'Secure score for devices') {
    # Sablonda "/100" sabit -> buraya yuzde yazilmali, ham puan degil
    $score = ($d.kpi.'Secure score for devices') -replace '%', ''
    if (-not $score) {
        $parts = $d.meta.secureScore -split '/'
        if ($parts.Count -eq 2) {
            $cur = ConvertTo-Num $parts[0]; $max = ConvertTo-Num $parts[1]
            if ($null -ne $cur -and $max -gt 0) { $score = [math]::Round(100 * $cur / $max) }
        }
    }
    $html = $html.Replace('<div class="bigscore"><span class="f" contenteditable data-ph="––"></span>',
                          "<div class=`"bigscore`"><span class=`"f`" contenteditable data-ph=`"––`">$score</span>")
    $filled.fields++
}

# ============================================================================
#  TASLAK ANLATIM METINLERI (best practice + toplanan veri)
#  Hepsi <span class="draft"> ile sarilir -> raporda sari REVIEW isareti.
#  Danisman kontrol edip rozete tiklayarak ya da tek butonla isareti kaldirir.
# ============================================================================
function K {
    param([string]$Name, [string]$Default = 'not measured')
    $v = $d.kpi.$Name
    if ($null -eq $v -or "$v" -eq '') { return $Default }
    return "$v"
}
function HasK {
    param([string]$Name)
    $v = $d.kpi.$Name
    return ($null -ne $v -and "$v" -ne '')
}

$fnd = Rows $d.tables.findings
$crit = @($fnd | Where-Object { $_.severity -eq 'Critical' })
$high = @($fnd | Where-Object { $_.severity -eq 'High' })
$med  = @($fnd | Where-Object { $_.severity -eq 'Medium' })
$low  = @($fnd | Where-Object { $_.severity -eq 'Low' })
$client = if ($ClientName) { $ClientName } elseif ($d.meta.tenantName) { $d.meta.tenantName } else { 'the organisation' }
$topRisk = if ($crit.Count) { $crit[0].finding } elseif ($high.Count) { $high[0].finding } else { 'no critical exposure was identified' }
$platforms = (@($d.tables.deviceInventory | ForEach-Object { "$($_.platform)".Trim() } |
    Where-Object { $_ -and $_ -ne 'Windows' } | Select-Object -Unique) -join ', ')
$window = if ($d.meta.alertWindow) { $d.meta.alertWindow } else { '90 days' }

$drafts = [ordered]@{}

$drafts['[This document contains confidential'] =
"This document contains confidential security information belonging to $client. Distribution is restricted to named recipients; onward sharing requires written approval from the information security owner."

$drafts['[Describe why this health check was performed'] =
"This health check assesses the Microsoft Defender for Endpoint deployment at $client against Microsoft best practice and the client's internal endpoint standard. It covers $(K 'Total Endpoints' 'the in-scope') endpoints, quantifies the gap between the deployed and the recommended configuration, and produces a prioritised remediation roadmap that the endpoint and security operations teams can execute within one budget year."

$drafts['[Defender portal settings, Intune'] =
"Defender portal configuration export, $(if ($d.tables.intunePolicies) { @($d.tables.intunePolicies).Count } else { 'the' }) Intune configuration policies, and the Microsoft security baseline comparison."

$drafts['[Advanced Hunting KQL queries'] =
"Advanced Hunting queries across a $window telemetry window (DeviceInfo, DeviceEvents, DeviceTvmSoftwareVulnerabilities, DeviceTvmSecureConfigurationAssessment, AlertInfo)."

$drafts['[List excluded systems'] =
"No systems were explicitly excluded from the automated collection. Confirm with the client whether air-gapped, OT or third-party managed estates exist that are not visible to Defender and should be listed here."

$drafts['[Two or three sentences for the executive audience'] =
"We assessed the Microsoft Defender for Endpoint deployment across $(K 'Total Endpoints' 'the estate') in-scope devices. $(if ($fnd.Count) { "The assessment raised $($fnd.Count) findings, of which $($crit.Count) are critical and $($high.Count) high." } else { 'No material findings were raised.' }) The single most consequential issue is that $topRisk."

$drafts['[Current state narrative'] =
"Onboarding coverage stands at $(K 'Onboarding Rate') with $(K 'Onboarded Devices') devices reporting to the service$(if ($platforms) { " across $platforms" }). Real-time protection is active on $(K 'Real-time protection on') of devices and cloud-delivered protection on $(K 'Cloud protection on'), while tamper protection reaches only $(K 'Tamper protection on'). Microsoft Secure Score for devices is $(K 'Secure score for devices') and the organisational exposure score is $(K 'Exposure Score')."

$drafts['[Risk statement'] =
"Unprotected and unmonitored endpoints sit in the same network zones as business-critical systems. A commodity ransomware intrusion on a device without a reporting sensor would be neither prevented nor visible to the security team until it reached a monitored host, and attack techniques currently observed in audit mode are permitted rather than blocked. Review this statement against the client's own crown-jewel systems before issue."

$drafts['[The single most consequential recommendation'] =
"$(if ($crit.Count -or $high.Count) { "Prioritise the $($crit.Count + $high.Count) critical and high findings in the register: complete endpoint onboarding, enforce tamper protection tenant-wide, and move attack surface reduction rules from audit to block mode." } else { 'Maintain the current posture and focus on operational maturity.' }) These actions require configuration effort rather than additional licence spend and are projected to deliver the largest single reduction in exposure."

$drafts['[Summarise the licensing model in place'] =
"$(if ($d.tables.licenses) { "$(@($d.tables.licenses).Count) licence SKUs are assigned in the tenant." } else { 'Licensing could not be enumerated.' }) Verify that every device carrying a Defender for Endpoint sensor holds an appropriate Plan 1 or Plan 2 entitlement, and that server workloads are licensed through Defender for Servers. Plan 1 devices cannot use EDR, advanced hunting or automated investigation, which limits the capabilities described in the detection sections of this report."

$drafts['[e.g. consolidate to a single plan'] =
"Reassign unused Plan 2 licences to the highest-value device populations, license any device currently running an unlicensed sensor, and retire duplicate third-party antivirus contracts at renewal now that Defender Antivirus is the primary engine."

$drafts['[Describe the current onboarding state'] =
"$(K 'Onboarded Devices') of $(K 'Total Endpoints') in-scope devices report to Defender for Endpoint, a coverage rate of $(K 'Onboarding Rate'). $(if ((K 'Not onboarded' '0') -ne '0') { "$(K 'Not onboarded') devices remain without a sensor and are listed in the gap analysis below." } else { 'No coverage gap was detected at collection time.' }) Confirm with the client which populations are deliberately out of scope before treating the remainder as a finding."

$drafts['[Assess whether onboarded devices are actually reporting'] =
"Sensor health across onboarded devices is $(K 'Sensor health'). $(K 'Impaired comms' '0') devices report impaired communications and $(K 'No sensor data' '0') are onboarded but sending no sensor data. Devices in these states appear protected on management dashboards while producing no telemetry, so they are invisible to detection, hunting and live response."

$drafts['[Describe the operational impact of unhealthy sensors'] =
"Devices with impaired communications or no sensor data are counted as onboarded in management reporting but generate no usable telemetry. This is the most dangerous class of gap because it does not present as a gap. Typical root causes are TLS inspection applied to Defender endpoints on the corporate proxy, missing URL allow-list entries, or an outdated sensor build."

$drafts['[Assess AV operating mode'] =
"Microsoft Defender Antivirus reports real-time protection enabled on $(K 'Real-time protection on') of devices and cloud-delivered protection on $(K 'Cloud protection on'). Tamper protection, which prevents an attacker or a local administrator from disabling protection, reaches $(K 'Tamper protection on') and should be enforced tenant-wide from the Defender portal rather than per device."

$drafts['[Excessive or over-broad exclusions'] =
"$(if ($d.tables.avExclusions) { "$(@($d.tables.avExclusions).Count) antivirus exclusions were recovered from Intune-managed policies." } else { 'No Intune-managed antivirus exclusions were recovered; exclusions may be applied through Group Policy or locally and should be collected manually.' }) Exclusions that cover whole drives, user-writable paths such as the user temp directory, or scripting hosts create scanning blind spots that commodity malware routinely lands in. Each exclusion should carry an owner, a documented justification and an expiry date."

$drafts['[Record the deployment state of every ASR rule'] =
"$(if (HasK 'Rules in block mode') { "$(K 'Rules in block mode') attack surface reduction rules are enforced in block mode and $(K 'Rules in audit mode') remain in audit." } else { 'Attack surface reduction rule state could not be derived from telemetry or Intune policy.' }) Rules left in audit mode record the attack technique and permit it; they provide visibility but no protection. Microsoft recommends enforcing the credential-theft, Office child-process and script-obfuscation rules first."

$drafts['[Summarise the audit-to-block transition plan'] =
"Move rules with zero or fully explained audit volume to block mode immediately. Pilot the remaining rules on a representative device group for two to three weeks, tune exclusions for line-of-business applications, then enforce. Track the transition weekly in the ASR report and expect a measurable Secure Score improvement on completion."

$drafts['[Describe the current exposure posture'] =
"The organisational exposure score is $(K 'Exposure Score') and Microsoft Secure Score for devices is $(K 'Secure score for devices'). $(K 'Total vulnerabilities') vulnerability instances are open across $(K 'Software products') discovered software products, including $(K 'Critical CVEs') critical CVEs. Confirm whether remediation runs through an established patch cycle and whether Defender remediation requests are tracked to closure."

$drafts['[Assess how endpoint configuration compares'] =
"$(if ($d.tables.secureConfiguration) { "Configuration assessment covers $(@($d.tables.secureConfiguration).Count) controls; the average compliance across applicable devices is $([math]::Round((@($d.tables.secureConfiguration) | Measure-Object compliance -Average).Average))%." } else { 'Configuration assessment data was not available.' }) Where compliance is low across the board, the security baseline has typically been published once and never re-applied. There is no automated drift detection unless the client has explicitly built one."

$drafts['[Assess EDR effectiveness'] =
"$(K 'Total alerts (90d)') alerts were raised over the last $window$(if (HasK 'Incidents (90d)') { " and correlated into $(K 'Incidents (90d)') incidents" }). $(K 'Open / in progress') alerts remain open or in progress. Review alert fidelity with the security operations team: a high proportion of unresolved or auto-closed alerts usually indicates tuning debt rather than a quiet environment."

$drafts['[Describe the automation level applied per device group'] =
"Automated investigation and response settings are configured per device group and could not be read through the API. Confirm the automation level for each group with the endpoint team: groups set to 'no automation' require an analyst for every remediation, and semi-automatic groups accumulate pending approvals that erode the benefit of automation."

$drafts['[Comment on the balance between automation'] =
"$(
if ($d.tables.customDetections -and @($d.tables.customDetections).Count -gt 0) {
    $cdAll  = Rows $d.tables.customDetections
    $cdOff  = @($cdAll | Where-Object { $_.enabled -eq $false })
    $cdSev  = @($cdAll | Where-Object { $_.severity } | Group-Object { "$($_.severity)".ToLower() } |
                Sort-Object Count -Descending | ForEach-Object { "$($_.Count) $($_.Name)" })
    # Tablo yalnizca ilk birkacini gosterir - okuyucu gercek olcegi buradan gorsun
    "$($cdAll.Count) custom detection rules are defined$(if ($cdSev.Count) { " ($($cdSev -join ', '))" })" +
    "$(if ($cdOff.Count) { ", of which $($cdOff.Count) are disabled" })." +
    " The table below lists the ones that warrant attention first, not the whole inventory;" +
    " at this volume the question is no longer whether rules exist but whether they are reviewed," +
    " version-controlled and still firing."
} else {
    'No custom detection rules are defined, so the environment relies entirely on Microsoft-supplied detections.'
}) Threat hunting output should feed back into custom detections; without a scheduled hunting cadence this loop rarely forms."

$drafts['[Assess how alerts are consumed operationally'] =
"$(if ($d.tables.socKpi) { "Measured response performance: $((@($d.tables.socKpi) | ForEach-Object { "$($_.metric) $($_.observed)" }) -join '; ')." } else { 'Response timing could not be measured from the available alert data.' }) Confirm the operating model with the client: who performs first-line triage, in which console, against which service level, and what happens outside business hours."

$drafts['[Assess who can see and act on endpoint data'] =
"$(if ($d.tables.privilegedRoles) { "Privileged role membership: $((@($d.tables.privilegedRoles) | ForEach-Object { "$($_.role) $($_.members)" }) -join ', ')." } else { 'Privileged role membership could not be enumerated.' }) Standing administrative access to the endpoint estate should be eliminated in favour of time-bound elevation through Privileged Identity Management, and device group scoping should limit each team to the devices it operates."

$caText = 'Conditional Access configuration could not be read.'
if ($d.tables.conditionalAccess) {
    $ca0 = @($d.tables.conditionalAccess)[0]
    $caText = "The tenant has $($ca0.totalPolicies) Conditional Access policies, $($ca0.enabledPolicies) of them enabled, and $($ca0.deviceComplianceCA) require device compliance."
}
$drafts['[Assess how Defender for Endpoint interoperates'] =
"$caText Device risk signals only reduce risk when a Conditional Access policy consumes them; without that link a device marked high risk retains full access to corporate resources until an analyst intervenes manually."

$drafts['[e.g. complete the Sentinel connector rollout'] =
"Publish a Conditional Access policy that blocks or steps up authentication for non-compliant and high-risk devices, stream the raw device tables to the SIEM so that hunting is possible outside the Defender portal, and nominate a single console as the system of record for incident status."

$drafts['[Map the assessed endpoint controls'] =
"The endpoint findings in this report map to the control areas listed below. Confirm which frameworks the client is actually certified or audited against, and mark any control area that already carries an open audit observation so that the remediation work can be justified against an existing obligation."

$drafts['[Record any sector-specific obligations'] =
"Endpoint telemetry contains user names, device identifiers and process command lines, which are personal data under GDPR and KVKK. Record the storage region, retention period and access model, and confirm alignment with the client's records of processing. Sector-specific obligations such as PCI DSS, HIPAA or NIS2 should be confirmed with the client's compliance function."

$drafts['[Which gaps would most likely be raised'] =
"$(if ($crit.Count -or $high.Count) { "The critical and high findings in this report - in particular incomplete endpoint coverage, unmanaged exclusions and standing privileged access - are the items most likely to be raised at the next audit." } else { 'No material audit exposure was identified from the collected data.' })"

$drafts['[Note anything that limits the confidence'] =
"Findings reflect the environment at the time of collection ($($d.meta.generatedUtc) UTC) and are based on data available through the Microsoft Graph and Defender APIs. Configuration applied through Group Policy rather than Intune is not visible to the collector, historical trends beyond the Advanced Hunting retention window are unavailable, and any device without a healthy sensor is under-represented in every metric in this report."

$drafts['[Closing statement'] =
"Security tools do not reduce risk by being deployed; they reduce risk by being completed, enforced and operated. The capability is already licensed - this roadmap is about switching it on."

# --- ilk kritik bulgunun detay blogu ---
if ($fnd.Count -gt 0) {
    $f1 = $fnd[0]
    $drafts['[What was found, with evidence'] = "$($f1.finding). Derived from the automated collection on $($d.meta.generatedUtc) UTC; verify against the Defender portal before issue."
    $drafts['[Devices / groups / platforms affected]'] = 'Confirm the affected device population and business owner.'
    $drafts['[What an attacker could do'] = 'State the concrete attack scenario this gap enables and the business system it would reach first.'
    $drafts['[Precise remediation steps'] = 'Document the exact policy path and setting value required to close this finding.'
    $drafts['[Low / Medium / High; prerequisites'] = 'Estimate effort, prerequisites, testing scope and the change window required.'
    $drafts['[team / person'] = 'Assign an owner and a target date.'
    $drafts['[Microsoft Learn article'] = 'Add the Microsoft Learn reference and the internal policy identifier.'
}

# ============================================================================
#  BEST PRACTICE YORUM KUTUPHANESI
#  Kontrol satirlarindaki bos "Comment / Observation / Recommendation" hucresine
#  Microsoft best practice temelli bir cumle yazar. Hepsi REVIEW isaretlidir.
# ============================================================================
$bp = [ordered]@{
    # --- tenant ---
    'Data storage region'                = 'Storage region is fixed at onboarding and cannot be changed later; confirm it satisfies the client data residency obligation.'
    'Data retention period'              = 'Set to the maximum the licence allows (180 days) unless a policy requires otherwise; retention drives how far back hunting can reach.'
    'Preview features enabled'           = 'Keep preview features off in production tenants; enable on a pilot tenant or a limited device group instead.'
    'Auto-remediation level'             = 'Full automation is recommended for standard workstations; servers commonly run semi-automatic with approval.'
    'Alert notification rules'           = 'At minimum, high severity alerts should notify the security operations mailbox; verify recipients are monitored out of hours.'
    'Advanced features'                  = 'Enable every integration the tenant is licensed for; each disabled switch removes correlation signal from incidents.'
    'Time zone / portal locale'          = 'Align the portal time zone with the SOC operating time zone to avoid timestamp confusion during incident handling.'
    'licence expiry'                     = 'Track the renewal date; sensors continue reporting after expiry but capability silently degrades.'

    # --- ajan / surum ---
    'Defender AV platform version'       = 'Platform updates ship monthly; devices more than two releases behind miss detection and performance fixes.'
    'Antimalware engine version'         = 'Engine version follows the platform update; a lagging engine usually indicates a stalled update channel.'
    'Security intelligence'              = 'Signature age above 24 hours on a connected device indicates a connectivity or update source problem.'
    'EDR sensor'                         = 'Keep the EDR sensor current; older builds lack newer behavioural detections and response actions.'
    'macOS / Linux agent build'          = 'Non-Windows agents are updated through the package manager and are commonly forgotten after the pilot.'
    'Update ring / channel strategy'     = 'Use gradual rollout rings so a regression is caught on a pilot group before reaching the whole estate.'

    # --- antivirus ---
    'Defender AV operating mode'         = 'Active mode is required for full protection; passive mode limits remediation to EDR block mode only.'
    'Real-time protection'               = 'Must be enabled everywhere; any device without it relies solely on scheduled scans.'
    'Behaviour monitoring'               = 'Required for behavioural detections; disabling it removes most fileless attack coverage.'
    'Cloud-delivered protection'         = 'Advanced MAPS membership gives access to the cloud protection service; without it detection falls back to local signatures.'
    'Cloud block level'                  = 'High is the recommended baseline for most estates; High+ adds latency and false positives on developer machines.'
    'Cloud extended timeout'             = 'Set to 50 seconds so the cloud verdict arrives before the file is released.'
    'Automatic sample submission'        = 'Send safe samples automatically; without samples the cloud cannot classify new binaries seen in this tenant.'
    'PUA protection'                     = 'Set to block. Potentially unwanted applications are the most common precursor to a real infection.'
    'Tamper protection'                  = 'Enforce tenant-wide from the Defender portal. Ransomware operators disable AV first; this control is what stops that.'
    'EDR in block mode'                  = 'Enable for all devices, not just the pilot group; it is what turns a behavioural detection into a prevention.'
    'Scan removable drives'              = 'Enable so USB media is scanned on mount rather than on first access.'
    'Scan network files'                 = 'Enable for workstations; on file servers assess performance impact first.'
    'Scheduled quick / full scan'        = 'A daily quick scan is sufficient when real-time protection is healthy; full scans are for remediation, not routine.'
    'Signature update interval'          = 'Four hours or less. Longer intervals leave a measurable window against fast-moving campaigns.'
    'Fallback update source'             = 'Order the sources so an isolated device can still update: Microsoft Update, then MMPC, then an internal UNC share.'
    'Catch-up scan'                      = 'Enable so devices that were offline scan and update as soon as they return.'
    'Archive / email scanning'           = 'Enable; archives are the standard delivery wrapper for malicious payloads.'
    'Script scanning'                    = 'AMSI script scanning is required to see obfuscated PowerShell and JScript at runtime.'
    'Potentially unwanted app removal'   = 'Set remediation to quarantine rather than allow, and review the quarantine weekly.'
    'Local admin override'               = 'Local administrators should not be able to change protection settings; combine with tamper protection.'
    'Troubleshooting mode'               = 'Troubleshooting mode temporarily disables tamper protection; every use should be ticketed and time-boxed.'

    # --- exclusions ---
    'Path exclusions'                    = 'Exclusions that cover a whole drive or a user-writable path create a scanning blind spot that malware lands in by default.'
    'Extension exclusions'               = 'Extension exclusions apply estate-wide and are almost never justified; prefer a narrow path or process exclusion.'
    'Process exclusions'                 = 'Process exclusions must name a signed binary with a full path; a bare process name can be impersonated.'
    'ASR per-rule exclusions'            = 'Per-rule exclusions silently weaken the rule for the scoped devices; review them whenever the rule set changes.'
    'Controlled folder access allowed'   = 'Keep the allowed application list short and reviewed; each entry can write to protected folders.'
    'Indicator allow-list'               = 'Allow indicators bypass detection entirely; every entry needs an owner and an expiry date.'
    'Exclusion review cadence'           = 'Exclusions accumulate. Review at least twice a year with the application owner and remove anything unclaimed.'

    # --- ASR ---
    'Block credential stealing from LSASS' = 'Highest value rule in the set: blocks the standard credential dumping path. Enforce first.'
    'Block all Office applications from creating child processes' = 'Blocks the classic macro-to-payload chain; expect tuning for finance macro suites.'
    'Block executable content from email' = 'Blocks payloads delivered by mail before execution; tune for legitimate self-extracting tooling.'
    'Block execution of potentially obfuscated scripts' = 'High value, but legacy logon scripts are often obfuscated by design; pilot before enforcing.'
    'Block JavaScript / VBScript'        = 'Blocks script-launched downloads; low false positive rate in most estates.'
    'Block Office applications from creating executable content' = 'Prevents Office writing payloads to disk; safe to enforce in most environments.'
    'Block Office applications from injecting' = 'Blocks process injection from Office; rarely conflicts with legitimate software.'
    'Block process creations originating from PSExec' = 'Blocks lateral movement tooling; exclude the management agent (MECM) before enforcing.'
    'Block untrusted and unsigned processes that run from USB' = 'Enforce together with removable media control for a complete USB story.'
    'Block persistence through WMI'       = 'Blocks a common fileless persistence route; safe to enforce.'
    'Block Webshell creation for servers' = 'Applies to servers with the appropriate licence; a key control for internet-facing web servers.'
    'Block Win32 API calls from Office macros' = 'Blocks the macro-to-shellcode path; verify against any macro-based line-of-business tooling.'
    'Block abuse of exploited vulnerable signed drivers' = 'Blocks bring-your-own-vulnerable-driver attacks used to disable security tooling.'
    'Block Adobe Reader'                 = 'Blocks the reader-to-payload chain; safe to enforce in almost all estates.'
    'Block rebooting machine in Safe Mode' = 'Prevents an attacker restarting into Safe Mode to disable protection; safe to enforce.'
    'Block use of copied or impersonated system tools' = 'Blocks renamed system binaries used to evade detection; safe to enforce.'
    'Block executable files unless prevalence' = 'Strong control but disruptive with bespoke internal tooling; audit first, then decide.'
    'Block Office communication application' = 'Blocks Outlook spawning child processes; safe to enforce.'
    'Use advanced protection against ransomware' = 'Adds cloud-backed ransomware heuristics; enable in block mode.'
    'Controlled folder access'           = 'The strongest anti-ransomware control available here; deploy in audit first to build the allowed application list.'

    # --- network / device / app ---
    'Network protection'                 = 'Move from audit to block; in audit mode malicious destinations are logged and still reached.'
    'Web content filtering'              = 'Block newly registered and uncategorised domains first; they carry most phishing infrastructure.'
    'Web threat protection'              = 'SmartScreen must be enforced through policy, not left to user preference in the browser.'
    'Custom URL / IP indicators'          = 'Maintain a managed block list fed by incident output and threat intelligence, with expiry dates.'
    'Network protection for macOS / Linux' = 'Available on both platforms and commonly missed; enable to close the non-Windows gap.'
    'DNS / proxy inspection'             = 'TLS inspection on Defender endpoints breaks sensor connectivity; bypass the Microsoft URL list on the proxy.'
    'Removable storage access control'   = 'Default to read-only for unknown USB storage and allow-list approved device IDs.'
    'Removable storage protection'       = 'Scan removable media on mount; pair with the USB ASR rule.'
    'Printer protection'                 = 'Restrict printing to approved printers where data exfiltration through print is a concern.'
    'Bluetooth / WPD control'            = 'Restrict pairing and file transfer on managed devices.'
    'Device installation restrictions'   = 'Allow-list by device instance ID; deny-lists are trivially bypassed with different hardware.'
    'BitLocker / disk encryption'        = 'Encryption must be enforced and recovery keys escrowed in Entra ID; verify escrow, not just enablement.'
    'App Control for Business'           = 'The strongest control against untrusted binaries; start in audit mode and build the policy from real telemetry.'
    'AppLocker'                          = 'Acceptable where WDAC is not viable, but weaker and easier to bypass; treat as an interim control.'
    'Smart App Control'                  = 'Only applies to clean-installed Windows 11 devices; evaluate for new builds.'
    'Exploit protection'                 = 'Apply the Microsoft baseline XML through policy rather than configuring mitigations per device.'
    'Hardware-based isolation'           = 'Application Guard requires supported hardware; assess coverage before committing to it as a control.'
    'Credential Guard / LSA protection'  = 'Enable both; together they remove the most common credential theft path from memory.'
    'Memory integrity'                   = 'HVCI blocks unsigned kernel code; check driver compatibility before enforcing.'
    'Secure Boot / TPM / VBS'            = 'Prerequisites for most modern protection features; devices without them cannot be fully hardened.'
    'Defender Firewall enabled'          = 'All three profiles must be on; a disabled public profile is the common gap on laptops.'
    'Inbound default action'             = 'Block by default and allow by exception; audit any rule that opens a listening port broadly.'
    'Rule merging from local admins'     = 'Disable local rule merging so users cannot silently open the firewall.'
    'Firewall rules managed centrally'   = 'Manage rules from Intune or Group Policy so drift is visible and reversible.'
    'Firewall logging'                   = 'Enable dropped-packet logging and forward it; without logs, firewall issues are invisible during incidents.'

    # --- TVM ---
    'Software inventory completeness'    = 'Inventory only covers devices with a healthy sensor; unhealthy devices under-report their exposure.'
    'Security recommendations triaged'   = 'Triage weekly against exposure and exploit availability rather than CVSS alone.'
    'Remediation requests'               = 'Route Defender remediation requests into Intune or the ticketing system so they are tracked to closure.'
    'Exception / mitigation tracking'    = 'Every exception should be time-bound, justified and re-reviewed on expiry.'
    'Browser extension assessment'       = 'Browser extensions run with page privileges and are a common data exfiltration route; review the installed set.'
    'Certificate inventory'              = 'Track expiring and weak certificates on endpoints; expiry causes outages that look like incidents.'
    'Firmware / hardware advisories'     = 'Firmware sits below the operating system and survives reimaging; include it in the patch cycle.'
    'Missing KB / OS patch visibility'   = 'Compare Defender findings against the patch management tool; divergence usually means a broken agent.'
    'Network share / SMB assessment'     = 'Review shares with broad write permissions; they are the standard lateral movement and ransomware amplifier.'
    'Authenticated scan'                 = 'Use authenticated scanning for network devices and unmanaged assets that cannot carry a sensor.'
    'SLA definition for critical CVEs'   = 'Define and measure remediation SLAs by severity and exploit availability, not by device count.'
    'Patch management integration'       = 'Vulnerability data is only useful when it drives a patch cycle; confirm the handover point is owned.'

    # --- baseline / policy ---
    'Primary policy authority'           = 'Pick one authority. Mixed GPO and Intune management is the most common source of silent policy conflicts.'
    'Policy conflicts detected'          = 'Any conflict leaves the effective setting undefined; resolve rather than document.'
    'Security settings management'       = 'Lets Defender manage security settings on devices that are not Intune-enrolled; useful for servers.'
    'Endpoint security profiles assigned' = 'Verify assignment coverage, not just profile existence; an unassigned profile protects nothing.'
    'Profile assignment coverage'        = 'Target coverage is every onboarded device; gaps here explain most configuration findings.'
    'Configuration drift detection'      = 'Without automated drift detection, deviation is found only when something fails or an incident occurs.'
    'Change control for security policy' = 'Security policy changes should follow the same change record as any other production change.'
    'Ring-based / pilot deployment'      = 'Deploy protection changes in rings; enforcement without a pilot is the main cause of rollback.'

    # --- EDR ---
    'EDR sensor active on all onboarded' = 'A device counted as onboarded but not reporting is invisible to detection, hunting and response.'
    'Behavioural blocking & containment' = 'Requires Plan 2; provides post-breach containment when a signature has not yet been produced.'
    'Device discovery'                   = 'Standard discovery finds unmanaged devices on the same network segments; basic discovery only sees passive traffic.'
    'Device isolation tested'            = 'Test isolation before you need it, and document who is authorised to trigger it out of hours.'
    'Contain device / contain user'      = 'Containment limits an unmanaged or compromised identity without a full isolation; verify it is available and understood.'
    'App execution restriction'          = 'Restricting execution to signed binaries is a lighter alternative to full isolation during triage.'
    'Live response enabled'              = 'Powerful and dangerous: restrict to named analysts and audit every session.'
    'Live response unsigned script'      = 'Allowing unsigned scripts effectively grants arbitrary code execution on any endpoint; restrict tightly.'
    'Investigation package'              = 'Collect the investigation package before remediation; remediation destroys the evidence.'
    'Timeline / device event retention'  = 'Timeline retention limits how far back an investigation can reach; align it with the detection-to-discovery gap.'
    'Alert suppression rules reviewed'   = 'Suppression rules hide alerts permanently; review them for over-broad scope at least quarterly.'
    'Alert tuning / false-positive'      = 'A defined tuning loop is what keeps alert volume manageable without suppressing real detections.'
    'Detection coverage validated'       = 'Validate with attack simulation or purple team rather than assuming coverage from configuration.'

    # --- hunting / TI ---
    'Advanced hunting used regularly'    = 'Hunting turns telemetry into detections; without a cadence it happens only after a public incident.'
    'Number of custom detection rules'   = 'Custom detections encode what the organisation knows about its own environment; Microsoft rules cannot.'
    'Custom rules reviewed'              = 'Keep rules in version control with an owner; unowned rules become noise and get suppressed.'
    'Rule frequency & impacted entities' = 'Match rule frequency to the attack timeline and set impacted entities so response actions can be automated.'
    'Automated actions on custom detections' = 'Attach response actions to high-confidence rules so containment does not wait for an analyst.'
    'Hunting query library'              = 'A shared query library is what makes hunting repeatable across analysts.'
    'Threat hunting programme'           = 'Schedule hunting as a recurring commitment, not as a response to news.'
    'Analyst KQL skill'                  = 'KQL capability is the limiting factor for both hunting and custom detections; plan training accordingly.'
    'Threat analytics reports reviewed'  = 'Threat analytics maps active campaigns to this tenant exposure; review on publication, not monthly.'
    'Exposed devices remediated per report' = 'Each report lists exposed and misconfigured devices; treat that list as a work queue.'
    'Indicators (file hash)'             = 'Hash indicators are precise but short-lived; use them for incident response, not as a strategy.'
    'Indicators (IP / URL / domain)'     = 'Network indicators age quickly; set expiry dates and review sources.'
    'Indicators (certificates)'          = 'Certificate indicators block signed malware families effectively and are often overlooked.'
    'Indicator expiry & review'          = 'Indicators without expiry accumulate into an unmanaged block list that eventually breaks something.'
    'External TI feed integration'       = 'Feed external intelligence in through the indicator API rather than by manual entry.'
    'Defender Experts'                   = 'Managed hunting is worth evaluating where the SOC lacks 24x7 coverage or deep hunting capability.'

    # --- yonetisim ---
    'RBAC enabled'                       = 'Move off tenant-wide roles: RBAC with device groups is what limits blast radius of an over-privileged account.'
    'Least-privilege review cadence'     = 'Review role membership quarterly; access granted for a project rarely gets removed afterwards.'
    'Privileged Identity Management'     = 'Standing administrative access should be replaced with time-bound, approved elevation.'
    'MFA enforced for admin roles'       = 'Non-negotiable. An administrator without MFA is the shortest path to the whole estate.'
    'Break-glass accounts documented'    = 'Emergency access accounts must be excluded from Conditional Access, monitored and tested.'
    'Portal action audit logging'        = 'Portal actions are recorded; review them to confirm response actions are taken by the expected people.'
    'API token / secret rotation'        = 'Application secrets used for integrations should be rotated on a schedule and stored in a vault.'
    'Device tagging strategy'            = 'Tags drive device groups, RBAC scope and automation level; an untagged estate cannot be governed.'
    'Device value'                       = 'Marking high-value devices changes exposure scoring and prioritisation; set it deliberately.'
    'Critical asset identification'      = 'Critical asset management raises the priority of alerts on business-critical devices.'
    'Exclusion group / policy scoping'   = 'Exclusion groups quietly remove devices from protection; review their membership as carefully as the policy itself.'
    'Alert email notification rules'     = 'Notification rules should be scoped by severity and device group so they stay actionable.'
    'Vulnerability event notifications'  = 'Notify on new exploitable vulnerabilities affecting the estate rather than on every published CVE.'
    'Executive / monthly security reporting' = 'Regular reporting is what keeps remediation funded; use a small stable set of metrics.'
    'KPI dashboard for management'       = 'Coverage, sensor health, ASR enforcement and remediation SLA are the four metrics worth reporting.'
    'Service health / message centre'    = 'Service health and message centre carry breaking changes that affect protection; assign an owner.'
    'Documented run-book'                = 'A run-book is what makes response repeatable when the person who knows is on leave.'

    # --- entegrasyon ---
    'Microsoft Defender XDR'             = 'The unified portal correlates endpoint, identity, mail and cloud app signal into a single incident.'
    'Microsoft Defender for Identity'    = 'Adds domain controller signal; without it lateral movement is only visible from the endpoint side.'
    'Microsoft Defender for Office 365'  = 'Links the delivering mail to the endpoint detonation; essential for phishing investigations.'
    'Microsoft Defender for Cloud Apps'  = 'Adds SaaS and shadow IT visibility to endpoint incidents.'
    'Microsoft Defender for Cloud'       = 'Provides the server onboarding and licensing path for cloud and hybrid workloads.'
    'Microsoft Intune connection'        = 'Required for compliance-driven access and for remediation requests to flow into a work queue.'
    'Device risk'                        = 'Publish device risk into Conditional Access; otherwise a compromised device keeps its access until an analyst acts.'
    'Microsoft Sentinel connector'       = 'Stream alerts, incidents and the raw device tables; alerts alone are not enough to hunt in the SIEM.'
    'Streaming API / raw data export'    = 'Raw export is the only way to keep endpoint telemetry beyond the portal retention window.'
    'Microsoft Purview'                  = 'Relevant where endpoint DLP or insider risk signals are in scope.'
    'Microsoft Security Copilot'         = 'Evaluate against analyst time saved on triage and summarisation; requires clean data to be useful.'
    'Third-party SIEM'                   = 'Confirm what is forwarded and what is lost in translation, particularly incident status and evidence.'
    'Non-Microsoft AV / EDR coexistence' = 'Running two protection agents degrades both; document the coexistence decision and the passive-mode implications.'

    # --- uyumluluk ---
    'Malware protection'                 = 'Evidenced by antivirus configuration and detection telemetry in this report.'
    'Endpoint hardening'                 = 'Evidenced by the security baseline compliance figures in Section 10.'
    'Vulnerability management'           = 'Evidenced by the exposure score and remediation performance in Section 09.'
    'Asset inventory'                    = 'Auditors expect evidence that the inventory is complete; the onboarding gap is the counter-evidence.'
    'Logging & monitoring'               = 'Evidenced by telemetry retention and SIEM forwarding; state both durations.'
    'Access control / privileged access' = 'Evidenced by the RBAC and privileged role review in Section 14.'
    'Application control'                = 'Evidenced by WDAC or AppLocker state; audit mode is partial compliance at best.'
    'Data protection on endpoints'       = 'Evidenced by disk encryption coverage and removable media control.'
    'Incident response'                  = 'Evidenced by response metrics and a tested playbook, not by the existence of a document.'
    'Removable media control'            = 'Evidenced by device control policy and USB-related ASR rules.'
    'Network protection / web filtering' = 'Evidenced by network protection mode and web content filtering policy coverage.'
    'Security awareness'                 = 'Endpoint findings that trace to user behaviour belong in the awareness programme, not only in technical remediation.'
}


# ============================================================================
#  GUVENLIK YAPILANDIRMA ESLEMESI
#  secureConfiguration (131 satir gercek veri) rapordaki kontrol tablolarina
#  islenir: Observed = "%X of N devices", Status = esige gore rozet.
#  Eslesme scid ile yapilir - isim benzerligi yanlis satiri doldurabilir.
# ============================================================================
$cfgRows = Rows $d.tables.secureConfiguration
$cfgById = @{}
foreach ($c in $cfgRows) { $cfgById[$c.id] = $c }
$script:cfgById = $cfgById

# Bir rapor satirini birden fazla kontrol karsilar (ornegin "firewall tum profillerde"
# = ac + domain + private + public). Ortalamayi alir ve kac kontrolden geldigini yazar.
# Eslesmeyen scid sessizce atlanir; hicbiri yoksa $null doner ve satira dokunulmaz.
function Cfg-Agg {
    param([string[]]$Scids)
    $rows = @($Scids | ForEach-Object { $script:cfgById[$_] } | Where-Object { $_ })
    if ($rows.Count -eq 0) { return $null }
    $pct = [math]::Round(($rows | Measure-Object compliance -Average).Average)
    $app = ($rows | Measure-Object applicable -Maximum).Maximum
    [pscustomobject]@{
        pct    = $pct
        status = $(if ($pct -ge 95) { 'pass' } elseif ($pct -ge 60) { 'partial' } else { 'fail' })
        text   = "$pct% of $app devices, across $($rows.Count) control$(if ($rows.Count -ne 1) { 's' })"
    }
}

function Cfg-Cell {
    param([string]$Scid)
    $c = $cfgById[$Scid]
    if (-not $c) { return $null }
    $pct = [math]::Round([double]$c.compliance)
    $st = if ($pct -ge 95) { 'pass' } elseif ($pct -ge 60) { 'partial' } else { 'fail' }
    return [pscustomobject]@{
        text = "$pct% of $($c.applicable) devices"
        pct = $pct
        status = $st
        name = $c.name
    }
}

# satir etiketi (regex) -> scid
$CTRL_SCID = [ordered]@{
    '^Defender AV operating mode'          = 'scid-2010'
    '^Real-time protection'                = 'scid-2012'
    '^Behaviour monitoring'                = 'scid-91'
    '^Cloud-delivered protection'          = 'scid-2016'
    '^PUA protection'                      = 'scid-2013'
    '^Tamper protection'                   = 'scid-2003'
    '^EDR in block mode'                   = 'scid-2004'
    '^Scan removable drives'               = 'scid-89'
    '^Signature update interval'           = 'scid-2011'
    '^Archive / email scanning'            = 'scid-90'
    'unwanted app removal'                 = 'scid-2013'
    '^Network protection$'                 = 'scid-96'
    'SmartScreen'                          = 'scid-2061'
    '^Controlled folder access'            = 'scid-2021'
    'BitLocker / disk encryption'          = 'scid-2090'
    'Credential Guard / LSA protection'    = 'scid-2080'
    '^Defender Firewall enabled'           = 'scid-2070'
    'Rule merging from local admins'       = 'scid-51'
    'EDR sensor active on all onboarded'   = 'scid-2000'
    'Investigation package collection'     = 'scid-2001'
}

# ASR: sablon satiri -> scid + Intune kural anahtari + telemetri kural adi
$ASR_MAP = @(
    @{ label = 'Block abuse of exploited vulnerable signed drivers'; scid='scid-2515'; rule='blockabuseofexploitedvulnerablesigneddrivers'; ev='' }
    @{ label = 'Block Adobe Reader from creating child processes'; scid='scid-2513'; rule='blockadobereaderfromcreatingchildprocesses'; ev='AdobeReaderChildProcess' }
    @{ label = 'Block all Office applications from creating child processes'; scid='scid-2501'; rule='blockallofficeapplicationsfromcreatingchildprocesses'; ev='OfficeChildProcess' }
    @{ label = 'Block credential stealing from LSASS'; scid='scid-2509'; rule='blockcredentialstealingfromwindowslocalsecurityauthoritysubsystem'; ev='LsassCredentialTheft' }
    @{ label = 'Block executable content from email client and webmail'; scid='scid-2500'; rule='blockexecutablecontentfromemailclientandwebmail'; ev='ExecutableEmailContent' }
    @{ label = 'Block executable files unless prevalence'; scid='scid-2507'; rule='blockexecutablefilesrunningunlesstheymeetprevalenceagetrustedlistcriterion'; ev='' }
    @{ label = 'Block execution of potentially obfuscated scripts'; scid='scid-2505'; rule='blockexecutionofpotentiallyobfuscatedscripts'; ev='' }
    @{ label = 'Block JavaScript / VBScript from launching'; scid='scid-2504'; rule='blockjavascriptorvbscriptfromlaunchingdownloadedexecutablecontent'; ev='' }
    @{ label = 'Block Office applications from creating executable content'; scid='scid-2502'; rule='blockofficeapplicationsfromcreatingexecutablecontent'; ev='ExecutableOfficeContent' }
    @{ label = 'Block Office applications from injecting code'; scid='scid-2503'; rule='blockofficeapplicationsfrominjectingcodeintootherprocesses'; ev='OfficeProcessInjection' }
    @{ label = 'Block Office communication application from creating child processes'; scid='scid-2512'; rule='blockofficecommunicationappfromcreatingchildprocesses'; ev='OfficeCommAppChildProcess' }
    @{ label = 'Block persistence through WMI event subscription'; scid='scid-2514'; rule='blockpersistencethroughwmieventsubscription'; ev='' }
    @{ label = 'Block process creations originating from PSExec and WMI'; scid='scid-2510'; rule='blockprocesscreationsfrompsexecandwmicommands'; ev='PsexecWmiChildProcess' }
    @{ label = 'Block rebooting machine in Safe Mode'; scid='scid-2518'; rule='blockrebootingmachineinsafemode'; ev='' }
    @{ label = 'Block untrusted and unsigned processes that run from USB'; scid='scid-2511'; rule='blockuntrustedunsignedprocessesthatrunfromusb'; ev='' }
    @{ label = 'Block use of copied or impersonated system tools'; scid='scid-2517'; rule='blockuseofcopiedorimpersonatedsystemtools'; ev='AbusedSystemTool' }
    @{ label = 'Block Webshell creation for servers'; scid=''; rule='blockwebshellcreationforservers'; ev='' }
    @{ label = 'Block Win32 API calls from Office macros'; scid='scid-2506'; rule='blockwin32apicallsfromofficemacros'; ev='' }
    @{ label = 'Use advanced protection against ransomware'; scid='scid-2508'; rule='useadvancedprotectionagainstransomware'; ev='' }
    @{ label = 'Controlled folder access'; scid='scid-2021'; rule=''; ev='' }
)

$asrByRule = @{}
foreach ($r in @($d.tables.asrRules)) { $asrByRule[("$($r.rule)".ToLower())] = $r.mode }
$asrEvByName = @{}
foreach ($e in @($d.tables.asrEvents)) { $asrEvByName[("$($e.rule)".ToLower())] = $e }

$MODE_OPTS2 = @(@('', 'Not configured'), @('pass', 'Block'), @('partial', 'Audit'), @('fail', 'Disabled'), @('na', 'Warn'))

$script:cfgFilled = 0
$html = [regex]::Replace($html, '(?s)<tr>(?:(?!</tr>).)*</tr>', {
    param($rm)
    $row = $rm.Value
    if ($row -notmatch 'data-ph=|<td class="sel">|<td class="mode">') { return $row }
    $first = [regex]::Match($row, '(?s)<td[^>]*>(.*?)</td>')
    if (-not $first.Success) { return $row }
    $label = (($first.Groups[1].Value -replace '<[^>]+>', ' ') -replace '&amp;', '&' -replace '\s+', ' ').Trim()
    if (-not $label) { return $row }

    # --- ASR kural satiri mi? ---
    $asrHit = $ASR_MAP | Where-Object { $label -like "$($_.label)*" } | Select-Object -First 1
    if ($asrHit) {
        $mode = $asrByRule[$asrHit.rule]
        if ($mode) {
            $v = switch ($mode) { 'Block' { 'pass' } 'Audit' { 'partial' } 'Warn' { 'na' } 'Disabled' { 'fail' } default { '' } }
            $row = $row -replace '<td class="mode"></td>', ('<td class="mode">' + (New-Select 'st' $MODE_OPTS2 $v) + '</td>')
            $script:cfgFilled++
        }
        $ev = if ($asrHit.ev) { $asrEvByName[$asrHit.ev.ToLower()] } else { $null }
        $cfg = if ($asrHit.scid) { Cfg-Cell $asrHit.scid } else { $null }
        # Exclusions | Audit events sutunlari
        $script:asrVals = @(
            $(if ($cfg) { "$($cfg.pct)% coverage" } else { '' }),
            $(if ($ev) { "$($ev.events)" } else { $(if ($mode -eq 'Audit') { '0' } else { '' }) })
        )
        $script:asrIdx = 0
        $row = [regex]::Replace($row, '<td class="num f"([^>]*)></td>', {
            param($cm)
            if ($script:asrIdx -ge $script:asrVals.Count) { return $cm.Value }
            $val = $script:asrVals[$script:asrIdx]; $script:asrIdx++
            if ("$val" -eq '') { return $cm.Value }
            "<td class=`"num f`"$($cm.Groups[1].Value)>$val</td>"
        })
        return $row
    }

    # --- scid ile eslesen kontrol satiri mi? ---
    # NOT: yerel degisken adi haritanin adiyla ayni olamaz ($scid = $SCID)
    $hitScid = $null
    foreach ($k in $CTRL_SCID.Keys) { if ($label -match $k) { $hitScid = $CTRL_SCID[$k]; break } }
    if (-not $hitScid) { return $row }
    $c = Cfg-Cell $hitScid
    if (-not $c) { return $row }

    # Observed hucresi: satirin ilk bos duzenlenebilir hucresi
    $m = [regex]::Match($row, '<td([^>]*class="[^"]*\bf\b[^"]*"[^>]*data-ph="[^"]*")></td>')
    if ($m.Success) {
        $repl = "<td$($m.Groups[1].Value)><span class=`"draft`">$(Esc $c.text)</span></td>"
        $row = $row.Remove($m.Index, $m.Length).Insert($m.Index, $repl)
    }
    $row = $row -replace '<td class="sel"></td>', ('<td class="sel">' + (New-Select 'st' $ST_OPTS $c.status) + '</td>')
    $script:cfgFilled++
    return $row
})

# Tamper KPI'si toplayicida yanlis eslesebiliyor (LDAP "tampering" satirina takiliyor) -
# elimizde scid varsa dogrusunu yaz
$tp = Cfg-Cell 'scid-2003'
if ($tp) {
    $html = [regex]::Replace($html,
        '(<div class="v f" contenteditable data-ph="[^"]*">)(?:[^<]*)(</div><div class="k">Tamper protection on</div>)',
        { param($m) "$($m.Groups[1].Value)$($tp.pct)%$($m.Groups[2].Value)" }, 1)
}

# ============================================================================
#  ANA KONTROL LISTESI (Ek A) - toplanan veriden belirlenebilenler
#  Belirlenemeyenler "Not assessed" kalir; uydurma yapilmaz.
# ============================================================================
function Inv-Cov {
    param([string]$Pattern)
    $rows = @($d.tables.deviceInventory | Where-Object { $_.platform -match $Pattern })
    if ($rows.Count -eq 0) { return $null }
    $disc = ($rows | Measure-Object discovered -Sum).Sum
    $onb  = ($rows | Measure-Object onboarded -Sum).Sum
    if ($disc -eq 0) { return $null }
    [pscustomobject]@{ pct = [math]::Round(100 * $onb / $disc); disc = $disc; onb = $onb }
}
function Chk-Cfg {
    param([string]$Scid, [int]$PassAt = 95, [int]$PartialAt = 60)
    $c = Cfg-Cell $Scid
    if (-not $c) { return $null }
    $st = if ($c.pct -ge $PassAt) { 'pass' } elseif ($c.pct -ge $PartialAt) { 'partial' } else { 'fail' }
    [pscustomobject]@{ status = $st; evidence = $c.text }
}
function Chk-Cov {
    param([string]$Pattern, [int]$PassAt = 95)
    $c = Inv-Cov $Pattern
    if (-not $c) { return $null }
    $st = if ($c.pct -ge $PassAt) { 'pass' } elseif ($c.pct -ge 50) { 'partial' } else { 'fail' }
    [pscustomobject]@{ status = $st; evidence = "$($c.onb) of $($c.disc) onboarded ($($c.pct)%)" }
}

$CHK = @{}
function Add-Chk { param([string]$Id, $R) if ($R) { $CHK[$Id] = $R } }

Add-Chk 'A1'  (Chk-Cov 'Windows 1[01]')
Add-Chk 'A2'  (Chk-Cov 'Windows Server')
Add-Chk 'A3'  (Chk-Cov 'macOS')
Add-Chk 'A4'  (Chk-Cov 'Linux')
Add-Chk 'A5'  (Chk-Cov 'iOS|Android')
Add-Chk 'A12' $(
    $sh = Kpi-Num 'Sensor health'
    if ($null -ne $sh) { [pscustomobject]@{ status = $(if ($sh -ge 95) { 'pass' } elseif ($sh -ge 80) { 'partial' } else { 'fail' }); evidence = "Sensor health $sh%" } })
Add-Chk 'A16' $(
    if ($d.tables.agentVersions) {
        $behind = (@($d.tables.agentVersions) | Measure-Object behind -Sum).Sum
        [pscustomobject]@{ status = $(if ($behind -eq 0) { 'pass' } elseif ($behind -lt 20) { 'partial' } else { 'fail' }); evidence = "$behind devices behind the newest build" } })
Add-Chk 'B3'  $(
    if ($lic.p2 -or $lic.p1) {
        $n = 0; if ($lic.p2) { $n += $lic.p2.assigned }; if ($lic.p1) { $n += $lic.p1.assigned }
        [pscustomobject]@{ status = 'partial'; evidence = "$n Defender entitlements assigned - compare against onboarded devices" } })
Add-Chk 'B6'  $(
    $groups = @($d.raw.machineGroups | Where-Object { $_.MachineGroup })
    [pscustomobject]@{ status = $(if ($groups.Count -gt 0) { 'pass' } else { 'fail' }); evidence = $(if ($groups.Count) { "$($groups.Count) device groups in use" } else { 'No device groups configured - all devices sit in the default group' }) })

Add-Chk 'C1'  (Chk-Cfg 'scid-2010')
Add-Chk 'C2'  (Chk-Cfg 'scid-2012')
Add-Chk 'C3'  (Chk-Cfg 'scid-91')
Add-Chk 'C4'  (Chk-Cfg 'scid-2016')
Add-Chk 'C8'  (Chk-Cfg 'scid-2013')
Add-Chk 'C9'  (Chk-Cfg 'scid-2003')
Add-Chk 'C10' (Chk-Cfg 'scid-2004')
Add-Chk 'C11' (Chk-Cfg 'scid-2011')
Add-Chk 'C14' (Chk-Cfg 'scid-89')
Add-Chk 'C15' (Chk-Cfg 'scid-92')

Add-Chk 'D1'  $(
    if ($d.tables.asrRules) {
        $n = @($d.tables.asrRules).Count
        [pscustomobject]@{ status = $(if ($n -ge 19) { 'pass' } elseif ($n -ge 10) { 'partial' } else { 'fail' }); evidence = "$n of 20 rules configured in Intune" } })
Add-Chk 'D2'  $(
    if ($d.tables.asrRules) {
        $blk = @($d.tables.asrRules | Where-Object { $_.mode -eq 'Block' }).Count
        [pscustomobject]@{ status = $(if ($blk -ge 14) { 'pass' } elseif ($blk -ge 6) { 'partial' } else { 'fail' }); evidence = "$blk rules in block mode" } })
Add-Chk 'D5'  (Chk-Cfg 'scid-2021')
Add-Chk 'D6'  (Chk-Cfg 'scid-96')
Add-Chk 'D10' (Chk-Cfg 'scid-2515')
Add-Chk 'D12' (Chk-Cfg 'scid-2080')
Add-Chk 'D13' (Chk-Cfg 'scid-2070')
Add-Chk 'D14' (Chk-Cfg 'scid-2090')

Add-Chk 'E1'  $(
    $tv = Kpi-Num 'Total vulnerabilities'
    if ($tv) { [pscustomobject]@{ status = 'pass'; evidence = "$($d.kpi.'Total vulnerabilities') vulnerability instances reported" } })
Add-Chk 'E7'  $(
    $sw = Kpi-Num 'Software products'
    if ($sw) { [pscustomobject]@{ status = 'pass'; evidence = "$($d.kpi.'Software products') products in inventory" } })
Add-Chk 'E12' $(
    $ss = Kpi-Num 'Secure score for devices'
    if ($ss) { [pscustomobject]@{ status = $(if ($ss -ge 80) { 'pass' } elseif ($ss -ge 60) { 'partial' } else { 'fail' }); evidence = "Secure Score $ss%" } })

Add-Chk 'F1'  (Chk-Cfg 'scid-2000')
Add-Chk 'F11' $(
    $n = @($d.tables.customDetections).Count
    [pscustomobject]@{ status = $(if ($n -ge 5) { 'pass' } elseif ($n -gt 0) { 'partial' } else { 'fail' }); evidence = "$n custom detection rules" })
Add-Chk 'F2'  $(
    $tot = Kpi-Num 'Total alerts (90d)'; $res = Kpi-Num 'Resolved'
    if ($tot) {
        $pct = [math]::Round(100 * $res / $tot)
        [pscustomobject]@{ status = $(if ($pct -ge 90) { 'pass' } elseif ($pct -ge 50) { 'partial' } else { 'fail' }); evidence = "$res of $tot alerts resolved ($pct%)" } })

Add-Chk 'G2'  $(
    if ($d.tables.intunePolicies) { [pscustomobject]@{ status = 'pass'; evidence = "$(@($d.tables.intunePolicies).Count) Intune configuration policies read" } })
Add-Chk 'G3'  $(
    if ($d.tables.conditionalAccess) {
        $ca = @($d.tables.conditionalAccess)[0]
        [pscustomobject]@{ status = $(if ($ca.deviceRiskUsed) { 'pass' } else { 'fail' }); evidence = "$($ca.deviceComplianceCA) of $($ca.enabledPolicies) enabled policies require device compliance" } })
Add-Chk 'H2'  $(
    if ($null -ne $d.meta.pimEligibleAssignments) {
        $n = [int]$d.meta.pimEligibleAssignments
        [pscustomobject]@{ status = $(if ($n -gt 0) { 'partial' } else { 'fail' }); evidence = "$n PIM-eligible role assignments" } })

if ($CHK.Count -gt 0) {
    $script:chkMap = $CHK
    $script:chkFilled = 0
    $script:html = [regex]::Replace($script:html, '(?s)<tr><td>([A-H]\d{1,2})</td>(?:(?!</tr>).)*</tr>', {
        param($rm)
        $row = $rm.Value
        $id = [regex]::Match($row, '<tr><td>([A-H]\d{1,2})</td>').Groups[1].Value
        if (-not $script:chkMap.ContainsKey($id)) { return $row }
        $e = $script:chkMap[$id]
        $row = $row -replace '<td class="sel"></td>', ('<td class="sel">' + (New-Select 'st' $ST_OPTS $e.status) + '</td>')
        $row = [regex]::Replace($row, '<td([^>]*class="[^"]*\bf\b[^"]*"[^>]*data-ph="[^"]*")></td>', {
            param($cm) "<td$($cm.Groups[1].Value)><span class=`"draft`">$(Esc $e.evidence)</span></td>"
        }, 1)
        $script:chkFilled++
        return $row
    })
    $filled.rows += $script:chkFilled
}

# ============================================================================
#  OLGUNLUK TABLOSU (Bolum 18)
#  $dom / $five zaten hesaplaniyordu ve iki grafige de ciziliyordu; tablo bos
#  kaliyordu. Ayni kaynaktan yazilir - grafik ile tablo asla ayrismasin.
# ============================================================================
$MAT_ROWS = [ordered]@{
    'Deployment &amp; onboarding'      = 'Deployment & Onboarding'
    'Next-generation protection'       = 'Next-Generation Protection'
    'Attack surface reduction'         = 'Attack Surface Reduction'
    'Vulnerability management'         = 'Vulnerability Management'
    'EDR &amp; automation'             = 'EDR & Automation'
    'Threat hunting &amp; intelligence' = ''
    'Integration &amp; SIEM'           = 'Integration & SIEM'
    'Governance &amp; RBAC'            = 'Identity & Access (RBAC)'
    'Security operations'              = 'Security Operations'
}
$MAT_ACTION = @{
    'Deployment & Onboarding'    = 'Onboard the remaining discovered devices and close the gap per platform.'
    'Next-Generation Protection' = 'Bring the antivirus controls below target to the baseline configuration across the estate.'
    'Attack Surface Reduction'   = 'Move the attack surface reduction rules from audit to block and confirm they apply on devices, not only in policy.'
    'Vulnerability Management'   = 'Work the exposed device list from the security recommendations by exposure, starting with the critical CVEs.'
    'EDR & Automation'           = 'Restore sensor health on the impaired devices and confirm data collection resumes.'
    'Security Operations'        = 'Close the open alerts and define the response SLA the resolution rate is measured against.'
}
# NOT: 'Vulnerability management' Bolum 16'da, 'Attack surface reduction' Bolum 03'te de
# satir basligi. Belge genelinde Replace(...,1) yanlis tabloyu yakalar - once tabloyu
# "Key action to close the gap" basligindan izole edip degisimi onun icinde yapiyoruz.
if ($five -and $five.Count) {
    $rxTable = [regex]'(?s)(<table[^>]*>\s*<thead>(?:(?!</table>).)*?Key action to close the gap(?:(?!</table>).)*?</thead>\s*<tbody>)(.*?)(</tbody>)'
    if ($rxTable.IsMatch($script:html)) {
        $script:matFilled = 0
        $script:html = $rxTable.Replace($script:html, {
            param($tm)
            $body = $tm.Groups[2].Value
            foreach ($label in $MAT_ROWS.Keys) {
                $key = $MAT_ROWS[$label]
                if (-not $key -or -not $five.ContainsKey($key)) { continue }
                $cur = [int]$five[$key]
                $tgt = [math]::Min(5, $cur + 1)
                $act = if ($MAT_ACTION.ContainsKey($key)) { $MAT_ACTION[$key] } else { "Raise $key to level $tgt." }
                # Seviyenin dayanagini hucreye yaz - "3" tek basina savunulamaz
                $ev = switch ($key) {
                    'Next-Generation Protection' { Sub-Evidence 'Antivirus' }
                    'Attack Surface Reduction'   { Sub-Evidence 'Attack Surface Reduction' }
                    'EDR & Automation'           { Sub-Evidence 'EDR' }
                    'Deployment & Onboarding'    { "Onboarding rate $($dom[$key])%." }
                    'Vulnerability Management'   { "Secure score for devices $($dom[$key])%." }
                    'Security Operations'        { "$($dom[$key])% of alerts in the window were resolved." }
                    default                      { '' }
                }
                if ($ev) { $act = "$ev $act" }
                $script:matCells = @("$cur", "$tgt", "+$($tgt - $cur)", $act)
                $rxRow = [regex]("(?s)(<tr><td>" + [regex]::Escape($label) + "</td>)(.*?)(</tr>)")
                if (-not $rxRow.IsMatch($body)) { continue }
                $body = $rxRow.Replace($body, {
                    param($m)
                    $script:matIdx = 0
                    $cells = [regex]::Replace($m.Groups[2].Value, '<td([^>]*data-ph="[^"]*")></td>', {
                        param($cm)
                        if ($script:matIdx -ge $script:matCells.Count) { return $cm.Value }
                        $v = $script:matCells[$script:matIdx]; $script:matIdx++
                        $script:draftCount++
                        "<td$($cm.Groups[1].Value)><span class=`"draft`">$(Esc $v)</span></td>"
                    })
                    "$($m.Groups[1].Value)$cells$($m.Groups[3].Value)"
                }, 1)
                $script:matFilled++
            }
            "$($tm.Groups[1].Value)$body$($tm.Groups[3].Value)"
        }, 1)
        $filled.rows += $script:matFilled
    }
}

# ============================================================================
#  KAPAK KPI: OVERALL MATURITY ve CONTROL COMPLIANCE
#  Ikisi de hicbir yerde hesaplanmiyordu; kurallari CONSULTANT-GUIDE.md'de yazili.
#  KPI regex pasindan (dosyanin basi) cok sonra calisiyoruz - checklist sonuclari
#  ancak burada hazir - o yuzden iki kutuyu dogrudan hedefleyerek yaziyoruz.
# ============================================================================
$MAT_NAME = @{ 1 = 'Initial'; 2 = 'Defined'; 3 = 'Managed'; 4 = 'Integrated'; 5 = 'Optimised' }
function Set-CoverKpi {
    param([string]$Label, [string]$Value, [string]$Desc)
    $rx = [regex]('(?s)(<div class="v f" contenteditable data-ph="[^"]*">)</div>(<div class="k">' +
                  [regex]::Escape($Label) + '</div><div class="d f" contenteditable data-ph="[^"]*">)</div>')
    if (-not $rx.IsMatch($script:html)) { return $false }
    $script:kpiVal = $Value; $script:kpiDesc = $Desc
    $script:html = $rx.Replace($script:html, {
        param($m)
        $script:draftCount += 2
        "$($m.Groups[1].Value)<span class=`"draft`">$(Esc $script:kpiVal)</span></div>" +
        "$($m.Groups[2].Value)<span class=`"draft`">$(Esc $script:kpiDesc)</span></div>"
    }, 1)
    return $true
}

# Overall maturity: puani olan alanlarin ortalamasinin asagi yuvarlanmasi; herhangi bir
# cekirdek alan seviye 1'deyse 3 ile sinirli (bkz. CONSULTANT-GUIDE.md).
if ($five -and $five.Count) {
    $core = @('Deployment & Onboarding','Next-Generation Protection','Attack Surface Reduction',
              'Vulnerability Management','EDR & Automation')
    $vals = @($five.Values | ForEach-Object { [int]$_ })
    $overall = [math]::Floor(($vals | Measure-Object -Average).Average)
    $weakCore = @($core | Where-Object { $five.ContainsKey($_) -and [int]$five[$_] -eq 1 })
    if ($weakCore.Count -gt 0 -and $overall -gt 3) { $overall = 3 }
    $overall = [math]::Max(1, [int]$overall)
    $desc = "$($MAT_NAME[$overall]) - $($five.Count) of $($dom.Count) domains scored"
    if ($weakCore.Count) { $desc += "; capped, $($weakCore -join ' and ') at level 1" }
    Set-CoverKpi -Label 'Overall Maturity' -Value "$overall / 5" -Desc $desc | Out-Null

    # Bolum 18'deki "Current overall maturity / Target maturity" satiri
    $script:ovVal = "$overall"; $script:ovTgt = "$([math]::Min(5, $overall + 1))"
    $rxOv = [regex]'(?s)(Current overall maturity:\s*<b class="f" contenteditable data-ph="\[level\]">)</b>(.*?)(<b class="f" contenteditable data-ph="\[level\]">)</b>'
    if ($rxOv.IsMatch($script:html)) {
        $script:html = $rxOv.Replace($script:html, {
            param($m)
            $script:draftCount += 2
            "$($m.Groups[1].Value)<span class=`"draft`">$($script:ovVal)</span></b>$($m.Groups[2].Value)" +
            "$($m.Groups[3].Value)<span class=`"draft`">$($script:ovTgt)</span></b>"
        }, 1)
    }
}

# Control compliance: uyumlu / degerlendirilen. "Not assessed" ve "N/A" paydaya girmez -
# 110'a bolmek olculmemis satirlari basarisiz gostermek olur (bkz. CONSULTANT-GUIDE.md).
if ($CHK -and $CHK.Count -gt 0) {
    $assessed = @($CHK.Values | Where-Object { $_.status -in 'pass','partial','fail' })
    if ($assessed.Count -gt 0) {
        $pass = @($assessed | Where-Object { $_.status -eq 'pass' }).Count
        $part = @($assessed | Where-Object { $_.status -eq 'partial' }).Count
        $pct = [math]::Round(100 * $pass / $assessed.Count)
        $totalRows = @([regex]::Matches($script:html, '<tr><td>[A-H]\d{1,2}</td>')).Count
        $notAssessed = [math]::Max(0, $totalRows - $assessed.Count)
        $desc = "$pass of $($assessed.Count) assessed controls compliant"
        if ($part) { $desc += ", $part partial" }
        if ($notAssessed) { $desc += "; $notAssessed of $totalRows not assessed" }
        Set-CoverKpi -Label 'Control Compliance' -Value "$pct%" -Desc $desc | Out-Null
    }
}

# ============================================================================
#  HOST FIREWALL / CIHAZ KONTROLU (Bolum 08)
#  Bu satirlar bos kaliyordu ama kontroller secureConfiguration'da duruyor.
#  ESLEME KURALI: kontrol satiri gercekten karsilamiyorsa BOS BIRAK. "Credential
#  Guard" satirini "yerel parola saklamayi kapat" kontroluyle doldurmak, tamper
#  protection hatasinin (tuzak 9) baska kiliktaki hali olurdu.
# ============================================================================
$fwMap = @{}
$fwAll = Cfg-Agg @('scid-2070', 'scid-2071', 'scid-2072', 'scid-2073')   # ac + domain/private/public profil
if ($fwAll) { $fwMap['Defender Firewall enabled'] = @{ v = @('', $fwAll.text); status = $fwAll.status; draft = $true } }
$fwMerge = Cfg-Agg @('scid-50', 'scid-51')                                # yerel kural birlestirmeyi kapat
if ($fwMerge) { $fwMap['Rule merging'] = @{ v = @('', $fwMerge.text); status = $fwMerge.status; draft = $true } }
if ($fwMap.Count) { Fill-Rows -Heading 'Host Firewall' -Map $fwMap | Out-Null }

$dcMap = @{}
$bit = Cfg-Agg @('scid-2090')                                             # tum BitLocker destekli surucleri sifrele
if ($bit) { $dcMap['BitLocker'] = @{ v = @('', $bit.text); status = $bit.status; draft = $true } }
if ($dcMap.Count) { Fill-Rows -Heading 'Device Control &amp; Peripheral Security' -Map $dcMap | Out-Null }

# ------------------------------------------- MISCONFIGURATION FINDINGS ----
# Esik mutlak 50 idi: 9 cihazlik bir tenant'ta hicbir kontrol gecmiyor ve tablo
# sessizce bos kaliyordu. Olcegi ortama gore al - en genis uygulanabilirlik neyse
# onun ceyregi, en az 3 cihaz. Boylece kucuk ortamda da dolar, tek cihazlik gurultu
# de tabloya cikmaz.
$cfgMaxApp = 0
if ($cfgAll.Count) { $cfgMaxApp = ($cfgAll | Measure-Object applicable -Maximum).Maximum }
$cfgFloor = [math]::Max(3, [math]::Floor($cfgMaxApp * 0.25))
$worst = @($cfgAll | Where-Object { $_.applicable -ge $cfgFloor } |
           Sort-Object @{ Expression = { [double]$_.compliance } },
                       @{ Expression = { [int]$_.applicable }; Descending = $true } |
           Select-Object -First 6)
if ($worst.Count) {
    $script:misRows = $worst
    $script:misIdx = 0
    $rxMis = [regex]'(?s)(<h3[^>]*>Misconfiguration Findings</h3>(?:(?!<h3).)*?<tbody>)(.*?)(</tbody>)'
    if ($rxMis.IsMatch($script:html)) {
        $script:html = $rxMis.Replace($script:html, {
            param($m)
            $body = [regex]::Replace($m.Groups[2].Value, '(?s)<tr>.*?</tr>', {
                param($rm)
                if ($script:misIdx -ge $script:misRows.Count) { return $rm.Value }
                $c = $script:misRows[$script:misIdx]; $script:misIdx++
                $nonCompliant = [int]$c.applicable - [int]$c.compliant
                $sev = if ($c.compliance -lt 25) { 'high' } elseif ($c.compliance -lt 60) { 'medium' } else { 'low' }
                $script:filled.rows++
                "<tr><td class=`"f`" contenteditable data-ph=`"––`"><span class=`"draft`">$(Esc $c.name)</span></td>" +
                "<td class=`"num f`" contenteditable data-ph=`"––`">$nonCompliant</td>" +
                "<td class=`"sev`">$(New-Select 'sev' $SEV_OPTS $sev)</td>" +
                "<td class=`"f`" contenteditable data-ph=`"––`"><span class=`"draft`">$(Esc "Currently compliant on $([math]::Round([double]$c.compliance))% of $($c.applicable) applicable devices ($($c.id))")</span></td></tr>"
            })
            "$($m.Groups[1].Value)$body$($m.Groups[3].Value)"
        }, 1)
    }
}

# ------------------------------------------------ DEVICE GROUPS & TAGGING -
$mg = @($d.raw.machineGroups)
if ($mg.Count) {
    $named = @($mg | Where-Object { $_.MachineGroup } | Group-Object MachineGroup |
               ForEach-Object { [pscustomobject]@{ name = $_.Name; devices = ($_.Group | Measure-Object Devices -Sum).Sum } })
    $ungrouped = ($mg | Where-Object { -not $_.MachineGroup } | Measure-Object Devices -Sum).Sum
    $script:dgRows = @($named) + @([pscustomobject]@{ name = 'Ungrouped devices'; devices = $ungrouped })
    $script:dgIdx = 0
    $rxDg = [regex]'(?s)(<h3[^>]*>Device Groups &amp; Tagging</h3>(?:(?!<h3).)*?<tbody>)(.*?)(</tbody>)'
    if ($rxDg.IsMatch($script:html)) {
        $script:html = $rxDg.Replace($script:html, {
            param($m)
            $body = [regex]::Replace($m.Groups[2].Value, '(?s)<tr>.*?</tr>', {
                param($rm)
                if ($script:dgIdx -ge $script:dgRows.Count) { return $rm.Value }
                $g = $script:dgRows[$script:dgIdx]; $script:dgIdx++
                if (-not $g.devices) { return $rm.Value }
                $script:filled.rows++
                $note = if ($g.name -eq 'Ungrouped devices') { 'Default group - no RBAC scoping or automation level can be applied separately' } else { 'Confirm the membership rule and automation level' }
                "<tr><td class=`"f`" contenteditable data-ph=`"––`"><span class=`"draft`">$(Esc $g.name)</span></td>" +
                "<td class=`"f`" contenteditable data-ph=`"––`"></td>" +
                "<td class=`"num f`" contenteditable data-ph=`"––`">$($g.devices)</td>" +
                "<td class=`"f`" contenteditable data-ph=`"––`"></td>" +
                "<td class=`"f`" contenteditable data-ph=`"––`"><span class=`"draft`">$(Esc $note)</span></td></tr>"
            })
            "$($m.Groups[1].Value)$body$($m.Groups[3].Value)"
        }, 1)
    }
}

# ---------------------------------------------------- BOLUM 01 TABLOLARI --
# In Scope: cihaz envanterinden kategori bazinda topla
if ($d.tables.deviceInventory) {
    $inv = Rows $d.tables.deviceInventory
    function ScopeText {
        param([string]$Pattern)
        $rows = @($inv | Where-Object { $_.platform -match $Pattern })
        if ($rows.Count -eq 0) { return 'None discovered' }
        $tot = ($rows | Measure-Object discovered -Sum).Sum
        $onb = ($rows | Measure-Object onboarded -Sum).Sum
        $names = ($rows | ForEach-Object { $_.platform }) -join ', '
        return "$tot discovered / $onb onboarded - $names"
    }
    Fill-Rows -Heading 'In Scope' -Map @{
        '^Windows clients'   = @{ v = @((ScopeText 'Windows 1[01]')) }
        '^Windows servers'   = @{ v = @((ScopeText 'Windows Server')) }
        '^macOS'             = @{ v = @((ScopeText 'macOS')) }
        '^Linux'             = @{ v = @((ScopeText 'Linux')) }
        'Mobile'             = @{ v = @((ScopeText 'iOS|Android')) }
        'Network / IoT / OT' = @{ draft = $true; v = @('Device discovery only - not onboarded; confirm whether OT segments are in scope') }
    } | Out-Null
}

# Data Sources Used: neyin nereden geldigi
$ahTables = 'DeviceInfo, DeviceEvents, DeviceTvmSoftwareVulnerabilities, DeviceTvmSecureConfigurationAssessment, DeviceTvmSoftwareInventory, AlertInfo'
$polCount = if ($d.tables.intunePolicies) { @($d.tables.intunePolicies).Count } else { 0 }
Fill-Rows -Heading 'Data Sources Used' -Map @{
    'Microsoft Defender portal' = @{ v = @(
        'Device inventory, secure configuration assessment, exposure and recommendations (read via API)',
        "Collected $($d.meta.generatedUtc) UTC") }
    'Advanced Hunting' = @{ v = @($ahTables, "$($d.meta.eventWindow) event window, $($d.meta.alertWindow) alert window") }
    'Microsoft Intune' = @{ v = @('Endpoint security and configuration policies with assignments, antivirus exclusions',
        "$polCount configuration policies read") }
    'Group Policy / MECM' = @{ draft = $true; v = @('Not readable through the API',
        'Request a GPO report if any protection setting is managed outside Intune') }
    'Microsoft Secure Score' = @{ v = @('Tenant score, control breakdown and recommended actions',
        "$(if ($d.meta.secureScore) { "Score $($d.meta.secureScore)" } else { 'Not available' })") }
    'Microsoft Sentinel / SIEM' = @{ draft = $true; v = @('Connector state not read by this collection',
        'Confirm connector health and ingestion volume with the SOC') }
} | Out-Null

# Severity Definitions: standart tanimlar
Fill-Rows -Heading 'Severity Definitions' -Map @{
    '^Critical' = @{ draft = $true; v = @('Exploitable now with no compensating control, or protection is absent on production systems. Remediate immediately.') }
    '^High'     = @{ draft = $true; v = @('Significant exposure with a realistic attack path; a compensating control may exist but is partial. Remediate within 30 days.') }
    '^Medium'   = @{ draft = $true; v = @('Moderate risk or a control operating below its intended effectiveness. Remediate within 90 days.') }
    '^Low'      = @{ draft = $true; v = @('Hardening or optimisation opportunity with limited immediate risk. Schedule into routine work.') }
} | Out-Null

# best practice yorumlarini satirin SON bos duzenlenebilir hucresine yaz
$script:bpCount = 0
$script:bpMap = $bp
$html = [regex]::Replace($html, '(?s)<tr>(?:(?!</tr>).)*</tr>', {
    param($rm)
    $row = $rm.Value
    if ($row -notmatch 'data-ph=') { return $row }
    $cells = [regex]::Matches($row, '(?s)<td[^>]*>(.*?)</td>')
    if ($cells.Count -lt 2) { return $row }
    $label = (($cells[0].Groups[1].Value -replace '<[^>]+>', ' ') -replace '&amp;', '&' -replace '\s+', ' ').Trim()
    if (-not $label -or $label.StartsWith('[')) { return $row }

    $text = $null
    foreach ($k in $script:bpMap.Keys) {
        if ($label -like "*$k*") { $text = $script:bpMap[$k]; break }
    }
    if (-not $text) { return $row }

    # son bos duzenlenebilir hucreyi bul
    $empties = [regex]::Matches($row, '<td([^>]*class="[^"]*\bf\b[^"]*"[^>]*data-ph="[^"]*")></td>')
    if ($empties.Count -eq 0) { return $row }
    $last = $empties[$empties.Count - 1]
    $script:bpCount++
    $repl = "<td$($last.Groups[1].Value)><span class=`"draft`">$(Esc $text)</span></td>"
    return $row.Remove($last.Index, $last.Length).Insert($last.Index, $repl)
})

# --- taslaklari yerlestir (yalnizca hala bos olan alanlara) ---
$script:draftCount = 0
foreach ($key in $drafts.Keys) {
    $text = $drafts[$key]
    if (-not $text) { continue }
    $pat = '(?s)(<(\w+)[^>]*class="[^"]*\bf\b[^"]*"[^>]*data-ph="' + [regex]::Escape($key) + '[^"]*"[^>]*>)</\2>'
    $rx = [regex]$pat
    if (-not $rx.IsMatch($html)) { continue }
    $script:draftText = $text
    $html = $rx.Replace($html, {
        param($m)
        $script:draftCount++
        "$($m.Groups[1].Value)<span class=`"draft`">$(Esc $script:draftText)</span></$($m.Groups[2].Value)>"
    }, 1)
}

# --- yol haritasi tablolari: bulgulardan ---
function Fill-Roadmap {
    param([string]$Heading, $Items, [string]$Horizon)
    if (-not $Items -or @($Items).Count -eq 0) { return }
    $script:rmItems = @($Items)
    $script:rmIdx = 0
    $rx = [regex]("(?s)(<h3[^>]*>" + [regex]::Escape($Heading) + "</h3>\s*<table class=`"t compact`">.*?<tbody>)(.*?)(</tbody>)")
    if (-not $rx.IsMatch($script:html)) { return }
    # NOT: fonksiyon icinde $html'e atama yerel kopya olusturur -> $script:html
    $script:html = $rx.Replace($script:html, {
        param($m)
        $body = [regex]::Replace($m.Groups[2].Value, '(?s)<tr>.*?</tr>', {
            param($rm)
            if ($script:rmIdx -ge $script:rmItems.Count) { return $rm.Value }
            $it = $script:rmItems[$script:rmIdx]; $script:rmIdx++
            $script:draftCount++
            $eff = switch ($it.severity) { 'Critical' { 'Low' } 'High' { 'Medium' } default { 'Medium' } }
            $imp = switch ($it.severity) { 'Critical' { 'Critical' } 'High' { 'High' } 'Medium' { 'Medium' } default { 'Low' } }
            $act = "Remediate $($it.id): $($it.finding)"
            "<tr><td class=`"f`" contenteditable data-ph=`"––`"><span class=`"draft`">$(Esc $act)</span></td><td class=`"f`" contenteditable data-ph=`"––`"></td><td class=`"f`" contenteditable data-ph=`"––`"><span class=`"draft`">$eff</span></td><td class=`"f`" contenteditable data-ph=`"––`"><span class=`"draft`">$imp</span></td><td class=`"f`" contenteditable data-ph=`"––`"><span class=`"draft`">$(Esc "Closes $($it.id)")</span></td></tr>"
        })
        "$($m.Groups[1].Value)$body$($m.Groups[3].Value)"
    }, 1)
}

if ($fnd.Count -gt 0) {
    Fill-Roadmap -Heading 'Quick Wins — implement within 30 days' -Items ($crit + $high) -Horizon '30d'
    Fill-Roadmap -Heading 'Short Term — 90 days' -Items $med -Horizon '90d'
    Fill-Roadmap -Heading 'Strategic — next 12 months' -Items $low -Horizon '12m'

    # kritik bosluk kartlari
    $gi = 1
    foreach ($g in @($fnd | Select-Object -First 4)) {
        $script:gTitle = $g.finding
        foreach ($ph in "[Gap $gi title]", '[Description and impact]') {
            $rx = [regex]('(?s)(<(\w+)[^>]*data-ph="' + [regex]::Escape($ph) + '"[^>]*>)</\2>')
            if ($rx.IsMatch($html)) {
                $script:gText = if ($ph -like '*title*') { $g.finding } else { "$($g.severity) severity, $($g.domain) domain. See $($g.id) in the findings register." }
                $html = $rx.Replace($html, {
                    param($m)
                    $script:draftCount++
                    "$($m.Groups[1].Value)<span class=`"draft`">$(Esc $script:gText)</span></$($m.Groups[2].Value)>"
                }, 1)
            }
        }
        $gi++
    }
}

# -------------------------------------------------- TOPLAMA NOTU / ROZET --
$warn = ($d.meta.warnings | ForEach-Object { "<li>$(Esc $_)</li>" }) -join ''
$manual = ($d.manual | ForEach-Object { "<li>$(Esc $_)</li>" }) -join ''
$note = @"
<section class="page" data-toc="Collection Notes (automatic)" data-grp="Collector">
  <div class="body">
    <div class="eyebrow">Collector output</div>
    <h2>Automated Collection Notes</h2>
    <div class="rule"></div>
    <p class="small mut">This page was added by MDE-Render.ps1 and is not part of the report.</p>
    <button type="button" class="pagedel" onclick="removePage(this)">Remove this page</button>
    <table class="t compact">
      <tbody>
        <tr><td style="width:30%"><b>Collected (UTC)</b></td><td>$(Esc $d.meta.generatedUtc)</td></tr>
        <tr><td><b>Tenant</b></td><td>$(Esc $d.meta.tenantName) · $(Esc $d.meta.verifiedDomain)</td></tr>
        <tr><td><b>Alert window</b></td><td>$(Esc $d.meta.alertWindow)</td></tr>
        <tr><td><b>Event window</b></td><td>$(Esc $d.meta.eventWindow)</td></tr>
        <tr><td><b>Automatically populated</b></td><td>$($filled.charts) charts · $($filled.kpi) KPIs · $($filled.rows) table rows · $($filled.fields) fields · $($script:draftCount + $script:bpCount) draft texts</td></tr>
      </tbody>
    </table>
    <h3>Collection warnings</h3>
    <ul class="small">$warn</ul>
    <h3>To be completed manually</h3>
    <ul class="small">$manual</ul>
  </div>
  <div class="pfoot"><span class="cls">Confidential</span><span>Microsoft Defender for Endpoint — Health Check Assessment</span><span class="pn">Page </span></div>
</section>
"@
$script:noteHtml = $note
$html = [regex]::Replace($html, '(?s)(</div>\s*<script>)', {
    param($m)
    $script:noteHtml + $m.Groups[1].Value
}, 1)

# ============================================================================
#  ANKET CEVAPLARI (New-Survey.ps1 -> musteri -> -SurveyFile)
#  En sonda calisir: yalnizca hicbir veri kaynaginin dolduramadigi hucreleri
#  doldurur. Toplanan veri HER ZAMAN kazanir - bir musteri beyani, olculmus bir
#  degerin uzerine yazamaz. Cevaplar "Self-reported" olarak isaretlenir, cunku
#  beyan ile gozlem ayni sey degildir.
# ============================================================================
if ($SurveyFile) {
    if (-not (Test-Path $SurveyFile)) { throw "Anket dosyasi bulunamadi: $SurveyFile" }
    $survey = Get-Content $SurveyFile -Raw -Encoding utf8 | ConvertFrom-Json
    if ($survey.schema -ne 'mde-survey/1') {
        Write-Warning "Anket surumu taninmadi ($($survey.schema)); yine de denenecek."
    }
    $ans = @{}
    foreach ($p in $survey.answers.PSObject.Properties) { $ans[$p.Name] = $p.Value }

    # Cevap dosyasi soru kimligi tasir; o kimligin hangi satiri dolduracagini
    # soru bankasi bilir. Banka olmadan birlestirme yapilamaz.
    $qFile = @((Join-Path $PSScriptRoot 'survey-questions.psd1'),
               (Join-Path (Split-Path $PSScriptRoot -Parent) 'survey-questions.psd1')) |
             Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $qFile) { throw 'survey-questions.psd1 bulunamadi - anket cevaplari eslenemez.' }
    $qBank = @((Import-PowerShellDataFile -Path $qFile).Questions)

    # New-Survey.ps1 icindeki Norm ile BIREBIR AYNI kalmali
    function Norm {
        param([string]$s)
        $t = ([System.Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', ''))).Trim() -replace '&', ' and '
        $t = $t -replace '[^\w\s]', ' ' -replace '\s+', ' '
        return $t.Trim().ToLower()
    }

    # hedef yolu -> cevap
    $byTarget = @{}
    foreach ($q in $qBank) {
        if (-not $ans.ContainsKey($q.id)) { continue }
        $byTarget["$(Norm $q.target.section)::$(Norm $q.target.table)::$(Norm $q.target.row)"] = $ans[$q.id]
    }
    $ans = $byTarget

    $script:svSection = ''; $script:svH3 = ''
    $script:svFilled = 0; $script:svConflict = 0; $script:svUnused = @{}
    foreach ($k in $ans.Keys) { $script:svUnused[$k] = $true }

    # Tek gecis: bolum basligi / h3 / satir - hangisi eslesirse durumu guncelle veya doldur
    $rxWalk = [regex]'(?s)<section class="page[^"]*"[^>]*data-toc="([^"]*)"|<h3[^>]*>(.*?)</h3>|<tr>((?:(?!</tr>).)*)</tr>'
    $html = $rxWalk.Replace($html, {
        param($m)
        if ($m.Groups[1].Success) { $script:svSection = Norm $m.Groups[1].Value; return $m.Value }
        if ($m.Groups[2].Success) { $script:svH3 = Norm $m.Groups[2].Value; return $m.Value }

        $row = $m.Groups[3].Value
        $cells = [regex]::Matches($row, '(?s)<td[^>]*>(.*?)</td>')
        if ($cells.Count -lt 2) { return $m.Value }
        $label = [System.Net.WebUtility]::HtmlDecode(($cells[0].Groups[1].Value -replace '<[^>]+>', '')).Trim()
        if (-not $label) { return $m.Value }

        $id = "$($script:svSection)::$($script:svH3)::$(Norm $label)"
        if (-not $ans.ContainsKey($id)) { return $m.Value }
        $a = $ans[$id]
        $script:svUnused.Remove($id) | Out-Null

        $new = $row
        # Ilk BOS duzenlenebilir hucre - dolu olan hucreye asla dokunma
        $rxEmpty = [regex]'<td([^>]*data-ph="[^"]*")></td>'
        if ($a.observed -and $rxEmpty.IsMatch($new)) {
            $script:svText = "Self-reported: $($a.observed)"
            $new = $rxEmpty.Replace($new, {
                param($cm)
                "<td$($cm.Groups[1].Value)><span class=`"draft`">$(Esc $script:svText)</span></td>"
            }, 1)
            $script:svFilled++
            $script:draftCount++
        }
        elseif ($a.observed) { $script:svConflict++ }

        # Durum hucresi iki bicimde olabilir: bos <td class="sel"></td> (istemcide
        # doldurulur) ya da sablona gomulu hazir <select>. Ikisini de ele al.
        if ($a.status) {
            if ($new -match '<td class="sel"></td>') {
                $new = $new -replace '<td class="sel"></td>', ('<td class="sel">' + (New-Select 'st' $ST_OPTS $a.status) + '</td>')
            }
            elseif ($new -notmatch 'selected') {
                $script:svStatus = $a.status
                $new = [regex]::Replace($new, '<option value="([^"]*)">', {
                    param($om)
                    if ($om.Groups[1].Value -eq $script:svStatus) { "<option value=`"$($om.Groups[1].Value)`" selected>" }
                    else { $om.Value }
                })
            }
        }
        # DIKKAT: eslesme <tr>...</tr>'nin TAMAMI, gruplanan ise yalnizca ici.
        # Sadece $new dondurursek satir etiketleri silinir ve tablo bozulur.
        return "<tr>$new</tr>"
    })

    Write-Host ''
    Write-Host "  Anket: $($script:svFilled) alan dolduruldu" -ForegroundColor Green
    if ($script:svConflict) {
        Write-Host "         $($script:svConflict) cevap kullanilmadi - o hucreleri toplanan veri zaten doldurmustu" -ForegroundColor DarkGray
    }
    if ($script:svUnused.Count) {
        Write-Host "         $($script:svUnused.Count) cevap hicbir satira eslenmedi - sablon degismis olabilir" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------ KAPAK LOGO --
if ($Logo -ne 'template') {
    $newLogo = if ($Logo -eq 'microsoft') {
        @'
<div class="logo">
      <svg viewBox="0 0 23 23" xmlns="http://www.w3.org/2000/svg" aria-label="Microsoft">
        <rect x="1"  y="1"  width="10" height="10" fill="#F25022"/>
        <rect x="12" y="1"  width="10" height="10" fill="#7FBA00"/>
        <rect x="1"  y="12" width="10" height="10" fill="#00A4EF"/>
        <rect x="12" y="12" width="10" height="10" fill="#FFB900"/>
      </svg>
      <div class="w ms">Microsoft</div>
    </div>
'@
    } else { '<div class="logo"></div>' }

    $script:logoHtml = $newLogo
    $rxLogo = [regex]'(?s)<div class="logo">.*?<div class="w">.*?</div>\s*</div>'
    if ($rxLogo.IsMatch($html)) {
        $html = $rxLogo.Replace($html, {
            param($m)
            $script:logoHtml
        }, 1)
        $filled.fields++
    } else {
        Write-Warning 'Kapak logosu bulunamadı — şablon değişmiş olabilir, logo değiştirilmedi.'
    }

    # Microsoft wordmark stili
    $anchor = '.cover .logo .w span{display:block;font-size:19pt}'
    if ($Logo -eq 'microsoft' -and $html.Contains($anchor)) {
        $html = $html.Replace($anchor, $anchor +
            "`n.cover .logo .w.ms{font-weight:400;font-size:23pt;letter-spacing:-.02em;color:#5E5E5E;line-height:1}" +
            "`n.cover .logo svg[aria-label=`"Microsoft`"]{width:38px}")
    }
}

if ($HideDataTables) { $html = $html.Replace('<body class="guides">', '<body class="nodata">') }
$html = $html.Replace("const KEY='mde-assessment-v1'", "const KEY='mde-assessment-$([guid]::NewGuid().ToString('N').Substring(0,8))'")

Set-Content -Path $OutFile -Value $html -Encoding utf8

Write-Host ''
Write-Host "  Rapor yazıldı: $OutFile" -ForegroundColor Green
Write-Host "  Dolduruldu: $($filled.charts) grafik, $($filled.kpi) KPI, $($filled.rows + $script:cfgFilled) tablo satırı, $($filled.fields) alan" -ForegroundColor DarkGray
Write-Host "  Taslak metin: $($script:draftCount + $script:bpCount) adet (REVIEW) isaretli — tarayicida tek tek onaylayin." -ForegroundColor DarkGray
Write-Host ''
try { Start-Process (Resolve-Path $OutFile) } catch { }
