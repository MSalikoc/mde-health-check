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
    [Parameter(Mandatory)][string]$Template,
    [string]$OutFile,
    [string]$ClientName,          # boşsa JSON'daki tenant adı kullanılır
    [switch]$HideDataTables,      # grafik veri tablolarını gizli başlat

    # Kapak logosu: template = şablondaki logoyu koru, microsoft = Microsoft
    # dört-kare logosu, none = logoyu kaldır
    [ValidateSet('template', 'microsoft', 'none')][string]$Logo = 'template'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$d = Get-Content $DataFile -Raw -Encoding utf8 | ConvertFrom-Json
$html = Get-Content $Template -Raw -Encoding utf8
$filled = [ordered]@{ charts = 0; kpi = 0; rows = 0; fields = 0 }

if (-not $OutFile) {
    $name = if ($ClientName) { $ClientName } elseif ($d.meta.tenantName) { $d.meta.tenantName } else { 'MDE' }
    $safe = ($name -replace '[^\w\-]', '-') -replace '-+', '-'
    $OutFile = "./$safe-MDE-Assessment-$(Get-Date -Format yyyy-MM-dd).html"
}

function Esc([string]$s) { $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }

# ------------------------------------------------------------- GRAFİKLER --
# <div class="chart" data-type="..."> … <div class="ct">Başlık</div> … <table class="data"> … </table> … </div>
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
            $sw = @($d.tables.topVulnerableSoftware)
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
            $a = @($d.tables.secureScoreActions)
            if ($script:ssIdx -ge $a.Count) { $script:ssIdx++; return $rm.Value }
            $x = $a[$script:ssIdx]; $script:ssIdx++
            $script:filled.rows++
            @"
<tr><td class="f" contenteditable data-ph="––">$(Esc $x.action)</td><td class="num f" contenteditable data-ph="+––"></td><td class="f" contenteditable data-ph="––">$(Esc $x.state)</td><td class="f" contenteditable data-ph="––">$(Esc $x.category)</td><td class="f" contenteditable data-ph="––"></td></tr>
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
        [hashtable]$Map
    )
    $anchor = if ($Heading) { [regex]::Escape($Heading) } else { '' }
    # h3 basliginda class olabilir (<h3 class="mt0">...)
    $rx = if ($Heading) {
        [regex]("(?s)(<h3[^>]*>$anchor</h3>\s*<table class=`"t[^`"]*`">)(.*?)(</table>)")
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

            # duzenlenebilir hucreler (sirayla)
            if ($entry.v) {
                $script:cellIdx = 0
                $script:cellVals = @($entry.v)
                $row = [regex]::Replace($row, '<td([^>]*class="[^"]*\bf\b[^"]*"[^>]*data-ph="[^"]*")></td>', {
                    param($cm)
                    if ($script:cellIdx -ge $script:cellVals.Count) { return $cm.Value }
                    $val = $script:cellVals[$script:cellIdx]
                    $script:cellIdx++
                    if ("$val" -eq '') { return $cm.Value }
                    "<td$($cm.Groups[1].Value)>$val</td>"
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
        $map["^$([regex]::Escape($f.id))$"] = @{
            v      = @($f.finding, $f.domain, $f.effort, $f.owner, $f.due)
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
    $all = @($d.tables.avExclusions)
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
    $rules = @($d.tables.customDetections)
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
if ($d.meta.secureScore) {
    $score = ($d.meta.secureScore -split '/')[0].Trim()
    $html = $html.Replace('<div class="bigscore"><span class="f" contenteditable data-ph="––"></span>',
                          "<div class=`"bigscore`"><span class=`"f`" contenteditable data-ph=`"––`">$score</span>")
    $filled.fields++
}

# -------------------------------------------------- TOPLAMA NOTU / ROZET --
$warn = ($d.meta.warnings | ForEach-Object { "<li>$(Esc $_)</li>" }) -join ''
$manual = ($d.manual | ForEach-Object { "<li>$(Esc $_)</li>" }) -join ''
$note = @"
<section class="page" data-toc="Toplama Notu (otomatik)" data-grp="Giriş">
  <div class="body">
    <div class="eyebrow">Collector output</div>
    <h2>Automated Collection Notes</h2>
    <div class="rule"></div>
    <p class="small mut">Bu sayfa MDE-Render.ps1 tarafından eklendi. Raporu teslim etmeden önce silin.</p>
    <table class="t compact">
      <tbody>
        <tr><td style="width:30%"><b>Toplama zamanı (UTC)</b></td><td>$(Esc $d.meta.generatedUtc)</td></tr>
        <tr><td><b>Tenant</b></td><td>$(Esc $d.meta.tenantName) · $(Esc $d.meta.verifiedDomain)</td></tr>
        <tr><td><b>Uyarı penceresi</b></td><td>$(Esc $d.meta.alertWindow)</td></tr>
        <tr><td><b>Olay penceresi</b></td><td>$(Esc $d.meta.eventWindow)</td></tr>
        <tr><td><b>Otomatik doldurulan</b></td><td>$($filled.charts) grafik · $($filled.kpi) KPI · $($filled.rows) tablo satırı · $($filled.fields) alan</td></tr>
      </tbody>
    </table>
    <h3>Toplama uyarıları</h3>
    <ul class="small">$warn</ul>
    <h3>Elle tamamlanacaklar</h3>
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
Write-Host "  Dolduruldu: $($filled.charts) grafik, $($filled.kpi) KPI, $($filled.rows) tablo satırı, $($filled.fields) alan" -ForegroundColor DarkGray
Write-Host '  Kalan alanlar yer tutuculu — tarayıcıda açıp elle tamamlayın.' -ForegroundColor DarkGray
Write-Host ''
