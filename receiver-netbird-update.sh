#!/bin/sh

set -u

VERSION="${1:-}"
BINARY_SHA256="${2:-}"
ARCHIVE='/tmp/netbird-update.tar.gz'
XZ_UPDATE='/tmp/netbird-update.xz'
XZ_WRAPPER='/tmp/netbird-lowflash-xz-wrapper.sh'
WORKDIR="/tmp/netbird-update.$$"
RESULT='/tmp/netbird-update-result.log'
LOCKDIR='/tmp/netbird-update.lock'
LOWFLASH_ARCHIVE='/usr/lib/netbird-runtime/netbird.tar.gz'
LOWFLASH_XZ_ARCHIVE='/usr/lib/netbird-runtime/netbird.xz'
WRAPPER_BACKUP=''

fail() {
    echo "UPDATE_ERROR: $*" >&2
    exit 1
}

[ -n "$VERSION" ] || fail 'Versionsnummer fehlt'
[ -x /usr/bin/netbird ] || fail '/usr/bin/netbird fehlt'
[ -x /etc/init.d/netbird ] || fail '/etc/init.d/netbird fehlt'

if [ -f "$LOWFLASH_XZ_ARCHIVE" ]; then
    INSTALL_MODE='lowflash-xz'
    [ -f "$XZ_UPDATE" ] || fail "$XZ_UPDATE fehlt"
    [ -f "$XZ_WRAPPER" ] || fail "$XZ_WRAPPER fehlt"
    [ -n "$BINARY_SHA256" ] || fail 'Pruefsumme der XZ-Binaerdatei fehlt'
elif [ -f "$LOWFLASH_ARCHIVE" ]; then
    INSTALL_MODE='lowflash-tar'
    [ -f "$ARCHIVE" ] || fail "$ARCHIVE fehlt"
else
    INSTALL_MODE='standard'
    [ -f "$ARCHIVE" ] || fail "$ARCHIVE fehlt"
fi

mkdir "$LOCKDIR" 2>/dev/null || fail 'Auf dieser Box laeuft bereits ein NetBird-Update'
trap 'rm -rf "$WORKDIR" "$LOCKDIR"' EXIT INT TERM

# Ueberreste abgebrochener alter Update-Laeufe entfernen. Diese liegen nur
# unter /tmp und enthalten keine NetBird-Konfiguration.
for stale_workdir in /tmp/netbird-update.*; do
    [ -d "$stale_workdir" ] && [ "$stale_workdir" != "$WORKDIR" ] && [ "$stale_workdir" != "$LOCKDIR" ] && rm -rf "$stale_workdir"
done
# Abgebrochene Low-Flash-Laeufe koennen eine fast vollstaendige Archivkopie
# im kleinen RAM-Dateisystem hinterlassen. Da der Lock fuer diesen Lauf bereits
# exklusiv gehalten wird, gehoeren vorhandene Backup-Dateien sicher zu einem
# frueheren Lauf und duerfen vor dem neuen Backup entfernt werden.
rm -f /tmp/netbird-archive-backup-*.tar.gz /tmp/netbird-xz-backup-*.xz /tmp/netbird-wrapper-backup-* /tmp/netbird-backup-* 2>/dev/null || true

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

if [ "$INSTALL_MODE" = 'lowflash-xz' ]; then
    command -v unxz >/dev/null 2>&1 || fail 'unxz fehlt fuer den Low-Flash-XZ-Modus'
    ACTUAL_BINARY_SHA256="$(unxz -c "$XZ_UPDATE" 2>/dev/null | sha256sum | awk '{print $1}')"
    [ "$ACTUAL_BINARY_SHA256" = "$BINARY_SHA256" ] || fail 'Pruefsumme der entpackten XZ-Binaerdatei stimmt nicht'

    OLD_VERSION="$(/usr/bin/netbird version 2>/dev/null | tail -n 1 | tr -cd '0-9A-Za-z._-')"
    [ -n "$OLD_VERSION" ] || OLD_VERSION='unknown'
    BACKUP="/tmp/netbird-xz-backup-${OLD_VERSION}.$$.xz"
    WRAPPER_BACKUP="/tmp/netbird-wrapper-backup-${OLD_VERSION}.$$"
    cp "$LOWFLASH_XZ_ARCHIVE" "$BACKUP" || fail 'Backup des bisherigen XZ-Laufzeitarchivs fehlgeschlagen'
    cp /usr/bin/netbird "$WRAPPER_BACKUP" || fail 'Backup des bisherigen XZ-Starters fehlgeschlagen'

    restore_xz_before_restart() {
        rm -f "$LOWFLASH_XZ_ARCHIVE" "${LOWFLASH_XZ_ARCHIVE}.new"
        cp "$BACKUP" "$LOWFLASH_XZ_ARCHIVE" 2>/dev/null || true
        cp "$WRAPPER_BACKUP" /usr/bin/netbird 2>/dev/null || true
        chmod 755 /usr/bin/netbird 2>/dev/null || true
    }

    mkdir -p "$(dirname "$LOWFLASH_XZ_ARCHIVE")"
    rm -f "${LOWFLASH_XZ_ARCHIVE}.new"
    rm -f "$LOWFLASH_XZ_ARCHIVE"
    if ! cp "$XZ_UPDATE" "${LOWFLASH_XZ_ARCHIVE}.new"; then
        restore_xz_before_restart
        fail 'Neues XZ-Laufzeitarchiv konnte nicht kopiert werden; altes Archiv wurde wiederhergestellt'
    fi
    if ! mv -f "${LOWFLASH_XZ_ARCHIVE}.new" "$LOWFLASH_XZ_ARCHIVE"; then
        restore_xz_before_restart
        fail 'XZ-Laufzeitarchiv konnte nicht aktiviert werden; altes Archiv wurde wiederhergestellt'
    fi
    if ! cp "$XZ_WRAPPER" /usr/bin/netbird || ! chmod 755 /usr/bin/netbird; then
        restore_xz_before_restart
        fail 'Low-Flash-XZ-Starter konnte nicht installiert werden; alte Version wurde wiederhergestellt'
    fi
    rm -rf /tmp/netbird-runtime
elif [ "$INSTALL_MODE" = 'lowflash-tar' ]; then
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
        CURRENT_VERSION="\$(/usr/bin/netbird version 2>/dev/null | tail -n 1 || true)"
        CURRENT_STATUS="\$(/usr/bin/netbird status 2>/dev/null || true)"
        case "\$CURRENT_VERSION" in
            *"$VERSION"*)
                if printf '%s\n' "\$CURRENT_STATUS" | grep -q 'Management:[[:space:]]*Connected'; then
                    echo "UPDATE_OK: $VERSION" > "$RESULT"
                    rm -f "$BACKUP" "$ARCHIVE" "$XZ_UPDATE" "$XZ_WRAPPER" ${WRAPPER_BACKUP:-}
                    exit 0
                fi
                ;;
        esac
    fi
    i=\$((i + 1))
done

echo 'Neuer Dienst kam nicht zurueck; Rollback wird ausgefuehrt.' > "$RESULT"
case "$INSTALL_MODE" in
    lowflash-xz)
        rm -f "$LOWFLASH_XZ_ARCHIVE" "${LOWFLASH_XZ_ARCHIVE}.new"
        cp "$BACKUP" "$LOWFLASH_XZ_ARCHIVE"
        if [ -n "${WRAPPER_BACKUP:-}" ] && [ -f "$WRAPPER_BACKUP" ]; then
            cp "$WRAPPER_BACKUP" /usr/bin/netbird
            chmod 755 /usr/bin/netbird
        fi
        rm -rf /tmp/netbird-runtime
        ;;
    lowflash-tar)
        rm -f "$LOWFLASH_ARCHIVE" "${LOWFLASH_ARCHIVE}.new"
        cp "$BACKUP" "$LOWFLASH_ARCHIVE"
        rm -rf /tmp/netbird-runtime
        ;;
    *)
        rm -f /usr/bin/netbird /usr/bin/netbird.rollback
        cp "$BACKUP" /usr/bin/netbird.rollback
        chmod 755 /usr/bin/netbird.rollback
        mv -f /usr/bin/netbird.rollback /usr/bin/netbird
        ;;
esac
/etc/init.d/netbird restart
sleep 8
if [ -S /var/run/netbird.sock ]; then
    echo 'ROLLBACK_OK' >> "$RESULT"
else
    echo 'ROLLBACK_FAILED' >> "$RESULT"
fi
rm -f "$BACKUP" "$ARCHIVE" "$XZ_UPDATE" "$XZ_WRAPPER" ${WRAPPER_BACKUP:-}
EOF

[ -s /tmp/netbird-finish-update.sh ] || fail 'Neustart-Helfer konnte nicht erzeugt werden'
chmod 700 /tmp/netbird-finish-update.sh
: > "$RESULT"
nohup sh /tmp/netbird-finish-update.sh >/tmp/netbird-finish-update.nohup 2>&1 </dev/null &

rm -rf "$WORKDIR"
echo "UPDATE_SCHEDULED: $OLD_VERSION -> $VERSION"
exit 0
