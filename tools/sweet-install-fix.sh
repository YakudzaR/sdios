#!/bin/bash
# Put libtopaz-fix.dylib (userland-fix CI build, branch builds-fix) into /topaz/lib on the iOS root on the SD card.
#   sudo bash tools/sweet-install-fix.sh /dev/sdX1 PATH/TO/libtopaz-fix.dylib     (the 16 GiB 0xAF partition, NOT the disk)
# fsck.hfsplus, mount read-write, copy one file (root:wheel 0755), unmount, fsck again. Nothing else is touched.
# Take a backup of the partition first:  sudo dd if=/dev/sdX1 of=card-root-backup.img bs=4M status=progress
set -euo pipefail
PART=${1:?partition, e.g. /dev/sdb1}
SRC=${2:?path to libtopaz-fix.dylib}
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
case "$PART" in *[0-9]) ;; *) echo "$PART does not look like a partition"; exit 1;; esac
[ -s "$SRC" ] || { echo "missing $SRC"; exit 1; }
command -v fsck.hfsplus >/dev/null || { echo "install hfsprogs (sudo apt install hfsprogs)"; exit 1; }
umount "$PART" 2>/dev/null || true
fsck.hfsplus -fy "$PART"
M=$(mktemp -d)
mount -t hfsplus -o rw,force "$PART" "$M"
trap 'umount "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
mkdir -p "$M/topaz/lib"
cp "$SRC" "$M/topaz/lib/libtopaz-fix.dylib"
chown 0:0 "$M/topaz/lib/libtopaz-fix.dylib"; chmod 755 "$M/topaz/lib/libtopaz-fix.dylib"
ls -l "$M/topaz/lib"
sync
umount "$M"; trap - EXIT; rmdir "$M"
fsck.hfsplus -fy "$PART"
echo "installed"
