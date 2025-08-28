#!/bin/sh
# Manage notif.sh process and updates

SCRIPT_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
NOTIF="$SCRIPT_DIR/notif.sh"

AUTO_KILL=0
[ "$1" = "--auto-kill" ] && AUTO_KILL=1

if [ "$AUTO_KILL" -eq 1 ]; then
    echo "=== Auto-killing $NOTIF processes ==="
    for pid in $(ps | grep "$NOTIF" | grep -v "grep" | awk '{print $1}'); do
        kill "$pid" 2>/dev/null && echo "Killed PID $pid"
    done
else
    echo "=== Current notif.sh processes ==="
    ps | grep "notif.sh" | grep -v "grep"

    echo ""
    echo -n "Enter PID to kill (or press Enter to skip): "
    read pid

    if [ ! -z "$pid" ]; then
        kill "$pid" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "Process $pid killed."
        else
            echo "Failed to kill process $pid (maybe invalid PID?)."
        fi
    else
        echo "No PID entered. Skipping kill step."
    fi
fi

echo ""
echo "Downloading new notif.sh..."
wget -O "$NOTIF" https://raw.githubusercontent.com/mikesaraus/wifi5-log-notif/refs/heads/main/notif.sh

if [ $? -eq 0 ]; then
    chmod +x "$NOTIF"
    echo "Running new notif.sh in background..."
    /bin/sh "$NOTIF" &
    echo "Started with PID $!"
else
    echo "Download failed!"
fi
