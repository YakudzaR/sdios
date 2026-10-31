#!/usr/bin/env python3
"""Read-only: show the SD card layout (MBR, HFS+ volume header, modem pack) before growing the iOS root.
   sudo python3 tools/sweet-root-inspect.py /dev/sdb      (whole disk). Writes nothing."""
import struct, sys, os
dev = sys.argv[1]
f = open(dev, 'rb')
size = f.seek(0, 2); f.seek(0)
print("device %s: %d bytes = %d sectors (%.2f GiB)" % (dev, size, size // 512, size / 2**30))
f.seek(0); mbr = f.read(512)
print("MBR signature %02x%02x" % (mbr[510], mbr[511]))
part = None
for i in range(4):
    e = mbr[446 + 16 * i: 462 + 16 * i]
    boot, typ = e[0], e[4]
    lba, n = struct.unpack('<II', e[8:16])
    if typ:
        print("  part %d: boot %02x type 0x%02x lba %d sectors %d (%.2f GiB) end lba %d" % (i + 1, boot, typ, lba, n, n * 512 / 2**30, lba + n))
        if typ == 0xAF and part is None:
            part = (i, lba, n)
if part is None:
    sys.exit("no 0xAF partition")
_, plba, pn = part
f.seek(plba * 512 + 1024); vh = f.read(512)
sig, ver, attr = struct.unpack('>2sHI', vh[:8])
print("HFS+ header: signature %r version %d attributes 0x%08x (journaled=%s, unmounted=%s)" % (sig, ver, attr, bool(attr & 0x2000), bool(attr & 0x100)))
(jib,) = struct.unpack('>I', vh[12:16])
fc, dc, bs, tb, fb, na = struct.unpack('>6I', vh[32:56])
print("  files %d folders %d blockSize %d totalBlocks %d (%.2f GiB) freeBlocks %d (%.2f GiB) nextAllocation %d journalInfoBlock %d" % (fc, dc, bs, tb, tb * bs / 2**30, fb, fb * bs / 2**30, na, jib))
print("  partition %d bytes, volume %d bytes, slack %d bytes" % (pn * 512, tb * bs, pn * 512 - tb * bs))
names = ['allocationFile', 'extentsFile', 'catalogFile', 'attributesFile', 'startupFile']
for k, nm in enumerate(names):
    o = 112 + 80 * k
    ls, clump, tbk = struct.unpack('>QII', vh[o:o + 16])
    ext = [struct.unpack('>II', vh[o + 16 + 8 * j:o + 24 + 8 * j]) for j in range(8)]
    ext = [x for x in ext if x[1]]
    print("  %-15s logical %d bytes, %d blocks, extents %s" % (nm, ls, tbk, ext))
# alternate volume header (second to last 1024 bytes of the volume)
f.seek(plba * 512 + tb * bs - 1024); alt = f.read(2)
print("  alternate header at volume end: %r" % alt)
# modem pack
end = size // 512
hdr_lba = end - 8200 - 8192 - 1
f.seek(hdr_lba * 512); h = f.read(512)
if h[:8] == b'SPESMDM1':
    n = struct.unpack('<I', h[8:12])[0]
    lows = []
    for i in range(n):
        nm, lba, sz = struct.unpack('<16sQQ', h[16 + 32 * i:48 + 32 * i])
        print("  pack %-10s lba %d size %d" % (nm.rstrip(b'\0').decode(), lba, sz))
        lows.append(lba)
    low = min(lows)
    print("  pack header at lba %d, lowest pack image at lba %d" % (hdr_lba, low))
    room = low - (plba + pn)
    print("FREE between root partition end and the pack: %d sectors = %.2f GiB" % (room, room * 512 / 2**30))
    print("max root size if grown: %.2f GiB (keep 1 GiB spare)" % ((low - plba) * 512 / 2**30))
else:
    print("no SPESMDM1 pack header at lba %d" % hdr_lba)
