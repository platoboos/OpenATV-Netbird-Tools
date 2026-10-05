[CmdletBinding()]
param(
    [string]$Inventory,
    [string]$KeyPath = (Join-Path $env:USERPROFILE '.ssh\netbird-receivers_ed25519'),
    [string]$CompatibilityKeyPath,
    [string]$KnownHostsPath,
    [string[]]$BoxName,
    [switch]$UseRsaCompatibilityKey
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($Inventory)) { $Inventory = Join-Path $scriptDirectory 'boxes.csv' }
if ([string]::IsNullOrWhiteSpace($CompatibilityKeyPath)) { $CompatibilityKeyPath = Join-Path $scriptDirectory '.secrets\netbird-receivers_rsa' }
if ([string]::IsNullOrWhiteSpace($KnownHostsPath)) { $KnownHostsPath = Join-Path $scriptDirectory '.known_hosts_receivers' }

if ($UseRsaCompatibilityKey) {
    $KeyPath = $CompatibilityKeyPath
}

foreach ($command in @('ssh.exe', 'ssh-keygen.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command wurde nicht gefunden. Installiere zuerst den Windows OpenSSH-Client."
    }
}

if (-not (Test-Path -LiteralPath $Inventory)) {
    throw "Inventarliste nicht gefunden: $Inventory"
}

$keyDirectory = Split-Path -Parent $KeyPath
New-Item -ItemType Directory -Force -Path $keyDirectory | Out-Null

if (-not (Test-Path -LiteralPath $KeyPath)) {
    Write-Host "Erzeuge einen eigenen SSH-Schluessel fuer die Receiver: $KeyPath" -ForegroundColor Cyan
    if ($UseRsaCompatibilityKey) {
        & ssh-keygen.exe -t rsa -b 3072 -f $KeyPath -N '""' -C 'netbird-receiver-updates-rsa-compat'
    }
    else {
        & ssh-keygen.exe -t ed25519 -a 64 -f $KeyPath -N '""' -C 'netbird-receiver-updates'
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'Der SSH-Schluessel konnte nicht erzeugt werden.'
    }
}

$publicKeyPath = "$KeyPath.pub"
if (-not (Test-Path -LiteralPath $publicKeyPath)) {
    throw "Public Key fehlt: $publicKeyPath"
}

$publicKey = (Get-Content -Raw -LiteralPath $publicKeyPath).Trim()
if ($publicKey.Contains("'")) {
    throw 'Der Public Key enthaelt ein unerwartetes Hochkomma.'
}

$boxes = @(Import-Csv -LiteralPath $Inventory)
if ($BoxName) {
    $boxes = @($boxes | Where-Object { $BoxName -contains $_.Name })
}
if ($boxes.Count -eq 0) {
    throw 'Keine passenden Boxen in der Inventarliste gefunden.'
}

Write-Host ''
Write-Host 'Bei jeder Box muss einmal das bisherige root-Passwort eingegeben werden.' -ForegroundColor Yellow
Write-Host 'Danach prueft das Skript die Anmeldung ohne Passwort.' -ForegroundColor Yellow

$failed = @()
$sshOptions = @('-i', $KeyPath, '-o', 'ConnectTimeout=15', '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=$KnownHostsPath", '-o', 'PubkeyAcceptedAlgorithms=+ssh-rsa')
foreach ($box in $boxes) {
    Write-Host ''
    Write-Host "[$($box.Name)] SSH-Schluessel auf $($box.IP) installieren" -ForegroundColor Cyan

    $remoteCommand = "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$publicKey' ~/.ssh/authorized_keys || printf '%s\n' '$publicKey' >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & ssh.exe @sshOptions "root@$($box.IP)" $remoteCommand
        $installExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($installExitCode -ne 0) {
        Write-Warning "Schluesselinstallation auf $($box.Name) fehlgeschlagen."
        $failed += $box.Name
        continue
    }

    try {
        $ErrorActionPreference = 'Continue'
        $testOutput = & ssh.exe @sshOptions -o BatchMode=yes "root@$($box.IP)" 'printf KEY_OK' 2>&1
        $testExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($testExitCode -eq 0 -and ($testOutput -join '') -match 'KEY_OK') {
        Write-Host "[$($box.Name)] KEY_OK" -ForegroundColor Green
    }
    else {
        Write-Warning "Die Anmeldung mit dem neuen Schluessel auf $($box.Name) funktioniert noch nicht."
        $failed += $box.Name
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Warning ('Fehlgeschlagen: ' + ($failed -join ', '))
    exit 1
}

Write-Host 'SSH-Schluessel wurde auf allen ausgewaehlten Boxen installiert.' -ForegroundColor Green
