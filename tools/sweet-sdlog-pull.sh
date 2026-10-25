#!/bin/bash
# Read the spes diagnostics area from the END of the SD card (card in a USB reader).
#   sudo tools/sweet-sdlog-pull.sh /dev/sdX OUTDIR
# Reads only the last 16392 sectors of the card; writes OUTDIR/console.txt and
# OUTDIR/live.dtb (when the kernel was booted with sddtb=<address>).
set -euo pipefail
dev=${1:?usage: sweet-sdlog-pull.sh /dev/sdX OUTDIR}; out=${2:?OUTDIR}
[[ -b $dev ]] || { echo "$dev is not a block device" >&2; exit 1; }
mkdir -p "$out"
here=$(dirname "$0")
sectors=$(( $(blockdev --getsize64 "$dev") / 512 ))
log=$(( sectors - 8200 )); dtb=$(( log - 8192 ))
dd if="$dev" of="$out/log.bin" bs=512 skip=$log count=8200 status=none
dd if="$dev" of="$out/dtb.bin" bs=512 skip=$dtb count=8192 status=none
python3 "$here/sweet-log.py" "$out/log.bin" "$out/console.txt" || echo "no readable log header" >&2
python3 - "$out/dtb.bin" "$out/live.dtb" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
if d[:7] != b'SPESDTB':
    print('no device tree saved (boot with sddtb=0x454fd000)'); sys.exit(0)
n = struct.unpack_from('<I', d, 8)[0]
open(sys.argv[2], 'wb').write(d[512:512 + n]); print('live.dtb', n, 'bytes')
PY
