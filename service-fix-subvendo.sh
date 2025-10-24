#!/bin/sh /etc/rc.common
# /etc/init.d/appendjs

START=99

start() {
    TARGET_DIR="/var/i/public/client/theme/static/js"
    TARGET_FILE=$(find "$TARGET_DIR" -maxdepth 1 -type f -name 'main.*.js' | head -n 1)
    TARGET_FILE="$TARGET_DIR/$(basename "$TARGET_FILE")"

    APPEND_SCRIPT=$(cat <<'EOF'
document.addEventListener("DOMContentLoaded", () => {
  setTimeout(() => {
    let wifi_interface = {
      "eth1": { id: "main", name: "Main PISOWIFI" },
      "vlan.12": { id: "main", name: "Sub PISOWIFI" }
      // Add more interfaces as needed
    };

    document.querySelector(".content-wrapper .card .dropdown-toggle")?.click();

    setTimeout(() => {
      const clientInt = document.querySelector(
        ".content-wrapper .card .clientInfo tr:nth-child(3) > td:last-child"
      )?.textContent?.trim();
      const currentWifiID = wifi_interface[clientInt]?.id || "main";
      document.getElementById(currentWifiID)?.click();
    }, 500);
  }, 3000);
});
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
