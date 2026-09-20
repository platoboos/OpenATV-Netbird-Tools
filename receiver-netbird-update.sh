#!/bin/sh

set -u

VERSION="${1:-}"
ARCHIVE='/tmp/netbird-update.tar.gz'
WORKDIR="/tmp/netbird-update.$$"
RESULT='/tmp/netbird-update-result.log'

fail() {
    echo "UPDATE_ERROR: $*" >&2
    exit 1
}

[ -n "$VERSION" ] || fail 'Versionsnummer fehlt'
[ -f "$ARCHIVE" ] || fail "$ARCHIVE fehlt"
[ -x /usr/bin/netbird ] || fail '/usr/bin/netbird fehlt'
[ -x /etc/init.d/netbird ] || fail '/etc/init.d/netbird fehlt'

modprobe tun 2>/dev/null || fail 'TUN-Modul konnte nicht geladen werden'
mkdir -p /var/log/netbird /var/lib/netbird /var/run || fail 'NetBird-Verzeichnisse konnten nicht angelegt werden'
touch /var/log/netbird/netbird.log /var/log/netbird/netbird.err 2>/dev/null || true

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
BACKUP="/usr/bin/netbird.backup-${OLD_VERSION}"

cp /usr/bin/netbird "$BACKUP" || fail 'Backup der bisherigen Binaerdatei fehlgeschlagen'
cp "$WORKDIR/netbird" /usr/bin/netbird.new || fail 'Neue Binaerdatei konnte nicht kopiert werden'
chmod 755 /usr/bin/netbird.new || fail 'chmod fuer neue Binaerdatei fehlgeschlagen'
mv -f /usr/bin/netbird.new /usr/bin/netbird || fail 'Austausch der Binaerdatei fehlgeschlagen'

cat > /tmp/netbird-finish-update.sh <<EOF
#!/bin/sh
sleep 3
mkdir -p /var/log/netbird /var/lib/netbird /var/run
modprobe tun 2>/dev/null
/etc/init.d/netbird restart

i=0
while [ \$i -lt 12 ]; do
    sleep 5
    if [ -S /var/run/netbird.sock ]; then
        CURRENT="\$(/usr/bin/netbird version 2>/dev/null | tail -n 1)"
        echo "UPDATE_OK: \$CURRENT" > "$RESULT"
        exit 0
    fi
    i=\$((i + 1))
done

echo 'Neuer Dienst kam nicht zurueck; Rollback wird ausgefuehrt.' > "$RESULT"
cp "$BACKUP" /usr/bin/netbird.rollback
chmod 755 /usr/bin/netbird.rollback
mv -f /usr/bin/netbird.rollback /usr/bin/netbird
/etc/init.d/netbird restart
sleep 8
if [ -S /var/run/netbird.sock ]; then
    echo 'ROLLBACK_OK' >> "$RESULT"
else
    echo 'ROLLBACK_FAILED' >> "$RESULT"
fi
EOF

chmod 700 /tmp/netbird-finish-update.sh
: > "$RESULT"
nohup sh /tmp/netbird-finish-update.sh >/tmp/netbird-finish-update.nohup 2>&1 </dev/null &

rm -rf "$WORKDIR"
echo "UPDATE_SCHEDULED: $OLD_VERSION -> $VERSION"
exit 0
