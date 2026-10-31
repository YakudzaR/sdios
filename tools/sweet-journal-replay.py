#!/usr/bin/env python3
"""Replay the pending HFS+ journal of an iOS root (what iOS itself would do on its next mount), then mark it empty.
  python3 tools/sweet-journal-replay.py IMAGE                                      dry run (reads only, validates everything)
  python3 tools/sweet-journal-replay.py IMAGE --write
  sudo python3 tools/sweet-journal-replay.py /dev/sdb --disk-lba 2048 --backup BACKUP.img [--write]
All checksums are verified before anything is written. Data blocks are written first, the journal header (start=end) last,
so an interrupted run can simply be run again. Afterwards run: sudo fsck.hfsplus -fy PARTITION"""
import struct, sys, os, time
T0 = time.time()
def step(m): print("[%5.1fs] %s" % (time.time() - T0, m), flush=True)
def die(m): sys.exit("ERROR: " + m)
def ck(b):
    c = 0
    for x in b: c = ((c << 8) ^ (c + x)) & 0xFFFFFFFF
    return (~c) & 0xFFFFFFFF
a = sys.argv[1:]
if not a: die("usage: see the header of this file")
path = a[0]; write = '--write' in a; base = 0
if '--disk-lba' in a: base = int(a[a.index('--disk-lba') + 1]) * 512
if base:
    if '--backup' not in a: die("--backup IMAGE is required with --disk-lba")
    bk = a[a.index('--backup') + 1]
    if not os.path.exists(bk): die("backup not found: " + bk)
    print("backup: %s (%d bytes)" % (bk, os.path.getsize(bk)))
step("opening %s (%s)" % (path, "WRITE mode" if write else "dry run, read only"))
f = open(path, 'r+b' if write else 'rb')
def rd(o, n): f.seek(base + o); return f.read(n)
def wr(o, d): f.seek(base + o); f.write(d)
vh = rd(1024, 512)
if vh[:2] not in (b'H+', b'HX'): die("not HFS+")
bs, tb = struct.unpack('>II', vh[40:48]); vol = bs * tb
jib = struct.unpack('>I', vh[12:16])[0]
ji = rd(jib * bs, 512); jflags = struct.unpack('>I', ji[:4])[0]; joff, jsz = struct.unpack('>QQ', ji[36:52])
if jflags & 3 != 1: die("journal not inside the volume (flags 0x%x)" % jflags)
jh = bytearray(rd(joff, 512))
bo = '<' if struct.unpack('<I', jh[:4])[0] == 0x4a4e4c78 else '>'
magic, endian, start, end, size, blsz, hck, jhsz = struct.unpack(bo + 'IIQQQIII', jh[:44])
if magic != 0x4a4e4c78 or endian != 0x12345678: die("bad journal header")
hh = bytearray(jh[:44]); hh[36:40] = bytes(4)
if ck(hh) != hck: die("journal header checksum mismatch")
if start == end: step("journal already empty, nothing to do"); sys.exit(0)
def jread(off, n):
    out = b''
    while n:
        if off >= size: off -= size - jhsz
        c = min(n, size - off)
        out += rd(joff + off, c); off += c; n -= c
    return out
pos = start; plan = []; ntx = 0
while pos != end:
    bl = jread(pos, blsz)
    maxb, nb, used, bck, pad = struct.unpack(bo + 'HHIII', bl[:16])
    b2 = bytearray(bl[:32]); b2[8:12] = bytes(4)
    if ck(b2) != bck: die("transaction %d checksum mismatch at %d" % (ntx, pos))
    off = pos + blsz
    tot = blsz
    for i in range(1, nb):
        bnum, bsize, _ = struct.unpack(bo + 'QII', bl[16 + 16 * i:32 + 16 * i])
        if bnum == 0xFFFFFFFFFFFFFFFF: die("sparse block entry (not supported)")
        dst = bnum * jhsz
        if dst + bsize > vol: die("block %d of txn %d lies outside the volume (offset %d)" % (i, ntx, dst))
        plan.append((dst, off, bsize))
        off += bsize; tot += bsize
        if off >= size: off -= size - jhsz
    if tot != used: die("transaction %d size mismatch" % ntx)
    pos = pos + used
    if pos >= size: pos -= size - jhsz
    ntx += 1
step("validated %d transactions, %d blocks (%d bytes); chain ends at the journal end" % (ntx, len(plan), sum(p[2] for p in plan)))
if not write:
    step("dry run finished: nothing written. Add --write to apply."); sys.exit(0)
step("applying blocks in order")
for k, (dst, src, n) in enumerate(plan):
    wr(dst, jread(src, n))
    if k % 100 == 0: step("  block %d / %d" % (k, len(plan)))
f.flush(); os.fsync(f.fileno())
step("marking the journal empty (start = end)")
struct.pack_into(bo + 'Q', jh, 8, end)
h2 = bytearray(jh[:44]); h2[36:40] = bytes(4)
struct.pack_into(bo + 'I', jh, 36, ck(h2))
wr(joff, bytes(jh)); f.flush(); os.fsync(f.fileno())
step("done. Now run: sudo fsck.hfsplus -fy on the partition (it sets the clean flag)")
