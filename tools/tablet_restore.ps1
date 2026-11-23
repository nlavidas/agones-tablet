$ErrorActionPreference = 'Continue'
$out = Join-Path $HOME 'agones-tablet-test'
$adb = $null
foreach ($c in @((Join-Path $HOME 'platform-tools/adb'), '/opt/homebrew/bin/adb', '/usr/local/bin/adb')) {
    if (Test-Path $c) { $adb = $c; break }
}
if (-not $adb) { Write-Host 'Δεν βρέθηκε το adb.'; return }
$devs = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' } | ForEach-Object { ($_ -split "`t")[0] })
foreach ($d in $devs) {
    $model = (& $adb -s $d shell getprop ro.product.model | Out-String).Trim()
    $maker = (& $adb -s $d shell getprop ro.product.manufacturer | Out-String).Trim()
    $safe = ($maker + '-' + $model) -replace '[^A-Za-z0-9\-]', '_'
    $file = Join-Path $out ($safe + '-changes.json')
    if (-not (Test-Path $file)) { Write-Host "Δεν υπάρχουν αλλαγές για το $maker $model."; continue }
    $ch = Get-Content $file -Raw | ConvertFrom-Json
    foreach ($p in $ch.disabled) { & $adb -s $d shell pm enable $p | Out-Null }
    $muted = @($ch.muted)
    for ($i = 0; $i -lt $muted.Count; $i += 15) {
        $chunk = $muted[$i..([Math]::Min($i + 14, $muted.Count - 1))]
        & $adb -s $d shell (($chunk | ForEach-Object { "appops set $_ POST_NOTIFICATION allow" }) -join '; ') | Out-Null
    }
    & $adb -s $d shell settings put global zen_mode 0 | Out-Null
    & $adb -s $d shell settings put global heads_up_notifications_enabled 1 | Out-Null
    & $adb -s $d shell settings put secure lockscreen.disabled 0 | Out-Null
    Write-Host "Το $maker $model επανήλθε όπως ήταν."
}
