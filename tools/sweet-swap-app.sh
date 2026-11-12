#!/bin/bash
# Swap the program of an Apple app on the iOS root (SD card) for the StressTest program that is already in /Applications.
# The app keeps its icon, bundle id and signature folder; the original program is kept as NAME.orig.
#   sudo bash tools/sweet-swap-app.sh /dev/sdX1 Camera          (swap in)
#   sudo bash tools/sweet-swap-app.sh /dev/sdX1 Camera undo     (put the original back)
# fsck.hfsplus before and after. Back up the partition first (dd if=/dev/sdX1 of=... bs=4M).
set -euo pipefail
PART=${1:?partition, e.g. /dev/sdb1}; APP=${2:?app name, e.g. Camera}; MODE=${3:-swap}
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
case "$PART" in *[0-9]) ;; *) echo "$PART does not look like a partition"; exit 1;; esac
command -v fsck.hfsplus >/dev/null || { echo "install hfsprogs"; exit 1; }
umount "$PART" 2>/dev/null || true
fsck.hfsplus -fy "$PART"
M=$(mktemp -d)
mount -t hfsplus -o rw,force "$PART" "$M"
trap 'umount "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
D="$M/Applications/$APP.app"; SRC="$M/Applications/StressTest.app/StressTest"
[ -d "$D" ] || { echo "no $D"; exit 1; }
if [ "$MODE" = undo ]; then
  [ -f "$D/$APP.orig" ] || { echo "no $APP.orig, nothing to undo"; exit 1; }
  rm -f "$D/$APP"; mv "$D/$APP.orig" "$D/$APP"; echo "restored"
else
  [ -f "$SRC" ] || { echo "StressTest.app is not installed"; exit 1; }
  [ -f "$D/$APP.orig" ] || cp -p "$D/$APP" "$D/$APP.orig"
  cp "$SRC" "$D/$APP"; chmod 755 "$D/$APP"; chown 0:0 "$D/$APP"; echo "swapped"
fi
ls -l "$D" | head -20
sync; umount "$M"; trap - EXIT; rmdir "$M"
fsck.hfsplus -fy "$PART"
echo done
