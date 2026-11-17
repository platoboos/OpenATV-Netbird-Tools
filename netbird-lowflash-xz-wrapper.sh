#!/bin/sh

set -eu

ARCHIVE='/usr/lib/netbird-runtime/netbird.xz'
RUNTIME_DIR='/tmp/netbird-runtime'
RUNTIME_BIN="$RUNTIME_DIR/netbird"

if [ ! -r "$ARCHIVE" ]; then
    echo "NetBird-Laufzeitarchiv fehlt: $ARCHIVE" >&2
    exit 1
fi

if [ ! -x "$RUNTIME_BIN" ] || [ "$ARCHIVE" -nt "$RUNTIME_BIN" ]; then
    rm -rf "$RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR"
    unxz -c "$ARCHIVE" > "${RUNTIME_BIN}.new"
    chmod 755 "${RUNTIME_BIN}.new"
    mv -f "${RUNTIME_BIN}.new" "$RUNTIME_BIN"
fi

exec "$RUNTIME_BIN" "$@"
