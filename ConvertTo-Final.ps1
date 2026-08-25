<#
.SYNOPSIS
    Bitmis bir raporu musteriye verilecek salt-okunur kopyaya cevirir.

.DESCRIPTION
    Sablonun "Save final" dugmesi ayni isi tarayicida yapar, ama daha once uretilmis
    bir raporda o dugme yoktur. Bu script yeniden render etmeden ayni sonucu verir -
    elle yaptiginiz duzenlemeler yerinde kalir.

    GIRDI, tarayicidaki "Save as HTML" ile kaydettiginiz dosya olmalidir. Renderer'in
    yazdigi ham dosyada grafikler henuz cizilmemistir (JS ciziyor); "Save as HTML"
    ciktisinda ise SVG olarak gomuludur ve boylece script'siz de gorunurler.

    Yapilanlar:
      - toolbar, icindekiler paneli, satir/sayfa dugmeleri ve tum <script> bloklari atilir
      - contenteditable nitelikleri kaldirilir - hicbir alan duzenlenemez
      - <select> secicileri, secili degeri tasiyan duz rozetlere cevrilir
      - (REVIEW) isaretleri duzlestirilir: metin kalir, sari vurgu gider
      - baskida renklerin korunmasi icin print-color-adjust eklenir

.EXAMPLE
    .\ConvertTo-Final.ps1 -Path .\Contoso-MDE-Assessment-2026-08-19.html
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$OutFile,
    [switch]$KeepDraftMarks       # (REVIEW) vurgularini oldugu gibi birak
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not (Test-Path $Path)) { throw "Dosya bulunamadi: $Path" }
if (-not $OutFile) {
    $OutFile = [IO.Path]::Combine(
        [IO.Path]::GetDirectoryName((Resolve-Path $Path)),
        [IO.Path]::GetFileNameWithoutExtension($Path) + '-FINAL.html')
}

$h = Get-Content $Path -Raw -Encoding utf8
$before = $h.Length

# Girdi kontrolu: grafikler cizilmis mi
$svg = ([regex]::Matches($h, '<svg')).Count
if ($svg -lt 5) {
    Write-Host ''
    Write-Host '  ! Bu dosyada cizilmis grafik yok gibi gorunuyor.' -ForegroundColor Yellow
    Write-Host '    Renderer ciktisini dogrudan verdiyseniz grafikler bos cikar - once raporu' -ForegroundColor DarkYellow
    Write-Host '    tarayicida acip "Save as HTML" ile kaydedin, sonra o dosyayi verin.' -ForegroundColor DarkYellow
    Write-Host ''
}

# --- 1) toolbar / icindekiler / dugmeler / scriptler
$h = [regex]::Replace($h, '(?s)<div id="bar".*?</div>\s*(?=<nav id="toc")', '')
$h = [regex]::Replace($h, '(?s)<nav id="toc".*?</nav>', '')
$h = [regex]::Replace($h, '(?s)<button[^>]*class="[^"]*(?:rowctl|pagedel)[^"]*"[^>]*>.*?</button>', '')
$h = [regex]::Replace($h, '(?s)<script\b.*?</script>', '')

# --- 2) duzenlenebilirligi kaldir
$editable = ([regex]::Matches($h, '\scontenteditable(?:="[^"]*")?')).Count
$h = [regex]::Replace($h, '\scontenteditable(?:="[^"]*")?', '')

# --- 3) secicileri duz rozete cevir
$script:selCount = 0
$h = [regex]::Replace($h, '(?s)<select([^>]*)>(.*?)</select>', {
    param($m)
    $attrs = $m.Groups[1].Value
    $inner = $m.Groups[2].Value
    $cls = if ($attrs -match 'class="([^"]*)"') { $matches[1] } else { '' }
    $kind = if ($cls -match '\bsev\b') { 'sev' } else { 'st' }
    # secili secenek: once selected niteligi, yoksa data-v, yoksa ilki
    $text = ''; $val = ''
    $sel = [regex]::Match($inner, '<option value="([^"]*)"[^>]*\bselected\b[^>]*>([^<]*)</option>')
    if ($sel.Success) { $val = $sel.Groups[1].Value; $text = $sel.Groups[2].Value }
    elseif ($attrs -match 'data-v="([^"]+)"') {
        $val = $matches[1]
        $byVal = [regex]::Match($inner, '<option value="' + [regex]::Escape($val) + '"[^>]*>([^<]*)</option>')
        if ($byVal.Success) { $text = $byVal.Groups[1].Value }
    }
    if (-not $text) {
        $first = [regex]::Match($inner, '<option[^>]*>([^<]*)</option>')
        if ($first.Success) { $text = $first.Groups[1].Value }
    }
    $script:selCount++
    "<span class=`"$kind`" data-v=`"$val`">$text</span>"
})

# --- 4) (REVIEW) isaretlerini duzlestir
$drafts = 0
if (-not $KeepDraftMarks) {
    $drafts = ([regex]::Matches($h, '<span class="draft">')).Count
    $h = [regex]::Replace($h, '(?s)<span class="draft">(.*?)</span>', '$1')
}

# --- 5) eski sablonlarda eksik olan CSS: rozet rengi ve baski rengi
if ($h -notmatch 'print-color-adjust') {
    $h = [regex]::Replace($h, '@media print\s*\{', "@media print{`n  *{-webkit-print-color-adjust:exact !important;print-color-adjust:exact !important}", 1)
}
# Renk kurallari eski sablonda 'select.st[data-v=...]' seklinde; span'lar icin genellestir
$h = [regex]::Replace($h, 'select\.(st|sev)\[data-v=', '.$1[data-v=')
if ($h -notmatch 'span\.st,span\.sev') {
    $h = [regex]::Replace($h, '(</style>)',
        "span.st,span.sev{display:inline-block;padding:2px 7px;border:1px solid #D7DDE7;border-radius:4px;font-size:8pt;font-weight:600;text-align:center}`n`$1", 1)
}

# --- 6) body sinifi (duzenleme modlari)
$h = [regex]::Replace($h, '<body class="[^"]*"', '<body')

$h | Set-Content -Path $OutFile -Encoding utf8

Write-Host ''
Write-Host "  Salt-okunur kopya: $OutFile" -ForegroundColor Green
Write-Host "  duzenlenebilir alan kaldirildi : $editable" -ForegroundColor Gray
Write-Host "  secici -> rozet                : $script:selCount" -ForegroundColor Gray
Write-Host "  duzlestirilen (REVIEW)         : $drafts" -ForegroundColor Gray
Write-Host "  grafik (SVG)                   : $svg" -ForegroundColor Gray
Write-Host "  boyut                          : $([math]::Round($before/1KB)) KB -> $([math]::Round($h.Length/1KB)) KB" -ForegroundColor Gray
Write-Host ''
