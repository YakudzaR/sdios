#!/bin/bash
# Put the lsreg helper (lsreg CI build, branch builds-lsreg) into /topaz/bin on the iOS root on the SD card.
#   sudo bash tools/sweet-install-lsreg.sh /dev/sdX1 PATH/TO/lsreg      (the 0xAF partition, NOT the disk)
# fsck.hfsplus, mount read-write, copy one file (root:wheel 0755), unmount, fsck again. Back up the partition first.
set -euo pipefail
PART=${1:?partition, e.g. /dev/sdb1}
SRC=${2:?path to lsreg}
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
case "$PART" in *[0-9]) ;; *) echo "$PART does not look like a partition"; exit 1;; esac
[ -s "$SRC" ] || { echo "missing $SRC"; exit 1; }
command -v fsck.hfsplus >/dev/null || { echo "install hfsprogs"; exit 1; }
umount "$PART" 2>/dev/null || true
fsck.hfsplus -fy "$PART"
M=$(mktemp -d)
mount -t hfsplus -o rw,force "$PART" "$M"
trap 'umount "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
mkdir -p "$M/topaz/bin"
cp "$SRC" "$M/topaz/bin/lsreg"
chown 0:0 "$M/topaz/bin/lsreg"; chmod 755 "$M/topaz/bin/lsreg"
ls -l "$M/topaz/bin"
sync
umount "$M"; trap - EXIT; rmdir "$M"
fsck.hfsplus -fy "$PART"
echo "installed"
