#!/usr/bin/env bash
#
# samsung-tethering-daemon — event-driven wrapper for the TetherKit RNDIS
# driver. The IOKit watcher (samsung-tethering-watch) starts this when an
# Android phone is plugged in.
#
# Flow: make sure exactly one driver is running -> wait for the feth0
# interface -> request a DHCP lease -> register or refresh the persistent
# "USB Tethering" network service so System Settings shows it as Connected.
# Then hold while the link is up and exit when the phone disconnects. If the
# link died while the phone is still attached and tethering, exit 3 so the
# watcher retries (the driver can die without the phone leaving the bus).
#
# A driver already running (e.g. orphaned by a daemon restart, or started
# manually with ./bin/tether start) is reused, never duplicated — but the
# DHCP + service wiring still runs, because that is what makes the service
# display as Connected.
#
# Usage:  samsung-tethering-daemon [/path/to/tetherkit-cli] [/path/to/service.sh]
# (the watcher runs it without arguments; paths then fall back to defaults)
#
# Logs to /var/log/samsung-tethering.log (see the launchd plist).

set -euo pipefail

BIN="${1:-}"
SERVICE_SH="${2:-}"
LOG="${LOG:-/var/log/samsung-tethering.log}"
FETH_TIMEOUT="${FETH_TIMEOUT:-45}"   # give up if no RNDIS device attaches

if [[ -z "$BIN" ]]; then
    BIN="$(command -v tetherkit-cli 2>/dev/null || echo /opt/homebrew/bin/tetherkit-cli)"
fi
if [[ -z "$SERVICE_SH" ]]; then
    SERVICE_SH="/usr/local/bin/samsung-tethering-service.sh"
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- ensure exactly one driver is running ---
DRIVER_PID=""
if pgrep -x tetherkit-cli >/dev/null 2>&1; then
    log "driver already running; reusing it"
else
    log "=== USB device appeared; starting driver ==="
    "$BIN" >>"$LOG" 2>&1 &
    DRIVER_PID=$!
fi

# --- wait for feth0 ---
up=0
if ifconfig feth0 >/dev/null 2>&1; then
    up=1
else
    for i in $(seq 1 "$FETH_TIMEOUT"); do
        if ifconfig feth0 >/dev/null 2>&1; then
            up=1
            break
        fi
        if [[ -n "$DRIVER_PID" ]] && ! kill -0 "$DRIVER_PID" 2>/dev/null; then
            log "driver exited before feth0 appeared (not an RNDIS device?)"
            wait "$DRIVER_PID" 2>/dev/null || true
            exit 0
        fi
        sleep 1
    done
fi

if [[ "$up" -ne 1 ]]; then
    log "feth0 never appeared within ${FETH_TIMEOUT}s"
    if [[ -n "$DRIVER_PID" ]]; then
        kill "$DRIVER_PID" 2>/dev/null || true
        wait "$DRIVER_PID" 2>/dev/null || true
    fi
    exit 0
fi

# --- wire up the link (the part that makes System Settings show Connected) ---
log "feth0 present; requesting DHCP lease..."
/usr/sbin/ipconfig set feth0 DHCP
sleep 3
IP="$(/usr/sbin/ipconfig getifaddr feth0 2>/dev/null || true)"
GW="$(/usr/sbin/ipconfig getoption feth0 router 2>/dev/null || true)"
log "feth0: ip=${IP:-none} gateway=${GW:-none}"

if [[ -n "$SERVICE_SH" && -n "$IP" ]]; then
    if [[ "$(networksetup -listallnetworkservices 2>/dev/null)" == *"USB Tethering"* ]]; then
        if "$SERVICE_SH" refresh feth0 >>"$LOG" 2>&1; then
            log "network service 'USB Tethering' refreshed"
        else
            log "network service refresh failed (see above)"
        fi
    else
        if "$SERVICE_SH" add feth0 "USB Tethering" >>"$LOG" 2>&1; then
            log "network service 'USB Tethering' registered"
        else
            log "network service registration failed (see above)"
        fi
    fi
fi

# --- hold while the link is up ---
while ifconfig feth0 >/dev/null 2>&1; do
    sleep 2
done
log "link dropped"

if [[ -n "$DRIVER_PID" ]]; then
    kill "$DRIVER_PID" 2>/dev/null || true
    wait "$DRIVER_PID" 2>/dev/null || true
    # If the driver died (keep-alive failures etc.) while the phone is still
    # attached and tethering, ask the watcher to retry instead of waiting for
    # a fresh USB arrival.
    if "$BIN" --list 2>/dev/null | grep -q 'RNDIS devices found'; then
        log "phone still present; asking the watcher to retry"
        exit 3
    fi
fi
log "=== done (waiting for the next USB event) ==="
exit 0
