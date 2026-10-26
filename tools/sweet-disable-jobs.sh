#!/bin/bash
# Turn off launchd jobs that only crash-loop on this phone (default: com.apple.syncdefaultsd), reversibly.
#   sudo bash tools/sweet-disable-jobs.sh /dev/sdX1 [LABEL ...]       disable
#   sudo bash tools/sweet-disable-jobs.sh --restore /dev/sdX1          put the original launchd.plist back
# Only /System/Library/xpc/launchd.plist changes; the original is kept next to it as launchd.plist.orig.
# fsck.hfsplus runs before and after, like tools/sweet-install-gpu.sh. Partition = the 16 GiB 0xAF one.
set -euo pipefail
RESTORE=0
if [ "${1:-}" = "--restore" ]; then RESTORE=1; shift; fi
PART=${1:?partition, e.g. /dev/sdb1}; shift || true
LABELS=("$@"); [ ${#LABELS[@]} -gt 0 ] || LABELS=(com.apple.syncdefaultsd)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
case "$PART" in *[0-9]) ;; *) echo "$PART does not look like a partition"; exit 1;; esac
command -v fsck.hfsplus >/dev/null || { echo "install hfsprogs (sudo apt install hfsprogs)"; exit 1; }
umount "$PART" 2>/dev/null || true
fsck.hfsplus -fy "$PART"
M=$(mktemp -d)
mount -t hfsplus -o rw,force "$PART" "$M"
trap 'umount "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
P="$M/System/Library/xpc/launchd.plist"
[ -f "$P" ] || { echo "no $P: wrong partition?"; exit 1; }
if [ $RESTORE = 1 ]; then
	[ -f "$P.orig" ] || { echo "no launchd.plist.orig: nothing to restore"; exit 1; }
	cp -p "$P.orig" "$P"
	echo "restored the original launchd.plist"
else
	[ -f "$P.orig" ] || cp -p "$P" "$P.orig"
	python3 -I - "$P" "${LABELS[@]}" <<'PY'
import os, plistlib, sys
path, labels = sys.argv[1], set(sys.argv[2:])
st = os.stat(path)
with open(path, 'rb') as f:
    plist = plistlib.load(f)
jobs = plist['LaunchDaemons']
gone = [k for k, j in jobs.items() if j.get('Label') in labels]
for k in gone:
    del jobs[k]
with open(path, 'wb') as f:
    plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
os.chown(path, st.st_uid, st.st_gid)
os.chmod(path, st.st_mode & 0o7777)
print('removed', len(gone), 'job(s) for', sorted(labels))
PY
fi
sync
umount "$M"; trap - EXIT; rmdir "$M"
fsck.hfsplus -fy "$PART"
echo done
