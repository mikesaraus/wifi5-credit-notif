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

# Global vars
WIFI5="/mnt/wifi5"
LOG_DIR="$WIFI5/mainlogs"
INACTIVITY=2
MAX_BUFFER_AGE=30
VENDO_CONFIG="$WIFI5/config/vendo.json"

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

# Helper: get ngrok URLs (http + ssh) if any
get_ngrok_urls() {
    # --- NGROK tunnels (4040 + 4041) ---
    proto="both" # default
    # parse arg (simple)
    if [ $# -ge 1 ]; then
        case "$1" in
            --proto) proto="$2" ;;
            -p) proto="$2" ;;
            http|tcp|both) proto="$1" ;;
            *) proto="$1" ;;
        esac
    fi

    # normalize
    case "$proto" in
        http) ;;
        tcp) ;;
        both) ;;
        *) proto="http" ;;
    esac

    ngrok_http_list=""
    ngrok_tcp_list=""
    for port in 4040 4041; do
        tmp_ngrok="/tmp/.ngrokjson.$$.$port"
        tmp_urls="/tmp/.ngrokurls.$$.$port"
        if wget -T 3 -qO "$tmp_ngrok" "http://127.0.0.1:$port/api/tunnels" 2>/dev/null; then
            # extract public_url values into a temp file (one per line)
            grep -o '"public_url":"[^"]*"' "$tmp_ngrok" 2>/dev/null | cut -d'"' -f4 > "$tmp_urls" 2>/dev/null

            # read the urls from file in the current shell (no subshell)
            if [ -s "$tmp_urls" ]; then
                while IFS= read -r url; do
                    case "$url" in
                        http*|https*)
                            # append only if not already present (space-separated list)
                            printf "%s\n" "$ngrok_http_list" | grep -x -F "$url" >/dev/null 2>&1 || ngrok_http_list="${ngrok_http_list}${url} "
                            ;;
                        tcp*)
                            printf "%s\n" "$ngrok_tcp_list" | grep -x -F "$url" >/dev/null 2>&1 || ngrok_tcp_list="${ngrok_tcp_list}${url} "
                            ;;
                    esac
                done < "$tmp_urls"
            fi

            rm -f "$tmp_ngrok" "$tmp_urls" 2>/dev/null || true
        fi
    done


    ngrok_http="N/A"; ngrok_tcp="N/A"
    if [ -n "$ngrok_http_list" ]; then ngrok_http=$(printf "%s" "$ngrok_http_list" | awk '{print $1}'); fi
    if [ -n "$ngrok_tcp_list" ]; then ngrok_tcp=$(printf "%s" "$ngrok_tcp_list" | awk '{print $1}'); fi

    case "$proto" in
        http) printf "%s" "$ngrok_http" ;;
        tcp) printf "%s" "$ngrok_tcp" ;;
        both) printf "HTTP: %s TCP: %s" "$ngrok_http" "$ngrok_tcp" ;;
    esac

    return 0
}

# Helper: get sales for today from SALES_FILE using jshn
get_sales_today() {
    # usage: get_sales_today --source main|others|both
    SALES_FILE="$WIFI5/sales/list"
    src="both" # default
    # parse arg (simple)
    if [ $# -ge 1 ]; then
        case "$1" in
            --source) src="$2" ;;
            -s) src="$2" ;;
            main|others|both) src="$1" ;;
            *) src="$1" ;;
        esac
    fi

    # normalize
    case "$src" in
        main) ;;
        others) ;;
        both) ;;
        *) src="main" ;;
    esac

    main_sales=0
    other_sales=0
    today=$(date +%d-%m-%Y)

    if [ ! -f "$SALES_FILE" ] || [ ! -r "$SALES_FILE" ]; then
        # print zeros according to request
        case "$src" in
            main) printf "%d" 0 ;;
            others) printf "%d" 0 ;;
            both) printf "%d %d" 0 0 ;;
        esac
        return 0
    fi

    # Try jshn first
    if [ "$HAVE_JSHN" -eq 1 ]; then
        if json_load "$(cat "$SALES_FILE")" >/dev/null 2>&1; then
            # get keys and iterate
            if json_get_keys vendos >/dev/null 2>&1; then
                for v in $vendos; do
                    if json_select "$v" >/dev/null 2>&1; then
                        if json_get_var tmp_sales "$today" >/dev/null 2>&1; then
                            : # tmp_sales set
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

    # If jshn wasn't available or didn't find numbers, fallback to sed parsing
    # We'll collect all occurrences of "$today":number and sum them.
    if ! printf "%s" "$main_sales" | grep -q '^[0-9]\+$' || [ "$other_sales" -eq 0 ]; then
        total_all=0
        # extract all numbers for today (may produce multiple lines)
        # sed prints only the numeric part for each occurrence of "$today":<num>
        sed -n "s/.*\"$today\":\([0-9]\+\).*/\1/p" "$SALES_FILE" 2>/dev/null > /tmp/.sales_today.$$ 2>/dev/null || true

        if [ -s /tmp/.sales_today.$$ ]; then
            while IFS= read -r n; do
                # ensure numeric
                case "$n" in
                    ''|*[!0-9]* ) n=0 ;;
                esac
                total_all=$((total_all + n))
            done < /tmp/.sales_today.$$
        fi
        # try to get main specifically if not set (search under "main" block)
        if ! printf "%s" "$main_sales" | grep -q '^[0-9]\+$'; then
            main_sales=$(sed -n "s/.*\"main\"[[:space:]]*:[[:space:]]*{[^}]*\"$today\":\([0-9]\+\).*/\1/p" "$SALES_FILE" 2>/dev/null | head -n1)
            [ -z "$main_sales" ] && main_sales=0
        fi

        # compute other as total_all - main_sales
        main_sales=${main_sales:-0}
        other_sales=$((total_all - main_sales))
        [ "$other_sales" -lt 0 ] && other_sales=0

        # cleanup temp
        [ -f /tmp/.sales_today.$$ ] && rm -f /tmp/.sales_today.$$ 2>/dev/null || true
    fi

    # ensure numeric defaults
    main_sales=${main_sales:-0}
    other_sales=${other_sales:-0}
    all_sales=$((main_sales + other_sales))

    case "$src" in
        main) printf "%d" "$main_sales" ;;
        others) printf "%d" "$other_sales" ;;
        both) printf "%d" "$all_sales" ;;
    esac

    return 0
}

# Helper: get main vendo name from VENDO_CONFIG using jshn or sed fallback
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

# Get logfile path for today
get_logfile() {
    echo "$LOG_DIR/voucher-$(date +%d-%m-%Y).txt"
}

# Get device model from /var/sysinfo/model
get_device_model() {
    model="Unknown"
    if [ -r /var/sysinfo/model ]; then
        model=$(sed -n '1p' /var/sysinfo/model 2>/dev/null | tr -d '\r\n')
        [ -z "$model" ] && model="Unknown"
    fi
    printf "%s" "$model"
    return 0
}

# Get system uptime in format Xd HH:MM:SS
get_uptime() {
    # --- uptime Xd HH:MM:SS ---
    uptime_seconds=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
    uptime_seconds=${uptime_seconds:-0}
    days=$(( uptime_seconds / 86400 ))
    rem=$(( uptime_seconds % 86400 ))
    hours=$(( rem / 3600 ))
    rem=$(( rem % 3600 ))
    mins=$(( rem / 60 ))
    secs=$(( rem % 60 ))
    uptime_fmt=$(printf "%dd %02d:%02d:%02d" "$days" "$hours" "$mins" "$secs")

    printf "%s" "$uptime_fmt"
    return 0
}

# Get device temperature if available
get_temperature() {
    # --- temperature ---
    temp="N/A"
    if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
        tval=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || true)
        if [ -n "$tval" ]; then
            if [ "${#tval}" -ge 4 ]; then
                temp=$(awk -v t="$tval" 'BEGIN{printf "%.1f°C", t/1000}')
            else
                temp="${tval}°C"
            fi
        fi
    fi
    printf "%s" "$temp"
    return 0
}

# Get CPU usage percentage (sample /proc/stat)
get_cpu_usage() {
    # --- CPU usage (sample /proc/stat, portable) ---
    cpu_stat1=$(head -n 1 /proc/stat 2>/dev/null || true)
    sleep 1
    cpu_stat2=$(head -n 1 /proc/stat 2>/dev/null || true)

    set -- $cpu_stat1
    u1=${2:-0}; n1=${3:-0}; s1=${4:-0}; i1=${5:-0}; w1=${6:-0}; irq1=${7:-0}; soft1=${8:-0}; steal1=${9:-0}
    set -- $cpu_stat2
    u2=${2:-0}; n2=${3:-0}; s2=${4:-0}; i2=${5:-0}; w2=${6:-0}; irq2=${7:-0}; soft2=${8:-0}; steal2=${9:-0}

    total1=$((u1 + n1 + s1 + i1 + w1 + irq1 + soft1 + steal1))
    total2=$((u2 + n2 + s2 + i2 + w2 + irq2 + soft2 + steal2))
    idle1=$((i1 + w1))
    idle2=$((i2 + w2))

    dt=$((total2 - total1))
    didle=$((idle2 - idle1))
    cpu_usage_num="0.00"
    if [ "$dt" -gt 0 ]; then
        cpu_usage_num=$(awk -v dt="$dt" -v didle="$didle" 'BEGIN{ if (dt>0) printf "%.2f", (1 - (didle/dt))*100; else printf "0.00" }' 2>/dev/null)
        case "$cpu_usage_num" in
            ''|*[!0-9.]* ) cpu_usage_num="0.00" ;;
        esac
    fi
    cpu_usage="${cpu_usage_num}%"
    printf "%s" "$cpu_usage"
    return 0
}

# Get RAM usage in MB used/total
get_ram_info() {
    # --- RAM used/total (MB) ---

    # parse arg (simple)
    if [ $# -ge 1 ]; then
        case "$1" in
            --source) src="$2" ;;
            -s) src="$2" ;;
            used|total|both) src="$1" ;;
            *) src="$1" ;;
        esac
    fi

    # normalize
    case "$src" in
        used) ;;
        total) ;;
        both) ;;
        *) src="used" ;;
    esac

    mem_total_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    mem_total_kb=${mem_total_kb:-0}
    mem_avail_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "")

    if [ -n "$mem_avail_kb" ]; then
        mem_used_kb=$((mem_total_kb - mem_avail_kb))
    else
        mem_free_kb=$(awk '/MemFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
        buff_kb=$(awk '/Buffers:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
        cached_kb=$(awk '/^Cached:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
        mem_used_kb=$((mem_total_kb - (mem_free_kb + buff_kb + cached_kb)))
    fi

    mem_total_kb=${mem_total_kb:-0}
    mem_used_kb=${mem_used_kb:-0}
    if [ "$mem_used_kb" -lt 0 ]; then mem_used_kb=0; fi

    mem_total_mb=$(awk -v v="$mem_total_kb" 'BEGIN{printf "%d", (v/1024 + 0.5)}' 2>/dev/null || printf "%d" 0)
    mem_used_mb=$(awk -v v="$mem_used_kb" 'BEGIN{printf "%d", (v/1024 + 0.5)}' 2>/dev/null || printf "%d" 0)

    
    case "$src" in
        used) printf "%d MB" "$mem_used_mb" ;;
        total) printf "%d MB" "$mem_total_mb" ;;
        both) printf "%d MB / %d MB" "$mem_used_mb" "$mem_total_mb" ;;
    esac

    return 0
}

# Convert HH:MM:SS AM/PM to seconds since midnight
# Usage: time_to_sec "HH:MM:SS" "am|pm"
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

# Send message to Telegram bot
# Usage: send_telegram "message text"
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

send_device_info() {
    # --- main vendo name ---
    vendo_name=$(get_vendo_name_from_config 2>/dev/null || echo "PISOWIFI")

    # --- count sub-vendos (excluding "main") ---
    sub_count=0
    if [ -f "$VENDO_CONFIG" ] && [ -r "$VENDO_CONFIG" ]; then
        if [ "$HAVE_JSHN" -eq 1 ]; then
            if json_load "$(cat "$VENDO_CONFIG")" >/dev/null 2>&1; then
                if json_select "sub" >/dev/null 2>&1; then
                    if json_get_keys subkeys >/dev/null 2>&1; then
                        for k in $subkeys; do
                            [ "$k" != "main" ] && sub_count=$((sub_count + 1))
                        done
                    fi
                    json_select .. >/dev/null 2>&1 || true
                fi
            fi
        else
            # best-effort fallback: count object keys under "sub" (approximate)
            sub_block=$(sed -n 's/.*"sub"[[:space:]]*:[[:space:]]*{\(.*\)}[[:space:]]*,.*/\1/p' "$VENDO_CONFIG" 2>/dev/null)
            if [ -n "$sub_block" ]; then
                # count quoted keys (approx)
                count_keys=$(printf "%s" "$sub_block" | grep -o '"[A-Za-z0-9_-]\+"' 2>/dev/null | wc -l 2>/dev/null || echo 0)
                sub_count=$((count_keys / 2))
                # subtract 1 for main if present
                if printf "%s" "$sub_block" | grep -q '"main"' 2>/dev/null; then
                    sub_count=$((sub_count - 1))
                    [ "$sub_count" -lt 0 ] && sub_count=0
                fi
            fi
        fi
    fi

    # --- device model ---
    model=$(get_device_model)
    # --- uptime Xd HH:MM:SS ---
    uptime=$(get_uptime)
    # --- temperature ---
    temp=$(get_temperature)
    # --- CPU usage %---
    cpu_usage=$(get_cpu_usage)
    # --- RAM used/total (MB) ---
    memory_usage=$(get_ram_info --source both)
    # NGROK tunnels
    ngrok_http=$(get_ngrok_urls --proto http)
    ngrok_ssh=$(get_ngrok_urls --proto tcp)
    # Sales today
    main_sales=$(get_sales_today --source main)
    other_sales=$(get_sales_today --source others)
    total_sales=$((main_sales + other_sales))
    # --- compose message (no trailing newline in variables) ---
    msg="🛜 Vendo Update 🛜\\n"
    msg="${msg}------------------\\n"
    msg="${msg}Name: ${vendo_name}\\n"
    msg="${msg}Total Subvendo: ${sub_count}\\n"
    msg="${msg}Device: ${model}\\n"
    msg="${msg}Uptime: ${uptime}\\n"
    msg="${msg}Temperature: ${temp}\\n"
    msg="${msg}CPU Usage: ${cpu_usage}\\n"
    msg="${msg}RAM: ${memory_usage}\\n"
    msg="${msg}------------------\\n"
    msg="${msg}💰 Sales Today:\\nMain: ₱ ${main_sales}.00\\nSub Vendos: ₱ ${other_sales}.00\\nTotal: ₱ ${total_sales}.00\\n"
    msg="${msg}------------------\\n"
    msg="${msg}🚀 NGROK Info:\\n🔗 HTTP: ${ngrok_http}\\n💻 TCP: ${ngrok_ssh}\\n"

    # send message
    send_telegram "${msg}"
}

# Flush buffer function
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
            [ -n "$name" ] && user_info="$name (U-$current_id)"
        else
            system_log "Basefile not found: $basefile"
        fi
        [ -z "$user_info" ] && [ -n "$current_id" ] && user_info="U-$current_id"
        user_info="👤 Client: ${user_info}"

        # Vendo Name / Profile extraction from logs
        profile=$(printf "%s" "$new_lines" \
            | grep -i -m1 'Profile:' 2>/dev/null \
            | sed -E 's/.*[Pp]rofile:[[:space:]]*//; s/^"//; s/"$//; s/[[:space:]]*$//')
        if [ -n "$profile" ]; then
            profile=$(printf "%s" "$profile" | sed 's/\\n//g' | tr -d '\r' | awk 'NR==1{printf "%s",$0; exit}')
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
                debug_log "Fallback to vendo_name: '$vendo_name'"
            fi
        fi

        title="🛜 ${vendo_name} - Vendo Update"
        if printf "%s" "$new_lines" | grep -qi 'expired'; then
            title="📴 ${vendo_name} - Session Expired"
        elif printf "%s" "$new_lines" | grep -qi 'Deducted Point'; then
            title="🎁 ${vendo_name} - Points Redeemed"
        elif printf "%s" "$new_lines" | grep -qi 'Trial Login'; then
            title="⌛ ${vendo_name} - Trial Login"
        else
            main_sales=$(get_sales_today --source main)
            other_sales=$(get_sales_today --source others)
            sales_info="\\n💰 Sales Today\\nMain: ₱ ${main_sales}.00\\nSub Vendos: ₱ ${other_sales}.00"
        fi

        # NGROK info (if available)
        ngrok_http=$(get_ngrok_urls --proto http)
        ngrok_ssh=$(get_ngrok_urls --proto tcp)
        ngrok_info="\\n🚀 NGROK Info:\\n🔗 HTTP: ${ngrok_http}\\n💻 TCP: ${ngrok_ssh}\\n"

        # remove trailing literal \n
        trimmed=$(printf "%s" "$new_lines" | sed 's/\\n$//')

        if send_telegram "${title}\\n${user_info}\\n------------------\\n${trimmed}${sales_info}${ngrok_info}"; then
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

# ---------------- CLI action handling ----------------
# Accepts:
#   ./notif.sh --action sendinfo
#   ./notif.sh -a sendinfo
#   ./notif.sh sendinfo
# If no action provided, runs normal long-lived log-listening loop.

ACTION=""
# simple args parsing (POSIX shell)
while [ $# -gt 0 ]; do
    case "$1" in
        --action|-a)
            ACTION="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--action ACTION]"
            echo "Actions: sendinfo   Send device info now and exit"
            exit 0
            ;;
        sendinfo|device_info|send_device_info)
            ACTION="$1"
            shift
            ;;
        *)
            # ignore unknown positional args
            shift
            ;;
    esac
done

if [ -n "$ACTION" ]; then
    case "$ACTION" in
        sendinfo|device_info|send_device_info)
            # run once then exit
            send_device_info
            exit $?
            ;;
        *)
            echo "Unknown action: $ACTION"
            exit 2
            ;;
    esac
fi
# ---------------- end CLI action handling ----------------

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

# Cleanup on exit
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
# ---------------- end main loop setup ----------------
