[CmdletBinding()]
param(
    [string]$BoxAddress,

    [string]$BoxName,

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Security.SecureString]$SetupKey,
    [string]$ManagementUrl,
    [string]$SshKeyPath = (Join-Path $env:USERPROFILE '.ssh\netbird-receivers_ed25519'),
    [string]$Inventory
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($Inventory)) { $Inventory = Join-Path $scriptDirectory 'boxes.csv' }
$installerScript = Join-Path $scriptDirectory 'install-netbird-openatv.sh'

if ([string]::IsNullOrWhiteSpace($BoxAddress)) {
    $BoxAddress = (Read-Host 'OpenVPN-IP oder aktuell erreichbare IP der Box').Trim()
}
if ([string]::IsNullOrWhiteSpace($BoxAddress)) {
    throw 'Es wurde keine Adresse fuer die Box eingegeben.'
}

if ([string]::IsNullOrWhiteSpace($ManagementUrl)) {
    $ManagementUrl = (Read-Host 'NetBird Management-URL, z.B. https://netbird.example.de').Trim()
}
$ManagementUrl = $ManagementUrl.TrimEnd('/')
try {
    $managementUri = [Uri]$ManagementUrl
}
catch {
    throw 'Die NetBird Management-URL ist ungueltig.'
}
if ($managementUri.Scheme -notin @('http', 'https') -or [string]::IsNullOrWhiteSpace($managementUri.Host)) {
    throw 'Die NetBird Management-URL muss mit http:// oder https:// beginnen und einen Hostnamen enthalten.'
}

if ([string]::IsNullOrWhiteSpace($BoxName)) {
    $BoxName = (Read-Host 'Wie soll die Box in NetBird heissen').Trim()
}
if ($BoxName -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') {
    throw 'Der Boxname darf nur Buchstaben, Zahlen und Bindestriche enthalten und nicht mit einem Bindestrich beginnen oder enden.'
}

foreach ($command in @('ssh.exe', 'scp.exe', 'ssh-keygen.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command wurde nicht gefunden. Installiere zuerst den Windows OpenSSH-Client."
    }
}

if (-not (Test-Path -LiteralPath $installerScript)) {
    throw "Installationshelfer fehlt: $installerScript"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    Write-Host 'Neueste stabile NetBird-Version ermitteln...' -ForegroundColor Cyan
    try {
        $release = Invoke-RestMethod `
            -UseBasicParsing `
            -Uri 'https://api.github.com/repos/netbirdio/netbird/releases/latest' `
            -Headers @{ 'User-Agent' = 'NetBird-OpenATV-Installer' }
        $Version = ([string]$release.tag_name).TrimStart('v')
    }
    catch {
        throw "Die neueste NetBird-Version konnte nicht ermittelt werden. Gib sie ersatzweise mit -Version an. $($_.Exception.Message)"
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "GitHub hat eine unerwartete Versionsangabe geliefert: $Version"
    }
}
Write-Host "Verwendete NetBird-Version: $Version" -ForegroundColor Green

$keyDirectory = Split-Path -Parent $SshKeyPath
New-Item -ItemType Directory -Force -Path $keyDirectory | Out-Null
if (-not (Test-Path -LiteralPath $SshKeyPath)) {
    Write-Host "Receiver-SSH-Schluessel erzeugen: $SshKeyPath" -ForegroundColor Cyan
    & ssh-keygen.exe -t ed25519 -a 64 -f $SshKeyPath -N '""' -C 'netbird-receiver-updates'
    if ($LASTEXITCODE -ne 0) {
        throw 'Der Receiver-SSH-Schluessel konnte nicht erzeugt werden.'
    }
}

$publicKeyPath = "$SshKeyPath.pub"
if (-not (Test-Path -LiteralPath $publicKeyPath)) {
    throw "Public Key fehlt: $publicKeyPath"
}
$publicKey = (Get-Content -Raw -LiteralPath $publicKeyPath).Trim()
if ($publicKey.Contains("'")) {
    throw 'Der Public Key enthaelt ein unerwartetes Hochkomma.'
}

Write-Host ''
Write-Host "SSH-Schluessel auf $BoxAddress einrichten." -ForegroundColor Cyan
Write-Host 'Falls die Box den Schluessel noch nicht kennt, jetzt einmal das bisherige root-Passwort eingeben.' -ForegroundColor Yellow
$keyCommand = "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$publicKey' ~/.ssh/authorized_keys || printf '%s\n' '$publicKey' >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
& ssh.exe -i $SshKeyPath -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "root@$BoxAddress" $keyCommand
if ($LASTEXITCODE -ne 0) {
    throw 'Der SSH-Schluessel konnte nicht auf der Box installiert werden.'
}

$sshOptions = @(
    '-i', $SshKeyPath,
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=15',
    '-o', 'StrictHostKeyChecking=accept-new'
)

$probeOutput = & ssh.exe @sshOptions "root@$BoxAddress" "uname -m; opkg print-architecture 2>/dev/null || true; command -v update-rc.d" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "SSH-Anmeldung mit dem Receiver-Schluessel fehlgeschlagen.`n$($probeOutput -join "`n")"
}
$probeText = $probeOutput -join "`n"

$packageArchitecture = if ($probeText -match '(?m)^armv7l\s*$') {
    'armv6'
}
elseif ($probeText -match '(?m)^aarch64\s*$') {
    'arm64'
}
elseif ($probeText -match '(?m)^x86_64\s*$') {
    'amd64'
}
elseif ($probeText -match '(?m)^mips\s*$' -and $probeText -match 'mips32el|mipsel') {
    'mipsle_hardfloat'
}
else {
    throw "Nicht unterstuetzte Receiver-Architektur:`n$probeText"
}

if ($probeText -notmatch '(?m)(^|/)update-rc\.d\s*$') {
    throw "Erforderliche OpenATV-Systemwerkzeuge fehlen:`n$probeText"
}
Write-Host "Erkannte Paketarchitektur: $packageArchitecture" -ForegroundColor Green

$cacheDirectory = Join-Path $scriptDirectory ".cache\netbird\$Version"
New-Item -ItemType Directory -Force -Path $cacheDirectory | Out-Null
$assetName = "netbird_${Version}_linux_${packageArchitecture}.tar.gz"
$assetPath = Join-Path $cacheDirectory $assetName
$checksumsPath = Join-Path $cacheDirectory "netbird_${Version}_checksums.txt"
$baseUrl = "https://github.com/netbirdio/netbird/releases/download/v$Version"

if (-not (Test-Path -LiteralPath $checksumsPath)) {
    Write-Host 'Offizielle Pruefsummen herunterladen...'
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/netbird_${Version}_checksums.txt" -OutFile $checksumsPath
}
if (-not (Test-Path -LiteralPath $assetPath)) {
    Write-Host "$assetName herunterladen..."
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$assetName" -OutFile $assetPath
}

$checksumLine = Get-Content -LiteralPath $checksumsPath | Where-Object { $_ -match "\s+$([regex]::Escape($assetName))$" } | Select-Object -First 1
if (-not $checksumLine) {
    throw "Keine offizielle Pruefsumme fuer $assetName gefunden."
}
$expectedHash = ($checksumLine -split '\s+')[0].ToLowerInvariant()
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
    Remove-Item -LiteralPath $assetPath -Force
    throw 'Die SHA-256-Pruefsumme stimmt nicht. Das heruntergeladene Archiv wurde geloescht.'
}
Write-Host 'SHA-256-Pruefsumme ist korrekt.' -ForegroundColor Green

Write-Host 'Installationsdateien auf die Box uebertragen...'
& scp.exe -O @sshOptions $assetPath "root@${BoxAddress}:/tmp/netbird-install.tar.gz"
if ($LASTEXITCODE -ne 0) {
    throw 'Upload des NetBird-Archivs fehlgeschlagen.'
}
& scp.exe -O @sshOptions $installerScript "root@${BoxAddress}:/tmp/install-netbird-openatv.sh"
if ($LASTEXITCODE -ne 0) {
    throw 'Upload des Installationshelfers fehlgeschlagen.'
}

if (-not $SetupKey) {
    $SetupKey = Read-Host 'NetBird Setup-Key eingeben' -AsSecureString
}
$bstr = [IntPtr]::Zero
$plainSetupKey = $null
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SetupKey)
    $plainSetupKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    if ([string]::IsNullOrWhiteSpace($plainSetupKey)) {
        throw 'Der Setup-Key ist leer.'
    }

    Write-Host 'NetBird auf der Box installieren und anmelden...' -ForegroundColor Cyan
    $remoteCommand = "chmod 700 /tmp/install-netbird-openatv.sh && sh /tmp/install-netbird-openatv.sh '$Version' '$BoxName' '$ManagementUrl'"
    $installOutput = ($plainSetupKey + "`n") | & ssh.exe @sshOptions "root@$BoxAddress" $remoteCommand 2>&1
    $installExitCode = $LASTEXITCODE
}
finally {
    $plainSetupKey = $null
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

$installText = $installOutput -join "`n"
Write-Host $installText
if ($installExitCode -ne 0 -or $installText -notmatch '(?m)^INSTALL_OK:') {
    throw 'NetBird-Installation oder Management-Anmeldung fehlgeschlagen. Siehe Ausgabe oberhalb.'
}

$ipMatch = [regex]::Match($installText, '(?m)^NETBIRD_IP=(\d{1,3}(?:\.\d{1,3}){3})\s*$')
if (-not $ipMatch.Success) {
    throw 'Installation war erfolgreich, aber die NetBird-IP konnte nicht ausgelesen werden.'
}
$netBirdIp = $ipMatch.Groups[1].Value
$inventoryName = $BoxName.ToLowerInvariant()

$inventoryRows = if (Test-Path -LiteralPath $Inventory) { @(Import-Csv -LiteralPath $Inventory) } else { @() }
$inventoryRows = @($inventoryRows | Where-Object { $_.Name -ne $inventoryName -and $_.IP -ne $netBirdIp })
$inventoryRows += [pscustomobject]@{ Name = $inventoryName; IP = $netBirdIp }
$inventoryRows | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $Inventory

& ssh.exe @sshOptions "root@$BoxAddress" "rm -f /tmp/install-netbird-openatv.sh /tmp/netbird-install.tar.gz" | Out-Null

Write-Host ''
Write-Host 'INSTALLATION_ERFOLGREICH' -ForegroundColor Green
Write-Host "Name:       $BoxName"
Write-Host "NetBird-IP: $netBirdIp"
Write-Host "Inventar:   $Inventory"
Write-Host "Test:       ssh -i `"$SshKeyPath`" root@$netBirdIp"
