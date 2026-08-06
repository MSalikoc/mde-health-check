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
$platforms = @($d.tables.deviceInventory | ForEach-Object { $_.platform }) -join ', '
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
