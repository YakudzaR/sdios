#!/usr/bin/env python3
"""Grow the HFS+ (HFSX) iOS root on the SD card in place, without moving or reformatting anything.

  Test on a COPY of the backup first (partition image, not the card):
      cp card-root-backup.img test.img
      python3 tools/sweet-grow-root.py --image test.img --gib 27            (dry run)
      python3 tools/sweet-grow-root.py --image test.img --gib 27 --write
      sudo fsck.hfsplus -fn test.img ; sudo mount -t hfsplus -o ro,force test.img /mnt/t ; df -h /mnt/t
  Real card (whole disk, after fsck.hfsplus -fy on the partition and a backup):
      sudo python3 tools/sweet-grow-root.py --disk /dev/sdb --gib 27 --backup card-root-backup.img            (dry run)
      sudo python3 tools/sweet-grow-root.py --disk /dev/sdb --gib 27 --backup card-root-backup.img --write

What it changes (nothing else is touched), in this order, so an interruption before step 3 leaves the old volume intact:
  1. the allocation file (bitmap) grows by a new extent at the start of the new space; its bits are marked used
  2. new alternate volume header at the new end of the volume
  3. main volume header: totalBlocks, freeBlocks, allocationFile fork   (one 512-byte write)
  4. old alternate header is zeroed and its block is freed
  5. (disk mode only) the MBR entry of the 0xAF partition gets the new sector count
Refuses unless: HFS+/HFSX, 4096-byte blocks or any size, unmounted bit set, journal empty, new end below the modem pack.
"""
import struct, sys, os, argparse

import functools, time
print = functools.partial(print, flush=True)
T0 = time.time()
def step(m): print("[%5.1fs] %s" % (time.time() - T0, m))
def die(m): sys.exit("ERROR: " + m)

def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--image'); g.add_argument('--disk')
    ap.add_argument('--gib', type=float, required=True)
    ap.add_argument('--backup'); ap.add_argument('--write', action='store_true')
    a = ap.parse_args()
    step("opening %s (%s)" % (a.image or a.disk, 'WRITE mode' if a.write else 'dry run, read only'))
    f = open(a.image or a.disk, 'r+b' if a.write else 'rb')
    size = f.seek(0, 2)
    base = 0; plba = 0; part_i = None
    if a.disk:
        f.seek(0); mbr = bytearray(f.read(512))
        if mbr[510:512] != b'\x55\xaa': die("no MBR")
        for i in range(4):
            e = mbr[446 + 16 * i:462 + 16 * i]
            if e[4] == 0xAF: part_i = i; plba, pn = struct.unpack('<II', e[8:16]); break
        if part_i is None: die("no 0xAF partition")
        base = plba * 512
        if not a.backup or not os.path.exists(a.backup): die("--backup IMAGE is required with --disk")
        if os.path.getsize(a.backup) < pn * 512: die("backup image is smaller than the partition")
        print("backup: %s (%d bytes)" % (a.backup, os.path.getsize(a.backup)))
    def rd(off, n): f.seek(base + off); return f.read(n)
    def wr(off, d): f.seek(base + off); f.write(d)
    step("reading the HFS+ volume header")
    vh = bytearray(rd(1024, 512))
    sig, ver, attr = struct.unpack('>2sHI', vh[:8])
    step("signature %r attributes 0x%08x" % (sig, attr))
    if sig not in (b'H+', b'HX'): die("not HFS+: %r" % sig)
    if not attr & 0x100: die("volume not marked unmounted; run: sudo fsck.hfsplus -fy PARTITION")
    jib = struct.unpack('>I', vh[12:16])[0]
    bs, tb, fb = struct.unpack('>3I', vh[40:52])
    oldbytes = tb * bs
    if attr & 0x2000:
        ji = rd(jib * bs, 512)
        jflags = struct.unpack('>I', ji[:4])[0]
        joff, jsz = struct.unpack('>QQ', ji[36:52])   # flags u32, device_signature u32[8], offset u64, size u64
        if jflags & 1 and not jflags & 2:   # in filesystem
            step("journal info: flags 0x%x offset %d size %d" % (jflags, joff, jsz))
            jh = rd(joff, 512)
            magic, endian, jstart, jend = struct.unpack('>IIQQ', jh[:24])
            if magic != 0x4a4e4c78: die("bad journal header magic %08x" % magic)
            if jstart != jend: die("journal not empty (start %d end %d); run fsck.hfsplus -fy and mount/unmount once" % (jstart, jend))
            print("journal at %d size %d: empty" % (joff, jsz))
        else:
            print("journal flags 0x%x: not on this volume; check manually" % jflags)
    newtb = int(a.gib * 2**30) // bs
    if newtb <= tb: die("new size not bigger than the volume")
    newbytes = newtb * bs
    if a.image is None:
        # modem pack limit
        end = size // 512
        h = bytearray(); f.seek((end - 8200 - 8192 - 1) * 512); h = f.read(512)
        if h[:8] != b'SPESMDM1': die("no modem pack header found; refusing")
        n = struct.unpack('<I', h[8:12])[0]
        low = min(struct.unpack('<16sQQ', h[16 + 32 * i:48 + 32 * i])[1] for i in range(n))
        if plba * 512 + newbytes > (low - 2048) * 512: die("new end overlaps the modem pack (lowest image lba %d)" % low)
        print("new end lba %d, modem pack starts at lba %d" % (plba + newbytes // 512, low))
    # allocation file
    ao = 112
    alen, aclump, ablk = struct.unpack('>QII', vh[ao:ao + 16])
    ext = [list(struct.unpack('>II', vh[ao + 16 + 8 * j:ao + 24 + 8 * j])) for j in range(8)]
    used = [e for e in ext if e[1]]
    need_bytes = (newtb + 7) // 8
    need_blocks = (need_bytes + bs - 1) // bs
    add = need_blocks - ablk
    if add < 0: add = 0
    if len(used) >= 8 and add: die("no free extent slot in the allocation file")
    if sum(e[1] for e in used) != ablk: die("allocation file extents do not sum up")
    newstart = tb          # first block of the new space
    print("blocks %d -> %d; bitmap %d -> %d blocks (+%d at block %d)" % (tb, newtb, ablk, need_blocks, add, newstart))
    step("reading the allocation bitmap (%d blocks)" % ablk)
    # read old bitmap
    bm = bytearray()
    for s, c in used: bm += rd(s * bs, c * bs)
    if len(bm) < (tb + 7) // 8: die("bitmap shorter than volume")
    bm = bytearray(bm[:ablk * bs])
    # free the old last block (alternate header lives there)
    last = tb - 1
    if not bm[last // 8] & (0x80 >> (last % 8)): die("old last block is already free?!")
    bm[last // 8] &= ~(0x80 >> (last % 8)) & 0xFF
    bm += bytearray(need_blocks * bs - len(bm))
    for b in range(newstart, newstart + add):
        bm[b // 8] |= 0x80 >> (b % 8)
    for b in range(newtb, len(bm) * 8):    # padding bits past the end are set
        bm[b // 8] |= 0x80 >> (b % 8)
    freecnt = sum(8 - bin(x).count('1') for x in bm[:need_bytes]) if False else None
    step("counting free blocks over %d blocks (a few seconds)" % newtb)
    # recount free blocks over the valid range
    nfree = 0
    for b in range(newtb):
        if not bm[b // 8] & (0x80 >> (b % 8)): nfree += 1
    print("freeBlocks %d -> %d" % (fb, nfree))
    if nfree != fb + (newtb - tb) - add + 1:
        print("note: recount differs from the expected %d (bitmap had other differences)" % (fb + (newtb - tb) - add + 1))
    # new header
    nvh = bytearray(vh)
    struct.pack_into('>I', nvh, 44, newtb)
    struct.pack_into('>I', nvh, 48, nfree)
    nlen = need_blocks * bs
    struct.pack_into('>QI', nvh, ao, nlen, aclump)
    struct.pack_into('>I', nvh, ao + 12, need_blocks)
    if add:
        ext[len(used)] = [newstart, add]
    for j, (s, c) in enumerate(ext):
        struct.pack_into('>II', nvh, ao + 16 + 8 * j, s, c)
    if not a.write:
        step("dry run finished: nothing was written. Add --write to apply."); return
    step("WRITING. step 1/5: bitmap")
    # 1. bitmap: rewrite old extents then the new one
    pos = 0
    allext = [e for e in ext if e[1]]
    for s, c in allext:
        wr(s * bs, bytes(bm[pos:pos + c * bs])); pos += c * bs
    f.flush(); os.fsync(f.fileno())
    step("step 2/5: new alternate volume header")
    # grow image file to the new size
    if a.image: f.truncate(newbytes) if size < newbytes + base else None
    # 2. alternate header at the new end
    wr(newbytes - 1024, bytes(nvh) + bytes(512)); f.flush(); os.fsync(f.fileno())
    step("step 3/5: main volume header")
    # 3. main header
    wr(1024, bytes(nvh)); f.flush(); os.fsync(f.fileno())
    step("step 4/5: clear the old alternate header")
    # 4. zero the old alternate header
    wr(oldbytes - 1024, bytes(1024)); f.flush(); os.fsync(f.fileno())
    step("step 5/5: partition table (disk mode only)")
    # 5. MBR
    if a.disk:
        struct.pack_into('<I', mbr, 446 + 16 * part_i + 12, newbytes // 512)
        f.seek(0); f.write(mbr); f.flush(); os.fsync(f.fileno())
        print("MBR updated: partition %d sectors" % (newbytes // 512))
    step("done")
    print("Now: sudo fsck.hfsplus -fy on the partition (re-read the table first: sudo partprobe /dev/sdb)")
main()
