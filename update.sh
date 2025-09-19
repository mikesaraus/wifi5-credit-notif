#!/bin/sh
# Simple notif.sh updater with automatic service creation
# Adds a 23:45 sendinfo cron and removes it on --clean
# Works from any directory (dynamic path detection)

SCRIPT_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
NOTIF="$SCRIPT_DIR/notif.sh"
SERVICE_FILE="/etc/init.d/notif"

# Existing midnight restart cron (keeps previous behavior)
CRON_RESTART_CMD="$SERVICE_FILE restart"
CRON_RESTART="1 0 * * * $CRON_RESTART_CMD"

# New sendinfo cron (23:45) — uses dynamic path to notif.sh
SENDINFO_CRON_TIME="45 23 * * *"
# Use absolute NOTIF path in the cron line; redirect to /dev/null
SENDINFO_CRON="${SENDINFO_CRON_TIME} ${NOTIF} --action sendinfo >/dev/null 2>&1"

# Helper: safely get current crontab (empty string if none)
_current_cron() {
    crontab -l 2>/dev/null || true
}

# Function to setup cron jobs
setup_cron_job() {
    echo "Setting up cron jobs..."

    existing="$(_current_cron)"

    # Add restart cron if not present
    if echo "$existing" | grep -Fq "$CRON_RESTART_CMD"; then
        echo "Restart cron already exists"
    else
        echo "Adding restart cron: $CRON_RESTART"
        (echo "$existing"; echo "$CRON_RESTART") | crontab -
    fi

    # Refresh variable (in case crontab updated)
    existing="$(_current_cron)"

    # Add sendinfo cron if not present
    # Use fixed-string match for the NOTIF path to avoid false positives
    if echo "$existing" | grep -Fq "$NOTIF --action sendinfo"; then
        echo "Sendinfo cron already exists"
    else
        echo "Adding sendinfo cron: $SENDINFO_CRON"
        (echo "$existing"; echo "$SENDINFO_CRON") | crontab -
    fi

    echo "Cron setup done."
}

# Function to remove cron jobs
remove_cron_job() {
    echo "Removing cron jobs..."

    existing="$(_current_cron)"

    # If nothing in crontab, exit
    if [ -z "$existing" ]; then
        echo "No crontab for root; nothing to remove."
        return 0
    fi

    # Remove lines containing the restart command
    echo "$existing" | grep -vF "$CRON_RESTART_CMD" | grep -vF "$NOTIF --action sendinfo" | crontab -
    echo "Cron jobs removed (if they existed)."
}

# Function to clean up service and cron job
clean_service() {
    echo "=== Cleaning up notif service ==="

    # Stop service if running
    if [ -f "$SERVICE_FILE" ]; then
        echo "Stopping notif service..."
        "$SERVICE_FILE" stop 2>/dev/null || true
    fi

    # Kill any remaining processes by matching the exact NOTIF path
    echo "Killing any remaining notif processes matching $NOTIF..."
    # use pgrep -f if available, otherwise fallback to ps+grep
    if command -v pgrep >/dev/null 2>&1; then
        pids=$(pgrep -f "$NOTIF" || true)
    else
        pids="$(ps | grep "$NOTIF" | grep -v "grep" | awk '{print $1}')"
    fi
    for pid in $pids; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null && echo "Killed PID $pid"
    done

    # Disable service
    if [ -f "$SERVICE_FILE" ]; then
        echo "Disabling service..."
        "$SERVICE_FILE" disable 2>/dev/null || true
    fi

    # Remove service file
    if [ -f "$SERVICE_FILE" ]; then
        rm -f "$SERVICE_FILE"
        echo "Removed service file: $SERVICE_FILE"
    fi

    # Remove PID file
    rm -f /var/run/notif.pid 2>/dev/null && echo "Removed PID file"

    # Remove cron job
    remove_cron_job

    echo "Cleanup completed"
    exit 0
}

# Parse command line arguments
FORCE_NEW_SERVICE=0
CLEAN_SERVICE=0
NO_CRON=0

for arg in "$@"; do
    case "$arg" in
        --new-service)
            FORCE_NEW_SERVICE=1
            ;;
        --clean)
            CLEAN_SERVICE=1
            ;;
        --no-cron)
            NO_CRON=1
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --new-service    Force recreate the service file"
            echo "  --clean          Remove and disable service, remove cron job"
            echo "  --no-cron        Do not add or keep cron job"
            echo "  --help, -h       Show this help"
            exit 0
            ;;
    esac
done

# Handle clean operation
if [ "$CLEAN_SERVICE" -eq 1 ]; then
    clean_service
fi

# Handle cron job
if [ "$NO_CRON" -eq 1 ]; then
    echo "Skipping cron job setup (--no-cron specified)"
    remove_cron_job
else
    setup_cron_job
fi

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

    # Update the path in the service file to use the dynamic NOTIF
    sed -i "s|/path/to/notif.sh|$NOTIF|g" "$SERVICE_FILE"

    chmod +x "$SERVICE_FILE"
    echo "Service created at $SERVICE_FILE"
}

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

if [ "$NO_CRON" -eq 1 ]; then
    echo "Update completed (without cron job)"
else
    echo "Update completed"
    echo "Cron jobs ensured (restart at 00:01 and sendinfo at 23:45)"
fi
