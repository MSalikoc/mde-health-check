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
if ($d.meta.secureScore -or $d.kpi.'Secure score for devices') {
    # Sablonda "/100" sabit -> buraya yuzde yazilmali, ham puan degil
    $score = ($d.kpi.'Secure score for devices') -replace '%', ''
    if (-not $score) {
        $parts = $d.meta.secureScore -split '/'
        if ($parts.Count -eq 2) {
            $cur = [double]($parts[0].Trim()); $max = [double]($parts[1].Trim())
            if ($max -gt 0) { $score = [math]::Round(100 * $cur / $max) }
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

$fnd = @($d.tables.findings)
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
"$(if ($d.tables.customDetections -and @($d.tables.customDetections).Count -gt 0) { "$(@($d.tables.customDetections).Count) custom detection rules are in place." } else { 'No custom detection rules are defined, so the environment relies entirely on Microsoft-supplied detections.' }) Threat hunting output should feed back into custom detections; without a scheduled hunting cadence this loop rarely forms."

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

# ---------------------------------------------------- BOLUM 01 TABLOLARI --
# In Scope: cihaz envanterinden kategori bazinda topla
if ($d.tables.deviceInventory) {
    $inv = @($d.tables.deviceInventory)
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
<section class="page" data-toc="Toplama Notu (otomatik)" data-grp="Giriş">
  <div class="body">
    <div class="eyebrow">Collector output</div>
    <h2>Automated Collection Notes</h2>
    <div class="rule"></div>
    <p class="small mut">This page was added by MDE-Render.ps1. Delete it before issuing the report.</p>
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
Write-Host "  Taslak metin: $($script:draftCount + $script:bpCount) adet (REVIEW) isaretli — tarayicida tek tek onaylayin." -ForegroundColor DarkGray
Write-Host ''
