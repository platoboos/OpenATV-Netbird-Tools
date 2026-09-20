[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repairCommand = @'
printf 'NetBird Management-URL eingeben: '; IFS= read -r NBURL; NBURL="${NBURL%/}"; case "$NBURL" in http://*|https://*) ;; *) echo 'Ungueltige Management-URL.'; exit 1;; esac; printf 'Wie soll die Box in NetBird heissen: '; IFS= read -r NBNAME; case "$NBNAME" in ''|*[!A-Za-z0-9-]*|-*|*-) echo 'Ungueltiger Boxname.'; exit 1;; esac; printf 'NetBird Setup-Key eingeben: '; stty -echo; IFS= read -r NBINPUT; stty echo; echo; NBKEY="$(printf '%s' "$NBINPUT" | grep -Eo '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -n 1)"; NBINPUT=''; if [ -z "$NBKEY" ]; then echo 'INSTALL_ERROR: Kein gueltiger 36-stelliger Setup-Key gefunden.'; exit 1; fi; netbird up --management-url "$NBURL" --setup-key "$NBKEY" --hostname "$NBNAME"; rc=$?; NBKEY=''; sleep 8; netbird status; exit $rc
'@

if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
    Set-Clipboard -Value $repairCommand
}
elseif (Get-Command clip.exe -ErrorAction SilentlyContinue) {
    $repairCommand | clip.exe
}
else {
    throw 'Die Windows-Zwischenablage konnte nicht angesprochen werden.'
}

Write-Host ''
Write-Host 'REPARATUR_VORBEREITET' -ForegroundColor Green
Write-Host 'Zur root@...# Konsole wechseln, Strg+V und danach Enter druecken.' -ForegroundColor Cyan
Write-Host 'Anschliessend Management-URL, Boxname und Setup-Key eingeben.' -ForegroundColor Cyan
