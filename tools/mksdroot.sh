#!/bin/bash
# Put the iOS HFS+ root image on a microSD card as an MBR partition of type 0xAF,
# for the spes SD root driver (rd=ufsroot0 finds type 0xAF, or sdpart=N).
#
#   sudo mksdroot.sh /dev/sdX ios16-root.img          (a real card: ERASES it)
#   mksdroot.sh --test-file card.img ios16-root.img    (rehearsal on a plain file)
#
# Safety: refuses anything that is not a removable disk of 8..512 GB unless the
# target is a regular file (--test-file); shows the disk and asks you to type its
# name. Nothing else on the computer is touched.
set -euo pipefail

testfile=0
if [[ ${1:-} == --test-file ]]; then testfile=1; shift; fi
[[ $# -eq 2 ]] || { sed -n '2,10p' "$0"; exit 2; }
dev=$1 img=$2
[[ -f $img ]] || { echo "no such image: $img" >&2; exit 1; }
imgbytes=$(stat -c %s "$img")
(( imgbytes % 512 == 0 )) || { echo "image size is not a multiple of 512" >&2; exit 1; }

if (( testfile )); then
	[[ -f $dev ]] || { echo "--test-file needs an existing regular file" >&2; exit 1; }
	devbytes=$(stat -c %s "$dev")
else
	[[ -b $dev ]] || { echo "$dev is not a block device" >&2; exit 1; }
	name=$(basename "$dev")
	[[ $name =~ [0-9]$ && ! $name =~ ^mmcblk[0-9]+$ ]] && { echo "give the whole disk, not a partition" >&2; exit 1; }
	[[ $(cat /sys/block/$name/removable 2>/dev/null || echo 0) == 1 || $name == mmcblk* ]] || \
		{ echo "$dev is not removable: refusing" >&2; exit 1; }
	devbytes=$(blockdev --getsize64 "$dev")
	(( devbytes >= 8*1024**3 && devbytes <= 512*1024**3 )) || { echo "$dev is not 8..512 GB: refusing" >&2; exit 1; }
	lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS "$dev"
	echo "ALL DATA ON $dev WILL BE ERASED."
	read -r -p "Type the disk name ($name) to continue: " ans
	[[ $ans == "$name" ]] || { echo "aborted"; exit 1; }
	for p in $(lsblk -nrpo NAME "$dev" | tail -n +2); do umount "$p" 2>/dev/null || true; done
fi

start=2048
need=$(( imgbytes / 512 ))
(( (start + need) * 512 <= devbytes )) || { echo "image does not fit on the card" >&2; exit 1; }

# One partition, type 0xAF, exactly the size of the image (the rest stays unused).
# A fresh MBR is built here (no sfdisk needed): zero boot code, one entry, 0x55AA.
python3 - "$start" "$need" <<'PY' | dd of="$dev" bs=512 count=1 conv=notrunc,fsync status=none
import struct, sys
start, count = int(sys.argv[1]), int(sys.argv[2])
mbr = bytearray(512)
struct.pack_into('<I', mbr, 440, 0x53504553)                    # disk signature "SPES"
mbr[446:462] = struct.pack('<B3sB3sII', 0, b'\xfe\xff\xff', 0xAF, b'\xfe\xff\xff', start, count)
mbr[510:512] = b'\x55\xaa'
sys.stdout.buffer.write(mbr)
PY
echo "partition table written: type 0xAF, start LBA $start, $need sectors"

dd if="$img" of="$dev" bs=1M seek=$(( start * 512 / 1048576 )) conv=fsync,notrunc status=progress
sync
# Verify: read the partition back and compare with the image.
cmp -n "$imgbytes" <(dd if="$dev" bs=1M skip=$(( start * 512 / 1048576 )) status=none) "$img" && echo "VERIFIED: card matches the image"
