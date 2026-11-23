$ErrorActionPreference = 'Continue'
$board = 'https://nlavidas.github.io/agones-tablet/'
$out = Join-Path $HOME 'agones-tablet-test'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$adb = $null
foreach ($c in @((Join-Path $HOME 'platform-tools/adb'), '/opt/homebrew/bin/adb', '/usr/local/bin/adb')) {
    if (Test-Path $c) { $adb = $c; break }
}
if (-not $adb) { $cmd = Get-Command adb -ErrorAction SilentlyContinue; if ($cmd) { $adb = $cmd.Source } }
if (-not $adb) {
    Write-Host 'Κατεβάζω τα Android platform-tools...'
    $zip = Join-Path $HOME 'platform-tools-mac.zip'
    Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-darwin.zip' -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $HOME -Force
    $adb = Join-Path $HOME 'platform-tools/adb'
    & chmod +x $adb
}

& $adb start-server | Out-Null
Start-Sleep -Seconds 2
$lines = & $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\S' }
if ($lines | Where-Object { $_ -match 'unauthorized' }) {
    Write-Host ''
    Write-Host 'Στο tablet εμφανίστηκε ερώτηση για τον εντοπισμό σφαλμάτων USB.'
    Write-Host 'Τσέκαρε «πάντα από αυτόν τον υπολογιστή», πάτα OK και ξανατρέξε την ίδια γραμμή.'
    return
}
$devs = @($lines | Where-Object { $_ -match '\tdevice$' } | ForEach-Object { ($_ -split "`t")[0] })
if (-not $devs) {
    Write-Host ''
    Write-Host 'Δεν βλέπω tablet. Έλεγξε το καλώδιο USB και τον «Εντοπισμό σφαλμάτων USB» στο tablet.'
    return
}

$keep = @('android', 'com.android.systemui', 'com.android.settings', 'com.android.chrome', 'com.android.browser',
          'org.mozilla.firefox', 'com.android.packageinstaller', 'com.android.shell')
$noisy = @('com.google.android.gm', 'com.google.android.youtube', 'com.google.android.apps.photos',
           'com.google.android.music', 'com.google.android.videos', 'com.google.android.apps.magazines',
           'com.google.android.apps.books', 'com.google.android.talk', 'com.google.android.apps.plus',
           'com.google.android.calendar', 'com.android.calendar', 'com.android.email', 'com.google.android.apps.docs',
           'com.google.android.keep', 'com.android.vending', 'com.android.cellbroadcastreceiver')

foreach ($d in $devs) {
    $sh = { param($cmd) (& $adb -s $d shell $cmd 2>$null | Out-String).Trim() }
    $model = & $sh 'getprop ro.product.model'
    $maker = & $sh 'getprop ro.product.manufacturer'
    $rel = & $sh 'getprop ro.build.version.release'
    $sim = & $sh 'getprop gsm.sim.state'
    $safe = ($maker + '-' + $model) -replace '[^A-Za-z0-9\-]', '_'
    Write-Host ''
    Write-Host "==== $maker $model, Android $rel" -ForegroundColor Cyan
    $url = Read-Host "Διεύθυνση για αυτό το tablet (π.χ. http://192.168.1.20:8080/ για το τηλεκοντρόλ). Enter για τον πίνακα αγώνων"
    if (-not $url) { $url = $board }

    $all = @((& $adb -s $d shell pm list packages) | ForEach-Object { ($_ -replace '^package:', '').Trim() } | Where-Object { $_ })
    $third = @((& $adb -s $d shell pm list packages -3) | ForEach-Object { ($_ -replace '^package:', '').Trim() } | Where-Object { $_ })
    $ime = (& $sh 'settings get secure default_input_method') -replace '/.*$', ''
    $protect = @($keep + @($ime) | Where-Object { $_ })

    $toDisable = @($all | Where-Object { ($noisy -contains $_) -or ($_ -match 'weather') -or (($third -contains $_) -and ($protect -notcontains $_) -and ($_ -notmatch 'keyboard|inputmethod|launcher|chrome|firefox|browser')) })
    Write-Host ''
    Write-Host 'Προτείνω να απενεργοποιηθούν αυτές οι εφαρμογές (στέλνουν μηνύματα):'
    for ($i = 0; $i -lt $toDisable.Count; $i++) { Write-Host ("  {0,2}. {1}" -f ($i + 1), $toDisable[$i]) }
    $ans = Read-Host 'Γράψε τους αριθμούς όσων θέλεις να ΜΕΙΝΟΥΝ (π.χ. 2 5). Enter = να απενεργοποιηθούν όλες. 0 = καμία'
    if ($ans -match '^\s*0\s*$') { $toDisable = @() }
    elseif ($ans) {
        $stay = @($ans -split '[^0-9]+' | Where-Object { $_ } | ForEach-Object { $toDisable[[int]$_ - 1] })
        $protect += $stay
        $toDisable = @($toDisable | Where-Object { $stay -notcontains $_ })
    }
    $ansN = Read-Host 'Να σβήσουν οι ειδοποιήσεις όλων των άλλων εφαρμογών εκτός του browser; Ν = ναι, Ο = όχι (Enter = ναι)'
    $muted = @()
    if ($ansN -notmatch '^[OoΟο]') { $muted = @($all | Where-Object { $protect -notcontains $_ }) }
    if ($muted.Count) { Write-Host 'Σβήνω τις ειδοποιήσεις...' }
    for ($i = 0; $i -lt $muted.Count; $i += 15) {
        $chunk = $muted[$i..([Math]::Min($i + 14, $muted.Count - 1))]
        $cmd = ($chunk | ForEach-Object { "appops set $_ POST_NOTIFICATION ignore" }) -join '; '
        & $adb -s $d shell $cmd 2>$null | Out-Null
    }

    $disabled = @()
    foreach ($p in $toDisable) {
        $r = (& $adb -s $d shell pm disable-user --user 0 $p 2>&1 | Out-String)
        if ($r -match 'disabled') { $disabled += $p }
    }

    & $adb -s $d shell settings put global stay_on_while_plugged_in 3 | Out-Null
    & $adb -s $d shell settings put system screen_off_timeout 1800000 | Out-Null
    & $adb -s $d shell settings put secure long_press_timeout 1500 | Out-Null
    & $adb -s $d shell settings put global heads_up_notifications_enabled 0 | Out-Null
    & $adb -s $d shell settings put global zen_mode 2 | Out-Null
    & $adb -s $d shell settings put secure lockscreen.disabled 1 | Out-Null

    @{ device = "$maker $model"; muted = $muted; disabled = $disabled } | ConvertTo-Json -Depth 3 |
        Set-Content -Path (Join-Path $out ($safe + '-changes.json')) -Encoding utf8

    & $adb -s $d shell input keyevent 224 | Out-Null
    & $adb -s $d shell input keyevent 82 | Out-Null
    & $adb -s $d shell am start -a android.intent.action.VIEW -d $url | Out-Null
    Write-Host 'Άνοιξα τη σελίδα. Περιμένω 25 δευτερόλεπτα να φορτώσει...'
    Start-Sleep -Seconds 25
    & $adb -s $d shell screencap -p /sdcard/agones-test.png | Out-Null
    $png = Join-Path $out ($safe + '.png')
    & $adb -s $d pull /sdcard/agones-test.png $png | Out-Null

    $report = @(
        "Tablet: $maker $model, Android $rel",
        "SIM: $(if ($sim) { $sim } else { 'καμία' })",
        "Σελίδα: $url",
        "Ειδοποιήσεις σβηστές σε $($muted.Count) εφαρμογές",
        "Απενεργοποιημένες εφαρμογές ($($disabled.Count)): $($disabled -join ', ')",
        "Οθόνη αναμμένη στη φόρτιση: $(& $sh 'settings get global stay_on_while_plugged_in') (3 = ναι)",
        "Μην ενοχλείτε: $(& $sh 'settings get global zen_mode') (2 = καμία διακοπή)",
        "Αναδυόμενες ειδοποιήσεις: $(& $sh 'settings get global heads_up_notifications_enabled') (0 = κλειστές)",
        "Καθυστέρηση αγγίγματος με κράτημα: $(& $sh 'settings get secure long_press_timeout') ms",
        "Στιγμιότυπο: $png"
    )
    $report | Set-Content -Path (Join-Path $out ($safe + '.txt')) -Encoding utf8
    Write-Host ''
    $report | ForEach-Object { Write-Host $_ }
}
Write-Host ''
Write-Host "Τέλος. Ο φάκελος $out έχει το στιγμιότυπο και την αναφορά."
& open $out
