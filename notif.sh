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

# Telegram sending function
send_telegram() {
    [ -z "$1" ] && return
    
    local MSG ENC URL
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
    system_log "Sending Telegram message: ${ENC:0:100}..."
    
    # Retry logic
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

# Helper functions
get_logfile() {
    date +$LOG_DIR/voucher-%d-%m-%Y.txt
}

time_to_sec() {
    local hhmmss=$1 ampm=$2 h m s temp
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

# Buffer management
flush_buffer() {
    [ -z "$buffer" ] && return
    
    system_log "Flushing buffer for ID: $current_id"
    local new_lines="" latest_ts=0 l ts sec ampm_part time_part
    
    # Process buffer content
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        
        debug_log "DEBUG: Processing line: '$l'"
        
        if [ "${l:2:1}" = ":" ]; then
            time_part="${l%% *}"
            ampm_part="${l#* }"
            ampm_part="${ampm_part%% *}"
            
            sec=$(time_to_sec "$time_part" "$ampm_part")
            debug_log "DEBUG: Line timestamp: $time_part $ampm_part -> $sec seconds, comparing to last_sent: $last_sent_time_sec"
            
            if [ $last_sent_time_sec -eq 0 ] || [ $sec -gt $last_sent_time_sec ]; then
                new_lines="${new_lines}${l}\n"
                latest_ts=$sec
                debug_log "DEBUG: INCLUDING line (newer timestamp)"
            else
                debug_log "DEBUG: FILTERING OUT line (older timestamp)"
            fi
        else
            new_lines="${new_lines}${l}\n"
            debug_log "DEBUG: INCLUDING line (no timestamp)"
        fi
    done <<EOF
$(printf "%b" "$buffer")
EOF

    if [ -n "$new_lines" ]; then
        local user_info="" vendo_name="*" title sales_info today sales_today name
        
        # Get user info
        local basefile="$WIFI5/base-id/$current_id"
        if [ -f "$basefile" ] && [ -r "$basefile" ]; then
            name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p;q' "$basefile")
            [ -n "$name" ] && user_info="Client: $name\n"
        else
            system_log "Basefile not found or not readable: $basefile"
        fi
        [ -z "$user_info" ] && [ -n "$current_id" ] && user_info="Client: U-$current_id\n"
        
        # Get vendo name
        if [ -f "$VENDO_CONFIG" ] && [ -r "$VENDO_CONFIG" ]; then
            vendo_name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p;q' "$VENDO_CONFIG")
        else
            system_log "Vendo config not found or not readable: $VENDO_CONFIG"
        fi
        
        # Determine message type
        title="🛜 ${vendo_name} - Vendo Update"
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
            # Sales information
            today=$(date +%d-%m-%Y)
            sales_today="0"
            if [ -f "$SALES_FILE" ] && [ -r "$SALES_FILE" ]; then
                sales_today=$(sed -n "s/.*\"$today\":\([0-9]\+\).*/\1/p" "$SALES_FILE")
                [ -z "$sales_today" ] && sales_today="0"
            else
                system_log "Sales file not found or not readable: $SALES_FILE"
            fi
            sales_info="\n💡 Total Sales Today: ₱ ${sales_today}.00"
            debug_log "Regular update, sales today: $sales_today"
        fi

        # Send message
        if send_telegram "${title}\n${user_info}${new_lines%\\n}${sales_info}${ngrok_info}"; then
            [ $latest_ts -gt 0 ] && last_sent_time_sec=$latest_ts
            system_log "Buffer flushed successfully, new last_sent_time_sec: $last_sent_time_sec"
        else
            system_log "Buffer flush FAILED - keeping buffer for retry"
            return 1
        fi
    else
        system_log "No new lines to send in buffer"
    fi

    buffer=""
    return 0
}

restart_tail() {
    system_log "Restarting tail process"
    kill $TAILPID 2>/dev/null
    rm -f "$tmpfifo" 2>/dev/null
    
    tmpfifo=$(mktemp -u)
    if mkfifo "$tmpfifo" 2>/dev/null; then
        system_log "Created FIFO: $tmpfifo"
    else
        system_log "Failed to create FIFO: $tmpfifo"
        return 1
    fi
    
    tail -n0 -F "$LOGFILE" > "$tmpfifo" &
    TAILPID=$!
    system_log "Switched tail to $LOGFILE, new PID: $TAILPID"
    return 0
}

# Main execution
current_id=""
buffer=""
last_time=$(date +%s)
last_sent_time_sec=0

LOGFILE=$(get_logfile)
system_log "Initial logfile: $LOGFILE"

tmpfifo=$(mktemp -u)
if mkfifo "$tmpfifo" 2>/dev/null; then
    system_log "Created FIFO: $tmpfifo"
else
    system_log "Failed to create FIFO: $tmpfifo"
    exit 1
fi

tail -n0 -F "$LOGFILE" > "$tmpfifo" &
TAILPID=$!
system_log "Started tail process PID: $TAILPID"

trap "kill $TAILPID 2>/dev/null; rm -f $tmpfifo 2>/dev/null; system_log 'Script terminated'" EXIT

system_log "Entering main loop"

while true; do
    # Reset timestamp at midnight
    current_hour=$(date +%H)
    if [ "$current_hour" -eq "00" ] && [ $last_sent_time_sec -gt 43200 ]; then
        system_log "Midnight detected, resetting last_sent_time_sec"
        last_sent_time_sec=0
    fi

    # Check tail process health
    if ! kill -0 $TAILPID 2>/dev/null; then
        system_log "Tail process died, restarting..."
        restart_tail
    fi

    # Check for log rotation
    new_logfile=$(get_logfile)
    if [ "$new_logfile" != "$LOGFILE" ]; then
        system_log "Logfile rotation detected: $LOGFILE -> $new_logfile"
        [ -n "$buffer" ] && flush_buffer
        buffer=""
        current_id=""
        
        if [ -f "$new_logfile" ]; then
            LOGFILE=$new_logfile
            restart_tail
        else
            system_log "Waiting for new logfile: $new_logfile"
        fi
    fi

    # Read from log file
    if read -t 1 line < "$tmpfifo"; then
        now=$(date +%s)
        id=$(echo "$line" | sed -n 's/.*ID: \([^ ]*\).*/\1/p')
        debug_log "New line received: ${line:0:50}..., ID: $id"

        # Get NGROK URL
        ngrok_info=""
        ngrok_url=$(wget -T 5 -qO- http://127.0.0.1:4040/api/tunnels 2>/dev/null \
            | grep -o '"public_url":"[^"]*"' \
            | cut -d'"' -f4 \
            | head -n1)
        
        if [ -n "$ngrok_url" ]; then
            debug_log "NGROK URL: $ngrok_url"
            ngrok_info="\n🔗 ${ngrok_url}"
        else
            system_log "NGROK not available"
        fi

        # Buffer management
        if [ -z "$current_id" ]; then
            current_id="$id"
            buffer="$line"
            system_log "New session started with ID: $current_id"
        elif [ "$id" = "$current_id" ]; then
            buffer="${buffer}\n${line}"
            debug_log "Added to existing buffer for ID: $current_id"
        else
            system_log "ID changed from $current_id to $id, flushing buffer"
            flush_buffer
            current_id="$id"
            buffer="$line"
        fi
        
        last_time=$now
        last_buffer_time=$now
        
    else
        # Buffer flushing logic
        now=$(date +%s)
        if [ -n "$buffer" ]; then
            if [ $((now - last_time)) -ge $INACTIVITY ]; then
                system_log "Inactivity flush triggered"
                flush_buffer
                current_id=""
            elif [ $((now - last_buffer_time)) -ge $MAX_BUFFER_AGE ]; then
                system_log "Max buffer age flush triggered"
                flush_buffer
                current_id=""
            fi
        fi
    fi
    sleep 1
done
