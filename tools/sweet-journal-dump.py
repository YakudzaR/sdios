#!/usr/bin/env python3
"""Read-only: walk the HFS+ journal of a partition image or partition and check it parses cleanly.
   python3 tools/sweet-journal-dump.py IMAGE_OR_PARTITION [--disk-lba N]      (for a whole disk give the partition start sector)
Prints every transaction (block list header) with its checksum status and where the chain ends."""
import struct, sys
def ck(b):
    c = 0
    for x in b: c = ((c << 8) ^ (c + x)) & 0xFFFFFFFF
    return c
path = sys.argv[1]; base = 0
if '--disk-lba' in sys.argv: base = int(sys.argv[sys.argv.index('--disk-lba') + 1]) * 512
f = open(path, 'rb')
def rd(o, n): f.seek(base + o); return f.read(n)
vh = rd(1024, 512); bs = struct.unpack('>I', vh[40:44])[0]; jib = struct.unpack('>I', vh[12:16])[0]
ji = rd(jib * bs, 512); jflags = struct.unpack('>I', ji[:4])[0]; joff, jsz = struct.unpack('>QQ', ji[36:52])
print("journal info flags 0x%x offset %d size %d" % (jflags, joff, jsz))
jh = rd(joff, 512)
bo = '<' if struct.unpack('<I', jh[:4])[0] == 0x4a4e4c78 else '>'
magic, endian, start, end, size, blsz, hck, jhsz = struct.unpack(bo + 'IIQQQIII', jh[:44])
hh = bytearray(jh[:44]); hh[28:32] = b'\0\0\0\0'
print("header: %s-endian start %d end %d size %d blhdr_size %d jhdr_size %d checksum %08x computed %08x %s" % (
    'little' if bo == '<' else 'big', start, end, size, blsz, jhsz, hck, ck(hh), 'OK' if hck == ck(hh) else 'MISMATCH'))
print("device block size (jhdr_size) = %d" % jhsz)
pos = start; n = 0; total = 0
while pos != end and n < 100000:
    bl = rd(joff + pos, blsz)
    maxb, nb, used, bck, pad = struct.unpack(bo + 'HHIII', bl[:16])
    b2 = bytearray(bl[:32]); b2[8:12] = b'\0\0\0\0'
    okc = (bck == ck(b2))
    bi = [struct.unpack(bo + 'QII', bl[16 + 16 * i:32 + 16 * i]) for i in range(nb)]
    nxt = bi[0][0]
    print("txn %d at %d: max %d num %d bytes_used %d checksum %s binfo[0]=(%d,%d,%d)" % (n, pos, maxb, nb, used, 'OK' if okc else 'MISMATCH %08x/%08x' % (bck, ck(b2)), bi[0][0], bi[0][1], bi[0][2]))
    for i in range(1, nb):
        total += 1
        if i <= 3 or bi[i][0] == 0xFFFFFFFFFFFFFFFF: print("   blk %d: bnum %d bsize %d next %d" % (i, bi[i][0], bi[i][1], bi[i][2]))
    if not okc: break
    pos = nxt; n += 1
print("chain ended at %d (journal end is %d): %s; %d transactions, %d data blocks" % (pos, end, 'MATCH' if pos == end else 'NO MATCH', n, total))
