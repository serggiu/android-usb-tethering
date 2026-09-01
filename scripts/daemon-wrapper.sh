#!/usr/bin/env bash
#
# samsung-tethering-daemon — launchd wrapper for the TetherKit RNDIS driver.
#
# Runs the user-space driver, waits for the feth0 interface the driver
# creates, then hands it a DHCP lease from the phone. Exits when the driver
# exits (e.g. phone unplugged / tethering toggled off). Not restarted by
# launchd; start it with:  sudo launchctl bootstrap system \
#                             /Library/LaunchDaemons/com.samsung-tethering.driver.plist
#
# Logs to /var/log/samsung-tethering.log (see the plist).

set -euo pipefail

BIN="${1:?usage: samsung-tethering-daemon /path/to/tetherkit-cli}"
LOG="${LOG:-/var/log/samsung-tethering.log}"

echo "=== samsung-tethering-daemon started $(date '+%Y-%m-%d %H:%M:%S') ==="

# Start the driver in the background (the wrapper stays around to configure
# the interface once feth0 exists).
"$BIN" &
DRIVER_PID=$!

# Wait for the feth0 interface (driver creates it right after RNDIS init).
FETH_UP=0
for i in $(seq 1 30); do
    if ifconfig feth0 >/dev/null 2>&1; then
        FETH_UP=1
        break
    fi
    if ! kill -0 "$DRIVER_PID" 2>/dev/null; then
        echo "driver exited before creating feth0; tail tetherkit output below"
        break
    fi
    sleep 1
done

if [[ "$FETH_UP" -eq 1 ]]; then
    echo "feth0 appeared; requesting DHCP lease..."
    /usr/sbin/ipconfig set feth0 DHCP
    sleep 3
    IP="$(/usr/sbin/ipconfig getifaddr feth0 2>/dev/null || true)"
    GW="$(/usr/sbin/ipconfig getoption feth0 router 2>/dev/null || true)"
    echo "feth0: ip=${IP:-none} gateway=${GW:-none}"
fi

# Keep running until the driver exits.
wait "$DRIVER_PID" || true
echo "=== driver exited; daemon stopping $(date '+%Y-%m-%d %H:%M:%S') ==="