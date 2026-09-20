# NetBird-Updates fuer OpenATV-Receiver

Diese Dateien aktualisieren ausschliesslich die NetBird-Clients auf den
OpenATV-Receivern. Das vorhandene `netbird-update.sh` ist dagegen fuer den
NetBird-Server auf dem VPS bestimmt und wird hiervon nicht verwendet.

## Dateien

- `boxes.csv`: Inventarliste der Receiver und ihrer NetBird-IP-Adressen
- `Install-NetBirdOpenATVBox.ps1`: komplette Erstinstallation einer neuen Box
- `install-netbird-openatv.sh`: Installationshelfer fuer die OpenATV-Box
- `Install-ReceiverSshKey.ps1`: verteilt einmalig einen eigenen SSH-Schluessel
- `Update-NetBirdReceivers.ps1`: fuehrt kontrollierte Receiver-Updates aus
- `receiver-netbird-update.sh`: Update-Helfer, der auf die Box kopiert wird

## Neue OpenATV-Box installieren

### Direkt auf der verbundenen Box

Direkt auf jeder Box genuegt:

```sh
wget -O /tmp/install-netbird.sh https://raw.githubusercontent.com/platoboos/openatv-netbird-tools/main/install-netbird-openatv.sh
sh /tmp/install-netbird.sh
```

Danach werden nur Boxname und Setup-Key abgefragt.

In Windows PowerShell ausfuehren:

```powershell
.\Start-NetBirdInstallationAufBox.ps1
```

Der Helfer packt den vollstaendigen Installer in einen Uebertragungsbefehl und
kopiert ihn in die Windows-Zwischenablage. Danach zur bereits geoeffneten
SSH-Konsole der Box (`root@...#`) wechseln, einmal `Strg+V` und danach Enter
druecken. Der eingefuegte Befehl uebertraegt und startet den Installer
automatisch.

Alternativ kann `install-netbird-openatv.sh` weiterhin per WinSCP nach `/tmp`
kopiert und dort manuell gestartet werden:

```sh
chmod 700 /tmp/install-netbird-openatv.sh
sh /tmp/install-netbird-openatv.sh
```

Dieses Verfahren benoetigt keine IP-Adresse als Eingabe. Das Skript fragt nur
nach dem gewuenschten NetBird-Namen und verdeckt nach dem Setup-Key. Am Ende
zeigt es die neue NetBird-IP und den benoetigten Eintrag fuer `boxes.csv` an.
Beim Setup-Key darf auch versehentlich `--setup-key=` oder weiterer kopierter
Text enthalten sein; der Installer extrahiert und prueft die 36-stellige UUID
vor der Anmeldung.

### Vom Windows-PC aus

Die Box muss zunaechst ueber ihre lokale oder bisherige OpenVPN-IP per SSH
erreichbar sein. Das Skript wird ohne Parameter gestartet:

```powershell
.\Install-NetBirdOpenATVBox.ps1
```

Das Skript fragt nach der OpenVPN-IP beziehungsweise aktuell erreichbaren IP
und dem gewuenschten Boxnamen. Es fragt einmal nach dem bisherigen
root-Passwort, wenn der gemeinsame Receiver-SSH-Schluessel noch nicht auf der
Box liegt. Danach wird der NetBird Setup-Key verdeckt abgefragt. Es erkennt
ARM-, MIPS- und weitere unterstuetzte
Architekturen automatisch, kontrolliert die offizielle SHA-256-Pruefsumme,
installiert TUN und den Autostart und wartet auf `Management: Connected`.
Abschliessend wird die vergebene NetBird-IP automatisch in `boxes.csv`
eingetragen. Ohne `-Version` wird die neueste stabile Version installiert.

## Einmalige Vorbereitung

PowerShell im Verzeichnis dieser Dateien oeffnen und ausfuehren:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install-ReceiverSshKey.ps1
```

Bei jeder Box muss einmal das bisherige root-Passwort eingegeben werden. Das
Passwort wird weder gespeichert noch in `boxes.csv` eingetragen.

Eine einzelne Box kann so vorbereitet werden:

```powershell
.\Install-ReceiverSshKey.ps1 -BoxName box-bodo
```

## Erst eine Testbox aktualisieren

Bei einer neuen NetBird-Version immer zuerst nur eine Box aktualisieren:

```powershell
.\Update-NetBirdReceivers.ps1 -Version 0.78.2 -BoxName box-bodo
```

Wenn die Testbox wieder `Management: Connected` meldet, folgen alle Boxen:

```powershell
.\Update-NetBirdReceivers.ps1 -Version 0.78.2
```

Boxen, auf denen diese Version bereits installiert ist, werden automatisch
uebersprungen. Mit `-Force` kann eine Version erneut installiert werden.

## Sicherheitsverhalten

- Die offiziellen Archive werden nur einmal pro Architektur heruntergeladen.
- Die SHA-256-Pruefsumme aus dem offiziellen Release wird kontrolliert.
- Die Architektur jeder Box wird vor dem Upload automatisch erkannt.
- Die bisherige Binaerdatei wird auf der Box gesichert.
- Die Boxen werden nacheinander aktualisiert.
- Wenn nach dem Neustart kein NetBird-Socket erscheint, erfolgt auf der Box ein
  automatischer Rollback auf die vorherige Binaerdatei.
- Das Skript wartet nach jedem Neustart auf `Management: Connected`.
- Ergebnisse werden als CSV im Unterordner `logs` gespeichert.

## Inventar pflegen

Neue Boxen werden in `boxes.csv` ergaenzt:

```csv
Name,IP
box-beispiel,100.64.0.10
```

Der Name muss eindeutig sein. Die IP ist die NetBird-IP des Receivers.
