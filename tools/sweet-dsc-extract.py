#!/usr/bin/env python3
"""Read-only: copy a few dylibs' segments out of the iOS dyld shared cache on the SD card into a tar.gz.

  sudo python3 tools/sweet-dsc-extract.py /dev/sdb1 OUT.tar.gz MediaPlayer.framework/MediaPlayer MediaLibraryCore.framework/MediaLibraryCore

Mounts the HFS+ root read-only (nothing is written to the card). For every image whose path ends with one of the
names, the file gets meta.txt (segments and sections) and one .bin per segment (not __LINKEDIT).
"""
import glob, io, os, struct, subprocess, sys, tarfile, tempfile

def main():
    part, out, names = sys.argv[1], sys.argv[2], sys.argv[3:]  # a name starting with ? only lists images containing that text
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
            res = b""
            while n > 0:
                for (f, a, s, o) in maps:
                    if a <= addr < a + s:
                        k = min(n, a + s - addr)
                        with open(f, "rb") as fh:
                            fh.seek(o + addr - a)
                            res += fh.read(k)
                        addr += k; n -= k
                        break
                else:
                    break
            return res
        with open(files[0], "rb") as fh:
            h = fh.read(0x200)
            ioff, icnt = struct.unpack_from("<II", h, 0x18)
            if ioff == 0:
                ioff, icnt = struct.unpack_from("<II", h, 0x1c0)
            fh.seek(ioff)
            imgs = [struct.unpack("<QQQII", fh.read(32)) for _ in range(icnt)]
            found = []
            for (a, mt, ino, po, pad) in imgs:
                fh.seek(po)
                p = fh.read(300).split(b"\0")[0].decode(errors="replace")
                if any(p.endswith(n) for n in names if not n.startswith("?")):
                    found.append((a, p))
                for n in names:
                    if n.startswith("?") and n[1:].lower() in p.lower():
                        print("image", p, file=sys.stderr)
        with tarfile.open(out, "w:gz") as tf:
            def add(name, data):
                ti = tarfile.TarInfo(name); ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
            for a, p in found:
                tag = p.strip("/").replace("/", "_")
                hdr = read(a, 0x4000)
                ncmds = struct.unpack_from("<I", hdr, 16)[0]
                off, meta = 32, ["image %s base %#x" % (p, a)]
                for i in range(ncmds):
                    cmd, sz = struct.unpack_from("<II", hdr, off)
                    if cmd == 0x19:
                        seg = hdr[off + 8:off + 24].split(b"\0")[0].decode()
                        vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", hdr, off + 24)
                        nsects = struct.unpack_from("<I", hdr, off + 64)[0]
                        meta.append("segment %s %#x %#x" % (seg, vmaddr, vmsize))
                        for s in range(nsects):
                            so = off + 72 + 80 * s
                            sn = hdr[so:so + 16].split(b"\0")[0].decode()
                            saddr, ssize = struct.unpack_from("<QQ", hdr, so + 32)
                            meta.append("  section %s %#x %#x" % (sn, saddr, ssize))
                        if seg != "__LINKEDIT":
                            add("%s/%s_%x.bin" % (tag, seg, vmaddr), read(vmaddr, vmsize))
                    off += sz
                add("%s/meta.txt" % tag, "\n".join(meta).encode())
                print("done", p, file=sys.stderr)
    finally:
        subprocess.run(["umount", mnt])
        os.rmdir(mnt)

main()
