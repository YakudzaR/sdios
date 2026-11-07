#!/bin/bash
# Live iOS kernel log from the spes phone over USB (boot an image with spesusb=2).
# Usage: sudo bash tools/spes-usb-log.sh [logfile]   (Ctrl+C to stop)
set -e
OUT="${1:-}"
IF=""
for i in $(seq 1 60); do
  IF=$(ls /sys/class/net | grep -m1 '^enx02005e77ee01$' || true)
  [ -n "$IF" ] && break
  [ "$i" = 1 ] && echo "waiting for the phone's USB Ethernet (enx02005e77ee01)..."
  sleep 1
done
[ -z "$IF" ] && { echo "interface not found: is the phone booted with spesusb=2 and plugged in?"; exit 1; }
nmcli device set "$IF" managed no 2>/dev/null || true
ip addr replace 192.168.7.1/24 dev "$IF"
ip link set "$IF" up
echo "$IF up as 192.168.7.1, listening on UDP 5140"
if [ -n "$OUT" ]; then nc -ukl 5140 | tee "$OUT"; else nc -ukl 5140; fi
