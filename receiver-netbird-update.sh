#!/bin/sh

set -u

VERSION="${1:-}"
ARCHIVE='/tmp/netbird-update.tar.gz'
WORKDIR="/tmp/netbird-update.$$"
RESULT='/tmp/netbird-update-result.log'
LOCKDIR='/tmp/netbird-update.lock'
LOWFLASH_ARCHIVE='/usr/lib/netbird-runtime/netbird.tar.gz'

fail() {
    echo "UPDATE_ERROR: $*" >&2
    exit 1
}

[ -n "$VERSION" ] || fail 'Versionsnummer fehlt'
[ -f "$ARCHIVE" ] || fail "$ARCHIVE fehlt"
[ -x /usr/bin/netbird ] || fail '/usr/bin/netbird fehlt'
[ -x /etc/init.d/netbird ] || fail '/etc/init.d/netbird fehlt'

mkdir "$LOCKDIR" 2>/dev/null || fail 'Auf dieser Box laeuft bereits ein NetBird-Update'
trap 'rm -rf "$WORKDIR" "$LOCKDIR"' EXIT INT TERM

# Ueberreste abgebrochener alter Update-Laeufe entfernen. Diese liegen nur
# unter /tmp und enthalten keine NetBird-Konfiguration.
for stale_workdir in /tmp/netbird-update.*; do
    [ -d "$stale_workdir" ] && [ "$stale_workdir" != "$WORKDIR" ] && [ "$stale_workdir" != "$LOCKDIR" ] && rm -rf "$stale_workdir"
done

if [ ! -c /dev/net/tun ]; then
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tun 2>/dev/null || true
    elif [ -x /sbin/modprobe ]; then
        /sbin/modprobe tun 2>/dev/null || true
    fi
fi
[ -c /dev/net/tun ] || fail 'TUN-Geraet /dev/net/tun ist nicht vorhanden'
mkdir -p /var/log/netbird /var/lib/netbird /var/run || fail 'NetBird-Verzeichnisse konnten nicht angelegt werden'
touch /var/log/netbird/netbird.log /var/log/netbird/netbird.err 2>/dev/null || true

if [ -f "$LOWFLASH_ARCHIVE" ]; then
    INSTALL_MODE='lowflash'
    # Das Archiv wurde auf dem Windows-Rechner bereits gegen die offizielle
    # SHA256-Datei geprueft. Auf Low-Flash-Boxen wird es hier nicht zusaetzlich
    # entpackt und ausgefuehrt, da zwei grosse MIPS-Binaerdateien gleichzeitig
    # den knappen RAM unnoetig belasten wuerden.
    tar -tzf "$ARCHIVE" 2>/dev/null | grep -qx 'netbird' || fail 'NetBird-Archiv ist ungueltig'
    OLD_VERSION='lowflash'
    BACKUP="/tmp/netbird-archive-backup-${OLD_VERSION}.$$.tar.gz"
    cp "$LOWFLASH_ARCHIVE" "$BACKUP" || fail 'Backup des bisherigen Laufzeitarchivs fehlgeschlagen'
    mkdir -p "$(dirname "$LOWFLASH_ARCHIVE")"
    cp "$ARCHIVE" "${LOWFLASH_ARCHIVE}.new" || fail 'Neues Laufzeitarchiv konnte nicht kopiert werden'
    mv -f "${LOWFLASH_ARCHIVE}.new" "$LOWFLASH_ARCHIVE" || fail 'Laufzeitarchiv konnte nicht ausgetauscht werden'
    rm -rf /tmp/netbird-runtime
else
    INSTALL_MODE='standard'
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR" || fail 'Temporaeres Verzeichnis konnte nicht angelegt werden'
    tar -xzf "$ARCHIVE" -C "$WORKDIR" || fail 'Archiv konnte nicht entpackt werden'
    [ -x "$WORKDIR/netbird" ] || chmod 755 "$WORKDIR/netbird"

    NEW_VERSION="$($WORKDIR/netbird version 2>/dev/null | tail -n 1)"
    case "$NEW_VERSION" in
        *"$VERSION"*) ;;
        *) fail "Neue Binaerdatei meldet unerwartete Version: $NEW_VERSION" ;;
    esac

    OLD_VERSION="$(/usr/bin/netbird version 2>/dev/null | tail -n 1 | tr -cd '0-9A-Za-z._-')"
    [ -n "$OLD_VERSION" ] || OLD_VERSION='unknown'
    BACKUP="/tmp/netbird-backup-${OLD_VERSION}.$$"

    # Alte Update-Artefakte duerfen den kleinen Receiver-Flash nicht fuellen.
    rm -f /usr/bin/netbird.backup-* /usr/bin/netbird.rollback /usr/bin/netbird.new
    cp /usr/bin/netbird "$BACKUP" || fail 'Backup der bisherigen Binaerdatei fehlgeschlagen'

    # Die laufende Binaerdatei ist bereits sicher in /tmp gesichert. Erst durch
    # das Entfernen wird auf kleinen Flash-Dateisystemen Platz fuer die neue
    # Datei frei. Der laufende Prozess bleibt bis zum Neustart funktionsfaehig.
    rm -f /usr/bin/netbird || fail 'Bisherige Binaerdatei konnte nicht geloescht werden'
    restore_before_restart() {
        rm -f /usr/bin/netbird /usr/bin/netbird.new
        cp "$BACKUP" /usr/bin/netbird
        chmod 755 /usr/bin/netbird
    }

    if ! cp "$WORKDIR/netbird" /usr/bin/netbird.new; then
        restore_before_restart
        fail 'Neue Binaerdatei konnte nicht kopiert werden; alte Version wurde wiederhergestellt'
    fi
    if ! chmod 755 /usr/bin/netbird.new; then
        restore_before_restart
        fail 'chmod fuer neue Binaerdatei fehlgeschlagen; alte Version wurde wiederhergestellt'
    fi
    if ! mv -f /usr/bin/netbird.new /usr/bin/netbird; then
        restore_before_restart
        fail 'Austausch der Binaerdatei fehlgeschlagen; alte Version wurde wiederhergestellt'
    fi
fi

cat > /tmp/netbird-finish-update.sh <<EOF
#!/bin/sh
sleep 3
mkdir -p /var/log/netbird /var/lib/netbird /var/run
if [ ! -c /dev/net/tun ]; then
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tun 2>/dev/null || true
    elif [ -x /sbin/modprobe ]; then
        /sbin/modprobe tun 2>/dev/null || true
    fi
fi
/etc/init.d/netbird restart

i=0
# Sehr alte MIPS-Receiver mit wenig RAM benoetigen nach einem groesseren
# NetBird-Update teilweise deutlich mehr als 60 Sekunden, bis der Socket
# erscheint. Vier Minuten verhindern einen verfruehten Rollback.
while [ \$i -lt 48 ]; do
    sleep 5
    if [ -S /var/run/netbird.sock ]; then
        echo "UPDATE_OK: $VERSION" > "$RESULT"
        rm -f "$BACKUP" "$ARCHIVE"
        exit 0
    fi
    i=\$((i + 1))
done

echo 'Neuer Dienst kam nicht zurueck; Rollback wird ausgefuehrt.' > "$RESULT"
if [ "$INSTALL_MODE" = 'lowflash' ]; then
    rm -f "$LOWFLASH_ARCHIVE" "${LOWFLASH_ARCHIVE}.new"
    cp "$BACKUP" "$LOWFLASH_ARCHIVE"
    rm -rf /tmp/netbird-runtime
else
    rm -f /usr/bin/netbird /usr/bin/netbird.rollback
    cp "$BACKUP" /usr/bin/netbird.rollback
    chmod 755 /usr/bin/netbird.rollback
    mv -f /usr/bin/netbird.rollback /usr/bin/netbird
fi
/etc/init.d/netbird restart
sleep 8
if [ -S /var/run/netbird.sock ]; then
    echo 'ROLLBACK_OK' >> "$RESULT"
else
    echo 'ROLLBACK_FAILED' >> "$RESULT"
fi
rm -f "$BACKUP" "$ARCHIVE"
EOF

chmod 700 /tmp/netbird-finish-update.sh
: > "$RESULT"
nohup sh /tmp/netbird-finish-update.sh >/tmp/netbird-finish-update.nohup 2>&1 </dev/null &

rm -rf "$WORKDIR"
echo "UPDATE_SCHEDULED: $OLD_VERSION -> $VERSION"
exit 0
