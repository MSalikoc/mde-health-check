param([Parameter(Mandatory)][string]$Report)
$h = Get-Content $Report -Raw
$tests = [ordered]@{
    'Olgunluk tablosu (Bolum 18)      ' = '(?s)Key action to close the gap.*?<span class="draft">\d</span>'
    'Kapak: Overall Maturity          ' = '(?s)<span class="draft">\d / 5</span>'
    'Kapak: Control Compliance        ' = 'assessed controls compliant'
    'Misconfiguration tablosu         ' = '(?s)Misconfiguration Findings.*?<td class="f"[^>]*>[A-Z]'
    'Host Firewall satiri             ' = '(?s)Defender Firewall enabled[^<]*</td>(?:(?!</tr>).)*?draft'
    'Indicator satirlari (Bolum 13)   ' = 'indicators carry no expiry'
    'Bulgu kaydi: Due tarihleri       ' = '(?s)<td>F-01</td>(?:(?!</tr>).)*?(Immediate|\d\d\.\d\d\.\d{4})'
    'Custom detection ozeti           ' = 'custom detection rules are defined'
    'Secure score impact  [TOPLAYICI] ' = '(?s)Top Recommended Actions.*?data-ph="\+––">\+\d'
    'Exclusion risk dokumu [TOPLAYICI]' = 'high-risk antivirus exclusions - \d'
    'Satir ekle/sil araclari          ' = 'initRowTools'
}
foreach ($t in $tests.Keys) {
    $ok = [regex]::IsMatch($h, $tests[$t])
    Write-Host ("  {0} {1}" -f $t, $(if ($ok) { 'VAR' } else { 'yok' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'DarkYellow' })
}
