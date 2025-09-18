#!/bin/sh
# Wifi5Soft Log Notification @Telegram

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && . "$SCRIPT_DIR/.env"

CHAT_ID="${CHAT_ID:-}"
BOT_TOKEN="${BOT_TOKEN:-}"
DEBUG=${DEBUG:-0}

debug_log() {
    [ "$DEBUG" -eq 1 ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /var/log/notif.log
}
system_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> /var/log/notif.log
}

WIFI5="/mnt/wifi5"
LOG_DIR="$WIFI5/mainlogs"
VENDO_CONFIG="$WIFI5/config/vendo.json"
SALES_FILE="$WIFI5/sales/list"
INACTIVITY=2
MAX_BUFFER_AGE=30

system_log "Script started"
system_log "SCRIPT_DIR: $SCRIPT_DIR"
system_log "LOG_DIR: $LOG_DIR"

send_telegram() {
    [ -z "$1" ] && return 1
    MSG=$(printf "%b" "$1")
    # Minimal URL-encoding suitable for application/x-www-form-urlencoded
    ENC=$(printf "%s" "$MSG" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/\n/%0A/g' \
                                      -e 's/!/%21/g' -e 's/:/%3A/g' -e 's/,/%2C/g' -e 's/&/%26/g')
    URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

    system_log "Sending Telegram message: ${ENC:0:120}..."
    for i in 1 2 3; do
        # wget on BusyBox: use --timeout (-T) and --post-data; redirect output to /dev/null
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

get_logfile() {
    # safer filename construction
    echo "$LOG_DIR/voucher-$(date +%d-%m-%Y).txt"
}

time_to_sec() {
    local hhmmss=$1 ampm=$2 h m s
    IFS=: read h m s <<EOF
$hhmmss
EOF
    h="${h##0}"; [ -z "$h" ] && h=0
    m="${m##0}"; [ -z "$m" ] && m=0
    s="${s##0}"; [ -z "$s" ] && s=0
    if [ "$ampm" = "pm" ] && [ "$h" -lt 12 ]; then h=$((h+12)); fi
    if [ "$ampm" = "am" ] && [ "$h" -eq 12 ]; then h=0; fi
    echo $((h*3600 + m*60 + s))
}

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
            if [ "$last_sent_time_sec" -eq 0 ] || [ "$sec" -gt "$last_sent_time_sec" ]; then
                new_lines="${new_lines}${l}\\n"
                latest_ts=$sec
                debug_log "INCLUDING line (newer timestamp)"
            else
                debug_log "FILTERING OUT line (older timestamp)"
            fi
        else
            new_lines="${new_lines}${l}\\n"
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
            [ -n "$name" ] && user_info="Client: $name (U-$current_id)\\n"
        else
            system_log "Basefile not found: $basefile"
        fi
        [ -z "$user_info" ] && [ -n "$current_id" ] && user_info="Client: U-$current_id\\n"

        # Vendo Name / Profile
        profile=$(printf "%s" "$new_lines" \
            | grep -i -m1 'Profile:' \
            | sed -E 's/.*[Pp]rofile:[[:space:]]*//; s/^"//; s/"$//; s/[[:space:]]*$//')

        if [ -n "$profile" ]; then
            # Remove surrounding quotes if any, trim again
            profile=$(printf "%s" "$profile" | sed 's/^"//; s/"$//; s/[[:space:]]*$//; s/^[[:space:]]*//')
            if [ -n "$profile" ]; then
                vendo_name="$profile"
                debug_log "Vendo name extracted from log Profile: $vendo_name"
            else
                vendo_name=""
                debug_log "No vendo name in Profile, falling back to default"
            fi
        fi

        vendo_name=""
        
        if [ -f "$VENDO_CONFIG" ] && [ -r "$VENDO_CONFIG" ]; then
            if [ -r /usr/share/libubox/jshn.sh ]; then
                . /usr/share/libubox/jshn.sh

                # load JSON and try to descend into sub -> main -> name
                if json_load "$(cat "$VENDO_CONFIG")" >/dev/null 2>&1; then
                    if json_select "sub" >/dev/null 2>&1 && json_select "main" >/dev/null 2>&1; then
                        # read "name" into variable vendo_name
                        if json_get_var vendo_name "name" >/dev/null 2>&1; then
                            debug_log "jshn: found vendo_name='$vendo_name'"
                        else
                            debug_log "jshn: 'name' not found under sub->main"
                            vendo_name=""
                        fi
                    else
                        debug_log "jshn: could not select sub->main"
                    fi
                else
                    debug_log "jshn: json_load failed for $VENDO_CONFIG"
                fi
            else
                debug_log "/usr/share/libubox/jshn.sh not found; falling back to sed"
            fi

            # fallback: if jshn failed, try original sed extraction (first "name" occurrence)
            if [ -z "$vendo_name" ]; then
                vendo_name=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VENDO_CONFIG" 2>/dev/null | head -n1)
                [ -n "$vendo_name" ] && debug_log "Vendo name extracted by sed fallback: $vendo_name" || system_log "Vendo name not found in config"
            fi
        else
            system_log "Vendo config not found: $VENDO_CONFIG"
        fi

        # final cleanup: trim whitespace and remove surrounding quotes / control chars
        if [ -n "$vendo_name" ]; then
            # remove leading/trailing whitespace and surrounding quotes if present
            vendo_name=$(printf "%s" "$vendo_name" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' -e 's/^"//; s/"$//')
        else
            vendo_name="*"
        fi

        debug_log "Final vendo_name: '$vendo_name'"

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
            sales_info="\\n💡 Total Sales Today: ₱ ${sales_today}.00"
        fi

        # NGROK info (if available)
        ngrok_info=""
        ngrok_url=$(wget -T 5 -qO- http://127.0.0.1:4040/api/tunnels 2>/dev/null \
            | grep -o '"public_url":"[^"]*"' | cut -d'"' -f4 | head -n1)
        if [ -n "$ngrok_url" ]; then
            ngrok_info="\\n🔗 ${ngrok_url}"
            debug_log "NGROK URL: $ngrok_url"
        else
            debug_log "NGROK not available"
        fi

        # remove trailing literal \n
        trimmed=$(printf "%s" "$new_lines" | sed 's/\\n$//')

        if send_telegram "${title}\\n${user_info}${trimmed}${sales_info}${ngrok_info}"; then
            [ "$latest_ts" -gt 0 ] && last_sent_time_sec=$latest_ts
            system_log "Buffer flushed successfully"
        else
            system_log "Buffer flush FAILED"
        fi
    else
        system_log "No new lines to send"
    fi
    buffer=""
}

current_id=""
buffer=""
last_time=$(date +%s)
last_sent_time_sec=0

LOGFILE="$(get_logfile)"
system_log "Initial logfile: $LOGFILE"
system_log "Entering main loop"

# FIFO + tail startup (robust)
FIFO="/tmp/wifi5_logfifo"
if [ ! -p "$FIFO" ]; then
    rm -f "$FIFO" 2>/dev/null
    if ! mkfifo "$FIFO"; then
        system_log "ERROR: mkfifo failed, falling back to direct tail read"
        # fallback: direct tail into while (less reliable on some busybox shells)
        tail -n0 -F "$LOGFILE" 2>/dev/null | while true; do sleep 60; done &
        TAIL_PID=$!
        system_log "Fallback tail started PID=$TAIL_PID"
    else
        system_log "FIFO created at $FIFO"
    fi
else
    system_log "Using existing FIFO $FIFO"
fi

# start tail (only if FIFO was successfully created)
if [ -p "$FIFO" ]; then
    tail -n0 -F "$LOGFILE" 2>/dev/null > "$FIFO" &
    TAIL_PID=$!
    system_log "tail -F started writing to fifo (PID=$TAIL_PID)"
fi

# safe cleanup: disable traps immediately to avoid recursion
cleanup() {
    # ignore further INT/TERM/EXIT while cleaning up
    trap '' INT TERM EXIT
    system_log "Caught termination, flushing buffer..."
    flush_buffer
    if [ -n "$TAIL_PID" ]; then
        system_log "Killing tail PID $TAIL_PID"
        kill "$TAIL_PID" 2>/dev/null || true
    fi
    rm -f "$FIFO" 2>/dev/null
    system_log "Cleanup complete, exiting"
    exit 0
}
trap cleanup INT TERM EXIT

# Main read loop: read with timeout so we wake when no input
while true; do
    if read -t 1 -r line < "$FIFO"; then
        now=$(date +%s)
        id=$(echo "$line" | sed -n 's/.*ID: \([^ ]*\).*/\1/p')
        debug_log "New line: ${line:0:120}..., ID: $id"

        # process line (same logic you already have for cleaning, buffering, id change)
        cleaned=$(echo "$line" | sed 's/^.* [0-9A-Za-z:]\{17\} //')
        if [ -z "$id" ]; then
            debug_log "No ID parsed from line; skipping"
            continue
        fi

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

    else
        # read timed out → no new line for 1s
        now=$(date +%s)
        if [ -n "$buffer" ]; then
            age=$((now - last_time))
            [ "$DEBUG" -eq 1 ] && debug_log "Timeout check: age=$age, INACTIVITY=$INACTIVITY, MAX_BUFFER_AGE=$MAX_BUFFER_AGE"
            if [ "$age" -ge "$MAX_BUFFER_AGE" ]; then
                system_log "Max buffer age flush triggered (age=${age})"
                flush_buffer
                current_id=""
                last_time=$(date +%s)
            elif [ "$age" -ge "$INACTIVITY" ]; then
                system_log "Inactivity flush triggered (age=${age})"
                flush_buffer
                current_id=""
                last_time=$(date +%s)
            fi
        else
            [ "$DEBUG" -eq 1 ] && debug_log "Timeout with empty buffer"
        fi
    fi
done
