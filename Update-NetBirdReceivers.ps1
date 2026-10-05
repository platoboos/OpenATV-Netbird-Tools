[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$Inventory,
    [string]$KeyPath = (Join-Path $env:USERPROFILE '.ssh\netbird-receivers_ed25519'),
    [string]$CompatibilityKeyPath,
    [string[]]$BoxName,
    [int]$ReconnectTimeoutSeconds = 480,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($Inventory)) { $Inventory = Join-Path $scriptDirectory 'boxes.csv' }
if ([string]::IsNullOrWhiteSpace($CompatibilityKeyPath)) { $CompatibilityKeyPath = Join-Path $scriptDirectory '.secrets\netbird-receivers_rsa' }
$helperScript = Join-Path $scriptDirectory 'receiver-netbird-update.sh'
$initScript = Join-Path $scriptDirectory 'netbird-init-openatv.sh'
$logDirectory = Join-Path $scriptDirectory 'logs'

if ([string]::IsNullOrWhiteSpace($Version)) {
    Write-Host 'Neueste stabile NetBird-Version ermitteln...' -ForegroundColor Cyan
    try {
        $release = Invoke-RestMethod `
            -UseBasicParsing `
            -Uri 'https://api.github.com/repos/netbirdio/netbird/releases/latest' `
            -Headers @{ 'User-Agent' = 'NetBird-OpenATV-Updater' }
        $Version = ([string]$release.tag_name).TrimStart('v')
    }
    catch {
        throw "Die neueste NetBird-Version konnte nicht ermittelt werden. Gib sie ersatzweise mit -Version an. $($_.Exception.Message)"
    }

    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "GitHub hat eine unerwartete Versionsangabe geliefert: $Version"
    }
    Write-Host "Ermittelte stabile Version: $Version" -ForegroundColor Green
}

$cacheDirectory = Join-Path $scriptDirectory ".cache\netbird\$Version"

foreach ($command in @('ssh.exe', 'scp.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command wurde nicht gefunden. Installiere zuerst den Windows OpenSSH-Client."
    }
}

foreach ($path in @($Inventory, $KeyPath, $helperScript, $initScript)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Erforderliche Datei fehlt: $path"
    }
}

$boxes = @(Import-Csv -LiteralPath $Inventory)
if ($BoxName) {
    $boxes = @($boxes | Where-Object { $BoxName -contains $_.Name })
}
if ($boxes.Count -eq 0) {
    throw 'Keine passenden Boxen in der Inventarliste gefunden.'
}

New-Item -ItemType Directory -Force -Path $cacheDirectory, $logDirectory | Out-Null
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultFile = Join-Path $logDirectory "receiver-update-$runStamp.csv"
$results = [System.Collections.Generic.List[object]]::new()

$sshOptions = @(
    '-i', $KeyPath,
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=12',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'PubkeyAcceptedAlgorithms=+ssh-rsa'
)
if (Test-Path -LiteralPath $CompatibilityKeyPath) {
    $sshOptions += @('-i', $CompatibilityKeyPath)
}

function Invoke-ReceiverSsh {
    param(
        [Parameter(Mandatory)] [string]$IP,
        [Parameter(Mandatory)] [string]$Command
    )

    # Windows PowerShell wandelt Text auf stderr (z. B. die normale
    # SSH-Meldung zu einem neuen Host-Key) bei ErrorActionPreference=Stop in
    # eine Ausnahme um. Fuer native SSH-Aufrufe entscheidet ausschliesslich
    # der Exitcode; dadurch koennen fehlende Schluessel sauber als
    # SSH_SETUP_REQUIRED protokolliert werden.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & ssh.exe @sshOptions "root@$IP" $Command 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($output -join "`n")
    }
}

function Get-NetBirdPackage {
    param([Parameter(Mandatory)] [string]$Package)

    $assetName = "netbird_${Version}_linux_${Package}.tar.gz"
    $assetPath = Join-Path $cacheDirectory $assetName
    $checksumsPath = Join-Path $cacheDirectory "netbird_${Version}_checksums.txt"
    $baseUrl = "https://github.com/netbirdio/netbird/releases/download/v$Version"

    if (-not (Test-Path -LiteralPath $checksumsPath)) {
        Write-Host "Pruefsummen fuer NetBird $Version herunterladen..." -ForegroundColor Cyan
        Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/netbird_${Version}_checksums.txt" -OutFile $checksumsPath
    }

    if (-not (Test-Path -LiteralPath $assetPath)) {
        Write-Host "$assetName herunterladen..." -ForegroundColor Cyan
        Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$assetName" -OutFile $assetPath
    }

    $checksumLine = Get-Content -LiteralPath $checksumsPath | Where-Object { $_ -match "\s+$([regex]::Escape($assetName))$" } | Select-Object -First 1
    if (-not $checksumLine) {
        throw "Keine Pruefsumme fuer $assetName gefunden."
    }

    $expectedHash = ($checksumLine -split '\s+')[0].ToLowerInvariant()
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        Remove-Item -LiteralPath $assetPath -Force
        throw "Pruefsumme fuer $assetName stimmt nicht. Die Datei wurde geloescht."
    }

    return $assetPath
}

function Add-Result {
    param($Box, [string]$Architecture, [string]$OldVersion, [string]$Status, [string]$Details)

    $results.Add([pscustomobject]@{
        Time         = (Get-Date).ToString('s')
        Name         = $Box.Name
        IP           = $Box.IP
        Architecture = $Architecture
        OldVersion   = $OldVersion
        Target       = $Version
        Status       = $Status
        Details      = $Details
    })
    $results | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $resultFile
}

Write-Host "NetBird $Version wird fuer $($boxes.Count) Box(en) vorbereitet." -ForegroundColor Cyan
Write-Host 'Die Boxen werden bewusst nacheinander aktualisiert.' -ForegroundColor Yellow

foreach ($box in $boxes) {
    $architecture = $null
    $oldVersion = $null

    Write-Host ''
    Write-Host "[$($box.Name)] $($box.IP)" -ForegroundColor Cyan

    if ([string]$box.Connected -eq 'False') {
        Write-Warning 'Box ist offline; Update wird bis zum naechsten Lauf zurueckgestellt.'
        Add-Result -Box $box -Architecture 'unbekannt' -OldVersion ([string]$box.Version) -Status 'DEFERRED_OFFLINE' -Details 'NetBird meldet den Peer als offline'
        continue
    }

    try {
        $probe = Invoke-ReceiverSsh -IP $box.IP -Command "uname -m; opkg print-architecture 2>/dev/null || true; /usr/bin/netbird version 2>/dev/null || true"
        if ($probe.ExitCode -ne 0) {
            Write-Warning 'SSH ist noch nicht eingerichtet oder durch eine Policy gesperrt. Box wird zurueckgestellt.'
            Add-Result -Box $box -Architecture 'unbekannt' -OldVersion ([string]$box.Version) -Status 'SSH_SETUP_REQUIRED' -Details $probe.Output
            continue
        }

        $architecture = if ($probe.Output -match '(?m)^armv7l\s*$') {
            'armv6'
        }
        elseif ($probe.Output -match '(?m)^aarch64\s*$') {
            'arm64'
        }
        elseif ($probe.Output -match '(?m)^x86_64\s*$') {
            'amd64'
        }
        elseif ($probe.Output -match '(?m)^mips\s*$' -and $probe.Output -match 'mips32el|mipsel') {
            'mipsle_hardfloat'
        }
        else {
            throw "Unbekannte Architektur:`n$($probe.Output)"
        }

        $versionMatches = [regex]::Matches($probe.Output, '(?m)^\d+\.\d+\.\d+\s*$')
        $oldVersion = if ($versionMatches.Count -gt 0) { $versionMatches[$versionMatches.Count - 1].Value.Trim() } else { 'unbekannt' }

        Write-Host "Architektur: $architecture; installiert: $oldVersion" -ForegroundColor Gray
        if (-not $Force -and $oldVersion -eq $Version) {
            Write-Host 'Bereits aktuell, wird uebersprungen.' -ForegroundColor Green
            Add-Result -Box $box -Architecture $architecture -OldVersion $oldVersion -Status 'SKIPPED' -Details 'Bereits aktuell'
            continue
        }

        $archive = Get-NetBirdPackage -Package $architecture

        Write-Host 'Archiv, Dienststeuerung und Update-Helfer uebertragen...'
        & scp.exe -O @sshOptions $archive "root@$($box.IP):/tmp/netbird-update.tar.gz"
        if ($LASTEXITCODE -ne 0) {
            throw 'Upload des NetBird-Archivs fehlgeschlagen.'
        }
        & scp.exe -O @sshOptions $helperScript "root@$($box.IP):/tmp/netbird-receiver-update.sh"
        if ($LASTEXITCODE -ne 0) {
            throw 'Upload des Update-Helfers fehlgeschlagen.'
        }
        & scp.exe -O @sshOptions $initScript "root@$($box.IP):/tmp/netbird-init-openatv.sh"
        if ($LASTEXITCODE -ne 0) {
            throw 'Upload der NetBird-Dienststeuerung fehlgeschlagen.'
        }

        $schedule = Invoke-ReceiverSsh -IP $box.IP -Command "chmod 700 /tmp/netbird-receiver-update.sh /tmp/netbird-init-openatv.sh && cp /tmp/netbird-init-openatv.sh /etc/init.d/netbird && chmod 755 /etc/init.d/netbird && sh /tmp/netbird-receiver-update.sh '$Version'"
        if ($schedule.ExitCode -ne 0 -or $schedule.Output -notmatch 'UPDATE_SCHEDULED') {
            throw "Update konnte nicht geplant werden: $($schedule.Output)"
        }

        Write-Host 'NetBird wird neu gestartet; auf die Rueckkehr der Box warten...'
        $deadline = (Get-Date).AddSeconds($ReconnectTimeoutSeconds)
        $verified = $false
        $lastOutput = ''
        do {
            Start-Sleep -Seconds 10
            $check = Invoke-ReceiverSsh -IP $box.IP -Command "/usr/bin/netbird version 2>/dev/null; netbird status 2>/dev/null; cat /tmp/netbird-update-result.log 2>/dev/null || true"
            $lastOutput = $check.Output
            if ($check.ExitCode -eq 0 -and $check.Output -match [regex]::Escape($Version) -and $check.Output -match 'Management:\s+Connected') {
                $verified = $true
                break
            }
        } while ((Get-Date) -lt $deadline)

        if (-not $verified) {
            throw "Box kam nicht verifiziert zurueck. Letzte Ausgabe: $lastOutput"
        }

        Write-Host "UPDATE_OK: $oldVersion -> $Version" -ForegroundColor Green
        Add-Result -Box $box -Architecture $architecture -OldVersion $oldVersion -Status 'OK' -Details 'Management Connected'
    }
    catch {
        Write-Warning $_.Exception.Message
        $architectureForResult = if ([string]::IsNullOrWhiteSpace($architecture)) { 'unbekannt' } else { $architecture }
        $oldVersionForResult = if ([string]::IsNullOrWhiteSpace($oldVersion)) { 'unbekannt' } else { $oldVersion }
        Add-Result -Box $box -Architecture $architectureForResult -OldVersion $oldVersionForResult -Status 'FAILED' -Details $_.Exception.Message
    }
}

Write-Host ''
Write-Host "Ergebnisdatei: $resultFile" -ForegroundColor Cyan
$results | Format-Table Name, IP, Architecture, OldVersion, Target, Status -AutoSize

if ($results.Status -contains 'FAILED') {
    exit 1
}
