#!/usr/bin/env bash
#
# service.sh — register a persistent macOS network service for a virtual
# interface (feth0) directly in the SystemConfiguration preferences, then
# restart configd to adopt it.
#
# Why not `networksetup -createnetworkservice`? It only accepts *hardware
# ports* and refuses virtual interfaces ("feth0 is not a valid hardware port
# name"). We write the same structure configd expects (mirroring the "iPhone
# USB" entry), then restart configd so it re-reads the preferences.
#
# Usage (run as root):
#   service.sh add <bsd-name> <service-name>
#   service.sh remove <bsd-name>
#
# Safety: backs up /Library/Preferences/SystemConfiguration/preferences.plist
# before every change.

set -euo pipefail

PLIST=/Library/Preferences/SystemConfiguration/preferences.plist
PB=/usr/libexec/PlistBuddy
action="${1:?usage: service.sh add|remove <bsd-name> [service-name]}"
DEV="${2:?usage: service.sh add|remove <bsd-name> [service-name]}"
NAME="${3:-USB Tethering}"

# --- helpers ---------------------------------------------------------------

backup_plist() {
    local bak="$PLIST.backup-$(date +%Y%m%d-%H%M%S)"
    /bin/cp "$PLIST" "$bak"
    echo "backup: $bak"
}

set_uuid() {
    "$PB" -c "Print :CurrentSet" "$PLIST" 2>/dev/null | sed 's#.*/##'
}

service_uuid_for_dev() {
    # Find the NetworkServices key whose Interface.DeviceName == $DEV
    local keys
    keys="$("$PB" -c "Print :NetworkServices" "$PLIST" 2>/dev/null | grep -E '^    [0-9A-F-]{36} = ' | sed -E 's/^    ([0-9A-F-]{36}) = .*/\1/')"
    for k in $keys; do
        local dn
        dn="$("$PB" -c "Print :NetworkServices:$k:Interface:DeviceName" "$PLIST" 2>/dev/null || true)"
        if [[ "$dn" == "$DEV" ]]; then
            echo "$k"
            return 0
        fi
    done
    return 1
}

# --- add -------------------------------------------------------------------

do_add() {
    local suid new uuid
    suid="$(set_uuid)"
    [[ -n "$suid" ]] || { echo "cannot determine current set"; exit 1; }
    if service_uuid_for_dev >/dev/null 2>&1; then
        echo "service for $DEV already exists: $(service_uuid_for_dev)"
        return 0
    fi
    uuid="$(uuidgen | tr 'A-Z' 'a-z')"
    backup_plist

    # 1. Service definition (mirrors "iPhone USB" entry)
    "$PB" -c "Add :NetworkServices:$uuid dict" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:Interface dict" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:Interface:DeviceName string $DEV" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:Interface:Hardware string Ethernet" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:Interface:Type string Ethernet" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:Interface:UserDefinedName string $NAME" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:DNS dict" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:IPv4 dict" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:IPv4:ConfigMethod string DHCP" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:IPv6 dict" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:IPv6:ConfigMethod string Automatic" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:Proxies dict" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:Proxies:ExceptionsList array" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:Proxies:ExceptionsList:0 string *.local" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:Proxies:ExceptionsList:1 string 169.254/16" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:Proxies:FTPPassive integer 1" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:SMB dict" "$PLIST"
    "$PB" -c "Add :NetworkServices:$uuid:UserDefinedName string $NAME" "$PLIST"

    # 2. Attach to the current set
    "$PB" -c "Add :Sets:$suid:Network:Service:$uuid dict" "$PLIST"
    "$PB" -c "Add :Sets:$suid:Network:Service:$uuid:__LINK__ string /NetworkServices/$uuid" "$PLIST"

    # 3. Append to the service order (safe: does not displace existing order)
    local n
    n="$("$PB" -c "Print :Sets:$suid:Network:Global:IPv4:ServiceOrder" "$PLIST" 2>/dev/null | grep -c '= ' || true)"
    "$PB" -c "Add :Sets:$suid:Network:Global:IPv4:ServiceOrder:$n string $uuid" "$PLIST"

    plutil -lint "$PLIST"
    echo "created service $NAME ($DEV) as $uuid"
}

# --- remove ----------------------------------------------------------------

do_remove() {
    local suid uuid
    suid="$(set_uuid)"
    uuid="$(service_uuid_for_dev || true)"
    if [[ -z "$uuid" ]]; then
        echo "no service for $DEV"
        return 0
    fi
    backup_plist
    "$PB" -c "Delete :NetworkServices:$uuid" "$PLIST"
    "$PB" -c "Delete :Sets:$suid:Network:Service:$uuid" "$PLIST" 2>/dev/null || true
    local order n
    order="$(mktemp)"
    "$PB" -c "Print :Sets:$suid:Network:Global:IPv4:ServiceOrder" "$PLIST" 2>/dev/null >"$order" || true
    n=0
    while "$PB" -c "Print :Sets:$suid:Network:Global:IPv4:ServiceOrder:$n" "$PLIST" >/dev/null 2>&1; do
        local v
        v="$("$PB" -c "Print :Sets:$suid:Network:Global:IPv4:ServiceOrder:$n" "$PLIST")"
        if [[ "$v" == "$uuid" ]]; then
            "$PB" -c "Delete :Sets:$suid:Network:Global:IPv4:ServiceOrder:$n" "$PLIST"
        else
            n=$((n+1))
        fi
    done
    rm -f "$order"
    plutil -lint "$PLIST"
    echo "removed service for $DEV ($uuid)"
}

# --- restart configd -------------------------------------------------------

apply() {
    echo "restarting configd to adopt the change..."
    /usr/bin/killall configd || true
    sleep 4
    echo "configd restarted"
    # Fallback: ensure feth0 has a DHCP lease either way
    if ifconfig feth0 >/dev/null 2>&1; then
        /usr/sbin/ipconfig set feth0 DHCP 2>/dev/null || true
        sleep 3
        echo "feth0: $(/usr/sbin/ipconfig getifaddr feth0 2>/dev/null || echo no-lease)"
    fi
}

case "$action" in
    add) do_add; apply ;;
    remove) do_remove; apply ;;
    *) echo "usage: service.sh add|remove <bsd-name> [service-name]"; exit 2 ;;
esac