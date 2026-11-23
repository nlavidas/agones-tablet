$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = Join-Path $env:SystemDrive 'Tilekontrol'
$dir = Join-Path $base 'agones-tablet-main\remote'

function Step($t) { Write-Host ''; Write-Host "==== $t" -ForegroundColor Cyan }
function RunPy { & py.exe -3 @args }

Step '1/6  Python'
if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
    $done = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install -e --id Python.Python.3.12 --scope machine --silent --accept-package-agreements --accept-source-agreements
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        $done = [bool](Get-Command py -ErrorAction SilentlyContinue)
    }
    if (-not $done) {
        $exe = Join-Path $env:TEMP 'python-3.12.8-amd64.exe'
        Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe' -OutFile $exe -UseBasicParsing
        Start-Process -FilePath $exe -ArgumentList '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_launcher=1' -Wait
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }
}
RunPy --version

Step '2/6  Κατέβασμα προγράμματος'
Stop-ScheduledTask -TaskName 'Tilekontrol' -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $base | Out-Null
$codes = Join-Path $dir 'codes.json'
$keep = $null
if (Test-Path $codes) { $keep = Get-Content $codes -Raw -Encoding UTF8 }
$zip = Join-Path $base 'agones-tablet.zip'
Invoke-WebRequest -Uri 'https://github.com/nlavidas/agones-tablet/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $base -Force
if ($keep) { Set-Content -Path $codes -Value $keep -Encoding UTF8 -NoNewline }
Set-Location $dir
RunPy -m pip install --quiet --disable-pip-version-check --upgrade broadlink qrcode pypng
$secretFile = Join-Path $base 'secret.txt'
if (-not (Test-Path $secretFile)) {
    $abc = 'abcdefghijkmnpqrstuvwxyz23456789'
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $secret = 'agones-' + (-join ($bytes | ForEach-Object { $abc[$_ % $abc.Length] }))
    Set-Content -Path $secretFile -Value $secret -Encoding ASCII -NoNewline
}
$secret = (Get-Content $secretFile -Raw).Trim()
$controlUrl = "https://nlavidas.github.io/agones-tablet/control.html#$secret"
$pyexe = (RunPy -c "import sys;print(sys.executable)").Trim()
$pyw = Join-Path (Split-Path $pyexe) 'pythonw.exe'
Get-NetFirewallRule -DisplayName 'Tilekontrol*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'Tilekontrol tablet 8080' -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'Tilekontrol program' -Direction Inbound -Program $pyw -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'Tilekontrol setup' -Direction Inbound -Program $pyexe -Action Allow -Profile Any | Out-Null

Step '3/6  Μάθηση πλήκτρων τηλεκοντρόλ'
for ($i = 0; $i -lt 3; $i++) {
    RunPy remote.py check | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    RunPy remote.py learn
}
RunPy remote.py check
if ($LASTEXITCODE -ne 0) { Write-Host 'Δεν μάθαμε όλα τα πλήκτρα. Ξανατρέξε την εγκατάσταση.' -ForegroundColor Red; return }

Step '4/6  Δοκιμή'
while ($true) {
    RunPy remote.py test 301
    do { $a = (Read-Host 'Ο αποκωδικοποιητής πήγε στο 301; Γράψε Ν για ναι ή Ο για όχι, και πάτα Enter').Trim() } until ($a -match '^[NnΝνOoΟο]')
    if ($a -match '^[NnΝν]') { break }
    Write-Host 'Ξαναμαθαίνουμε όλα τα πλήκτρα από την αρχή.' -ForegroundColor Yellow
    RunPy remote.py learn all
}

Step '5/6  Κρυφή αυτόματη εκκίνηση'
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
foreach ($p in @(
        @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0'),
        @('/setacvalueindex', 'SCHEME_CURRENT', '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1', '12bbebe6-58d6-4636-95bb-3217ef867c1a', '0'),
        @('/setactive', 'SCHEME_CURRENT'))) {
    try { $null = & powercfg.exe @p 2>&1 } catch { }
}
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" | Where-Object { $_.CommandLine -like '*remote.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
$act = New-ScheduledTaskAction -Execute $pyw -Argument 'remote.py serve' -WorkingDirectory $dir
$trg = New-ScheduledTaskTrigger -AtStartup
$pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
Register-ScheduledTask -TaskName 'Tilekontrol' -Action $act -Trigger $trg -Principal $pri -Settings $set -Force | Out-Null
Start-ScheduledTask -TaskName 'Tilekontrol'

Step '6/6  Έλεγχος'
$ok = $false
for ($i = 0; $i -lt 6 -and -not $ok; $i++) {
    Start-Sleep -Seconds 5
    try { $ok = (Invoke-WebRequest -Uri 'http://127.0.0.1:8080/api/state' -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } catch { $ok = $false }
}
if ($ok) { Write-Host 'Το τηλεκοντρόλ τρέχει κρυφά και ξεκινά μόνο του σε κάθε άνοιγμα του υπολογιστή.' -ForegroundColor Green }
else { Write-Host "Το τηλεκοντρόλ δεν απαντά. Δες το αρχείο remote.log στον φάκελο $dir" -ForegroundColor Red }
$ip = (RunPy -c "import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(('8.8.8.8',80));print(s.getsockname()[0])").Trim()
Write-Host ''
Write-Host "  Τηλεκοντρόλ (Asus):       http://$($ip):8080/" -ForegroundColor Green
Write-Host "  Πίνακας αγώνων (Acer):    nlavidas.github.io/agones-tablet" -ForegroundColor Green
Write-Host "  ή, αν δεν ανοίγει:        http://$($ip):8080/agones" -ForegroundColor Green
Write-Host ''
Write-Host '  Επιλογές ΝΑΙ/ΟΧΙ από το κινητό σου: σκάναρε αυτόν τον κωδικό με την κάμερα του κινητού' -ForegroundColor Green
RunPy -c "import qrcode,sys;q=qrcode.QRCode(border=2);q.add_data(sys.argv[1]);q.print_ascii(invert=True)" $controlUrl
Write-Host "  ή άνοιξε στο κινητό: $controlUrl" -ForegroundColor Green
$qrPng = Join-Path $base 'KINHTO-QR.png'
try {
    RunPy -c "import qrcode,sys;from qrcode.image.pure import PyPNGImage;qrcode.make(sys.argv[1],image_factory=PyPNGImage,box_size=12,border=4).save(sys.argv[2])" $controlUrl $qrPng
    if (Test-Path $qrPng) { Start-Process $qrPng }
} catch { }
Set-Content -Path (Join-Path $base 'DIEYTHYNSEIS.txt') -Encoding UTF8 -Value @(
    "Επιλογές ΝΑΙ/ΟΧΙ από το κινητό: $controlUrl",
    "Τηλεκοντρόλ (Asus): http://$($ip):8080/",
    "Πίνακας αγώνων (Acer): nlavidas.github.io/agones-tablet",
    "Πίνακας αγώνων, αν δεν ανοίγει: http://$($ip):8080/agones"
)
