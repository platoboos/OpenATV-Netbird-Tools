#!/bin/sh
set -eu

ARCHIVE='/usr/lib/netbird-runtime/netbird.tar.gz'
RUNTIME_DIR='/tmp/netbird-runtime'
RUNTIME_BIN="$RUNTIME_DIR/netbird"

if [ ! -r "$ARCHIVE" ]; then
    echo "NetBird-Laufzeitarchiv fehlt: $ARCHIVE" >&2
    exit 1
fi

if [ ! -x "$RUNTIME_BIN" ] || [ "$ARCHIVE" -nt "$RUNTIME_BIN" ]; then
    rm -rf "$RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR"
    tar -xzf "$ARCHIVE" -C "$RUNTIME_DIR"
    [ -f "$RUNTIME_BIN" ] || {
        echo 'NetBird-Binaerdatei fehlt im Laufzeitarchiv.' >&2
        exit 1
    }
    chmod 755 "$RUNTIME_BIN"
fi

exec "$RUNTIME_BIN" "$@"
