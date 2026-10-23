#!/usr/bin/env python3
"""Pack an arm64 Image into an Android boot image v3/v4 (empty ramdisk)."""
import argparse, struct

def pad(b, n=4096):
    return b + b'\0' * (-len(b) % n)

ap = argparse.ArgumentParser()
ap.add_argument('--kernel', required=True)
ap.add_argument('--version', type=int, choices=(3, 4), default=4)
ap.add_argument('--cmdline', default='')
ap.add_argument('--out', required=True)
a = ap.parse_args()

kernel = open(a.kernel, 'rb').read()
hdr_size = 1580 if a.version == 3 else 1584
cmd = a.cmdline.encode()
assert len(cmd) < 1536
hdr = b'ANDROID!'
hdr += struct.pack('<IIII', len(kernel), 0, 0, hdr_size)   # kernel, ramdisk, os_version, header_size
hdr += struct.pack('<4I', 0, 0, 0, 0)                      # reserved
hdr += struct.pack('<I', a.version)
hdr += cmd.ljust(1536, b'\0')
if a.version >= 4:
    hdr += struct.pack('<I', 0)                            # boot_signature_size
assert len(hdr) == hdr_size
open(a.out, 'wb').write(pad(hdr) + pad(kernel))
print(f'{a.out}: v{a.version}, kernel {len(kernel)} bytes')
