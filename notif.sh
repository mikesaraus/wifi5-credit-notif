#!/bin/sh
# Wifi5Soft Log Notification @Telegram

# Resolve directory of this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env file
[ -f "$SCRIPT_DIR/.env" ] && . "$SCRIPT_DIR/.env"

# Set CHAT_ID and BOT_TOKEN via .env
CHAT_ID="${CHAT_ID:-}"
BOT_TOKEN="${BOT_TOKEN:-}"

DEBUG=${DEBUG:-0}

# Logging functions
debug_log() {
    [ $DEBUG -eq 1 ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /var/log/notif.log
}
system_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /var/log/notif.log
}

# Constants
WIFI5="/mnt/wifi5"
LOG_DIR="$WIFI5/mainlogs"
VENDO_CONFIG="$WIFI5/config/vendo.json"
SALES_FILE="$WIFI5/sales/list"
INACTIVITY=2
MAX_BUFFER_AGE=30

# Initialize
system_log "Script started"
system_log "SCRIPT_DIR: $SCRIPT_DIR"
system_log "LOG_DIR: $LOG_DIR"

# Telegram send
send_telegram() {
    [ -z "$1" ] && return
    local MSG ENC URL
    MSG=$(printf "%b" "$1")
    ENC=$(printf "%s" "$MSG" | sed ':a;N;$!ba;s/\n/%0A/g')
    ENC=$(printf "%s" "$ENC" \
        | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/!/%21/g' \
              -e 's/:/%3A/g' -e 's/,/%2C/g' -e 's/&/%26/g')
    ENC=$(printf "%s" "$ENC" | sed 's/%250A/%0A/g')
    URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

    system_log "Sending Telegram message: ${ENC:0:100}..."
    for i in 1 2 3; do
        if wget -T 10 -qO- --post-data="chat_id=${CHAT_ID}&text=${ENC}" "$URL" >/dev/null 2>&1; then
            system_log "Message sent successfully"
            return 0
        else
            system_log "Send attempt $i failed"
            sleep 2
        fi
    done
    system_log "All send attempts failed"
    return 1
}

# Helpers
get_logfile() { date +$LOG_DIR/voucher-%d-%m-%Y.txt; }

time_to_sec() {
    local hhmmss=$1 ampm=$2 h m s
    IFS=: read h m s <<EOF
$hhmmss
EOF
    h="${h##0}"; [ -z "$h" ] && h=0
    m="${m##0}"; [ -z "$m" ] && m=0
    s="${s##0}"; [ -z "$s" ] && s=0
    [ "$ampm" = "pm" ] && [ $h -lt 12 ] && h=$((h+12))
    [ "$ampm" = "am" ] && [ $h -eq 12 ] && h=0
    echo $((h*3600 + m*60 + s))
}

# Flush buffer
flush_buffer() {
    [ -z "$buffer" ] && return
    system_log "Flushing buffer for ID: $current_id"

    local new_lines="" latest_ts=0
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        debug_log "Processing line: '$l'"
        if [ "${l:2:1}" = ":" ]; then
            time_part="${l%% *}"
            ampm_part="${l#* }"; ampm_part="${ampm_part%% *}"
            sec=$(time_to_sec "$time_part" "$ampm_part")
            if [ $last_sent_time_sec -eq 0 ] || [ $sec -gt $last_sent_time_sec ]; then
                new_lines="${new_lines}${l}\n"
                latest_ts=$sec
                debug_log "INCLUDING line (newer timestamp)"
            else
                debug_log "FILTERING OUT line (older timestamp)"
            fi
        else
            new_lines="${new_lines}${l}\n"
            debug_log "INCLUDING line (no timestamp)"
        fi
    done <<EOF
$(printf "%b" "$buffer")
EOF

    if [ -n "$new_lines" ]; then
        local user_info vendo_name title sales_info today sales_today name
        local basefile="$WIFI5/base-id/$current_id"
        if [ -f "$basefile" ] && [ -r "$basefile" ]; then
            name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p;q' "$basefile")
            [ -n "$name" ] && user_info="Client: $name (U-$current_id)\n"
        else
            system_log "Basefile not found: $basefile"
        fi
        [ -z "$user_info" ] && [ -n "$current_id" ] && user_info="Client: U-$current_id\n"

        if [ -f "$VENDO_CONFIG" ] && [ -r "$VENDO_CONFIG" ]; then
            vendo_name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p;q' "$VENDO_CONFIG")
        else
            vendo_name="*"
            system_log "Vendo config not found: $VENDO_CONFIG"
        fi

        title="🛜 ${vendo_name} - Vendo Update"
        if printf "%s" "$new_lines" | grep -qi 'expired'; then
            title="📴 ${vendo_name} - Session Expired"
        elif printf "%s" "$new_lines" | grep -qi 'Deducted Point'; then
            title="🎁 ${vendo_name} - Points Redeemed"
        elif printf "%s" "$new_lines" | grep -qi 'Trial Login'; then
            title="⌛ ${vendo_name} - Trial Login"
        else
            today=$(date +%d-%m-%Y)
            sales_today="0"
            if [ -f "$SALES_FILE" ] && [ -r "$SALES_FILE" ]; then
                sales_today=$(sed -n "s/.*\"$today\":\([0-9]\+\).*/\1/p" "$SALES_FILE")
                [ -z "$sales_today" ] && sales_today="0"
            else
                system_log "Sales file not found: $SALES_FILE"
            fi
            sales_info="\n💡 Total Sales Today: ₱ ${sales_today}.00"
        fi

        if send_telegram "${title}\n${user_info}${new_lines%\\n}${sales_info}${ngrok_info}"; then
            [ $latest_ts -gt 0 ] && last_sent_time_sec=$latest_ts
            system_log "Buffer flushed successfully"
        else
            system_log "Buffer flush FAILED"
        fi
    else
        system_log "No new lines to send"
    fi
    buffer=""
}

cleanup() {
    system_log "Caught termination, flushing buffer..."
    flush_buffer
    exit 0
}

trap cleanup INT TERM EXIT

# Main
current_id=""
buffer=""
last_time=$(date +%s)
last_sent_time_sec=0

LOGFILE=$(get_logfile)
system_log "Initial logfile: $LOGFILE"
system_log "Entering main loop"

check_timeouts() {
    local interval=$(( INACTIVITY < MAX_BUFFER_AGE ? INACTIVITY : MAX_BUFFER_AGE ))
    while true; do
        now=$(date +%s)
        # Flush checks
        if [ -n "$buffer" ]; then
            if [ $((now - last_time)) -ge $INACTIVITY ]; then
                system_log "Inactivity flush triggered"
                flush_buffer; current_id=""
            elif [ $((now - last_time)) -ge $MAX_BUFFER_AGE ]; then
                system_log "Max buffer age flush triggered"
                flush_buffer; current_id=""
            fi
        fi
        sleep $interval
    done
}

# Start timeout checker in background
check_timeouts &

# Read logfile with process substitution
while read -r line; do
    now=$(date +%s)
    id=$(echo "$line" | sed -n 's/.*ID: \([^ ]*\).*/\1/p')
    debug_log "New line: ${line:0:50}..., ID: $id"

    ngrok_info=""
    ngrok_url=$(wget -T 5 -qO- http://127.0.0.1:4040/api/tunnels 2>/dev/null \
        | grep -o '"public_url":"[^"]*"' | cut -d'"' -f4 | head -n1)
    if [ -n "$ngrok_url" ]; then
        ngrok_info="\n🔗 ${ngrok_url}"
        debug_log "NGROK URL: $ngrok_url"
    else
        system_log "NGROK not available"
    fi

    cleaned=$(echo "$line" | sed 's/^.* [0-9A-Za-z:]\{17\} //')
    if [ -z "$current_id" ]; then
        current_id="$id"
        buffer="$cleaned"
        system_log "New session started with ID: $current_id"
    elif [ "$id" = "$current_id" ]; then
        buffer="${buffer}\n${cleaned}"
        debug_log "Added to buffer for ID: $current_id"
    else
        system_log "ID changed from $current_id to $id, flushing buffer"
        flush_buffer
        current_id="$id"
        buffer="$cleaned"
    fi

    last_time=$now
done < <(tail -n0 -F "$LOGFILE")

