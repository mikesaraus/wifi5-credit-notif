#!/bin/sh
# Wifi5Soft Credit Log Notification @Telegram

# Resolve directory of this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Set CHAT_ID and BOT_TOKEN via .env
# CHAT_ID=""
# BOT_TOKEN=""

# Load .env file from same location
if [ -f "$SCRIPT_DIR/.env" ]; then
    . "$SCRIPT_DIR/.env"
fi

# Default DEBUG to 0 if not set
DEBUG=${DEBUG:-0}
WIFI5="/mnt/wifi5"
LOG_DIR="$WIFI5/mainlogs"
INACTIVITY=2   # seconds before flushing

send_telegram() {
    [ -z "$1" ] && return
    MSG=$(printf "%b" "$1")         # interpret \n
    ENC=$(printf "%s" "$MSG" | sed ':a;N;$!ba;s/\n/%0A/g')
    ENC=$(printf "%s" "$ENC" \
        | sed -e 's/%/%25/g' \
              -e 's/ /%20/g' \
              -e 's/!/%21/g' \
              -e 's/:/%3A/g' \
              -e 's/,/%2C/g')
    ENC=$(printf "%s" "$ENC" | sed 's/%250A/%0A/g')

    URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
    [ $DEBUG -eq 1 ] && echo ">> Telegram: $ENC"
    wget -qO- --post-data="chat_id=${CHAT_ID}&text=${ENC}" "$URL" >/dev/null 2>&1
}

get_logfile() {
    date +$LOG_DIR/credit-%d-%m-%Y.txt
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

    new_lines=""
    latest_ts=0

    while IFS= read -r l; do
        if [ "${l:2:1}" = ":" ]; then
            ts="${l%% *} ${l#*: }"  # crude split of time and am/pm
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
        # Get Userinfo
        user_info=""
        basefile="$WIFI5/base-id/$current_id"
        if [ -f "$basefile" ]; then
            # extract "name" with awk (single process)
            name=$(awk -F'"' '/"name":/ {print $4; exit}' "$basefile")
            [ -n "$name" ] && user_info="Name: $name\n"
        fi

        send_telegram "🛜 PisoWiFi Update\n${user_info}${new_lines%\\n}"
        [ $latest_ts -gt 0 ] && last_sent_time_sec=$latest_ts
    else
        [ $DEBUG -eq 1 ] && echo ">> No new lines to send"
    fi

    buffer=""
}

# State
current_id=""
buffer=""
last_time=$(date +%s)
last_sent_time_sec=0

LOGFILE=$(get_logfile)

# Tail the log file into a FIFO
tmpfifo=$(mktemp -u)
mkfifo "$tmpfifo"
tail -n0 -F "$LOGFILE" > "$tmpfifo" &
TAILPID=$!

trap "kill $TAILPID; rm -f $tmpfifo" EXIT

while true; do
    if read -t 1 line < "$tmpfifo"; then
        now=$(date +%s)
        id=$(echo "$line" | sed -n 's/.*ID: \([^ ]*\).*/\1/p')

        if [ -z "$current_id" ]; then
            [ $DEBUG -eq 1 ] && echo ">> First ID: $id"
            current_id="$id"
            buffer="$line"
        elif [ "$id" = "$current_id" ]; then
            buffer="${buffer}\n${line}"
        else
            [ $DEBUG -eq 1 ] && echo ">> New ID: $id"
            flush_buffer
            current_id="$id"
            buffer="$line"
        fi

        last_time=$now
    else
        now=$(date +%s)
        if [ -n "$buffer" ] && [ $((now - last_time)) -ge $INACTIVITY ]; then
            [ $DEBUG -eq 1 ] && echo ">> Flushing after inactivity"
            flush_buffer
            current_id=""
        fi
    fi
done
