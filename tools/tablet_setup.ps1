$ErrorActionPreference = 'Continue'
$url = 'https://nlavidas.github.io/agones-tablet/'
$out = Join-Path $HOME 'agones-tablet-test'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$adb = $null
foreach ($c in @((Join-Path $HOME 'platform-tools/adb'), '/opt/homebrew/bin/adb', '/usr/local/bin/adb')) {
    if (Test-Path $c) { $adb = $c; break }
}
if (-not $adb) { $cmd = Get-Command adb -ErrorAction SilentlyContinue; if ($cmd) { $adb = $cmd.Source } }
if (-not $adb) {
    Write-Host 'Δεν βρέθηκε το adb. Κατεβάζω τα Android platform-tools...'
    $zip = Join-Path $HOME 'platform-tools-mac.zip'
    Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-darwin.zip' -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $HOME -Force
    $adb = Join-Path $HOME 'platform-tools/adb'
    & chmod +x $adb
}

& $adb start-server | Out-Null
Start-Sleep -Seconds 2
$lines = & $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\S' }
$unauth = $lines | Where-Object { $_ -match 'unauthorized' }
$devs = $lines | Where-Object { $_ -match '\tdevice$' } | ForEach-Object { ($_ -split "`t")[0] }

if ($unauth) {
    Write-Host ''
    Write-Host 'Στο tablet εμφανίστηκε ερώτηση «Να επιτρέπεται ο εντοπισμός σφαλμάτων USB;».'
    Write-Host 'Τσέκαρε «Να επιτρέπεται πάντα από αυτόν τον υπολογιστή», πάτα OK, και ξανατρέξε την ίδια γραμμή.'
    return
}
if (-not $devs) {
    Write-Host ''
    Write-Host 'Δεν βλέπω tablet. Έλεγξε: καλώδιο USB που περνά δεδομένα, και «Εντοπισμός σφαλμάτων USB» ενεργό στο tablet.'
    return
}

foreach ($d in $devs) {
    $sh = { param($cmd) (& $adb -s $d shell $cmd 2>$null | Out-String).Trim() }
    $model = & $sh 'getprop ro.product.model'
    $maker = & $sh 'getprop ro.product.manufacturer'
    $rel = & $sh 'getprop ro.build.version.release'
    $sdk = & $sh 'getprop ro.build.version.sdk'
    $size = & $sh 'wm size'
    $dens = & $sh 'wm density'
    $chrome = & $sh 'dumpsys package com.android.chrome | grep versionName'
    $browser = & $sh 'pm list packages | grep -i -E "browser|chrome|firefox"'

    & $adb -s $d shell settings put global stay_on_while_plugged_in 3 | Out-Null
    & $adb -s $d shell settings put system screen_off_timeout 1800000 | Out-Null
    & $adb -s $d shell settings put secure long_press_timeout 1500 | Out-Null

    $stay = & $sh 'settings get global stay_on_while_plugged_in'
    $tout = & $sh 'settings get system screen_off_timeout'
    $lp = & $sh 'settings get secure long_press_timeout'

    & $adb -s $d shell input keyevent 224 | Out-Null
    & $adb -s $d shell am start -a android.intent.action.VIEW -d $url | Out-Null
    Write-Host "Άνοιξα τη σελίδα στο $maker $model. Περιμένω 25 δευτερόλεπτα να φορτώσει..."
    Start-Sleep -Seconds 25
    & $adb -s $d shell screencap -p /sdcard/agones-test.png | Out-Null
    $safe = ($maker + '-' + $model) -replace '[^A-Za-z0-9\-]', '_'
    $png = Join-Path $out ($safe + '.png')
    & $adb -s $d pull /sdcard/agones-test.png $png | Out-Null

    $report = @(
        "Tablet: $maker $model",
        "Android: $rel (SDK $sdk)",
        "Οθόνη: $size / $dens",
        "Chrome: $chrome",
        "Browsers: $($browser -replace "`r?`n", ', ')",
        "Οθόνη αναμμένη στη φόρτιση: $stay (3 = ναι)",
        "Σβήσιμο οθόνης μετά από: $tout ms",
        "Καθυστέρηση αγγίγματος και κρατήματος: $lp ms",
        "Στιγμιότυπο: $png"
    )
    $report | Set-Content -Path (Join-Path $out ($safe + '.txt')) -Encoding utf8
    Write-Host ''
    $report | ForEach-Object { Write-Host $_ }
}
Write-Host ''
Write-Host "Τέλος. Στείλε μου στο chat το στιγμιότυπο από τον φάκελο $out"
& open $out
