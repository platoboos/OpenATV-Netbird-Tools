# OpenATV-Netbird-Tools

Diese Skripte installieren und aktualisieren den NetBird-Client auf
OpenATV-Receivern. Beim Start wird die Adresse des selbst gehosteten
Management-Servers abgefragt, zum Beispiel `https://mein.vps-server.de`.

## Direkte Installation auf einer Box

Den Installer auf der bereits per SSH geoeffneten Box herunterladen und
ausfuehren:

```sh
wget -O /tmp/install-netbird.sh https://raw.githubusercontent.com/platoboos/OpenATV-Netbird-Tools/main/install-netbird-openatv.sh
sh /tmp/install-netbird.sh
```

Das Skript fragt nach der NetBird-Management-URL, dem gewuenschten Boxnamen und
dem NetBird-Setup-Key. Die neueste stabile NetBird-Version, die Architektur,
das passende Paket, TUN und der Autostart werden automatisch behandelt. Die
offizielle SHA-256-Pruefsumme des NetBird-Pakets wird vor der Installation
kontrolliert.

Der Setup-Key ist nicht Bestandteil dieses Repositorys und wird bei der
Eingabe nicht angezeigt oder gespeichert.

## Zentrale Updates unter Windows

Die PowerShell-Helfer koennen mehrere Receiver nacheinander ueber ihre
NetBird-IP aktualisieren. `boxes.example.csv` zeigt das Format der lokalen
Inventardatei. Die echte `boxes.csv` und Update-Protokolle werden bewusst nicht
versioniert.

Weitere Einzelheiten stehen in `RECEIVER-UPDATES.md`.
