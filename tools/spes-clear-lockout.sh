#!/bin/bash
# Reset SpringBoard's saved failed-passcode counter and lockout time (SBDeviceLockFailedAttempts, SBDeviceLockBlockTime..., SBDeviceLockBlocked) on the iOS root on the SD card.
#   sudo bash tools/spes-clear-lockout.sh /dev/sdb1     (the 27 GiB 0xAF partition, NOT the disk)
# fsck.hfsplus, mount read-write, back up com.apple.springboard.plist next to itself, set those keys to 0/removed,
# unmount, fsck again. Nothing else is touched.
set -euo pipefail
PART=${1:?partition, e.g. /dev/sdb1}
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
case "$PART" in *[0-9]) ;; *) echo "$PART does not look like a partition"; exit 1;; esac
command -v fsck.hfsplus >/dev/null || { echo "install hfsprogs (sudo apt install hfsprogs)"; exit 1; }
umount "$PART" 2>/dev/null || true
fsck.hfsplus -fy "$PART"
M=$(mktemp -d)
mount -t hfsplus -o rw,force "$PART" "$M"
trap 'umount "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
P="$M/private/var/mobile/Library/Preferences/com.apple.springboard.plist"
[ -f "$P" ] || { echo "missing $P"; exit 1; }
cp -p "$P" "$P.before-lockout-clear"
python3 -I - "$P" <<'PY'
import plistlib, sys
p = sys.argv[1]
raw = open(p, 'rb').read()
fmt = plistlib.FMT_BINARY if raw[:6] == b'bplist' else plistlib.FMT_XML
d = plistlib.loads(raw)
print('SBDeviceLockFailedAttempts was', d.get('SBDeviceLockFailedAttempts'))
d['SBDeviceLockFailedAttempts'] = 0
print('SBDeviceLockBlockTimeIntervalSinceReferenceDate was', d.pop('SBDeviceLockBlockTimeIntervalSinceReferenceDate', None))
d['SBDeviceLockBlocked'] = False
open(p, 'wb').write(plistlib.dumps(d, fmt=fmt))
print('now', plistlib.loads(open(p, 'rb').read()).get('SBDeviceLockFailedAttempts'))
PY
ls -l "$P" "$P.before-lockout-clear"
sync
umount "$M"; trap - EXIT; rmdir "$M"
fsck.hfsplus -fy "$PART"
echo "done"
