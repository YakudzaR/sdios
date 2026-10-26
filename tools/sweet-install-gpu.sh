#!/bin/bash
# Put the GPU libraries (userland-gpu CI build) into the iOS root on the SD card, nothing else.
#   sudo bash tools/sweet-install-gpu.sh /dev/sdX1 DYLIB_DIR     (the 16 GiB 0xAF partition, NOT the disk)
# Steps: fsck.hfsplus replays/checks the journal, mount read-write, copy three files into /topaz/lib
# (root:wheel 0755), unmount, fsck again. Does not touch the partition table or any other file.
# Take a backup of the partition first:  sudo dd if=/dev/sdX1 of=card-root-backup.img bs=4M status=progress
set -euo pipefail
PART=${1:?partition, e.g. /dev/sdb1}
SRC=${2:?directory with the three .dylib files}
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
case "$PART" in *[0-9]) ;; *) echo "$PART does not look like a partition"; exit 1;; esac
for f in libOSMesa.8.dylib libtopaz-gl.dylib libtopaz-inject.dylib; do [ -s "$SRC/$f" ] || { echo "missing $SRC/$f"; exit 1; }; done
command -v fsck.hfsplus >/dev/null || { echo "install hfsprogs (sudo apt install hfsprogs)"; exit 1; }
umount "$PART" 2>/dev/null || true
fsck.hfsplus -fy "$PART"
M=$(mktemp -d)
mount -t hfsplus -o rw,force "$PART" "$M"
trap 'umount "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
mkdir -p "$M/topaz/lib"
for f in libOSMesa.8.dylib libtopaz-gl.dylib libtopaz-inject.dylib; do
	cp "$SRC/$f" "$M/topaz/lib/$f"
	chown 0:0 "$M/topaz/lib/$f"; chmod 755 "$M/topaz/lib/$f"
done
chown 0:0 "$M/topaz" "$M/topaz/lib"; chmod 755 "$M/topaz" "$M/topaz/lib"
ls -l "$M/topaz/lib"
sync
umount "$M"; trap - EXIT; rmdir "$M"
fsck.hfsplus -fy "$PART"
echo "installed"
