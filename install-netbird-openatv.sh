#!/bin/sh

set -u

VERSION="${1:-}"
HOSTNAME_VALUE="${2:-}"
MANAGEMENT_URL="${3:-}"
ARCHIVE='/tmp/netbird-install.tar.gz'
WORKDIR="/tmp/netbird-install.$$"
DAEMON='/usr/bin/netbird'
INIT_SCRIPT='/etc/init.d/netbird'
DAEMON_BACKUP='/usr/bin/netbird.before-install'
INIT_BACKUP='/etc/init.d/netbird.before-install'
HAD_DAEMON=0
HAD_INIT=0
STANDALONE=0

fail() {
    echo "INSTALL_ERROR: $*" >&2
    exit 1
}

rollback() {
    echo 'Installation fehlgeschlagen; vorherigen Zustand wiederherstellen.' >&2
    if [ "$HAD_DAEMON" -eq 1 ] && [ -f "$DAEMON_BACKUP" ]; then
        cp "$DAEMON_BACKUP" "$DAEMON"
        chmod 755 "$DAEMON"
    else
        rm -f "$DAEMON"
    fi
    if [ "$HAD_INIT" -eq 1 ] && [ -f "$INIT_BACKUP" ]; then
        cp "$INIT_BACKUP" "$INIT_SCRIPT"
        chmod 755 "$INIT_SCRIPT"
    else
        rm -f "$INIT_SCRIPT"
    fi
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
    fi
}

if [ -z "$VERSION" ] && [ -z "$HOSTNAME_VALUE" ] && [ -z "$MANAGEMENT_URL" ]; then
    STANDALONE=1

    printf 'NetBird Management-URL eingeben (z.B. https://netbird.example.de): '
    IFS= read -r MANAGEMENT_URL || fail 'Management-URL konnte nicht gelesen werden'
    MANAGEMENT_URL="${MANAGEMENT_URL%/}"
    case "$MANAGEMENT_URL" in
        http://*|https://*) ;;
        *) fail 'Die Management-URL muss mit http:// oder https:// beginnen' ;;
    esac
    case "$MANAGEMENT_URL" in
        *[[:space:]]*|*'['*|*']'*|*'('*|*')'*)
            fail 'Die Management-URL enthaelt ungueltige Zeichen'
            ;;
    esac

    printf 'Wie soll die Box in NetBird heissen: '
    IFS= read -r HOSTNAME_VALUE || fail 'Boxname konnte nicht gelesen werden'
    case "$HOSTNAME_VALUE" in
        ''|*[!A-Za-z0-9-]*|-*|*-)
            fail 'Der Boxname darf nur Buchstaben, Zahlen und Bindestriche enthalten und nicht mit einem Bindestrich beginnen oder enden'
            ;;
    esac

    echo 'Neueste stabile NetBird-Version ermitteln...'
    command -v wget >/dev/null 2>&1 || fail 'wget fehlt auf der Box'
    RELEASE_JSON="$(wget -qO- 'https://api.github.com/repos/netbirdio/netbird/releases/latest')" || fail 'GitHub-Versionsabfrage fehlgeschlagen'
    VERSION="$(printf '%s\n' "$RELEASE_JSON" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n 1)"
    case "$VERSION" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) fail "Unerwartete Versionsangabe von GitHub: $VERSION" ;;
    esac
    echo "Stabile NetBird-Version: $VERSION"

    MACHINE="$(uname -m)"
    OPKG_ARCH="$(opkg print-architecture 2>/dev/null || true)"
    case "$MACHINE" in
        armv7l) PACKAGE_ARCH='armv6' ;;
        aarch64) PACKAGE_ARCH='arm64' ;;
        x86_64) PACKAGE_ARCH='amd64' ;;
        mips)
            if printf '%s\n' "$OPKG_ARCH" | grep -Eq 'mips32el|mipsel'; then
                PACKAGE_ARCH='mipsle_hardfloat'
            else
                fail "Nicht unterstuetzte MIPS-Architektur: $OPKG_ARCH"
            fi
            ;;
        *) fail "Nicht unterstuetzte Architektur: $MACHINE" ;;
    esac
    echo "Paketarchitektur: $PACKAGE_ARCH"

    ASSET="netbird_${VERSION}_linux_${PACKAGE_ARCH}.tar.gz"
    CHECKSUMS="/tmp/netbird_${VERSION}_checksums.txt"
    BASE_URL="https://github.com/netbirdio/netbird/releases/download/v$VERSION"
    rm -f "$ARCHIVE" "$CHECKSUMS"
    echo 'Offizielle Pruefsummen herunterladen...'
    wget -O "$CHECKSUMS" "$BASE_URL/netbird_${VERSION}_checksums.txt" || fail 'Pruefsummen konnten nicht heruntergeladen werden'
    echo "$ASSET herunterladen..."
    wget -O "$ARCHIVE" "$BASE_URL/$ASSET" || fail 'NetBird-Paket konnte nicht heruntergeladen werden'

    command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum fehlt auf der Box'
    EXPECTED_HASH="$(awk -v asset="$ASSET" '$2 == asset {print $1; exit}' "$CHECKSUMS")"
    [ -n "$EXPECTED_HASH" ] || fail "Keine offizielle Pruefsumme fuer $ASSET gefunden"
    ACTUAL_HASH="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
    [ "$EXPECTED_HASH" = "$ACTUAL_HASH" ] || fail 'SHA-256-Pruefsumme stimmt nicht'
    echo 'SHA-256-Pruefsumme ist korrekt.'

    printf 'NetBird Setup-Key eingeben: '
    STTY_CHANGED=0
    if command -v stty >/dev/null 2>&1 && [ -t 0 ]; then
        stty -echo
        STTY_CHANGED=1
    fi
    IFS= read -r SETUP_KEY_INPUT || {
        [ "$STTY_CHANGED" -eq 1 ] && stty echo
        echo
        fail 'Setup-Key konnte nicht gelesen werden'
    }
    if [ "$STTY_CHANGED" -eq 1 ]; then
        stty echo
    fi
    echo
else
    [ -n "$VERSION" ] || fail 'Versionsnummer fehlt'
    [ -n "$HOSTNAME_VALUE" ] || fail 'Hostname fehlt'
    [ -n "$MANAGEMENT_URL" ] || fail 'Management-URL fehlt'
    IFS= read -r SETUP_KEY_INPUT || fail 'Setup-Key konnte nicht gelesen werden'
fi

MANAGEMENT_URL="${MANAGEMENT_URL%/}"
case "$MANAGEMENT_URL" in
    http://*|https://*) ;;
    *) fail 'Die Management-URL muss mit http:// oder https:// beginnen' ;;
esac
case "$MANAGEMENT_URL" in
    *[[:space:]]*|*'['*|*']'*|*'('*|*')'*)
        fail 'Die Management-URL enthaelt ungueltige Zeichen'
        ;;
esac

[ -f "$ARCHIVE" ] || fail "$ARCHIVE fehlt"
SETUP_KEY="$(printf '%s' "$SETUP_KEY_INPUT" | grep -Eo '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -n 1)"
SETUP_KEY_INPUT=''
[ -n "$SETUP_KEY" ] || fail 'Kein gueltiger Setup-Key gefunden. Erwartet wird nur die 36-stellige UUID, zum Beispiel 12345678-1234-1234-1234-123456789abc'

if ! modprobe tun 2>/dev/null; then
    echo 'TUN-Modul installieren...'
    opkg update || fail 'opkg update fehlgeschlagen'
    opkg install kernel-module-tun || fail 'kernel-module-tun konnte nicht installiert werden'
    modprobe tun 2>/dev/null || fail 'TUN-Modul konnte nicht geladen werden'
fi

mkdir -p /dev/net /var/run /var/log/netbird /var/lib/netbird || fail 'Verzeichnisse konnten nicht angelegt werden'
[ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 || fail '/dev/net/tun konnte nicht angelegt werden'
chmod 666 /dev/net/tun
touch /etc/modules
grep -qx 'tun' /etc/modules 2>/dev/null || echo 'tun' >> /etc/modules

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR" || fail 'Arbeitsverzeichnis konnte nicht angelegt werden'
tar -xzf "$ARCHIVE" -C "$WORKDIR" || fail 'NetBird-Archiv konnte nicht entpackt werden'
[ -f "$WORKDIR/netbird" ] || fail 'NetBird-Binaerdatei fehlt im Archiv'
chmod 755 "$WORKDIR/netbird"

PACKAGE_VERSION="$($WORKDIR/netbird version 2>/dev/null | tail -n 1)"
case "$PACKAGE_VERSION" in
    *"$VERSION"*) ;;
    *) fail "Binaerdatei meldet unerwartete Version: $PACKAGE_VERSION" ;;
esac

if [ -f "$DAEMON" ]; then
    HAD_DAEMON=1
    cp "$DAEMON" "$DAEMON_BACKUP" || fail 'Vorhandene NetBird-Binaerdatei konnte nicht gesichert werden'
fi
if [ -f "$INIT_SCRIPT" ]; then
    HAD_INIT=1
    cp "$INIT_SCRIPT" "$INIT_BACKUP" || fail 'Vorhandenes Init-Skript konnte nicht gesichert werden'
fi

if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
fi

cp "$WORKDIR/netbird" "$DAEMON.new" || fail 'NetBird konnte nicht nach /usr/bin kopiert werden'
chmod 755 "$DAEMON.new"
mv -f "$DAEMON.new" "$DAEMON"

cat > "$INIT_SCRIPT" <<'INITEOF'
#!/bin/sh

DAEMON="/usr/bin/netbird"
PIDFILE="/var/run/netbird.pid"
SOCKET="/var/run/netbird.sock"
LOGFILE="/var/log/netbird/client.log"

start_netbird() {
    modprobe tun 2>/dev/null
    mkdir -p /var/run /var/log/netbird /var/lib/netbird

    if [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "NetBird läuft bereits mit PID $(cat "$PIDFILE")."
        return 0
    fi

    rm -f "$PIDFILE" "$SOCKET"
    echo "NetBird wird gestartet..."
    start-stop-daemon -S -b -m -p "$PIDFILE" -x "$DAEMON" -- \
        service run \
        --daemon-addr unix:///var/run/netbird.sock \
        --log-file "$LOGFILE"

    sleep 5
    if [ -S "$SOCKET" ]; then
        echo "NetBird wurde gestartet."
        return 0
    fi

    echo "Fehler: NetBird-Socket wurde nicht erstellt."
    return 1
}

stop_netbird() {
    echo "NetBird wird beendet..."
    if [ -s "$PIDFILE" ]; then
        start-stop-daemon -K -p "$PIDFILE" 2>/dev/null
        sleep 2
    fi
    rm -f "$PIDFILE" "$SOCKET"
}

status_netbird() {
    if [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "NetBird läuft mit PID $(cat "$PIDFILE")."
        return 0
    fi
    echo "NetBird läuft nicht."
    return 1
}

case "$1" in
    start) start_netbird ;;
    stop) stop_netbird ;;
    restart) stop_netbird; start_netbird ;;
    status) status_netbird ;;
    *) echo "Verwendung: $0 {start|stop|restart|status}"; exit 1 ;;
esac
INITEOF

chmod 755 "$INIT_SCRIPT"
if command -v update-rc.d >/dev/null 2>&1; then
    update-rc.d -f netbird remove >/dev/null 2>&1 || true
    update-rc.d netbird defaults >/dev/null 2>&1 || {
        rollback
        fail 'NetBird-Autostart konnte nicht eingerichtet werden'
    }
fi

if ! "$INIT_SCRIPT" restart; then
    rollback
    fail 'NetBird-Dienst konnte nicht gestartet werden'
fi

i=0
while [ "$i" -lt 12 ] && [ ! -S /var/run/netbird.sock ]; do
    sleep 5
    i=$((i + 1))
done
if [ ! -S /var/run/netbird.sock ]; then
    rollback
    fail 'NetBird-Socket wurde nicht erstellt'
fi

echo 'Box am NetBird-Management anmelden...'
UP_OUTPUT="$($DAEMON up --management-url "$MANAGEMENT_URL" --setup-key "$SETUP_KEY" --hostname "$HOSTNAME_VALUE" 2>&1)"
UP_EXIT=$?
SETUP_KEY=''
printf '%s\n' "$UP_OUTPUT"
if [ "$UP_EXIT" -ne 0 ]; then
    echo 'netbird up meldete einen Fehler; Verbindungsstatus wird trotzdem geprüft.' >&2
fi

i=0
LAST_STATUS=''
while [ "$i" -lt 18 ]; do
    sleep 5
    LAST_STATUS="$($DAEMON status 2>&1 || true)"
    if printf '%s\n' "$LAST_STATUS" | grep -q 'Management:[[:space:]]*Connected'; then
        NETBIRD_IP="$(printf '%s\n' "$LAST_STATUS" | awk '/NetBird IP:/ {print $3; exit}' | cut -d/ -f1)"
        echo "INSTALL_OK: $($DAEMON version 2>/dev/null | tail -n 1)"
        echo "NETBIRD_IP=$NETBIRD_IP"
        if [ "$STANDALONE" -eq 1 ]; then
            INVENTORY_NAME="$(printf '%s' "$HOSTNAME_VALUE" | tr 'A-Z' 'a-z')"
            echo "INVENTAR_EINTRAG=$INVENTORY_NAME,$NETBIRD_IP"
        fi
        printf '%s\n' "$LAST_STATUS"
        rm -rf "$WORKDIR" "$ARCHIVE" "/tmp/netbird_${VERSION}_checksums.txt"
        exit 0
    fi
    i=$((i + 1))
done

printf '%s\n' "$LAST_STATUS" >&2
fail 'Management wurde nicht als Connected gemeldet'
