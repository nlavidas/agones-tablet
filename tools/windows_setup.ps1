$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$dir = Join-Path $HOME 'agones-tablet-main\remote'

function Step($t) { Write-Host ''; Write-Host "==== $t" -ForegroundColor Cyan }

Step 'Python'
$py = Get-Command py -ErrorAction SilentlyContinue
if (-not $py) {
    winget install -e --id Python.Python.3.12 --scope machine --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
& py -3 --version

Step 'Κατέβασμα προγράμματος'
$codes = Join-Path $dir 'codes.json'
$keep = $null
if (Test-Path $codes) { $keep = Get-Content $codes -Raw }
$zip = Join-Path $HOME 'agones-tablet.zip'
Invoke-WebRequest -Uri 'https://github.com/nlavidas/agones-tablet/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $HOME -Force
if ($keep) { Set-Content -Path $codes -Value $keep -Encoding UTF8 }
Set-Location $dir
& py -3 -m pip install --quiet --upgrade broadlink

Step 'Μάθηση πλήκτρων τηλεκοντρόλ'
if ($keep) {
    Write-Host 'Τα πλήκτρα είναι ήδη μαθημένα. Παραλείπεται.'
} else {
    & py -3 remote.py learn
}

Step 'Δοκιμή: ο αποκωδικοποιητής πρέπει να πάει στο 301'
& py -3 remote.py test 301

Step 'Τείχος προστασίας, αναμονή, αυτόματη εκκίνηση'
$pyw = (& py -3 -c "import sys,os;print(os.path.join(os.path.dirname(sys.executable),'pythonw.exe'))").Trim()
Get-NetFirewallRule -DisplayName 'Tilekontrol*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'Tilekontrol tablet 8080' -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'Tilekontrol program' -Direction Inbound -Program $pyw -Action Allow -Profile Any | Out-Null
powercfg /change standby-timeout-ac 0
Get-Process pythonw -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $pyw } | Stop-Process -Force
$act = New-ScheduledTaskAction -Execute $pyw -Argument 'remote.py serve' -WorkingDirectory $dir
$trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
Register-ScheduledTask -TaskName 'Tilekontrol' -Action $act -Trigger $trg -Settings $set -Force | Out-Null
Start-ScheduledTask -TaskName 'Tilekontrol'
Start-Sleep -Seconds 8

Step 'Έλεγχος'
$ok = $false
try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8080/api/state' -UseBasicParsing -TimeoutSec 10; $ok = $r.StatusCode -eq 200 } catch { $ok = $false }
if ($ok) { Write-Host 'Το τηλεκοντρόλ τρέχει κρυφά στο παρασκήνιο.' -ForegroundColor Green }
else { Write-Host 'Το τηλεκοντρόλ δεν απαντά ακόμα. Δες το αρχείο remote.log στον φάκελο:' $dir -ForegroundColor Yellow }
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -eq 'Dhcp' } | ForEach-Object {
    Write-Host ''
    Write-Host "Στα tablet άνοιξε:  http://$($_.IPAddress):8080/" -ForegroundColor Green
}
