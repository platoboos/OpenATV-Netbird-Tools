[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installerPath = Join-Path $PSScriptRoot 'install-netbird-openatv.sh'

if (-not (Test-Path -LiteralPath $installerPath)) {
    throw "Installer wurde nicht gefunden: $installerPath"
}

$installerBytes = [IO.File]::ReadAllBytes($installerPath)
$memoryStream = [IO.MemoryStream]::new()
$gzipStream = [IO.Compression.GZipStream]::new(
    $memoryStream,
    [IO.Compression.CompressionMode]::Compress,
    $true
)
try {
    $gzipStream.Write($installerBytes, 0, $installerBytes.Length)
}
finally {
    $gzipStream.Dispose()
}

$encodedInstaller = [Convert]::ToBase64String($memoryStream.ToArray())
$memoryStream.Dispose()

$remotePath = '/tmp/install-netbird-openatv.sh'
$startCommand = "printf '%s' '$encodedInstaller' | base64 -d | gzip -d > '$remotePath' && chmod 700 '$remotePath' && sh '$remotePath'"

if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
    Set-Clipboard -Value $startCommand
}
elseif (Get-Command clip.exe -ErrorAction SilentlyContinue) {
    $startCommand | clip.exe
}
else {
    throw 'Die Windows-Zwischenablage konnte nicht angesprochen werden.'
}

Write-Host ''
Write-Host 'VORBEREITUNG_OK' -ForegroundColor Green
Write-Host 'Der komplette Installer befindet sich jetzt in der Zwischenablage.' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Naechste Schritte:' -ForegroundColor Yellow
Write-Host '1. Zur bereits geoeffneten root@...# Konsole der Box wechseln.'
Write-Host '2. Einmal Strg+V druecken.'
Write-Host '3. Enter druecken.'
Write-Host '4. NetBird Management-URL, Boxnamen und Setup-Key eingeben.'
Write-Host ''
Write-Host 'Es werden keine IP-Adresse und kein SSH-Passwort abgefragt.' -ForegroundColor Green
