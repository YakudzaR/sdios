#!/usr/bin/env python3
"""
Put the phone's modem firmware and modem data into a raw spare area at the END of the
SD card, where the spes kernel (sweet_sd_read_part, bsd/dev/sweet_ufs.c) reads it for Wi-Fi.

  sudo python3 tools/spes-modem-pack.py /dev/sdb --dir DIR            # dry run: shows the plan
  sudo python3 tools/spes-modem-pack.py /dev/sdb --dir DIR --write    # really writes

DIR holds the five copies pulled from the phone with `adb pull`:
  modem_a.img  modemst1.img  modemst2.img  fsg.img  fsc.img

The target is the whole DISK (/dev/sdb), never the partition (/dev/sdb1). Only sectors that
are inside none of the partitions of the card's MBR are written, and the area ends before
the card's diagnostic areas:

  [ ... root partition ... | free | modem pack | header | DTB copy 8192 | log 8200 ]
                                                          ^ card end - 16392 - 1

The pack is: the five images as they are, plus "fwtable", the list of every file of the
modem_a FAT volume (path, size, where it is) which this tool reads out of modem_a itself.
Nothing here is specific to one firmware version.

The modem data (modemst1/2, fsg, fsc) is the phone's IMEI and radio calibration: the images
stay on your computer and go onto your own card only.

  python3 tools/spes-modem-pack.py --selftest        # checks the FAT reader (no card needed)
"""
import argparse, hashlib, os, struct, sys

SECTOR = 512
LOG_SECTORS = 8200           # SD_LOG_SECTORS in sweet_ufs.c
DTB_SECTORS = 8192           # SD_DTB_SECTORS
MAGIC = b"SPESMDM1"
FWT_MAGIC = b"SPESFWT1"
PARTS = ["modem_a", "modemst1", "modemst2", "fsg", "fsc"]   # names the kernel asks for
ALIGN = 2048                 # 1 MiB


# ------------------------------------------------------------------ FAT reader

class Fat:
    def __init__(self, f):
        self.f = f
        b = self.rd(0, 512)
        if b[510:512] != b"\x55\xaa":
            raise SystemExit("modem_a: no boot sector signature (is it a raw FAT image?)")
        self.bps, self.spc, self.rsvd, self.nfats, self.rootents, self.ts16, _m, self.fs16 = \
            struct.unpack_from("<HBHBHHBH", b, 11)
        ts32, = struct.unpack_from("<I", b, 32)
        self.fs32, = struct.unpack_from("<I", b, 36)
        self.rootclus, = struct.unpack_from("<I", b, 44)
        if self.bps not in (512, 1024, 2048, 4096) or self.spc == 0 or self.nfats == 0:
            raise SystemExit("modem_a: not a FAT boot sector (bps=%d spc=%d)" % (self.bps, self.spc))
        self.fatsz = self.fs16 or self.fs32
        total = self.ts16 or ts32
        self.root_sectors = (self.rootents * 32 + self.bps - 1) // self.bps
        self.data_start = self.rsvd + self.nfats * self.fatsz + self.root_sectors
        self.nclus = (total - self.data_start) // self.spc
        if self.nclus < 4085:
            raise SystemExit("modem_a: FAT12 is not supported")
        self.fat32 = self.nclus >= 65525
        self.csize = self.spc * self.bps
        fat = self.rd(self.rsvd * self.bps, self.fatsz * self.bps)
        if self.fat32:
            self.fat = struct.unpack("<%dI" % (len(fat) // 4), fat)
            self.eoc = 0x0ffffff8
        else:
            self.fat = struct.unpack("<%dH" % (len(fat) // 2), fat)
            self.eoc = 0xfff8
        self.total_bytes = total * self.bps

    def rd(self, off, n):
        self.f.seek(off)
        d = self.f.read(n)
        if len(d) != n:
            raise SystemExit("modem_a: image is truncated (wanted %d bytes at %d)" % (n, off))
        return d

    def clus_off(self, c):
        return self.data_start * self.bps + (c - 2) * self.csize

    def chain(self, c):
        out = []
        seen = 0
        while 2 <= c < len(self.fat) and c < self.eoc:
            out.append(c)
            c = self.fat[c]
            seen += 1
            if seen > self.nclus + 2:
                raise SystemExit("modem_a: FAT chain loop")
        return out

    def extents(self, c, size):
        """[(byte offset, length)] of a file, runs of consecutive clusters merged"""
        ext = []
        left = size
        for cl in self.chain(c):
            if left <= 0:
                break
            off = self.clus_off(cl)
            ln = min(self.csize, left)
            if ext and ext[-1][0] + ext[-1][1] == off and ext[-1][1] % self.csize == 0:
                ext[-1] = (ext[-1][0], ext[-1][1] + ln)
            else:
                ext.append((off, ln))
            left -= ln
        if left > 0:
            raise SystemExit("FAT chain of a file is shorter than its size")
        return ext

    def dir_bytes(self, c):
        if c == 0 and not self.fat32:                    # the fixed FAT16 root directory
            return self.rd((self.rsvd + self.nfats * self.fatsz) * self.bps, self.root_sectors * self.bps)
        if c == 0:
            c = self.rootclus
        return b"".join(self.rd(self.clus_off(x), self.csize) for x in self.chain(c))

    def walk(self, c=0, prefix=""):
        d = self.dir_bytes(c)
        lfn = {}
        csum = None
        for i in range(0, len(d), 32):
            e = d[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn = {}
                continue
            attr = e[11]
            if attr == 0x0f:
                seq = e[0] & 0x1f
                part = e[1:11] + e[14:26] + e[28:32]
                lfn[seq] = part.decode("utf-16-le")
                csum = e[13]
                continue
            if attr & 0x08:                              # volume label
                lfn = {}
                continue
            raw = bytes(e[0:11])
            if raw[0] == 0x05:
                raw = b"\xe5" + raw[1:]
            name = None
            if lfn:
                s = 0
                for ch in raw:
                    s = (((s & 1) << 7) + (s >> 1) + ch) & 0xff
                if s == csum:
                    name = "".join(lfn[k] for k in sorted(lfn))
                    name = name.split("\x00")[0].split("￿")[0]
            if name is None:
                base = raw[:8].decode("cp437").rstrip()
                ext = raw[8:11].decode("cp437").rstrip()
                if e[12] & 0x08:
                    base = base.lower()
                if e[12] & 0x10:
                    ext = ext.lower()
                name = base + ("." + ext if ext else "")
            lfn = {}
            if name in (".", ".."):
                continue
            hi, = struct.unpack_from("<H", e, 20)
            lo, = struct.unpack_from("<H", e, 26)
            first = (hi << 16 | lo) if self.fat32 else lo
            size, = struct.unpack_from("<I", e, 28)
            path = prefix + name
            if attr & 0x10:
                yield from self.walk(first, path + "/")
            else:
                yield path, size, first


def fwtable(img):
    """blob read by the kernel (fw_table_load in TopazModem.cpp), all little endian:
       "SPESFWT1" u32 nfiles u32 next u32 nstr
       nfiles * { u32 name_off, size, ext, next }   (ext/next: index and count into the extents)
       next   * { u32 off, len }                    (byte offsets in modem_a)
       nstr bytes of NUL-terminated names"""
    with open(img, "rb") as f:
        fat = Fat(f)
        files = list(fat.walk())
        ents, exts, strs = [], [], bytearray()
        for path, size, first in files:
            nm = path.encode()
            if len(nm) > 120:
                print("skipping long path", path)
                continue
            e = fat.extents(first, size) if size else []
            if any(o >= 1 << 32 or o + l >= 1 << 32 for o, l in e):
                raise SystemExit("modem_a is over 4 GiB?")
            ents.append((len(strs), size, len(exts), len(e)))
            exts.extend(e)
            strs += nm + b"\0"
    blob = FWT_MAGIC + struct.pack("<III", len(ents), len(exts), len(strs))
    for t in ents:
        blob += struct.pack("<IIII", *t)
    for o, l in exts:
        blob += struct.pack("<II", o, l)
    blob += bytes(strs)
    return blob, files


# ------------------------------------------------------------------ the card

def mbr_parts(dev):
    dev.seek(0)
    s = dev.read(512)
    if s[510:512] != b"\x55\xaa":
        raise SystemExit("no MBR on the card (the root partition is type 0xAF in an MBR)")
    out = []
    for i in range(4):
        e = s[446 + 16 * i: 462 + 16 * i]
        typ = e[4]
        lba, n = struct.unpack("<II", e[8:16])
        if typ and n:
            out.append((i + 1, typ, lba, n))
    return out


def card_sectors(dev):
    return dev.seek(0, 2) // SECTOR


def plan(dev, sizes):
    total = card_sectors(dev)
    hdr = total - LOG_SECTORS - DTB_SECTORS - 1
    cur = hdr
    layout = []
    for name in reversed(sizes):                          # laid out downwards from the header
        n = (sizes[name] + SECTOR - 1) // SECTOR
        cur = (cur - n) // ALIGN * ALIGN
        layout.append((name, cur, sizes[name]))
    layout.reverse()
    return total, hdr, layout


def header(layout):
    h = MAGIC + struct.pack("<II", len(layout), 0)
    for name, lba, size in layout:
        h += name.encode().ljust(16, b"\0") + struct.pack("<QQ", lba, size)
    if len(h) > SECTOR:
        raise SystemExit("too many entries")
    return h.ljust(SECTOR, b"\0")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("disk", nargs="?")
    ap.add_argument("--dir", default=".")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--table-only", metavar="OUT", help="write the fwtable blob of --dir/modem_a.img and stop")
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    files = {p: os.path.join(a.dir, p + ".img") for p in PARTS}
    for p, fn in files.items():
        if not os.path.isfile(fn):
            raise SystemExit("missing %s" % fn)
    blob, flist = fwtable(files["modem_a"])
    print("modem_a: %d files in the FAT volume, table %d bytes" % (len(flist), len(blob)))
    need = {"image/modem.mdt", "image/wlanmdsp.mbn", "image/bdwlan.bin"}
    have = {p.lower() for p, _, _ in flist}
    for n in sorted(need - have):
        print("WARNING: %s is not in modem_a" % n)
    if a.table_only:
        open(a.table_only, "wb").write(blob)
        return
    if not a.disk:
        raise SystemExit("give the disk, e.g. /dev/sdb")
    if a.disk[-1].isdigit() and not a.disk.startswith("/dev/mmcblk") and not a.disk.startswith("/dev/nvme"):
        raise SystemExit("%s looks like a partition: give the whole disk (e.g. /dev/sdb)" % a.disk)

    sizes = {p: os.path.getsize(files[p]) for p in PARTS}
    sizes["fwtable"] = len(blob)
    with open(a.disk, "rb") as dev:
        parts = mbr_parts(dev)
        total, hdr, layout = plan(dev, sizes)
    print("card: %d sectors (%.1f GiB)" % (total, total * SECTOR / 2**30))
    for n, typ, lba, cnt in parts:
        print("  partition %d: type 0x%02x, sectors %d..%d" % (n, typ, lba, lba + cnt - 1))
    lowest = layout[0][1]
    for n, typ, lba, cnt in parts:
        if lba + cnt > lowest:
            raise SystemExit("the card is too small: partition %d reaches sector %d but the modem pack needs sector %d on" % (n, lba + cnt - 1, lowest))
    for name, lba, size in layout:
        print("  %-9s sectors %d..%d  (%d bytes)" % (name, lba, lba + (size + SECTOR - 1) // SECTOR - 1, size))
    print("  header    sector %d" % hdr)
    if not a.write:
        print("dry run: nothing written. Add --write to write it.")
        return

    data = dict((p, files[p]) for p in PARTS)
    with open(a.disk, "r+b", buffering=0) as dev:
        # the header goes last, so a half-written pack is never used
        dev.seek(hdr * SECTOR)
        dev.write(b"\0" * SECTOR)
        for name, lba, size in layout:
            dev.seek(lba * SECTOR)
            if name == "fwtable":
                dev.write(blob.ljust((size + SECTOR - 1) // SECTOR * SECTOR, b"\0"))
                continue
            with open(data[name], "rb") as f:
                done = 0
                while True:
                    b = f.read(1 << 20)
                    if not b:
                        break
                    dev.write(b)
                    done += len(b)
                pad = -done % SECTOR
                if pad:
                    dev.write(b"\0" * pad)
            print("wrote", name)
        os.fsync(dev.fileno())
        dev.seek(hdr * SECTOR)
        dev.write(header(layout))
        os.fsync(dev.fileno())
    print("verifying...")
    with open(a.disk, "rb") as dev:
        dev.seek(hdr * SECTOR)
        if dev.read(SECTOR) != header(layout):
            raise SystemExit("VERIFY FAILED: header")
        for name, lba, size in layout:
            h = hashlib.sha256()
            dev.seek(lba * SECTOR)
            left = size
            while left:
                b = dev.read(min(left, 1 << 20))
                if not b:
                    raise SystemExit("VERIFY FAILED: short read of " + name)
                h.update(b)
                left -= len(b)
            want = hashlib.sha256(blob).hexdigest() if name == "fwtable" else sha(data[name])
            if h.hexdigest() != want:
                raise SystemExit("VERIFY FAILED: " + name)
    print("OK: the modem pack is on the card (verified).")


# ------------------------------------------------------------------ self test

def mkfat(path, files, fat32=False, frag=False):
    """tiny FAT16/FAT32 writer for the self test: files = {"image/a.b00": bytes}"""
    import random
    bps, spc = 512, 4
    nclus = 70000 if fat32 else 20000
    rsvd = 32 if fat32 else 4
    fatsz = ((nclus + 2) * (4 if fat32 else 2) + bps - 1) // bps
    rootents = 0 if fat32 else 512
    root_sec = rootents * 32 // bps
    data_start = rsvd + 2 * fatsz + root_sec
    total = data_start + nclus * spc
    img = bytearray(total * bps)
    bs = bytearray(512)
    bs[0:3] = b"\xeb\x3c\x90"
    bs[3:11] = b"MSDOS5.0"
    struct.pack_into("<HBHBHHBH", bs, 11, bps, spc, rsvd, 2, rootents, 0 if fat32 or total > 65535 else total, 0xf8, 0 if fat32 else fatsz)
    struct.pack_into("<I", bs, 32, total)
    if fat32:
        struct.pack_into("<I", bs, 36, fatsz)
        struct.pack_into("<I", bs, 44, 2)
    bs[510:512] = b"\x55\xaa"
    img[0:512] = bs
    fat = [0] * (nclus + 2)
    fat[0], fat[1] = 0xfffffff8 if fat32 else 0xfff8, 0xffffffff if fat32 else 0xffff
    eoc = 0x0fffffff if fat32 else 0xffff
    free = list(range(2, nclus + 2))
    if frag:
        random.Random(1).shuffle(free)
    nxt = [0]

    def alloc(n):
        cl = [free.pop(0) for _ in range(max(n, 1))]
        for a, b in zip(cl, cl[1:]):
            fat[a] = b
        fat[cl[-1]] = eoc
        return cl

    def put(cl, data):
        for i, c in enumerate(cl):
            o = (data_start + (c - 2) * spc) * bps
            chunk = data[i * spc * bps:(i + 1) * spc * bps]
            img[o:o + len(chunk)] = chunk

    def lfn_entries(name, short):
        s = 0
        for ch in short:
            s = (((s & 1) << 7) + (s >> 1) + ch) & 0xff
        u = name.encode("utf-16-le") + b"\0\0"
        u = u.ljust(((len(u) + 25) // 26) * 26, b"\xff")
        n = len(u) // 26
        out = []
        for k in range(n, 0, -1):
            p = u[(k - 1) * 26:k * 26]
            e = bytearray(32)
            e[0] = k | (0x40 if k == n else 0)
            e[1:11] = p[0:10]
            e[11] = 0x0f
            e[13] = s
            e[14:26] = p[10:22]
            e[28:32] = p[22:26]
            out.append(bytes(e))
        return out

    def mkdir(tree):
        ents = b""
        for name, v in tree.items():
            nxt[0] += 1
            short = ("F%07d" % nxt[0]).encode() + b"   "
            lower = name.lower() == name and name.upper().replace(".", "")[:8] == name.upper().replace(".", "")
            if isinstance(v, dict):
                sub = mkdir(v)
                cl = alloc((len(sub) + spc * bps - 1) // (spc * bps))
                put(cl, sub)
                first, size, attr = cl[0], 0, 0x10
            else:
                cl = alloc((len(v) + spc * bps - 1) // (spc * bps)) if v else [0]
                if v:
                    put(cl, v)
                first, size, attr = cl[0], len(v), 0x20
            ents += b"".join(lfn_entries(name, short))
            e = bytearray(32)
            e[0:11] = short
            e[11] = attr
            struct.pack_into("<H", e, 20, first >> 16)
            struct.pack_into("<H", e, 26, first & 0xffff)
            struct.pack_into("<I", e, 28, size)
            ents += bytes(e)
        return ents

    tree = {}
    for p, d in files.items():
        t = tree
        parts = p.split("/")
        for x in parts[:-1]:
            t = t.setdefault(x, {})
        t[parts[-1]] = d
    root = mkdir(tree)
    if fat32:
        cl = alloc((len(root) + spc * bps - 1) // (spc * bps))
        # root must be cluster 2
        put(cl, root)
        struct.pack_into("<I", bs, 44, cl[0])
        img[0:512] = bs
    else:
        o = (rsvd + 2 * fatsz) * bps
        img[o:o + len(root)] = root
    fmt = "<%dI" % len(fat) if fat32 else "<%dH" % len(fat)
    fb = struct.pack(fmt, *fat)
    for i in range(2):
        o = (rsvd + i * fatsz) * bps
        img[o:o + len(fb)] = fb
    open(path, "wb").write(img)


def selftest():
    import random, tempfile
    r = random.Random(7)
    files = {
        "image/modem.mdt": bytes(r.getrandbits(8) for _ in range(9100)),
        "image/bdwlan.102": bytes(r.getrandbits(8) for _ in range(40000)),
        "image/wlanmdsp.mbn": bytes(r.getrandbits(8) for _ in range(300000)),
        "image/empty.bin": b"",
        "readonly/Mixed.Case.File": b"abc" * 1000,
        "a/b/c/deep.txt": b"deep" * 5000,
    }
    for fat32 in (False, True):
        for frag in (False, True):
            with tempfile.TemporaryDirectory() as td:
                p = os.path.join(td, "m.img")
                mkfat(p, files, fat32, frag)
                blob, flist = fwtable(p)
                assert blob[:8] == FWT_MAGIC
                n, ne, ns = struct.unpack_from("<III", blob, 8)
                assert n == len(files), (n, len(files))
                eo = 20 + 16 * n
                so = eo + 8 * ne
                img = open(p, "rb").read()
                for i in range(n):
                    no, size, ex, nex = struct.unpack_from("<IIII", blob, 20 + 16 * i)
                    name = blob[so + no: blob.index(b"\0", so + no)].decode()
                    got = b""
                    for k in range(nex):
                        off, ln = struct.unpack_from("<II", blob, eo + 8 * (ex + k))
                        got += img[off:off + ln]
                    assert got == files[name], name
                print("selftest FAT%d%s: %d files, %d extents OK" % (32 if fat32 else 16, " fragmented" if frag else "", n, ne))
    print("selftest passed")


if __name__ == "__main__":
    main()
