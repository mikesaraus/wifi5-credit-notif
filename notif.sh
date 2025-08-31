#!/bin/sh
# Wifi5Soft Log Notification @Telegram

# Resolve directory of this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env file from same location
if [ -f "$SCRIPT_DIR/.env" ]; then
    . "$SCRIPT_DIR/.env"
fi

# Set CHAT_ID and BOT_TOKEN via .env
# CHAT_ID=""
# BOT_TOKEN=""

DEBUG=${DEBUG:-0}

# Debug logging function
debug_log() {
    [ $DEBUG -eq 1 || ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /var/log/notif.log
}

# System logging function
system_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /var/log/notif.log
}

WIFI5="/mnt/wifi5"
LOG_DIR="$WIFI5/mainlogs"
VENDO_CONFIG="$WIFI5/config/vendo.json"
SALES_FILE="$WIFI5/sales/list"

INACTIVITY=2   # seconds before flushing

debug_log "Script started"
debug_log "SCRIPT_DIR: $SCRIPT_DIR"
debug_log "LOG_DIR: $LOG_DIR"

send_telegram() {
    [ -z "$1" ] && return
    MSG=$(printf "%b" "$1")         # interpret \n
    ENC=$(printf "%s" "$MSG" | sed ':a;N;$!ba;s/\n/%0A/g')
    ENC=$(printf "%s" "$ENC" \
        | sed -e 's/%/%25/g' \
              -e 's/ /%20/g' \
              -e 's/!/%21/g' \
              -e 's/:/%3A/g' \
              -e 's/,/%2C/g' \
              -e 's/&/%26/g')
    ENC=$(printf "%s" "$ENC" | sed 's/%250A/%0A/g')

    URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
    [ $DEBUG -eq 1 ] && echo ">> Telegram: $ENC"
    debug_log "Sending Telegram message: ${ENC:0:100}..."
    
    # Add timeout and retry logic
    for i in 1 2 3; do
        if wget -T 10 -qO- --post-data="chat_id=${CHAT_ID}&text=${ENC}" "$URL" >/dev/null 2>&1; then
            debug_log "Message sent successfully"
            return 0
        else
            system_log "Send attempt $i failed"
            sleep 2
        fi
    done
    system_log "All send attempts failed"
    return 1
}

get_logfile() {
    date +$LOG_DIR/voucher-%d-%m-%Y.txt
}

# Convert "07:22:33 pm" → seconds of day
time_to_sec() {
    local hhmmss=$1 ampm=$2
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

flush_buffer() {
    [ -z "$buffer" ] && return

    debug_log "Flushing buffer for ID: $current_id"
    new_lines=""
    latest_ts=0

    while IFS= read -r l; do
        if [ "${l:2:1}" = ":" ]; then
            ts="${l%% *} ${l#*: }"
            sec=$(time_to_sec "${ts%% *}" "${ts##* }")
            if [ $sec -gt $last_sent_time_sec ]; then
                new_lines="${new_lines}${l}\n"
                latest_ts=$sec
            fi
        else
            new_lines="${new_lines}${l}\n"
        fi
    done <<EOF
$(printf "%b" "$buffer")
EOF

    if [ -n "$new_lines" ]; then
        user_info=""
        basefile="$WIFI5/base-id/$current_id"
        if [ -f "$basefile" ] && [ -r "$basefile" ]; then
            name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p;q' "$basefile")
            [ -n "$name" ] && user_info="Client: $name\n"
        fi
        vendo_name="*"
        if [ -f "$VENDO_CONFIG" ]; then
            vendo_name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p;q' "$VENDO_CONFIG")
        fi
        
        title="🛜 ${vendo_name} - Vendo Update"
        sales_info=""
        if printf "%s" "$new_lines" | grep -qi 'expired'; then
            title="📴 ${vendo_name} - Session Expired"
            debug_log "Session expired detected"
        elif printf "%s" "$new_lines" | grep -qi 'Deducted Point'; then
            title="🎁 ${vendo_name} - Points Redeemed"
            debug_log "Points redeemed detected"
        elif printf "%s" "$new_lines" | grep -qi 'Trial Login'; then
            title="⌛ ${vendo_name} - Trial Login"
            debug_log "Trial login detected"
        else
            ### SALES ###
            today=$(date +%d-%m-%Y)
            sales_today="0"
            if [ -f "$SALES_FILE" ]; then
                sales_today=$(sed -n "s/.*\"$today\":\([0-9]\+\).*/\1/p" "$SALES_FILE")
                [ -z "$sales_today" ] && sales_today="0"
            fi
            sales_info="\n💡 Total Sales Today: ₱ ${sales_today}.00"
            debug_log "Regular update, sales today: $sales_today"
        fi

        send_telegram "${title}\n${user_info}${new_lines%\\n}${sales_info}${ngrok_info}"
        [ $latest_ts -gt 0 ] && last_sent_time_sec=$latest_ts
        debug_log "Buffer flushed successfully, new last_sent_time_sec: $last_sent_time_sec"
    else
        debug_log "No new lines to send in buffer"
        [ $DEBUG -eq 1 ] && echo ">> No new lines to send"
    fi

    buffer=""
}

# --- State ---
current_id=""
buffer=""
last_time=$(date +%s)
last_sent_time_sec=0

LOGFILE=$(get_logfile)
debug_log "Initial logfile: $LOGFILE"

tmpfifo=$(mktemp -u)
if mkfifo "$tmpfifo" 2>/dev/null; then
    debug_log "Created FIFO: $tmpfifo"
else
    system_log "Failed to create FIFO: $tmpfifo"
    exit 1
fi

tail -n0 -F "$LOGFILE" > "$tmpfifo" &
TAILPID=$!
debug_log "Started tail process PID: $TAILPID"

restart_tail() {
    debug_log "Restarting tail process"
    kill $TAILPID 2>/dev/null
    rm -f "$tmpfifo"
    tmpfifo=$(mktemp -u)
    mkfifo "$tmpfifo"
    tail -n0 -F "$LOGFILE" > "$tmpfifo" &
    TAILPID=$!
    debug_log "Switched tail to $LOGFILE, new PID: $TAILPID"
    [ $DEBUG -eq 1 ] && echo ">> Switched tail to $LOGFILE"
}

trap "kill $TAILPID; rm -f $tmpfifo; debug_log 'Script terminated'" EXIT

MAX_BUFFER_AGE=30
debug_log "Entering main loop"

while true; do
    if ! kill -0 $TAILPID 2>/dev/null; then
        debug_log "Tail process died, restarting..."
        restart_tail
    fi

    # Check for day change / new log file
    new_logfile=$(get_logfile)
    if [ "$new_logfile" != "$LOGFILE" ]; then
        debug_log "Logfile changed detected: $new_logfile != $LOGFILE"
        # flush pending before switching
        [ -n "$buffer" ] && flush_buffer && buffer="" && current_id=""
        if [ -f "$new_logfile" ]; then
            LOGFILE=$new_logfile
            restart_tail
        else
            debug_log "Waiting for $new_logfile to be created"
            [ $DEBUG -eq 1 ] && echo ">> Waiting for $new_logfile to be created"
        fi
    fi

    if read -t 1 line < "$tmpfifo"; then
        now=$(date +%s)
        id=$(echo "$line" | sed -n 's/.*ID: \([^ ]*\).*/\1/p')
        debug_log "New line received: ${line:0:50}..., ID: $id"

        # Get NGROK url
        ngrok_info=""
        ngrok_url=$(wget -T 5 -qO- http://127.0.0.1:4040/api/tunnels 2>/dev/null \
            | grep -o '"public_url":"[^"]*"' \
            | cut -d'"' -f4 \
            | head -n1)
        if [ -z "$ngrok_url" ]; then
            system_log "NGROK not available"
        else
            debug_log "NGROK URL: $ngrok_url"
            ngrok_info="\n🔗 ${ngrok_url}"
        fi

        if [ -z "$current_id" ]; then
            current_id="$id"
            buffer="$line"
            debug_log "New session started with ID: $current_id"
        elif [ "$id" = "$current_id" ]; then
            buffer="${buffer}\n${line}"
            debug_log "Added to existing buffer for ID: $current_id"
        else
            debug_log "ID changed from $current_id to $id, flushing buffer"
            flush_buffer
            current_id="$id"
            buffer="$line"
        fi
        last_time=$now
        last_buffer_time=$now
    else
        now=$(date +%s)
        if [ -n "$buffer" ]; then
            # inactivity flush
            if [ $((now - last_time)) -ge $INACTIVITY ]; then
                debug_log "Inactivity flush triggered"
                flush_buffer
                current_id=""
            # max buffer age flush
            elif [ $((now - last_buffer_time)) -ge $MAX_BUFFER_AGE ]; then
                debug_log "Max buffer age flush triggered"
                [ $DEBUG -eq 1 ] && echo ">> Flushing due to max age"
                flush_buffer
                current_id=""
            fi
        fi
    fi
done
