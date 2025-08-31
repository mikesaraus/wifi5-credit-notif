#!/bin/sh
# Simple notif.sh updater with automatic service creation

SCRIPT_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
NOTIF="$SCRIPT_DIR/notif.sh"
SERVICE_FILE="/etc/init.d/notif"

# Function to create init.d service
create_service() {
    echo "Creating notif service..."
    cat > "$SERVICE_FILE" << 'EOF'
#!/bin/sh /etc/rc.common
# notif.sh daemon service
# Auto-created by update.sh

START=99
STOP=10

EXTRA_COMMANDS="status"
EXTRA_HELP="    status  Check if notif.sh is running"

start() {
    echo "Starting notif.sh"
    /path/to/notif.sh >/dev/null 2>&1 &
    echo $! > /var/run/notif.pid
    echo "Started with PID: $!"
}

stop() {
    echo "Stopping notif.sh"
    [ -f /var/run/notif.pid ] && {
        pid=$(cat /var/run/notif.pid)
        kill $pid 2>/dev/null
        rm -f /var/run/notif.pid
        echo "Stopped PID: $pid"
    }
    killall notif.sh 2>/dev/null && echo "Cleaned up stray processes"
}

restart() {
    stop
    sleep 2
    start
}

status() {
    if [ -f /var/run/notif.pid ]; then
        pid=$(cat /var/run/notif.pid)
        if kill -0 $pid 2>/dev/null; then
            echo "notif.sh is running with PID: $pid"
            return 0
        else
            echo "notif.sh PID file exists but process is dead (PID: $pid)"
            rm -f /var/run/notif.pid
            return 1
        fi
    else
        if pgrep -f "notif.sh" >/dev/null; then
            echo "notif.sh is running but no PID file found"
            echo "Running PIDs: $(pgrep -f 'notif.sh' | tr '\n' ' ')"
            return 0
        else
            echo "notif.sh is not running"
            return 3
        fi
    fi
}
EOF

    # Update the path in the service file
    sed -i "s|/path/to/notif.sh|$NOTIF|g" "$SERVICE_FILE"
    
    chmod +x "$SERVICE_FILE"
    echo "Service created at $SERVICE_FILE"
}

# Parse command line arguments
FORCE_NEW_SERVICE=0
for arg in "$@"; do
    case "$arg" in
        --new-service)
            FORCE_NEW_SERVICE=1
            ;;
        --help|-h)
            echo "Usage: $0 [--new-service]"
            echo "  --new-service  Force recreate the service file"
            exit 0
            ;;
    esac
done

# Handle service creation
if [ "$FORCE_NEW_SERVICE" -eq 1 ]; then
    echo "Force recreating service file..."
    create_service
    echo "Enabling notif service to start on boot..."
    /etc/init.d/notif enable
elif [ ! -f "$SERVICE_FILE" ]; then
    create_service
    echo "Enabling notif service to start on boot..."
    /etc/init.d/notif enable
fi

echo "Stopping notif service..."
/etc/init.d/notif stop 2>/dev/null || echo "Service not running or already stopped"

echo "Downloading new notif.sh..."
wget -O "$NOTIF.tmp" https://raw.githubusercontent.com/mikesaraus/wifi5-log-notif/refs/heads/main/notif.sh

if [ $? -eq 0 ]; then
    mv "$NOTIF.tmp" "$NOTIF"
    chmod +x "$NOTIF"
    echo "Download successful"
else
    echo "Download failed, keeping existing version"
    rm -f "$NOTIF.tmp" 2>/dev/null
fi

echo "Starting notif service..."
/etc/init.d/notif start

echo "Update completed"
