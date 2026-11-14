#!/bin/bash
# READ-ONLY: look for the saved passcode lockout ("iPhone Unavailable") on the iOS root on the SD card.
#   sudo bash tools/spes-find-lockout.sh /dev/sdb1 > ~/Desktop/lockout-find.txt
# Mounts the partition read-only (no fsck, no writes) and lists files whose names or contents mention lockout/backoff/failed attempts.
set -euo pipefail
PART=${1:?partition, e.g. /dev/sdb1}
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
umount "$PART" 2>/dev/null || true
M=$(mktemp -d)
mount -t hfsplus -o ro,force "$PART" "$M"
trap 'umount "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
echo "== names =="
find "$M/private/var" -xdev \( -iname '*lockout*' -o -iname '*backoff*' -o -iname '*passcode*' -o -iname '*failedattempt*' -o -iname '*unavailable*' \) 2>/dev/null | sed "s#$M##" | head -40
echo "== plist contents (SpringBoard / coreauth / keybag / backboard / Preferences) =="
for d in "$M/private/var/mobile/Library/Preferences" "$M/private/var/root/Library/Preferences" "$M/private/var/preferences" "$M/private/var/db" "$M/private/var/keybags"; do
  [ -d "$d" ] || continue
  grep -rIl -a -i -E 'lockout|backoff|failedattempt|FailedPasscode|unavailable' "$d" 2>/dev/null | sed "s#$M##" | head -20
  grep -rl -a -E 'ockout|ackoff|ailedAttempt' "$d" 2>/dev/null | sed "s#$M##" | head -20
done | sort -u
echo "== newest files in Preferences dirs =="
find "$M/private/var/mobile/Library/Preferences" "$M/private/var/root/Library/Preferences" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort -r | head -15 | sed "s#$M##"
