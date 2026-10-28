#!/usr/bin/env python3
"""Read code out of the iOS dyld shared cache on the SD card, read-only (nothing is written to the card).

  sudo python3 tools/sweet-dsc-peek.py /dev/sdb1 > dsc-peek.txt

Mounts the HFS+ root read-only, finds the shared cache, prints which dylib each unslid address is in and
hex words around it. The addresses are the Settings SIGTRAP: pc 0x1cdc47da8, lr 0x1cdc47d10, caller 0x1cdc18958.
"""
import glob, os, struct, subprocess, sys, tempfile

ADDRS = [0x1cdc47da8, 0x1cdc47d10, 0x1cdc18958]
WINDOWS = {0x1cdc47da8: (0x300, 0x80), 0x1cdc47d10: (0x0, 0x0), 0x1cdc18958: (0x100, 0x40)}

def main():
    part = sys.argv[1]
    mnt = tempfile.mkdtemp()
    subprocess.run(["mount", "-t", "hfsplus", "-o", "ro,force", part, mnt], check=True)
    try:
        files = sorted(glob.glob(mnt + "/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64*"))
        files = [f for f in files if not f.endswith(".map")]
        if not files:
            files = sorted(glob.glob(mnt + "/**/dyld_shared_cache_arm64*", recursive=True))
        print("cache files:", files)
        main_file = None
        maps = []  # (file, addr, size, fileoff)
        for f in files:
            with open(f, "rb") as fh:
                h = fh.read(0x200)
                if h[:4] != b"dyld":
                    continue
                moff, mcnt = struct.unpack_from("<II", h, 0x10)
                fh.seek(moff)
                for i in range(mcnt):
                    a, s, o, _, _, _ = struct.unpack("<QQQIII", fh.read(32))
                    maps.append((f, a, s, o))
                if main_file is None:
                    main_file = f
        print("mappings:", len(maps))
        # images (main file)
        with open(main_file, "rb") as fh:
            h = fh.read(0x200)
            ioff, icnt = struct.unpack_from("<II", h, 0x18)
            if ioff == 0:
                ioff, icnt = struct.unpack_from("<II", h, 0x1c0)
            fh.seek(ioff)
            imgs = []
            for i in range(icnt):
                a, mt, ino, po, pad = struct.unpack("<QQQII", fh.read(32))
                imgs.append((a, po))
            for a in ADDRS:
                best = max((x for x in imgs if x[0] <= a), key=lambda x: x[0], default=None)
                if best:
                    fh.seek(best[1])
                    path = fh.read(200).split(b"\0")[0].decode(errors="replace")
                    print("addr %#x is in image %s (base %#x, +%#x)" % (a, path, best[0], a - best[0]))
        for a in ADDRS:
            before, after = WINDOWS[a]
            if before == 0 and after == 0:
                continue
            start, end = (a - before) & ~3, a + after
            for (f, ma, ms, mo) in maps:
                if ma <= start and end <= ma + ms:
                    with open(f, "rb") as fh:
                        fh.seek(mo + (start - ma))
                        data = fh.read(end - start)
                    for i in range(0, len(data), 32):
                        print("CODE %#x: %s" % (start + i, " ".join("%08x" % w for w in struct.unpack("<%dI" % (len(data[i:i+32]) // 4), data[i:i+32]))))
                    break
            else:
                print("addr %#x not in any mapping" % a)
    finally:
        subprocess.run(["umount", mnt])
        os.rmdir(mnt)

main()
