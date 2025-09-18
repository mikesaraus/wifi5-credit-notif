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

# --- Source jshn once if available ---
JSHN_PATH="/usr/share/libubox/jshn.sh"
HAVE_JSHN=0
if [ -r "$JSHN_PATH" ]; then
    # shellcheck source=/usr/share/libubox/jshn.sh
    . "$JSHN_PATH"
    HAVE_JSHN=1
    debug_log "libubox jshn loaded"
else
    debug_log "libubox jshn not available at $JSHN_PATH"
fi
# --- end jshn sourcing ---

send_telegram() {
    [ -z "$1" ] && return 1
    MSG=$(printf "%b" "$1")
    ENC=$(printf "%s" "$MSG" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/\n/%0A/g' \
                                      -e 's/!/%21/g' -e 's/:/%3A/g' -e 's/,/%2C/g' -e 's/&/%26/g')
    URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

    system_log "Sending Telegram message: ${ENC:0:120}..."
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

get_logfile() {
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

# ----------------------
# Helper: get vendo name from config using jshn (sub->main->name)
# Sets: echo result (stdout); returns 0 on success, 1 on failure
get_vendo_name_from_config() {
    local name=""
    if [ ! -f "$VENDO_CONFIG" ] || [ ! -r "$VENDO_CONFIG" ]; then
        return 1
    fi

    if [ "$HAVE_JSHN" -eq 1 ]; then
        if json_load "$(cat "$VENDO_CONFIG")" >/dev/null 2>&1; then
            if json_select "sub" >/dev/null 2>&1; then
                if json_select "main" >/dev/null 2>&1; then
                    if json_get_var name "name" >/dev/null 2>&1; then
                        :
                    else
                        name=""
                    fi
                    json_select .. >/dev/null 2>&1 || true
                fi
                json_select .. >/dev/null 2>&1 || true
            fi
        fi
    fi

    # fallback sed extraction (if jshn not present or failed)
    if [ -z "$name" ]; then
        name=$(sed -n 's/.*"sub"[[:space:]]*:[[:space:]]*{[^}]*"main"[[:space:]]*:[[:space:]]*{[^}]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VENDO_CONFIG" 2>/dev/null | head -n1)
    fi

    # cleanup and output
    if [ -n "$name" ]; then
        name=$(printf "%s" "$name" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' -e 's/^"//; s/"$//' | tr -d '\r\n')
        printf "%s" "$name"
        return 0
    fi
    return 1
}
# ----------------------

# ----------------------
# Helper: get sales for today from SALES_FILE using jshn
# Sets global main_sales and other_sales
get_sales_today() {
    main_sales=0
    other_sales=0
    today=$(date +%d-%m-%Y)

    if [ ! -f "$SALES_FILE" ] || [ ! -r "$SALES_FILE" ]; then
        return 1
    fi

    if [ "$HAVE_JSHN" -eq 1 ]; then
        if json_load "$(cat "$SALES_FILE")" >/dev/null 2>&1; then
            if json_get_keys vendos >/dev/null 2>&1; then
                for v in $vendos; do
                    if json_select "$v" >/dev/null 2>&1; then
                        if json_get_var tmp_sales "$today" >/dev/null 2>&1; then
                            :
                        else
                            tmp_sales=0
                        fi
                        if [ "$v" = "main" ]; then
                            main_sales=$tmp_sales
                        else
                            tmp_sales=${tmp_sales:-0}
                            other_sales=$((other_sales + tmp_sales))
                        fi
                        json_select .. >/dev/null 2>&1 || true
                    fi
                done
            fi
        fi
    fi

    # fallback for main_sales if it's not numeric/zero and jshn not available
    if ! printf "%s" "$main_sales" | grep -q '^[0-9]\+$'; then
        main_sales=$(sed -n "s/.*\"main\"[[:space:]]*:[[:space:]]*{[^}]*\"$today\":\([0-9]\+\).*/\1/p" "$SALES_FILE" 2>/dev/null | head -n1)
        [ -z "$main_sales" ] && main_sales=$(sed -n "s/.*\"$today\":\([0-9]\+\).*/\1/p" "$SALES_FILE" 2>/dev/null | head -n1)
        [ -z "$main_sales" ] && main_sales=0
    fi

    # ensure numeric defaults
    main_sales=${main_sales:-0}
    other_sales=${other_sales:-0}
    return 0
}
# ----------------------

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
        local user_info name profile vendo_name title sales_info
        local basefile="$WIFI5/base-id/$current_id"
        if [ -f "$basefile" ] && [ -r "$basefile" ]; then
            name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p;q' "$basefile")
            [ -n "$name" ] && user_info="Client: $name (U-$current_id)\\n"
        else
            system_log "Basefile not found: $basefile"
        fi
        [ -z "$user_info" ] && [ -n "$current_id" ] && user_info="Client: U-$current_id\\n"

        # Vendo Name / Profile extraction from logs
        profile=$(printf "%s" "$new_lines" \
            | grep -i -m1 'Profile:' 2>/dev/null \
            | sed -E 's/.*[Pp]rofile:[[:space:]]*//; s/^"//; s/"$//; s/[[:space:]]*$//')
        if [ -n "$profile" ]; then
            profile=$(printf "%s" "$profile" | sed 's/^"//; s/"$//' | tr -d '\r\n')
            if [ -n "$profile" ]; then
                vendo_name="$profile"
                debug_log "Vendo name extracted from log Profile: $vendo_name"
            else
                vendo_name=""
            fi
        fi

        # If not found in logs, use config
        if [ -z "$vendo_name" ]; then
            if get_vendo_name_from_config >/dev/null 2>&1; then
                vendo_name="$(get_vendo_name_from_config)"
                debug_log "Vendo name from config: $vendo_name"
            else
                vendo_name="PISOWIFI"
            fi
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
            # sales computation (main vs other)
            get_sales_today
            sales_info="\\n💡 Sales Today\\nMain: ₱ ${main_sales}.00\\nOther vendos: ₱ ${other_sales}.00"
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

# ---------------- main loop setup ----------------
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
        tail -n0 -F "$LOGFILE" 2>/dev/null | while true; do sleep 60; done &
        TAIL_PID=$!
        system_log "Fallback tail started PID=$TAIL_PID"
    else
        system_log "FIFO created at $FIFO"
    fi
else
    system_log "Using existing FIFO $FIFO"
fi

if [ -p "$FIFO" ]; then
    tail -n0 -F "$LOGFILE" 2>/dev/null > "$FIFO" &
    TAIL_PID=$!
    system_log "tail -F started writing to fifo (PID=$TAIL_PID)"
fi

cleanup() {
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

while true; do
    if read -t 1 -r line < "$FIFO"; then
        now=$(date +%s)
        id=$(echo "$line" | sed -n 's/.*ID: \([^ ]*\).*/\1/p')
        debug_log "New line: ${line:0:120}..., ID: $id"

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
