#!/bin/bash
# nord_diag.sh — collect NordVPN-relevant diagnostics (run as root)
echo "=== pf rules ==="
/sbin/pfctl -s rules 2>&1 | head -20
echo
echo "=== NordVPN app recent logs ==="
log show --last 15m --predicate 'process == "NordVPN"' --style compact 2>/dev/null | tail -30
echo
echo "=== connectivity / internet mentions (any process) ==="
log show --last 15m --predicate 'eventMessage CONTAINS[c] "no internet" OR eventMessage CONTAINS[c] "connectivity" OR eventMessage CONTAINS[c] "internet connection"' --style compact 2>/dev/null | tail -15