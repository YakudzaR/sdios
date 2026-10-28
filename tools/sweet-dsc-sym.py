#!/usr/bin/env python3
"""Read-only: names for addresses in the iOS dyld shared cache on the SD card, plus C strings.

  sudo python3 tools/sweet-dsc-sym.py /dev/sdb1 sym 0x1cdc47da8 0x1cdc18958 ... str 0x182b1482d ...  > dsc-sym.txt

'sym' addresses: the nearest local symbol at or before the address (from the .symbols file) and the image.
'str' addresses: the C string there. Nothing is written to the card.
"""
import glob, os, struct, subprocess, sys, tempfile

def main():
    part = sys.argv[1]
    syms, strs, cur = [], [], None
    for a in sys.argv[2:]:
        if a in ("sym", "str"):
            cur = syms if a == "sym" else strs
        else:
            cur.append(int(a, 16))
    mnt = tempfile.mkdtemp()
    subprocess.run(["mount", "-t", "hfsplus", "-o", "ro,force", part, mnt], check=True)
    try:
        d = mnt + "/System/Library/Caches/com.apple.dyld/"
        files = sorted(f for f in glob.glob(d + "dyld_shared_cache_arm64*") if not f.endswith(".map"))
        maps = []
        for f in files:
            with open(f, "rb") as fh:
                h = fh.read(0x200)
                if h[:4] != b"dyld":
                    continue
                moff, mcnt = struct.unpack_from("<II", h, 0x10)
                fh.seek(moff)
                for i in range(mcnt):
                    a, s, o, _, _ = struct.unpack("<QQQII", fh.read(32))
                    maps.append((f, a, s, o))
        def read(addr, n):
            for (f, a, s, o) in maps:
                if a <= addr < a + s:
                    with open(f, "rb") as fh:
                        fh.seek(o + addr - a)
                        return fh.read(min(n, a + s - addr))
            return b""
        for a in strs:
            print("STR %#x: %r" % (a, read(a, 160).split(b"\0")[0]))
        main_file = files[0]
        with open(main_file, "rb") as fh:
            h = fh.read(0x200)
            ioff, icnt = struct.unpack_from("<II", h, 0x18)
            if ioff == 0:
                ioff, icnt = struct.unpack_from("<II", h, 0x1c0)
            fh.seek(ioff)
            imgs = [struct.unpack("<QQQII", fh.read(32))[0] for _ in range(icnt)]
            base_addr = struct.unpack_from("<Q", h, 0x10 + 0)[0] if False else None
        sym_file = [f for f in files if f.endswith(".symbols")][0]
        with open(sym_file, "rb") as fh:
            h = fh.read(0x200)
            lso, lss = struct.unpack_from("<QQ", h, 0x48)
            fh.seek(lso)
            info = fh.read(24)
            nlo, nlc, sto, sts, eno, enc = struct.unpack("<IIIIII", info)
            fh.seek(lso + eno)
            ents = [struct.unpack("<QII", fh.read(16)) for _ in range(enc)]
            for a in syms:
                img = max((x for x in imgs if x <= a), default=None)
                off = img - 0x180000000
                ent = [e for e in ents if e[0] == off]
                if not ent:
                    print("SYM %#x: no entry for image %#x" % (a, img))
                    continue
                _, start, cnt = ent[0]
                fh.seek(lso + nlo + 16 * start)
                raw = fh.read(16 * cnt)
                best = None
                for i in range(cnt):
                    strx, typ, sect, desc, val = struct.unpack_from("<IBBHQ", raw, 16 * i)
                    if val <= a and (best is None or val > best[0]):
                        best = (val, strx)
                if best:
                    fh.seek(lso + sto + best[1])
                    name = fh.read(300).split(b"\0")[0].decode(errors="replace")
                    print("SYM %#x: %s + %#x (image base %#x)" % (a, name, a - best[0], img))
                else:
                    print("SYM %#x: no symbol" % a)
    finally:
        subprocess.run(["umount", mnt])
        os.rmdir(mnt)

main()
