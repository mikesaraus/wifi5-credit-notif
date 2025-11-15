#!/bin/sh /etc/rc.common
# /etc/init.d/appendjs

START=99

start() {
    TARGET_DIR="/var/i/public/client/theme/static/js"
    TARGET_FILE=$(find "$TARGET_DIR" -maxdepth 1 -type f -name 'main.*.js' | head -n 1)
    TARGET_FILE="$TARGET_DIR/$(basename "$TARGET_FILE")"

    APPEND_SCRIPT=$(cat <<'EOF'
const script = document.createElement('script');
script.src = '/html/script.js';
document.body.appendChild(script);
EOF
)

    (
        logger -t appendjs "Waiting for $TARGET_FILE to appear..."
        while [ ! -f "$TARGET_FILE" ]; do
            sleep 2
        done
        logger -t appendjs "File found, appending script..."
        echo "$APPEND_SCRIPT" >> "$TARGET_FILE"
        logger -t appendjs "Append complete."
    ) &
}
