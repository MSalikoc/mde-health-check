<#
.SYNOPSIS
    Musterinin dolduracagi tek dosyalik anket formunu uretir.

.DESCRIPTION
    Sorular survey-questions.psd1 icinde ELLE yazilir. Satir etiketini soru diye
    sormak ("Data storage region") musteriye ne sordugumuzu anlatmaz; her sorunun
    tam cumle bir metni, ne kastettigimizi acan bir notu ve kapali bir cevap
    kumesi vardir.

    Uretici her sorunun hedef satirini SABLONA KARSI DOGRULAR. Sablonda olmayan
    bir hedef ya da sorusu olmayan bir bosluk sessizce gecmez - ikisi de raporlanir.
    Boylece soru bankasi ile sablon ayrisamaz.

    Cikan form tek bir HTML dosyasidir: musteride hicbir sey kurulu olmasi
    gerekmez, cevrimdisi calisir, "Download answers" ile JSON uretir.
    MDE-Render.ps1 o JSON'u -SurveyFile ile alir.

.EXAMPLE
    .\New-Survey.ps1 -ClientName "Contoso A.S."
#>
[CmdletBinding()]
param(
    [string]$Template,
    [string]$Questions,
    [string]$ClientName,
    [string]$OutFile = './mde-survey-form.html',
    [switch]$ShowUnasked          # sorusu olmayan sablon bosluklarini da listele
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Resolve-Beside {
    param([string]$Name)
    @((Join-Path $PSScriptRoot $Name), (Join-Path (Split-Path $PSScriptRoot -Parent) $Name)) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Template)  { $Template  = Resolve-Beside 'MDE-Health-Assessment-Template.html' }
if (-not $Questions) { $Questions = Resolve-Beside 'survey-questions.psd1' }
if (-not $Template -or -not (Test-Path $Template))   { throw 'Sablon bulunamadi. -Template ile verin.' }
if (-not $Questions -or -not (Test-Path $Questions)) { throw 'Soru bankasi bulunamadi. -Questions ile verin.' }

function Strip {
    param([string]$s)
    ([System.Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', ''))).Trim()
}
function Norm {
    # Eslesme icin sadeleştirme: buyuk/kucuk, & ve noktalama, fazladan bosluk onemsiz.
    # MDE-Render.ps1 icindeki ayni isimli fonksiyonla BIREBIR AYNI kalmali.
    param([string]$s)
    $t = (Strip $s) -replace '&', ' and '
    $t = $t -replace '[^\w\s]', ' ' -replace '\s+', ' '
    return $t.Trim().ToLower()
}
function Esc { param([string]$s) $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' }

$html = Get-Content $Template -Raw -Encoding utf8
$bank = Import-PowerShellDataFile -Path $Questions
$qs = @($bank.Questions)
if ($qs.Count -eq 0) { throw 'Soru bankasi bos.' }

# --------------------------------------------------- SABLON HARITASI ------
# section -> table -> satir etiketleri (yalnizca bos hucresi olanlar)
$map = @{}
foreach ($mSec in [regex]::Matches($html, '(?s)<section class="page[^"]*"[^>]*data-toc="([^"]*)".*?(?=<section class="page|\Z)')) {
    $secKey = Norm $mSec.Groups[1].Value
    if (-not $map.ContainsKey($secKey)) { $map[$secKey] = @{} }
    foreach ($blk in [regex]::Split($mSec.Value, '(?=<h3)')) {
        $mh = [regex]::Match($blk, '(?s)<h3[^>]*>(.*?)</h3>')
        if (-not $mh.Success) { continue }
        $tblKey = Norm $mh.Groups[1].Value
        if (-not $map[$secKey].ContainsKey($tblKey)) { $map[$secKey][$tblKey] = @{} }
        foreach ($mr in [regex]::Matches($blk, '(?s)<tr>((?:(?!</tr>).)*)</tr>')) {
            $cells = [regex]::Matches($mr.Groups[1].Value, '(?s)<td[^>]*>(.*?)</td>')
            if ($cells.Count -lt 2) { continue }
            $label = Strip $cells[0].Groups[1].Value
            if (-not $label) { continue }
            $blank = $false
            for ($i = 1; $i -lt $cells.Count; $i++) { if ((Strip $cells[$i].Groups[1].Value) -eq '') { $blank = $true; break } }
            if ($blank) { $map[$secKey][$tblKey][(Norm $label)] = $label }
        }
    }
}

# --------------------------------------------------- DOGRULAMA -----------
$bad = [System.Collections.Generic.List[string]]::new()
$asked = @{}
foreach ($q in $qs) {
    $s = Norm $q.target.section; $t = Norm $q.target.table; $r = Norm $q.target.row
    if (-not $map.ContainsKey($s))            { $bad.Add("$($q.id): bolum yok - '$($q.target.section)'"); continue }
    if (-not $map[$s].ContainsKey($t))        { $bad.Add("$($q.id): tablo yok - '$($q.target.table)'"); continue }
    if (-not $map[$s][$t].ContainsKey($r))    { $bad.Add("$($q.id): satir yok veya zaten dolu - '$($q.target.row)'"); continue }
    $asked["$s::$t::$r"] = $true
}
if ($bad.Count) {
    Write-Host ''
    Write-Host '  ! Soru bankasi sablonla ortusmuyor:' -ForegroundColor Yellow
    $bad | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
}

$unasked = [System.Collections.Generic.List[string]]::new()
foreach ($s in $map.Keys) { foreach ($t in $map[$s].Keys) { foreach ($r in $map[$s][$t].Keys) {
    if (-not $asked.ContainsKey("$s::$t::$r")) { $unasked.Add("$($map[$s][$t][$r])") }
} } }

# --------------------------------------------------- FORM ----------------
# Gruplar raporun sirasini izlesin - Group-Object alfabetik siralar ve "Tenant &
# Portal Configuration" anketin dibine duserdi. Sablondaki konumuna gore siralıyoruz.
$order = @{}
foreach ($q in $qs) {
    $key = "$(Norm $q.target.section)::$(Norm $q.target.table)"
    if ($order.ContainsKey($key)) { continue }
    $rx = [regex]("(?s)data-toc=`"[^`"]*`"(?:(?!<section class=`"page).)*?<h3[^>]*>(?:(?!</h3>).)*?" +
                  [regex]::Escape(($q.target.table -replace '&', '&amp;')))
    $m = $rx.Match($html)
    $order[$key] = if ($m.Success) { $m.Index } else { [int]::MaxValue }
}
$groups = $qs | Where-Object { $asked.ContainsKey("$(Norm $_.target.section)::$(Norm $_.target.table)::$(Norm $_.target.row)") } |
          Group-Object { $_.target.table } |
          Sort-Object { $order["$(Norm ($_.Group[0].target.section))::$(Norm ($_.Group[0].target.table))"] }

$sb = [System.Text.StringBuilder]::new()
foreach ($g in $groups) {
    $sec = ($g.Group | Select-Object -First 1).target.section
    [void]$sb.AppendLine("<section class=`"grp`"><h2>$(Esc $g.Name)</h2><p class=`"sec`">$(Esc $sec)</p>")
    foreach ($q in $g.Group) {
        [void]$sb.AppendLine("<div class=`"q`" data-id=`"$(Esc $q.id)`">")
        [void]$sb.AppendLine("  <p class=`"qt`">$(Esc $q.text)</p>")
        if ($q.info) { [void]$sb.AppendLine("  <p class=`"qi`">$(Esc $q.info)</p>") }
        if ($q.type -eq 'text') {
            [void]$sb.AppendLine("  <input type=`"text`" data-q=`"$(Esc $q.id)`" placeholder=`"leave blank if you are not sure`">")
        }
        else {
            foreach ($a in @($q.answers)) {
                [void]$sb.AppendLine(
                    "  <label class=`"opt`"><input type=`"radio`" name=`"$(Esc $q.id)`" data-q=`"$(Esc $q.id)`"" +
                    " value=`"$(Esc $a.value)`" data-text=`"$(Esc $a.text)`"> $(Esc $a.text)</label>")
            }
        }
        [void]$sb.AppendLine('</div>')
    }
    [void]$sb.AppendLine('</section>')
}

$total = @($qs | Where-Object { $asked.ContainsKey("$(Norm $_.target.section)::$(Norm $_.target.table)::$(Norm $_.target.row)") }).Count
$client = if ($ClientName) { $ClientName } else { '' }

$doc = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Defender for Endpoint — Health Check Questionnaire</title>
<style>
 :root{--navy:#0A1F44;--blue:#2C5BE3;--line:#D7DDE7;--mut:#5A6B85}
 *{box-sizing:border-box}
 body{margin:0;padding:0 0 70px;font:15px/1.6 "Segoe UI",system-ui,sans-serif;color:#16233B;background:#F4F6FA}
 header{background:var(--navy);color:#fff;padding:24px 26px}
 header h1{margin:0 0 5px;font-size:21px}
 header p{margin:0;opacity:.85;font-size:13.5px;max-width:70ch}
 main{max-width:880px;margin:0 auto;padding:0 18px}
 .intro{background:#fff;border:1px solid var(--line);border-radius:8px;padding:16px 18px;margin:20px 0}
 .intro b{color:var(--navy)}
 .meta{display:flex;gap:14px;flex-wrap:wrap;margin-top:12px}
 .meta label{font-size:12px;color:var(--mut);display:block;margin-bottom:3px}
 .meta input{padding:7px 9px;border:1px solid var(--line);border-radius:5px;font:inherit;min-width:230px}
 .grp{background:#fff;border:1px solid var(--line);border-radius:8px;padding:16px 20px;margin:16px 0}
 .grp h2{margin:0;font-size:16.5px;color:var(--navy)}
 .sec{margin:2px 0 4px;font-size:12px;color:var(--mut)}
 .q{padding:14px 0;border-top:1px solid #EEF1F6}
 .q:first-of-type{border-top:0}
 .qt{margin:0 0 3px;font-weight:600}
 .qi{margin:0 0 9px;font-size:13px;color:var(--mut);max-width:74ch}
 .opt{display:block;padding:5px 8px;border-radius:5px;cursor:pointer}
 .opt:hover{background:#F2F5FB}
 .opt input{margin-right:8px}
 .q input[type=text]{width:100%;max-width:460px;padding:7px 9px;border:1px solid var(--line);border-radius:5px;font:inherit}
 .q.done .qt::after{content:' ✓';color:#1E7A45}
 #bar{position:sticky;bottom:0;background:var(--navy);color:#fff;padding:12px 18px;display:flex;
      align-items:center;gap:14px;flex-wrap:wrap}
 #bar button{background:var(--blue);color:#fff;border:0;border-radius:6px;padding:10px 18px;font:inherit;cursor:pointer}
 #bar button:hover{background:#1E48C8}
 #count{font-size:13.5px;opacity:.9}
</style></head><body>
<header>
  <h1>Microsoft Defender for Endpoint — Health Check Questionnaire</h1>
  <p>$total questions about settings and practices that no API exposes. Everything that could be read
     from your tenant automatically has already been collected; none of it is asked again here.</p>
</header>
<main>
  <div class="intro">
    <b>How to use this.</b> Answer what you know and leave the rest blank &mdash; &ldquo;not sure&rdquo; is a
    real answer and far more useful than a guess, because every answer is checked against the collected
    data before it reaches the report. Nothing is transmitted anywhere: this file works offline and the
    button at the bottom saves your answers to your own machine. Send that file back with the collected JSON.
    <div class="meta">
      <div><label for="cl">Organisation</label><input id="cl" type="text" value="$(Esc $client)"></div>
      <div><label for="tn">Tenant domain</label><input id="tn" type="text" placeholder="contoso.onmicrosoft.com"></div>
      <div><label for="wh">Completed by</label><input id="wh" type="text" placeholder="name / role"></div>
    </div>
  </div>
$($sb.ToString())
</main>
<div id="bar">
  <button type="button" onclick="saveAnswers()">Download answers</button>
  <span id="count"></span>
</div>
<script>
function collect(){
  const out={};
  document.querySelectorAll('.q').forEach(q=>{
    const id=q.dataset.id;
    const r=q.querySelector('input[type=radio]:checked');
    const t=q.querySelector('input[type=text]');
    if(r)      out[id]={observed:r.dataset.text,status:r.value};
    else if(t&&t.value.trim()) out[id]={observed:t.value.trim(),status:''};
    q.classList.toggle('done',!!out[id]);
  });
  return out;
}
function tally(){
  const n=Object.keys(collect()).length, t=document.querySelectorAll('.q').length;
  document.getElementById('count').textContent=n+' of '+t+' answered';
}
document.addEventListener('input',tally);
document.addEventListener('change',tally);
function saveAnswers(){
  const answers=collect();
  const payload={
    schema:'mde-survey/1',
    client:document.getElementById('cl').value.trim(),
    tenant:document.getElementById('tn').value.trim(),
    completedBy:document.getElementById('wh').value.trim(),
    completedUtc:new Date().toISOString(),
    answered:Object.keys(answers).length,
    answers:answers
  };
  const blob=new Blob([JSON.stringify(payload,null,2)],{type:'application/json'});
  const a=document.createElement('a');
  a.href=URL.createObjectURL(blob);
  const slug=(payload.tenant||payload.client||'tenant').replace(/[^\w.-]+/g,'-').toLowerCase();
  a.download='mde-survey-'+slug+'-'+new Date().toISOString().slice(0,10)+'.json';
  a.click();URL.revokeObjectURL(a.href);
}
tally();
</script>
</body></html>
"@

$doc | Set-Content -Path $OutFile -Encoding utf8
Write-Host ''
Write-Host "  Anket formu yazildi: $OutFile" -ForegroundColor Green
Write-Host "  $total soru, $($groups.Count) grup" -ForegroundColor Gray
if ($unasked.Count) {
    Write-Host "  Sablonda sorusu olmayan $($unasked.Count) bosluk var - bunlar elle doldurulmaya devam eder." -ForegroundColor DarkGray
    if ($ShowUnasked) { $unasked | Sort-Object | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray } }
    else { Write-Host '  Listelemek icin -ShowUnasked ekleyin.' -ForegroundColor DarkGray }
}
Write-Host ''
