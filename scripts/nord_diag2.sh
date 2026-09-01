#!/bin/bash
# nord_diag2.sh — dig into NordVPN's own log subsystem + Shield extension
echo "=== NordVPN app subsystem logs (last 20m, non-CFNetwork) ==="
log show --last 20m --predicate 'process == "NordVPN" AND NOT eventMessage CONTAINS[c] "CFNetwork"' --style compact 2>/dev/null | tail -40
echo
echo "=== Shield / network extension logs ==="
log show --last 20m --predicate 'process CONTAINS[c] "nordvpn.macos.Shield" OR process CONTAINS[c] "nordvpn.macos.helper"' --style compact 2>/dev/null | tail -25
echo
echo "=== any 'internet' / 'offline' / 'reachab' mentions in NordVPN ==="
log show --last 20m --predicate 'process == "NordVPN" AND (eventMessage CONTAINS[c] "internet" OR eventMessage CONTAINS[c] "offline" OR eventMessage CONTAINS[c] "reachab" OR eventMessage CONTAINS[c] "network")' --style compact 2>/dev/null | tail -25