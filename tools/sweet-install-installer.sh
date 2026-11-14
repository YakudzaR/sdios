#!/bin/bash
# Put the topaz-install helper (installer CI build, branch builds-installer) into /topaz/bin on the iOS root on the SD card
# as a SETUID ROOT program (it has to write root-owned files into /Applications), and create the drop folder.
#   sudo bash tools/sweet-install-installer.sh /dev/sdX1 PATH/TO/topaz-install      (the 0xAF partition, NOT the disk)
# fsck.hfsplus, mount read-write, copy one file (root:wheel, mode 4755), create /private/var/mobile/Media/Install
# (mobile-owned, so files can be put there), unmount, fsck again. Back up the partition first.
set -euo pipefail
PART=${1:?partition, e.g. /dev/sdb1}
SRC=${2:?path to topaz-install}
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
cp "$SRC" "$M/topaz/bin/topaz-install"
chown 0:0 "$M/topaz/bin/topaz-install"; chmod 4755 "$M/topaz/bin/topaz-install"
mkdir -p "$M/private/var/mobile/Media/Install"
chown 501:501 "$M/private/var/mobile/Media/Install"; chmod 777 "$M/private/var/mobile/Media/Install"
ls -l "$M/topaz/bin"; ls -ld "$M/private/var/mobile/Media/Install"
sync
umount "$M"; trap - EXIT; rmdir "$M"
fsck.hfsplus -fy "$PART"
echo "installed"
