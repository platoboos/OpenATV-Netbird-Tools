#!/bin/sh

DAEMON="/usr/bin/netbird"
PIDFILE="/var/run/netbird.pid"
SOCKET="/var/run/netbird.sock"
LOGFILE="/var/log/netbird/client.log"

running_pids() {
    PIDS=''
    if [ -s "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE")"
        if kill -0 "$PID" 2>/dev/null; then
            PIDS="$PID"
        fi
    fi
    if command -v pidof >/dev/null 2>&1; then
        for PID in $(pidof netbird 2>/dev/null); do
            case " $PIDS " in
                *" $PID "*) ;;
                *) PIDS="$PIDS $PID" ;;
            esac
        done
    fi
    echo "$PIDS"
}

start_netbird() {
    modprobe tun 2>/dev/null || true
    mkdir -p /var/run /var/log/netbird /var/lib/netbird

    PIDS="$(running_pids)"
    if [ -n "$PIDS" ]; then
        PID="$(echo "$PIDS" | awk '{print $1}')"
        echo "$PID" > "$PIDFILE"
        echo "NetBird laeuft bereits mit PID $PID."
        return 0
    fi

    rm -f "$PIDFILE" "$SOCKET"
    echo "NetBird wird gestartet..."
    if command -v start-stop-daemon >/dev/null 2>&1; then
        start-stop-daemon -S -b -m -p "$PIDFILE" -x "$DAEMON" -- \
            service run \
            --daemon-addr unix:///var/run/netbird.sock \
            --log-file "$LOGFILE"
    else
        nohup "$DAEMON" service run \
            --daemon-addr unix:///var/run/netbird.sock \
            --log-file "$LOGFILE" \
            >>/var/log/netbird/netbird.err 2>&1 </dev/null &
        echo $! > "$PIDFILE"
    fi

    sleep 10
    if [ -S "$SOCKET" ] && [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "NetBird wurde gestartet."
        return 0
    fi

    echo "Fehler: NetBird-Socket wurde nicht erstellt."
    return 1
}

stop_netbird() {
    echo "NetBird wird beendet..."
    PIDS="$(running_pids)"
    if [ -n "$PIDS" ]; then
        if command -v start-stop-daemon >/dev/null 2>&1; then
            [ -s "$PIDFILE" ] && start-stop-daemon -K -p "$PIDFILE" 2>/dev/null || true
        else
            kill $PIDS 2>/dev/null || true
        fi
        i=0
        while [ -n "$(running_pids)" ] && [ "$i" -lt 10 ]; do
            sleep 1
            i=$((i + 1))
        done
        PIDS="$(running_pids)"
        [ -n "$PIDS" ] && kill -9 $PIDS 2>/dev/null || true
    fi
    rm -f "$PIDFILE" "$SOCKET"
}

status_netbird() {
    PIDS="$(running_pids)"
    if [ -n "$PIDS" ]; then
        PID="$(echo "$PIDS" | awk '{print $1}')"
        echo "$PID" > "$PIDFILE"
        echo "NetBird laeuft mit PID $PID."
        return 0
    fi
    echo "NetBird laeuft nicht."
    return 1
}

case "$1" in
    start) start_netbird ;;
    stop) stop_netbird ;;
    restart) stop_netbird; start_netbird ;;
    status) status_netbird ;;
    *) echo "Verwendung: $0 {start|stop|restart|status}"; exit 1 ;;
esac
